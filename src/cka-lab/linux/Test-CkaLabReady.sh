#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
cluster=0
while (($#)); do
    case $1 in
        --help|-h) printf 'Usage: bash linux/Test-CkaLabReady.sh [--cluster] [--dry-run]\nRun lib/validate-node.sh on every VM over SSH stdin. --cluster also requires every Kubernetes node Ready.\n'; exit 0 ;;
        --cluster) cluster=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) lab_die "Unknown option: $1" ;;
    esac
    shift
done
[[ $DRY_RUN == 0 ]] || { lab_info "Would validate all nodes (cluster gate: $cluster)."; exit 0; }
failed=0
for node in "${LAB_NODES[@]}"; do
    lab_step "Validating $node"
    if lab_ssh "$node" < "$LAB_ROOT/lib/validate-node.sh"; then
        printf '[OK] %s PASS\n' "$node"
    else
        lab_warn "$node FAIL"
        failed=1
    fi
done
if [[ $cluster == 1 ]] && ! lab_ready; then failed=1; fi
[[ $failed == 0 ]] || lab_die 'Aggregate FAIL; do not save a baseline.'
lab_info 'Aggregate PASS.'