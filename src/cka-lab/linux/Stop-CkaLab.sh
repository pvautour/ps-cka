#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
while (($#)); do
    case $1 in
        --help|-h) printf 'Usage: bash linux/Stop-CkaLab.sh [--dry-run]\nGracefully halt all lab VMs; never destroys guests or snapshots.\n'; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        *) lab_die "Unknown option: $1" ;;
    esac
    shift
done
lab_lock
lab_run lab_vagrant halt "${LAB_NODES[@]}"