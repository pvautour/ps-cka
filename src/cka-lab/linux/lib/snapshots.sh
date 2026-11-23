#!/usr/bin/env bash

snapshot_main() {
    local operation=$1
    shift
    local snapshot_name=pre-cluster name_set=0 prune=0 key target name found count
    local -a names=() keep=(pre-cluster m02-pre-upgrade) targets=()
    while (($#)); do
        case $1 in
            --help|-h)
                printf 'Usage: bash linux/%s-CkaSnapshot.sh [NAME] [options]\n' "$operation"
                printf '%s\n' '--dry-run  Read-only preflight and operation plan.' '--yes  Confirm save, restore or delete without prompting.'
                if [[ $operation == Remove ]]; then printf '%s\n' '--prune  Remove all except protected names.' '--keep NAME  Replace default protection list; repeat to protect multiple names.' '--keep-none  Explicitly allow removal of baseline names.' 'Without names or --prune: read-only inventory.'; fi
                printf '%s\n' 'Save/restore/delete preflight all VMs and snapshots before halting.' 'Save/restore leave all VMs halted, including after partial failure. Start explicitly.' 'Operations are sequential, NOT transactional; --dry-run changes nothing.'
                return 0 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes) YES=1 ;;
            --prune) [[ $operation == Remove ]] || lab_die '--prune is only for Remove.'; prune=1 ;;
            --keep)
                [[ $operation == Remove && $# -ge 2 && $2 != --* ]] || lab_die 'Invalid --keep option.'
                [[ ${keep_custom:-0} == 1 ]] || keep=()
                keep_custom=1; keep+=("$2"); shift ;;
            --keep-none) [[ $operation == Remove ]] || lab_die '--keep-none is only for Remove.'; keep=(); keep_custom=1 ;;
            --*) lab_die "Unknown option: $1" ;;
            *)
                [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || lab_die 'Unsafe snapshot name.'
                names+=("$1"); snapshot_name=$1; name_set=1 ;;
        esac
        shift
    done
    [[ $operation == Remove || ${#names[@]} -le 1 ]] || lab_die 'Only one snapshot name is allowed.'
    [[ $prune == 0 || ${#names[@]} == 0 ]] || lab_die 'Choose names or --prune, not both.'
    if [[ $operation != Get && ! ( $operation == Remove && $name_set == 0 && $prune == 0 ) ]]; then lab_lock; fi
    lab_preflight
    lab_domains
    lab_snapshot_inventory
    if [[ $operation == Get || $operation == Remove ]]; then
        printf '%-32s %s\n' SNAPSHOT NODES
        local -A distinct=()
        for key in "${!LAB_SNAPSHOTS[@]}"; do distinct["${key#*/}"]=1; done
        for name in "${!distinct[@]}"; do
            [[ $operation != Get || $name_set == 0 || $name == "$snapshot_name" ]] || continue
            count=0
            printf '%-32s' "$name"
            for target in "${LAB_NODES[@]}"; do
                if [[ ${LAB_SNAPSHOTS[$target/$name]:-0} == 1 ]]; then printf ' %s' "$target"; count=$((count + 1)); fi
            done
            [[ $count == ${#LAB_NODES[@]} ]] || printf ' [PARTIAL]'
            printf '\n'
        done
        [[ $operation != Get ]] || return 0
        [[ $name_set == 1 || $prune == 1 ]] || return 0
        if [[ $prune == 1 ]]; then names=("${!distinct[@]}"); fi
        for name in "${names[@]}"; do
            found=0
            for key in "${keep[@]}"; do [[ $key != "$name" ]] || found=1; done
            if [[ $found == 1 ]]; then lab_warn "Protected snapshot skipped: $name"; continue; fi
            [[ ${distinct[$name]:-0} == 1 ]] || lab_die "Snapshot not found: $name. Nothing deleted."
            targets+=("$name")
        done
        [[ ${#targets[@]} -gt 0 ]] || return 0
    else
        for target in "${LAB_NODES[@]}"; do
            if [[ $operation == Save && ${LAB_SNAPSHOTS[$target/$snapshot_name]:-0} == 1 ]]; then lab_die "Snapshot already exists on $target: $snapshot_name. Nothing saved."; fi
            if [[ $operation == Restore && ${LAB_SNAPSHOTS[$target/$snapshot_name]:-0} != 1 ]]; then lab_die "Snapshot missing on $target: $snapshot_name. Nothing restored."; fi
        done
        targets=("$snapshot_name")
    fi
    lab_confirm "$operation snapshots (${targets[*]}) across the lab?"
    if [[ $DRY_RUN == 1 ]]; then lab_info "Would halt all VMs, then $operation: ${targets[*]}; leave halted."; return 0; fi
    lab_halt_all
    for name in "${targets[@]}"; do
        for target in "${LAB_NODES[@]}"; do
            case $operation in
                Save) lab_vagrant snapshot save "$target" "$name" || lab_die "Save failed on $target. All VMs remain halted; inspect partial snapshots." ;;
                Restore) lab_vagrant snapshot restore "$target" "$name" --no-start --no-provision || lab_die "Restore failed on $target. All VMs remain halted; resolve the partial restore." ;;
                Remove)
                    [[ ${LAB_SNAPSHOTS[$target/$name]:-0} == 1 ]] || continue
                    lab_vagrant snapshot delete "$target" "$name" || lab_die "Delete failed on $target. All VMs remain halted; inspect inventory." ;;
            esac
        done
    done
    lab_info "$operation complete. All VMs remain halted; use Start-CkaLab.sh when safe."
}