#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
while (($#)); do
    case $1 in
        --help|-h) printf 'Usage: bash linux/Start-CkaLab.sh [--dry-run]\nBoot all libvirt VMs without re-provisioning. For first installation use vagrant up --provider=libvirt.\n'; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        *) lab_die "Unknown option: $1" ;;
    esac
    shift
done
lab_lock
lab_step 'Starting lab without provisioning'
lab_run lab_vagrant up "${LAB_NODES[@]}" --provider=libvirt --no-provision