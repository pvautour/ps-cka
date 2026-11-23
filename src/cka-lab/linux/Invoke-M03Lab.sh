#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/cka.sh"

usage() {
    printf '%s\n' 'Usage: bash linux/Invoke-M03Lab.sh [options]
Five recording phases: documentation, Helm, Kustomize, CRDs, cleanup.
  --pre-helm-snapshot NAME  Clean v1.35 restore point (default: m03-pre-helm)
  --skip-restore            Use current state; Helm history may differ
  --helm-version VERSION   Pin Helm (for example v3.16.4); default latest Helm 3
  --node NAME               Driving node; must be the control plane
  --yes                    Authorize restore and demo mutations/cleanup
  --non-interactive         Disable recording pauses
  --dry-run                 Print only; local exercise assets must still exist
  --help                    Show help
Requires Linux restore/start wrappers for restore, a Ready v1.35 cluster and
network access to Helm installer, charts and images. Failures stop the demo.
The ENTIRE exercise tree is tar-streamed over SSH into /home/vagrant/m03-demo;
no synced folder is used. Existing remote demo assets are replaced.
Restore/start is followed by readiness and a Calico token-refresh rollout.
CRD establishment is awaited before discovery or creating custom resources.
Cleanup deletes the release, production overlay and CRD (including instances),
but leaves Helm and uploaded files. Libvirt snapshots are not atomic backups.'
}
pre_snapshot=m03-pre-helm
skip_restore=0
helm_version=''
node=$CP_NODE
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --skip-restore) skip_restore=1 ;;
        --pre-helm-snapshot|--helm-version|--node)
            (($# >= 2)) && [[ -n $2 ]] || lab_die "Missing value for $1"
            case $1 in
                --pre-helm-snapshot) pre_snapshot=$2 ;;
                --helm-version) helm_version=$2 ;;
                --node) node=$2 ;;
            esac
            shift ;;
        *) lab_die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done
lab_node "$node"
[[ $node == "$CP_NODE" ]] || lab_die 'M03 needs the control-plane admin kubeconfig; --node must select the control plane.'
[[ -z $helm_version || $helm_version =~ ^v3\.[0-9]+\.[0-9]+$ ]] || lab_die 'Helm version must be an exact v3.x.y release.'
[[ $pre_snapshot =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || lab_die 'Unsafe snapshot name.'
exercise_dir=$EXERCISE_ROOT/course-03-lifecycle-upgrades/m03-helm-kustomize-crds
[[ -d $exercise_dir ]] || lab_die "Missing exercise tree: $exercise_dir"
for asset in m03-kustomize-demo/base/deployment.yaml m03-kustomize-demo/base/kustomization.yaml m03-kustomize-demo/overlays/staging/kustomization.yaml m03-kustomize-demo/overlays/production/kustomization.yaml m03-crds-demo/backuppolicy-crd.yaml m03-crds-demo/globomantics-backuppolicy.yaml; do
    [[ -f $exercise_dir/$asset ]] || lab_die "Missing exercise asset: $exercise_dir/$asset"
done
wrapper_args=()
[[ $DRY_RUN == 0 ]] || wrapper_args+=(--dry-run)
if [[ $skip_restore == 0 && $DRY_RUN == 0 ]]; then
    for wrapper in Restore-CkaSnapshot Start-CkaLab; do
        [[ -f $SCRIPT_DIR/$wrapper.sh ]] || lab_die "Missing linux/$wrapper.sh."
    done
fi
beat() { lab_beat "$1" "$node" "set -euo pipefail
$2"; }
asset_beat() { beat "$1" "cd /home/vagrant/m03-demo
$2"; }
lab_confirm 'Restore (unless skipped), replace demo assets, and run M03 including cleanup?'
if [[ $skip_restore == 0 ]]; then
    lab_run bash "$SCRIPT_DIR/Restore-CkaSnapshot.sh" "$pre_snapshot" --yes "${wrapper_args[@]}"
    lab_run bash "$SCRIPT_DIR/Start-CkaLab.sh" "${wrapper_args[@]}"
    lab_ready
    lab_command "$node" 'set -euo pipefail
calico_namespace=$(kubectl get daemonsets -A -o json | python3 -c '\''import json,sys; namespaces=[item["metadata"]["namespace"] for item in json.load(sys.stdin)["items"] if item["metadata"]["name"] == "calico-node"]; print("\n".join(namespaces))'\'')
if [[ -n $calico_namespace ]]; then
    [[ $calico_namespace != *$'\''\n'\''* ]] || { echo "Multiple calico-node daemonsets; aborting" >&2; exit 1; }
    kubectl -n "$calico_namespace" rollout restart daemonset/calico-node
    kubectl -n "$calico_namespace" rollout status daemonset/calico-node --timeout=180s
else
    printf "[WARN] No calico-node daemonset; skipping token refresh.\n"
fi'
else
    lab_warn 'Using CURRENT state; rollback to revision 1 assumes an appropriate existing release history.'
    lab_ready
fi
lab_command "$node" 'set -euo pipefail
kubectl get nodes -o json | python3 -c '\''import json,sys; nodes=json.load(sys.stdin)["items"]; assert nodes and all(node["status"]["nodeInfo"]["kubeletVersion"].startswith("v1.35.") for node in nodes), "M03 requires v1.35 nodes"'\''
rm -rf -- /home/vagrant/m03-demo'
lab_upload "$exercise_dir" "$node" /home/vagrant/m03-demo
beat '0: Starting frame' 'kubectl get nodes'
beat '1.1: Live deployment schema' 'kubectl explain deployment.spec.strategy --recursive'
beat '1.2: Client-side YAML scaffolding' 'kubectl create deployment web --image=nginx --dry-run=client -o yaml'
helm_env=''
[[ -z $helm_version ]] || helm_env="DESIRED_VERSION=$helm_version "
beat '2.1: Install Helm 3' "curl -fsSL https://raw.githubusercontent.com/helm/helm/v3.16.3/scripts/get-helm-3 | ${helm_env}bash"
beat '2.2: Register and refresh chart repo' 'helm repo add podinfo https://stefanprodan.github.io/podinfo --force-update
helm repo update'
beat '2.3: Install release' 'helm upgrade --install globo-podinfo podinfo/podinfo --wait --timeout=180s'
beat '2.4: Release ledger' 'helm list'
beat '2.5: Upgrade replica count' 'helm upgrade globo-podinfo podinfo/podinfo --reuse-values --set replicaCount=3 --wait --timeout=180s'
beat '2.6: Roll back to revision 1' 'helm rollback globo-podinfo 1 --wait --timeout=180s'
beat '2.7: Release history' 'helm history globo-podinfo'
asset_beat '3.1: Base deployment' 'cat m03-kustomize-demo/base/deployment.yaml'
asset_beat '3.2: Base resources' 'cat m03-kustomize-demo/base/kustomization.yaml'
asset_beat '3.3: Staging overlay' 'cat m03-kustomize-demo/overlays/staging/kustomization.yaml'
asset_beat '3.4: Render staging' 'kubectl kustomize m03-kustomize-demo/overlays/staging'
asset_beat '3.5: Production overlay' 'cat m03-kustomize-demo/overlays/production/kustomization.yaml'
asset_beat '3.6: Render production' 'kubectl kustomize m03-kustomize-demo/overlays/production'
asset_beat '3.7: Apply production' 'kubectl apply -k m03-kustomize-demo/overlays/production
kubectl wait --for=condition=Available deployment -l env=production --timeout=180s'
asset_beat '3.8: Verify production resources' 'kubectl get deploy,svc -l env=production'
asset_beat '4.1: CRD schema' 'cat m03-crds-demo/backuppolicy-crd.yaml'
asset_beat '4.2: Register kind and wait for establishment' 'kubectl apply -f m03-crds-demo/backuppolicy-crd.yaml
kubectl wait --for=condition=Established crd/backuppolicies.globomantics.io --timeout=90s'
asset_beat '4.3: Query CRD' 'kubectl get crd backuppolicies.globomantics.io'
asset_beat '4.4: Explain custom schema' 'kubectl explain backuppolicy.spec'
asset_beat '4.5: Custom resource instance' 'cat m03-crds-demo/globomantics-backuppolicy.yaml'
asset_beat '4.6: Create validated instance' 'kubectl apply -f m03-crds-demo/globomantics-backuppolicy.yaml'
asset_beat '4.7: Custom printer columns' 'kubectl get backuppolicies'
beat '5.1: Uninstall Helm release' 'helm uninstall globo-podinfo --wait --timeout=180s'
asset_beat '5.2: Remove production overlay' 'kubectl delete -k m03-kustomize-demo/overlays/production --ignore-not-found'
asset_beat '5.3: Delete CRD and all its instances' 'kubectl delete -f m03-crds-demo/backuppolicy-crd.yaml --ignore-not-found'
if [[ $DRY_RUN == 1 ]]; then
    lab_info 'Dry run complete; no demo commands or health checks were executed.'
else
    lab_info "Module 3 complete. Restore $pre_snapshot to re-record."
fi