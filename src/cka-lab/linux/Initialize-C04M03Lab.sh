#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/cka.sh"
source "$LAB_ROOT/linux/lib/c04.sh"

C04_MODULE=03
C04_FOLDER=m03-admission-controls
C04_REQUIRED=(commands.sh lab.sh limitrange.yaml limitrange-ceiling.yaml oversized-pod.yaml resourcequota.yaml privileged-deployment.yaml hardened-pod.yaml)
C04_GATE_PLAN='LimitRanger/ResourceQuota/PodSecurity behavior; 100m/500m defaults; 800m/1500m ceiling; bare quota counts requests; PSA before quota; Deployment/RS/no Pods and refusal event; baseline vs restricted hardened Pod; uid101/read-only root'

c04_module_gates() {
    local namespace filename resource output
    mkdir -p "$base/.gate"
    for filename in limitrange.yaml limitrange-ceiling.yaml oversized-pod.yaml privileged-deployment.yaml hardened-pod.yaml; do
        c04_probe_manifest "$filename" gateprobe
    done
    c04_probe_manifest hardened-pod.yaml gateprobe-restricted hardened-pod-restricted.yaml
    for namespace in gateprobe gateprobe-quota gateprobe-order gateprobe-restricted; do
        kubectl create ns "$namespace"
        kubectl label ns "$namespace" cka-gate=probe
    done
    kubectl label ns gateprobe pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=baseline
    kubectl label ns gateprobe-order pod-security.kubernetes.io/enforce=baseline
    kubectl label ns gateprobe-restricted pod-security.kubernetes.io/enforce=restricted
    kubectl apply -f "$base/.gate/limitrange.yaml"
    kubectl -n gateprobe-quota create quota bare --hard=cpu=2,memory=2Gi
    kubectl -n gateprobe-order create quota zero --hard=pods=0
    kubectl -n gateprobe-quota wait --for=jsonpath='{.status.hard.cpu}'=2 quota/bare --timeout=120s
    kubectl -n gateprobe-order wait --for=jsonpath='{.status.hard.pods}'=0 quota/zero --timeout=120s
    kubectl -n gateprobe run lrprobe --image=registry.k8s.io/pause:3.10 --restart=Never
    c04_value 'LimitRanger injects CPU request' 100m kubectl -n gateprobe get pod lrprobe -o jsonpath='{.spec.containers[0].resources.requests.cpu}'
    c04_value 'LimitRanger injects CPU limit' 500m kubectl -n gateprobe get pod lrprobe -o jsonpath='{.spec.containers[0].resources.limits.cpu}'
    c04_deny 'ResourceQuota is active' 'Forbidden.*exceeded quota' \
        kubectl -n gateprobe-order run rqprobe --image=registry.k8s.io/pause:3.10 --restart=Never
    c04_deny 'PodSecurity is active' 'Forbidden.*violates PodSecurity' \
        kubectl -n gateprobe run psprobe --image=registry.k8s.io/pause:3.10 --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"psprobe","image":"registry.k8s.io/pause:3.10","securityContext":{"privileged":true}}]}}'
    kubectl apply -f "$base/.gate/limitrange-ceiling.yaml"
    c04_deny 'LimitRanger names ceiling and submitted limit' 'Forbidden.*maximum cpu usage per Container is 800m, but limit is 1500m' \
        kubectl create -f "$base/.gate/oversized-pod.yaml"
    kubectl -n gateprobe-quota run qprobe --image=registry.k8s.io/pause:3.10 --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"qprobe","image":"registry.k8s.io/pause:3.10","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"900m","memory":"512Mi"}}}]}}'
    kubectl -n gateprobe-quota wait --for=jsonpath='{.status.used.cpu}'=100m quota/bare --timeout=120s
    c04_value 'bare quota memory counts requests' 64Mi kubectl -n gateprobe-quota get quota bare -o jsonpath='{.status.used.memory}'
    c04_deny 'PodSecurity speaks before exhausted quota' 'Forbidden.*violates PodSecurity' \
        kubectl -n gateprobe-order run orderprobe --image=registry.k8s.io/pause:3.10 --restart=Never \
        --overrides='{"spec":{"containers":[{"name":"orderprobe","image":"registry.k8s.io/pause:3.10","securityContext":{"privileged":true}}]}}'
    c04_value 'dual-violation Pod not persisted' '' kubectl -n gateprobe-order get pod orderprobe --ignore-not-found -o name
    kubectl apply -f "$base/.gate/privileged-deployment.yaml"
    kubectl -n gateprobe wait --for=condition=ReplicaFailure deployment/legacy-agent --timeout=120s
    c04_value 'privileged Deployment exists' deployment.apps/legacy-agent kubectl -n gateprobe get deployment legacy-agent -o name
    resource=$(kubectl -n gateprobe get rs -l app=legacy-agent -o jsonpath='{.items[*].metadata.name}')
    [[ -n $resource && $resource != *' '* ]] || { printf '[ERROR] Expected exactly one legacy-agent ReplicaSet\n' >&2; return 1; }
    c04_value 'privileged ReplicaSet persists no Pods' '' kubectl -n gateprobe get pods -l app=legacy-agent -o name
    output=$(kubectl -n gateprobe describe rs "$resource")
    [[ $output == *'violates PodSecurity'* && $output != *'exceeded quota'* ]] || { printf '[ERROR] ReplicaSet refusal not readable or wrong: %s\n' "$output" >&2; return 1; }
    printf '[OK] GATE PASS Deployment/ReplicaSet exist, no Pods, PSA refusal on ReplicaSet\n'
    c04_deny 'hardened manifest is baseline, not restricted' 'Forbidden.*violates PodSecurity' \
        kubectl create -f "$base/.gate/hardened-pod-restricted.yaml"
    kubectl apply -f "$base/.gate/hardened-pod.yaml"
    kubectl -n gateprobe wait --for=condition=Ready pod/hardened --timeout=150s
    c04_value 'hardened Pod runs as uid 101' 101 kubectl -n gateprobe exec hardened -- id -u
    c04_deny 'hardened root filesystem is read-only' '[Rr]ead-only file system' \
        kubectl -n gateprobe exec hardened -- touch /root-test
}

c04_main "$@"