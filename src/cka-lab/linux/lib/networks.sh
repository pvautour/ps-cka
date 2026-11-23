#!/usr/bin/env bash

lab_network_check() {
    local network=$1 subnet=$2 network_xml
    network_xml=$(lab_virsh net-dumpxml "$network") || lab_die "Network missing: $network. Use create-nat-switch.sh --create --yes for first installation."
    printf '%s\n' "$network_xml" | python3 -c '
import ipaddress
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
ip = root.find("ip")
forward = root.find("forward")
if ip is None or forward is None or forward.get("mode") != "nat":
    sys.exit("Unexpected libvirt network configuration")
actual = ipaddress.ip_network(ip.attrib["address"] + "/" + (ip.get("prefix") or ip.attrib["netmask"]), strict=False)
if actual != ipaddress.ip_network(sys.argv[1]):
    sys.exit("Wrong network subnet; refusing changes")
if sys.argv[2] == "cka-management" and root.find("ip/dhcp/range") is None:
    sys.exit("Management DHCP missing")
print(root.find("bridge").attrib["name"])
    ' "$subnet" "$network"
}
lab_network_main() {
    local mode=$1 create=0 network subnet bridge index info route_json
    shift
    while (($#)); do
        case $1 in
            --help|-h)
                printf 'Usage: bash linux/%s.sh [--dry-run] [--yes]' "$mode"
                [[ $mode != create-nat-switch ]] || printf ' [--create]'
                printf '\n%s\n' 'Linux uses cka-management and cka-lab libvirt NAT networks, not Hyper-V switches.'
                printf '%s\n' 'Default: read-only network checks. --create boots/provisions all guests through Vagrant.' 'Repair starts/autostarts only existing, verified lab networks; never replaces XML or modifies UFW.' 'Requires normal-user permission for qemu:///system. Review host/VPN subnet collisions first.'
                return 0 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes) YES=1 ;;
            --create) [[ $mode == create-nat-switch ]] || lab_die '--create is only for creation.'; create=1 ;;
            *) lab_die "Unknown option: $1" ;;
        esac
        shift
    done
    if [[ $DRY_RUN == 1 ]]; then
        lab_info "Would verify lab network XML/subnets and host routes; $mode (create=$create). No networking or VM changes."
        return 0
    fi
    lab_require virsh
    lab_require ip
    lab_require python3
    lab_virsh net-list --all
    ip -4 route
    if [[ $create == 1 ]]; then
        local -a allowed_bridges=()
        local existing_networks
        existing_networks=$(lab_virsh net-list --all --name) || lab_die 'Cannot list libvirt networks.'
        for network in cka-management cka-lab; do
            if printf '%s\n' "$existing_networks" | grep -Fxq "$network"; then
                subnet=172.28.50.0/24
                [[ $network != cka-lab ]] || subnet=192.168.50.0/24
                bridge=$(lab_network_check "$network" "$subnet") || lab_die "Invalid network: $network"
                allowed_bridges+=("$bridge")
            fi
        done
        route_json=$(ip -j -4 route) || lab_die 'Cannot read host routes.'
        printf '%s\n' "$route_json" | ruby -rjson -ripaddr -e '
            subnets = [IPAddr.new("172.28.50.0/24"), IPAddr.new("192.168.50.0/24")]
            JSON.parse(STDIN.read).each do |route|
                next if route["dst"] == "default" || ARGV.include?(route["dev"])
                cidr = IPAddr.new(route.fetch("dst"))
                abort "Conflicting host route: #{route}; resolve before creation" if subnets.any? { |subnet| cidr.include?(subnet) || subnet.include?(cidr) }
            end
        ' "${allowed_bridges[@]}" || lab_die 'Host subnet collision; nothing created.'
        lab_confirm 'Create missing lab networks by booting/provisioning all guests?'
        lab_lock
        lab_vagrant up "${LAB_NODES[@]}" --provider=libvirt
    fi
    local -a networks=(cka-management cka-lab) subnets=(172.28.50.0/24 192.168.50.0/24) bridges=()
    for index in "${!networks[@]}"; do
        bridge=$(lab_network_check "${networks[$index]}" "${subnets[$index]}") || lab_die 'Network preflight failed; nothing repaired.'
        bridges+=("$bridge")
    done
    if [[ $mode == Repair-CkaNatSwitch ]]; then
        lab_confirm 'Start and enable autostart for verified libvirt lab networks?'
        lab_lock
    fi
    for index in "${!networks[@]}"; do
        network=${networks[$index]}
        if [[ $mode == Repair-CkaNatSwitch ]]; then
            info=$(LC_ALL=C lab_virsh net-info "$network") || lab_die "Cannot inspect $network"
            if ! grep -Eq '^Active:[[:space:]]+yes$' <<< "$info"; then lab_virsh net-start "$network"; fi
            lab_virsh net-autostart "$network"
        fi
        info=$(LC_ALL=C lab_virsh net-info "$network") || lab_die "Cannot inspect $network"
        grep -Eq '^Active:[[:space:]]+yes$' <<< "$info" || lab_die "$network is inactive."
        ip -j -4 addr show dev "${bridges[$index]}" | ruby -rjson -ripaddr -e '
            subnet = IPAddr.new(ARGV[0])
            addresses = JSON.parse(STDIN.read).flat_map { |link| link.fetch("addr_info", []) }
            abort "Bridge has no expected gateway address" unless addresses.any? { |addr| subnet.include?(addr.fetch("local")) && addr.fetch("local") == (subnet.to_i + 1).then { |value| IPAddr.new(value, Socket::AF_INET).to_s } }
        ' "${subnets[$index]}" || lab_die "Host bridge verification failed: ${bridges[$index]}"
        lab_info "$network active on ${bridges[$index]} (${subnets[$index]})"
    done
    lab_info 'Network checks passed. This does not verify UFW forwarding, guest DNS, or cross-node traffic; see TUTORIAL-LIBVIRT.md.'
}