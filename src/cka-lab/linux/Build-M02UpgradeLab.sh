#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/cka.sh"

usage() {
    printf '%s\n' 'Usage: bash linux/Build-M02UpgradeLab.sh --yes [options]
Destroy and rebuild the libvirt lab at v1.34, initialize/join it, wait for Ready,
and save a halted m02-pre-upgrade snapshot. ALL existing snapshots are lost.
  --package-version VERSION  Exact v1.34 apt version (default: 1.34.6-1.1)
  --snapshot-name NAME       Re-record point (default: m02-pre-upgrade)
  --skip-snapshot            Leave the ready cluster running without saving
  --yes                     Required authorization for destruction
  --dry-run                 Print operations only; --yes is still required
  --non-interactive         Disable pauses (this build has no recording pauses)
  --export-baseline         REFUSED: no verified libvirt export is implemented
  --help                    Show this help
Preserve a baseline in a separate lab directory with independently named VMs
and a verified offline copy of ALL disks/configuration, tested for restoration,
before rebuilding. Copying the repository or taking a snapshot is NOT a backup.
Requires Vagrant/libvirt, network/package access and Linux snapshot/start wrappers.
Version environment overrides are scoped to provisioning, not your shell.'
}
package_version=1.34.6-1.1
snapshot_name=m02-pre-upgrade
skip_snapshot=0
export_baseline=0
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --skip-snapshot) skip_snapshot=1 ;;
        --export-baseline) export_baseline=1 ;;
        --package-version|--snapshot-name)
            (($# >= 2)) && [[ -n $2 ]] || lab_die "Missing value for $1"
            case $1 in --package-version) package_version=$2 ;; --snapshot-name) snapshot_name=$2 ;; esac
            shift ;;
        *) lab_die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done
[[ $export_baseline == 0 ]] || lab_die 'Baseline export is unsupported. Before destruction, preserve a separate lab copy with independently named VMs and verified offline disk/config backups; test its restore. See --help. Nothing destroyed.'
[[ $YES == 1 ]] || lab_die 'Rebuild requires --yes, including --dry-run. ALL current VMs and snapshots will be lost.'
[[ $package_version =~ ^1\.34\.[0-9]+-[0-9]+\.[0-9]+$ ]] || lab_die 'Package must be an exact v1.34 apt version, such as 1.34.6-1.1.'
[[ $snapshot_name =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || lab_die 'Unsafe snapshot name.'
grep -Fqx 'sudo kubeadm init \' "$LAB_ROOT/bootstrap_cp.sh" || lab_die 'Bootstrap init command changed; review exact-version injection before destruction.'
bootstrap_text=$(sed "s/^sudo kubeadm init /sudo kubeadm init --kubernetes-version=v${package_version%%-*} /" "$LAB_ROOT/bootstrap_cp.sh")
wrapper_args=()
[[ $DRY_RUN == 0 ]] || wrapper_args+=(--dry-run)
if [[ $skip_snapshot == 0 && $DRY_RUN == 0 ]]; then
    [[ -f $SCRIPT_DIR/Save-CkaSnapshot.sh ]] || lab_die 'Missing linux/Save-CkaSnapshot.sh; install the snapshot wrapper before rebuilding.'
fi
lab_warn 'Destroy removes ALL lab VMs and snapshots, including your v1.35 baseline. No export is performed.'
lab_confirm 'Destroy the current lab and rebuild at v1.34?'
lab_step 'Destroy current VMs'
lab_run lab_vagrant destroy -f
lab_step "Provision v1.34 ($package_version)"
(
    export CKA_K8S_MINOR=1.34 CKA_K8S_PKG_VERSION="$package_version"
    lab_run lab_vagrant up --provider=libvirt
)
lab_step 'Initialize control plane, join every worker, and wait for readiness'
lab_command "$CP_NODE" "set -euo pipefail
export CP_IP='$CP_IP'
$bootstrap_text"
if [[ $DRY_RUN == 1 ]]; then
    lab_info 'Would fetch a fresh kubeadm join command from the control plane and join every worker.'
else
    join_command=$(lab_command "$CP_NODE" 'set -euo pipefail
sudo kubeadm token create --print-join-command')
    [[ $join_command == kubeadm\ join\ * && $join_command != *$'\n'* ]] || lab_die 'Invalid join command from control plane.'
    for worker in "${LAB_NODES[@]:1}"; do
        lab_command "$worker" "set -euo pipefail
sudo $join_command"
    done
fi
lab_ready
lab_command "$CP_NODE" "set -euo pipefail
kubectl get nodes
test \"\$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}' | grep -Fxc 'v${package_version%%-*}')\" -eq ${#LAB_NODES[@]}"
if [[ $skip_snapshot == 0 ]]; then
    lab_step "Save $snapshot_name (leaves machines halted)"
    lab_run bash "$SCRIPT_DIR/Save-CkaSnapshot.sh" "$snapshot_name" --yes "${wrapper_args[@]}"
    if [[ $DRY_RUN == 1 ]]; then
        lab_info 'Dry run complete; no machines were changed or health verified. A real snapshot leaves machines halted.'
    else
        lab_info 'Build complete; machines are halted. The upgrade demo restores and starts them.'
    fi
else
    if [[ $DRY_RUN == 1 ]]; then
        lab_info 'Dry run complete; no machines were changed or health verified.'
    else
        lab_info 'Build complete; cluster is running without a re-record snapshot.'
    fi
fi