#!/usr/bin/env bash

c04_help() {
    printf 'Usage: bash linux/Initialize-C04M%sLab.sh [options]\n' "$C04_MODULE"
    printf '%s\n' \
        'Boot without provisioning, verify v1.35, stage all course assets, gate, reset, snapshot.' \
        '--help             Show this help.' \
        '--dry-run          Print the complete plan; no guest or VM operations.' \
        '--yes              Confirm reset/snapshot operations without prompting.' \
        '--bootstrap        Initialize a missing cluster and join workers.' \
        '--skip-boot        Assume VMs are already running.' \
        '--skip-snapshot    Leave the clean lab running without saving.' \
        '--snapshot-name N  Override the module snapshot name.' \
        '--node N           Drive the topology control plane only.' \
        'Snapshots use Save-CkaSnapshot.sh and leave VMs halted; start again for recording.' \
        'Linux does not require jq to be absent or automatically bounce a CNI after restore.' \
        'M02 measures extended lifetime on a Pod-projected token, not a manual TokenRequest.'
}

c04_cleanup_script() {
    printf 'set -euo pipefail\nmodule=%q\nbase=%q\n' "$C04_MODULE" "$C04_REMOTE"
    declare -f c04_guest_cleanup
    printf 'c04_guest_cleanup\n'
}

c04_guest_cleanup() {
    local cleanup_rc=0 output identity
    kubectl config use-context cka-vagrant >/dev/null || cleanup_rc=1
    kubectl get --raw=/readyz >/dev/null || cleanup_rc=1
    kubectl delete ns gateprobe gateprobe-quota gateprobe-order gateprobe-restricted \
        --ignore-not-found --wait=true --timeout=120s || cleanup_rc=1
    rm -rf -- "$base/.gate" || cleanup_rc=1
    if [[ -x $base/lab.sh ]]; then
        (cd -- "$base" && timeout 180s bash ./lab.sh reset) || cleanup_rc=1
    fi
    case "$module" in
        01)
            kubectl delete ns dev-team --ignore-not-found --wait=true --timeout=120s || cleanup_rc=1
            kubectl delete clusterrolebinding frontend-dev-views-all --ignore-not-found --timeout=120s || cleanup_rc=1
            kubectl delete csr frontend-dev --ignore-not-found --timeout=120s || cleanup_rc=1
            for identity in context user; do
                if output=$(kubectl config view -o "jsonpath={.${identity}s[*].name}"); then
                    if [[ " $output " == *' frontend-dev '* ]]; then
                        kubectl config "delete-$identity" frontend-dev || cleanup_rc=1
                    fi
                else cleanup_rc=1; fi
            done
            rm -rf -- /home/vagrant/certs || cleanup_rc=1
            mkdir -p /home/vagrant/certs || cleanup_rc=1
            ;;
        02)
            kubectl delete ns staging sa-probe --ignore-not-found --wait=true --timeout=120s || cleanup_rc=1
            ;;
        03)
            kubectl delete ns production quota-trap pss-probe --ignore-not-found --wait=true --timeout=120s || cleanup_rc=1
            kubectl -n default delete deploy filler legacy-agent --ignore-not-found --timeout=120s || cleanup_rc=1
            kubectl -n default delete pod web-1 greedy hardened --ignore-not-found --wait=true --timeout=120s || cleanup_rc=1
            kubectl -n default delete quota production-cap --ignore-not-found --timeout=120s || cleanup_rc=1
            kubectl -n default delete limitrange production-defaults --ignore-not-found --timeout=120s || cleanup_rc=1
            if output=$(kubectl get deploy,rs,pods,quota,limitrange -A -o name); then
                if [[ $output =~ (filler|legacy-agent|hardened|greedy|web-1|production-cap|production-defaults) ]]; then
                    printf '[ERROR] Module leftovers: %s\n' "$output" >&2
                    cleanup_rc=1
                fi
            else cleanup_rc=1; fi
            ;;
    esac
    kubectl config set-context cka-vagrant --namespace=default >/dev/null || cleanup_rc=1
    kubectl get --raw=/readyz >/dev/null || cleanup_rc=1
    return "$cleanup_rc"
}

c04_exit() {
    local original_rc=$?
    trap - EXIT INT TERM
    if [[ ${C04_CLEANUP_ARMED:-0} == 1 && $DRY_RUN != 1 ]]; then
        lab_warn 'Initializer did not finish; attempting probe and module cleanup (no snapshot).'
        if ! lab_command "$C04_NODE" "$(c04_cleanup_script)"; then
            lab_warn 'Cleanup failed; inspect the guest before recording or taking a snapshot.'
            [[ $original_rc != 0 ]] || original_rc=1
        fi
    fi
    exit "$original_rc"
}

c04_main() {
    C04_NODE=$CP_NODE
    C04_SNAPSHOT="c04-m${C04_MODULE}-rbac-ready"
    C04_REMOTE="/home/vagrant/m${C04_MODULE}"
    C04_BOOTSTRAP=0 C04_SKIP_BOOT=0 C04_SKIP_SNAPSHOT=0 C04_CLEANUP_ARMED=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) c04_help; return 0 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes) YES=1 ;;
            --bootstrap) C04_BOOTSTRAP=1 ;;
            --skip-boot) C04_SKIP_BOOT=1 ;;
            --skip-snapshot) C04_SKIP_SNAPSHOT=1 ;;
            --snapshot-name|--node)
                [[ $# -ge 2 && -n $2 && $2 != --* ]] || lab_die "Missing value for $1"
                if [[ $1 == --node ]]; then C04_NODE=$2; else C04_SNAPSHOT=$2; fi
                shift ;;
            *) lab_die "Unknown option: $1" ;;
        esac
        shift
    done
    lab_node "$C04_NODE"
    [[ $C04_NODE == "$CP_NODE" ]] || lab_die '--node must be the topology control plane.'
    [[ $C04_SNAPSHOT =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || lab_die 'Unsafe snapshot name.'
    C04_SOURCE="$EXERCISE_ROOT/course-04-rbac-admission/$C04_FOLDER"
    local course_root="$EXERCISE_ROOT/course-04-rbac-admission" required
    [[ -d $C04_SOURCE && -f $course_root/setup-contexts.sh ]] || lab_die 'Course assets are missing.'
    for required in "${C04_REQUIRED[@]}"; do
        [[ -f $C04_SOURCE/$required ]] || lab_die "Required asset missing: $required"
    done
    if [[ $DRY_RUN == 1 ]]; then
        [[ $C04_SKIP_BOOT == 1 ]] || lab_info 'Would boot all lab nodes: vagrant up --no-provision.'
        lab_info "Would check SSH, configure cka-vagrant on $C04_NODE, and probe /readyz."
        [[ $C04_BOOTSTRAP == 0 ]] || lab_info 'Would bootstrap only if admin.conf is absent, then join workers.'
        lab_info 'Would wait for every topology node Ready and require one v1.35.x kubelet version and containerd.'
        lab_upload "$C04_SOURCE" "$C04_NODE" "$C04_REMOTE"
        lab_info 'Would tar/SSH upload setup-contexts.sh to /home/vagrant and verify all transferred bytes.'
        lab_info "Would execute module $C04_MODULE gates: $C04_GATE_PLAN"
        lab_info 'Would clean probes on success or failure, run lab.sh reset, and independently scrub/verify frame zero.'
        if [[ $C04_SKIP_SNAPSHOT == 0 ]]; then
            lab_info "Would save only after ALL gates and cleanup succeed: bash $LAB_ROOT/linux/Save-CkaSnapshot.sh $C04_SNAPSHOT --yes --dry-run (VMs halted)."
        else lab_info 'Snapshot skipped; VMs remain running.'; fi
        lab_info 'Parity: no jq-absence requirement or automatic Hyper-V CNI repair; projected-token lifetime uses the actual injected token.'
        return 0
    fi
    lab_require vagrant
    lab_require tar
    [[ $C04_SKIP_SNAPSHOT == 1 || -f $LAB_ROOT/linux/Save-CkaSnapshot.sh ]] || lab_die 'Save-CkaSnapshot.sh is not installed; use --skip-snapshot.'
    lab_confirm "Reset C04 M$C04_MODULE demo state and save a clean baseline?"
    trap c04_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $C04_SKIP_BOOT == 0 ]]; then
        lab_step 'Booting without provisioning'
        lab_vagrant up "${LAB_NODES[@]}" --no-provision
    fi
    local target attempt answered
    for target in "${LAB_NODES[@]}"; do
        answered=0
        for attempt in {1..12}; do
            if lab_command "$target" 'set -euo pipefail; true'; then answered=1; break; fi
            sleep 2
        done
        [[ $answered == 1 ]] || lab_die "SSH unavailable on $target after 12 attempts."
    done
    if lab_command "$C04_NODE" 'set -euo pipefail; sudo test -f /etc/kubernetes/admin.conf'; then
        lab_info 'Existing kubeadm cluster; bootstrap skipped.'
    else
        [[ $C04_BOOTSTRAP == 1 ]] || lab_die 'No admin.conf; use --bootstrap on provisioned VMs.'
        lab_bootstrap
    fi
    lab_command "$C04_NODE" "$(c04_context_script)"
    C04_CLEANUP_ARMED=1
    lab_ready
    lab_command "$C04_NODE" "$(c04_health_script)"
    lab_step 'Uploading every module asset with tar over SSH stdin'
    lab_command "$C04_NODE" "set -euo pipefail
mkdir -p '$C04_REMOTE'
find '$C04_REMOTE' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
    lab_upload "$C04_SOURCE" "$C04_NODE" "$C04_REMOTE"
    tar -C "$course_root" -cf - setup-contexts.sh | lab_vagrant ssh "$C04_NODE" -c 'tar -xf - -C /home/vagrant'
    (cd -- "$C04_SOURCE" && find . -type f -exec sha256sum {} +) | \
        lab_vagrant ssh "$C04_NODE" -c "cd '$C04_REMOTE' && sha256sum -c -"
    (cd -- "$course_root" && sha256sum setup-contexts.sh) | \
        lab_vagrant ssh "$C04_NODE" -c 'cd /home/vagrant && sha256sum -c -'
    lab_command "$C04_NODE" "set -euo pipefail
find '$C04_REMOTE' -type f -name '*.sh' -exec chmod +x {} +
chmod +x /home/vagrant/setup-contexts.sh
while IFS= read -r -d '' script; do
    test \"\$(head -c 1 \"\$script\")\" = '#'
    bash -n \"\$script\"
done < <(find '$C04_REMOTE' -type f -name '*.sh' -print0)
bash -n /home/vagrant/setup-contexts.sh"
    lab_step "Running C04 M$C04_MODULE guest gates"
    lab_command "$C04_NODE" "$(c04_gate_script)"
    lab_step 'Scrubbing probes and resetting the module'
    lab_command "$C04_NODE" "$(c04_cleanup_script)"
    C04_CLEANUP_ARMED=0
    if [[ $C04_SKIP_SNAPSHOT == 0 ]]; then
        bash "$LAB_ROOT/linux/Save-CkaSnapshot.sh" "$C04_SNAPSHOT" --yes
        lab_info 'Snapshot saved; VMs are halted. Start-CkaLab.sh boots without provisioning.'
    fi
    lab_info "C04 M$C04_MODULE gates and frame-zero checks passed."
}

c04_context_script() {
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'mkdir -p "$HOME/.kube"
admin_config=$(mktemp)
merged_config=$(mktemp "$HOME/.kube/config.XXXXXX")
trap '\''rm -f -- "$admin_config" "$merged_config"'\'' EXIT
sudo cat /etc/kubernetes/admin.conf > "$admin_config"
admin_cluster=$(KUBECONFIG="$admin_config" kubectl config view --minify -o jsonpath="{.contexts[0].context.cluster}")
admin_user=$(KUBECONFIG="$admin_config" kubectl config view --minify -o jsonpath="{.contexts[0].context.user}")
test -n "$admin_cluster" && test -n "$admin_user"
KUBECONFIG="$admin_config:$HOME/.kube/config" kubectl config view --flatten --raw > "$merged_config"
chmod 600 "$merged_config"
mv -- "$merged_config" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"
kubectl config set-context cka-vagrant --cluster="$admin_cluster" --user="$admin_user" --namespace=default
kubectl config use-context cka-vagrant'
}

c04_health_script() {
    printf 'set -euo pipefail\nexpected_count=%q\n' "${#LAB_NODES[@]}"
    printf 'expected_nodes=('
    printf ' %q' "${LAB_NODES[@]}"
    printf ' )\n'
    printf '%s\n' 'test "$(kubectl get nodes -o name | wc -l)" -eq "$expected_count"
for node in "${expected_nodes[@]}"; do
    kubectl wait --for=condition=Ready "node/$node" --timeout=240s
done
versions=$(kubectl get nodes -o jsonpath="{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}" | sort -u)
[[ $versions =~ ^v1\.35\.[0-9]+[^[:space:]]*$ ]] || { echo "Wrong or mixed kubelet versions: $versions" >&2; exit 1; }
runtimes=$(kubectl get nodes -o jsonpath="{range .items[*]}{.status.nodeInfo.containerRuntimeVersion}{\"\\n\"}{end}")
while IFS= read -r runtime; do [[ $runtime == containerd://* ]]; done <<< "$runtimes"
kubectl get --raw=/readyz'
}

c04_gate_script() {
    printf 'set -euo pipefail\nbase=%q\n' "$C04_REMOTE"
    declare -f c04_assert c04_value c04_deny c04_probe_manifest c04_module_gates
    printf '%s\n' 'kubectl delete ns gateprobe gateprobe-quota gateprobe-order gateprobe-restricted --ignore-not-found --wait=true --timeout=120s
c04_module_gates'
}

c04_assert() {
    local name=$1 want=$2 got=$3
    if [[ $got != "$want" ]]; then
        printf '[ERROR] GATE FAIL %s: expected <%s>, got <%s>\n' "$name" "$want" "$got" >&2
        return 1
    fi
    printf '[OK] GATE PASS %s\n' "$name"
}

c04_value() {
    local name=$1 want=$2 output status
    shift 2
    if output=$("$@"); then
        c04_assert "$name" "$want" "$output"
    else
        status=$?
        printf '[ERROR] GATE FAIL %s: query exited %s\n' "$name" "$status" >&2
        return "$status"
    fi
}

c04_deny() {
    local name=$1 pattern=$2 output status
    shift 2
    if output=$("$@" 2>&1); then
        printf '[ERROR] GATE FAIL %s: command unexpectedly succeeded\n' "$name" >&2
        return 1
    else status=$?; fi
    if [[ $status != 1 || ! $output =~ $pattern ]]; then
        printf '[ERROR] GATE FAIL %s: exit %s, wrong denial: %s\n' "$name" "$status" "$output" >&2
        return 1
    fi
    if [[ $pattern == *PodSecurity* && $output == *'exceeded quota'* ]]; then
        printf '[ERROR] GATE FAIL %s: quota error was also reported\n' "$name" >&2
        return 1
    fi
    printf '[OK] GATE PASS %s (expected exit %s)\n' "$name" "$status"
}

c04_probe_manifest() {
    local filename=$1 namespace=$2 destination=${3:-$1} original
    original=$(kubectl create --dry-run=client -f "$base/$filename" -o jsonpath='{.metadata.namespace}')
    c04_assert "$filename source namespace" production "$original"
    kubectl create --dry-run=client -f "$base/$filename" -o json | \
        kubectl patch --local -f - --type=merge -p "{\"metadata\":{\"namespace\":\"$namespace\"}}" -o yaml > "$base/.gate/$destination"
}