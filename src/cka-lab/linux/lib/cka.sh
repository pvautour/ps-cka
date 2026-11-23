#!/usr/bin/env bash

LAB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
EXERCISE_ROOT=$(cd -- "$LAB_ROOT/../.." && pwd)/exercise-files
DRY_RUN=${DRY_RUN:-0}
YES=${YES:-0}
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
LAB_NODES=()
LAB_IPS=()
while IFS=$'\t' read -r node_name node_ip; do
    LAB_NODES+=("$node_name")
    LAB_IPS+=("$node_ip")
done < <(ruby -rjson -e 'JSON.parse(File.read(ARGV[0])).each { |node| puts [node.fetch("Name"), node.fetch("IP")].join("\t") }' "$LAB_ROOT/lib/nodes.json")
[[ ${#LAB_NODES[@]} -gt 0 ]] || { printf '[ERROR] Cannot load lab topology; Ruby is required.\n' >&2; exit 1; }
CP_NODE=${LAB_NODES[0]}
CP_IP=${LAB_IPS[0]}

lab_info() { printf '[INFO] %s\n' "$*"; }
lab_warn() { printf '[WARN] %s\n' "$*" >&2; }
lab_die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
lab_step() { printf '\n[STEP] %s\n' "$*"; }
lab_require() { command -v "$1" >/dev/null || lab_die "Required command not found: $1"; }
lab_node() {
    local candidate
    for candidate in "${LAB_NODES[@]}"; do [[ $1 == "$candidate" ]] && return 0; done
    lab_die "Unknown lab node: $1"
}
lab_vagrant() {
    (cd -- "$LAB_ROOT" && VAGRANT_DEFAULT_PROVIDER=libvirt VAGRANT_CWD="$LAB_ROOT" VAGRANT_VAGRANTFILE="$LAB_ROOT/Vagrantfile" vagrant "$@")
}
lab_run() {
    if [[ $DRY_RUN == 1 ]]; then printf '[DRY RUN]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
lab_ssh() {
    lab_node "$1"
    lab_vagrant ssh "$1" -c 'bash -se -o pipefail'
}
lab_command() {
    local target=$1 command_text=$2
    if [[ $DRY_RUN == 1 ]]; then lab_info "Would run on $target: $command_text"; return; fi
    printf '%s\n' "$command_text" | lab_ssh "$target"
}
lab_confirm() {
    [[ $YES == 1 || $DRY_RUN == 1 ]] && return 0
    [[ -t 0 ]] || lab_die "$1 Re-run with --yes after reviewing the operation."
    local answer
    read -r -p "$1 Type yes to continue: " answer
    [[ $answer == yes ]] || lab_die 'Cancelled.'
}
lab_pause() {
    [[ $NON_INTERACTIVE == 1 || $DRY_RUN == 1 ]] && return 0
    [[ -t 0 ]] || lab_die 'Recording pauses need a terminal; use --non-interactive.'
    read -r -p 'Press Enter to continue...' </dev/tty
}
lab_beat() {
    lab_step "$1"
    lab_pause
    lab_command "$2" "$3"
}
lab_ready() {
    local ready_script node
    ready_script="deadline=\$((SECONDS + 240))
until kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1 &&
      test \"\$(kubectl --request-timeout=5s get nodes -o name | wc -l)\" -eq ${#LAB_NODES[@]}; do
    (( SECONDS < deadline )) || { echo '[ERROR] API or node registration timed out.' >&2; exit 1; }
    sleep 2
done"
    for node in "${LAB_NODES[@]}"; do ready_script+=$'\n'"kubectl wait --for=condition=Ready node/$node --timeout=240s"; done
    lab_command "$CP_NODE" "$ready_script"
}
lab_bootstrap() {
    [[ $DRY_RUN == 1 ]] && { lab_info 'Would bootstrap control plane, join workers, and wait for Ready nodes.'; return; }
    lab_ssh "$CP_NODE" < "$LAB_ROOT/bootstrap_cp.sh"
    local join_command worker
    join_command=$(lab_command "$CP_NODE" 'sudo kubeadm token create --print-join-command')
    [[ $join_command == kubeadm\ join\ * && $join_command != *$'\n'* ]] || lab_die 'Invalid join command returned by control plane.'
    for worker in "${LAB_NODES[@]:1}"; do lab_command "$worker" "sudo $join_command"; done
    lab_ready
}
lab_upload() {
    local source_dir=$1 target=$2 destination=$3 quoted_destination
    [[ -d $source_dir ]] || lab_die "Exercise directory missing: $source_dir"
    [[ $destination =~ ^/home/vagrant/[a-zA-Z0-9/_-]+$ ]] || lab_die 'Unsafe upload destination.'
    printf -v quoted_destination '%q' "$destination"
    if [[ $DRY_RUN == 1 ]]; then lab_info "Would upload $source_dir to $target:$destination"; return; fi
    lab_command "$target" "mkdir -p $quoted_destination"
    tar -C "$source_dir" -cf - . | lab_vagrant ssh "$target" -c "tar -xf - -C $quoted_destination"
}

lab_states() {
    local status_text
    status_text=$(lab_vagrant status --machine-readable) || lab_die 'Cannot read Vagrant status.'
    declare -gA LAB_STATES=()
    local timestamp target record value remainder
    while IFS=, read -r timestamp target record value remainder; do
        if [[ $record == state ]]; then LAB_STATES["$target"]=$value; fi
    done <<< "$status_text"
    for target in "${LAB_NODES[@]}"; do
        [[ -n ${LAB_STATES[$target]:-} ]] || lab_die "No state returned for $target."
    done
}
lab_preflight() {
    lab_states
    local target failed=0
    for target in "${LAB_NODES[@]}"; do
        case ${LAB_STATES[$target]} in
            running|poweroff|shutoff|saved|paused) lab_info "$target: ${LAB_STATES[$target]}" ;;
            *) lab_warn "$target: ${LAB_STATES[$target]} (VM unavailable)"; failed=1 ;;
        esac
    done
    [[ $failed == 0 ]] || lab_die 'Every lab VM must exist. Nothing changed.'
}
lab_virsh() { virsh -c qemu:///system "$@"; }
lab_domains() {
    lab_require virsh
    declare -gA LAB_DOMAINS=()
    local target domain_id
    for target in "${LAB_NODES[@]}"; do
        [[ -f $LAB_ROOT/.vagrant/machines/$target/libvirt/id ]] || lab_die "Missing libvirt ID for $target. Nothing changed."
        domain_id=$(< "$LAB_ROOT/.vagrant/machines/$target/libvirt/id")
        [[ $domain_id =~ ^[a-fA-F0-9-]{36}$ ]] || lab_die "Invalid libvirt UUID for $target."
        lab_virsh dominfo "$domain_id" >/dev/null || lab_die "Libvirt VM unavailable: $target"
        LAB_DOMAINS["$target"]=$domain_id
    done
}
lab_snapshot_inventory() {
    declare -gA LAB_SNAPSHOTS=()
    local target snapshot_list snapshot
    for target in "${LAB_NODES[@]}"; do
        snapshot_list=$(lab_virsh snapshot-list "${LAB_DOMAINS[$target]}" --name) || lab_die "Cannot list snapshots for $target."
        while IFS= read -r snapshot; do
            [[ -z $snapshot ]] || LAB_SNAPSHOTS["$target/$snapshot"]=1
        done <<< "$snapshot_list"
    done
}
lab_lock() {
    [[ $DRY_RUN == 1 ]] && return
    lab_require flock
    mkdir -p -- "$LAB_ROOT/.vagrant"
    exec {LAB_LOCK_FD}>"$LAB_ROOT/.vagrant/cka-linux.lock"
    flock -n "$LAB_LOCK_FD" || lab_die 'Another Linux management command is running.'
}
lab_halt_all() {
    lab_vagrant halt "${LAB_NODES[@]}" || lab_die 'Halt failed. No snapshot operation attempted; inspect all VM states.'
    lab_states
    local target
    for target in "${LAB_NODES[@]}"; do
        [[ ${LAB_STATES[$target]} == poweroff || ${LAB_STATES[$target]} == shutoff ]] || lab_die "$target is not halted. No snapshot operation attempted."
    done
}