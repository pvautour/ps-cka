#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
while (($#)); do
    case $1 in
        --help|-h) printf 'Usage: bash linux/Get-CkaConnectionInfo.sh [--dry-run]\nShow lab IPs, VM states and Vagrant SSH commands (management DHCP is separate).\n'; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        *) lab_die "Unknown option: $1" ;;
    esac
    shift
done
[[ $DRY_RUN == 0 ]] || { lab_info 'Would read VM states and SSH configuration.'; exit 0; }
lab_states
printf '%-12s %-16s %-14s %s\n' NODE LAB-IP STATE COMMAND
for index in "${!LAB_NODES[@]}"; do
    node=${LAB_NODES[$index]}
    printf '%-12s %-16s %-14s vagrant ssh %s\n' "$node" "${LAB_IPS[$index]}" "${LAB_STATES[$node]}" "$node"
    if [[ ${LAB_STATES[$node]} == running ]]; then lab_vagrant ssh-config "$node"; fi
done