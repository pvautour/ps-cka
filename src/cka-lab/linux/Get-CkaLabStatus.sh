#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
quiet=0
while (($#)); do
    case $1 in
        --help|-h) printf 'Usage: bash linux/Get-CkaLabStatus.sh [--quiet] [--dry-run]\nRead-only Vagrant state table. --quiet exits 1 if any VM is running. No teardown prompt.\n'; exit 0 ;;
        --quiet) quiet=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) lab_die "Unknown option: $1" ;;
    esac
    shift
done
[[ $DRY_RUN == 0 ]] || { lab_info 'Would read Vagrant VM state and host memory.'; exit 0; }
lab_states
printf '%-12s %-16s %s\n' NODE LAB-IP STATE
running=0
for index in "${!LAB_NODES[@]}"; do
    node=${LAB_NODES[$index]}
    printf '%-12s %-16s %s\n' "$node" "${LAB_IPS[$index]}" "${LAB_STATES[$node]}"
    [[ ${LAB_STATES[$node]} != running ]] || running=1
done
free -h
[[ $quiet == 0 || $running == 0 ]]