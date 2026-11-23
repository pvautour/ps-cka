#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/cka.sh"

usage() {
    printf '%s\n' 'Usage: bash linux/Invoke-M02Upgrade.sh [options]
Eight recording phases: control-plane-first model, etcd backup, repo, kubeadm,
plan/apply, control-plane kubelet, workers, and exact-version verification.
  --pre-upgrade-snapshot NAME  Default: m02-pre-upgrade
  --from-version MINOR         Default: 1.34
  --to-version MINOR           Default: 1.35; must be the next minor
  --to-package VERSION         Default: 1.35.0-1.1; must match --to-version
  --skip-restore               Use current state (not an automatic resume)
  --no-auto-snapshot           Disable all-node checkpoints after each node
  --yes                       Authorize restore and cluster mutations
  --non-interactive            Run without recording pauses
  --dry-run                    Print commands only, including missing wrappers
  --help                       Show help
Snapshot/start wrappers are required for real restores/boundaries. Saving halts
ALL machines; each boundary immediately starts them and waits for Ready again.
Snapshots are not atomic libvirt transactions or portable backups. The etcd
backup stays inside the control-plane VM and is lost on VM destruction.
Requires an existing kubeadm cluster, apt/network access and available packages.
Errors stop the demo; a failure may leave a node cordoned or partially upgraded.'
}
pre_snapshot=m02-pre-upgrade
from_version=1.34
to_version=1.35
to_package=1.35.0-1.1
skip_restore=0
auto_snapshot=1
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --skip-restore) skip_restore=1 ;;
        --no-auto-snapshot) auto_snapshot=0 ;;
        --pre-upgrade-snapshot|--from-version|--to-version|--to-package)
            (($# >= 2)) && [[ -n $2 ]] || lab_die "Missing value for $1"
            case $1 in
                --pre-upgrade-snapshot) pre_snapshot=$2 ;;
                --from-version) from_version=$2 ;;
                --to-version) to_version=$2 ;;
                --to-package) to_package=$2 ;;
            esac
            shift ;;
        *) lab_die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done
[[ $from_version =~ ^1\.([0-9]{1,2})$ ]] || lab_die 'Invalid source minor.'
from_minor=${BASH_REMATCH[1]}
[[ $to_version =~ ^1\.([0-9]{1,2})$ ]] || lab_die 'Invalid target minor.'
[[ $((10#${BASH_REMATCH[1]})) -eq $((10#$from_minor + 1)) ]] || lab_die 'Upgrade exactly one minor at a time.'
[[ $to_package =~ ^1\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ && ${to_package%.*-*} == "$to_version" ]] || lab_die 'Target package must match the target minor (for example 1.35.0-1.1).'
[[ $pre_snapshot =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || lab_die 'Unsafe snapshot name.'
target_patch=${to_package%%-*}
wrapper_args=()
[[ $DRY_RUN == 0 ]] || wrapper_args+=(--dry-run)
if [[ $DRY_RUN == 0 ]]; then
    if [[ $skip_restore == 0 ]]; then
        [[ -f $SCRIPT_DIR/Restore-CkaSnapshot.sh ]] || lab_die 'Missing linux/Restore-CkaSnapshot.sh.'
    fi
    if [[ $auto_snapshot == 1 ]]; then
        [[ -f $SCRIPT_DIR/Save-CkaSnapshot.sh ]] || lab_die 'Missing linux/Save-CkaSnapshot.sh.'
    fi
    if [[ $skip_restore == 0 || $auto_snapshot == 1 ]]; then
        [[ -f $SCRIPT_DIR/Start-CkaLab.sh ]] || lab_die 'Missing linux/Start-CkaLab.sh.'
    fi
fi
beat() { lab_beat "$1" "$2" "set -euo pipefail
$3"; }
start_ready() {
    lab_run bash "$SCRIPT_DIR/Start-CkaLab.sh" "${wrapper_args[@]}"
    lab_ready
}
boundary() {
    [[ $auto_snapshot == 1 ]] || return 0
    lab_step "Snapshot all nodes: m02-after-$1 (halts machines)"
    lab_run bash "$SCRIPT_DIR/Save-CkaSnapshot.sh" "m02-after-$1" --yes "${wrapper_args[@]}"
    start_ready
}
lab_confirm 'Restore (unless skipped) and upgrade the lab, including boundary snapshots?'
if [[ $skip_restore == 0 ]]; then
    lab_run bash "$SCRIPT_DIR/Restore-CkaSnapshot.sh" "$pre_snapshot" --yes "${wrapper_args[@]}"
    start_ready
else
    lab_warn 'Using CURRENT state; phases still run from the beginning.'
    lab_ready
fi
lab_step "Verify every node and the API start at v$from_version"
lab_command "$CP_NODE" "set -euo pipefail
kubectl get nodes -o json | python3 -c 'import json,sys; nodes=json.load(sys.stdin)[\"items\"]; prefix=\"v$from_version.\"; assert len(nodes) == ${#LAB_NODES[@]} and all(node[\"status\"][\"nodeInfo\"][\"kubeletVersion\"].startswith(prefix) for node in nodes), \"Wrong source kubelet version\"'
kubectl get --raw=/version | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"gitVersion\"].startswith(\"v$from_version.\"), \"Wrong source API version\"'"
beat '0: Starting state and drain workload' "$CP_NODE" "kubectl get nodes
kubectl create deployment globo-shop --image=nginx --replicas=3 --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout status deployment/globo-shop --timeout=180s
kubectl get pods -l app=globo-shop -o wide"
lab_step '1/8: Control plane first; kubelets must never lead the API server'
lab_pause
beat '2/8: Back up etcd before mutation' "$CP_NODE" "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system exec etcd-$CP_NODE -- \\
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \\
--cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \\
snapshot save /var/lib/etcd/m02-pre-$target_patch.db"
repo_command="cat /etc/apt/sources.list.d/kubernetes.list
printf '%s\\n' 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$to_version/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -qq
apt-cache madison kubeadm"
kubeadm_command="sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm='$to_package'
sudo apt-mark hold kubeadm
kubeadm version -o short"
kubelet_command="sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='$to_package' kubectl='$to_package'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
sudo systemctl is-active kubelet"
beat "3/8: Repoint apt to v$to_version" "$CP_NODE" "$repo_command"
beat "4/8: Upgrade kubeadm to $to_package" "$CP_NODE" "$kubeadm_command"
beat '5/8: Review upgrade plan' "$CP_NODE" 'sudo kubeadm upgrade plan'
beat "5/8: Apply exact v$target_patch, not a floating minor" "$CP_NODE" "sudo kubeadm upgrade apply v$target_patch -y
kubectl get nodes"
beat '6/8: Drain control plane' "$CP_NODE" "kubectl drain '$CP_NODE' --ignore-daemonsets --timeout=240s"
beat '6/8: Upgrade control-plane kubelet and kubectl' "$CP_NODE" "$kubelet_command"
beat '6/8: Uncordon control plane' "$CP_NODE" "kubectl uncordon '$CP_NODE'"
lab_ready
boundary "$CP_NODE"
for worker in "${LAB_NODES[@]:1}"; do
    beat "7/8: $worker repo and kubeadm" "$worker" "$repo_command
$kubeadm_command"
    beat "7/8: $worker runs upgrade node, not apply" "$worker" 'sudo kubeadm upgrade node'
    beat "7/8: Drain $worker FROM control plane" "$CP_NODE" "kubectl drain '$worker' --ignore-daemonsets --delete-emptydir-data --timeout=240s"
    beat "7/8: Upgrade $worker kubelet and kubectl" "$worker" "$kubelet_command"
    beat "7/8: Uncordon $worker FROM control plane" "$CP_NODE" "kubectl uncordon '$worker'"
    lab_ready
    boundary "$worker"
done
lab_ready
beat '8/8: Verify exact node/API version and workload health' "$CP_NODE" "kubectl get nodes
test \"\$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}' | grep -Fxc 'v$target_patch')\" -eq ${#LAB_NODES[@]}
test \"\$(kubectl get --raw=/version | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"gitVersion\"])')\" = 'v$target_patch'
kubectl rollout status deployment/globo-shop --timeout=180s
kubectl get pods -A"
if [[ $DRY_RUN == 1 ]]; then
    lab_info 'Dry run complete; no upgrade or health verification was performed.'
else
    lab_info "Module 2 complete: $from_version -> v$target_patch. Restore $pre_snapshot to re-record."
fi