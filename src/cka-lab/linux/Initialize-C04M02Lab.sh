#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/cka.sh"
source "$LAB_ROOT/linux/lib/c04.sh"

C04_MODULE=02
C04_FOLDER=m02-serviceaccounts
C04_REQUIRED=(lab.sh deploy-runner.yaml ghost-sa.yaml no-automount.yaml check-token-exp.sh capture-m02.sh)
C04_GATE_PLAN='no automatic token Secrets; no legacy-token feature metrics; projected expiration 3607; 10-minute TokenRequest floor; missing-SA admission/no Pod persisted; actual projected-token extended lifetime'

c04_module_gates() {
    local metrics token lifetime
    kubectl create ns gateprobe
    kubectl -n gateprobe create sa g
    c04_value 'fresh SA has no token Secrets' '' kubectl -n gateprobe get sa g -o jsonpath='{.secrets}'
    c04_value 'no auto-created token Secret objects' '' kubectl -n gateprobe get secrets --field-selector=type=kubernetes.io/service-account-token -o name
    metrics=$(kubectl get --raw=/metrics)
    [[ $metrics != *'name="LegacyServiceAccountToken'* ]] || { printf '[ERROR] Legacy token feature gate still registered\n' >&2; return 1; }
    printf '[OK] GATE PASS no LegacyServiceAccountToken feature gate registered\n'
    kubectl -n gateprobe run gp --image=busybox:1.36 --restart=Never \
        --overrides='{"spec":{"serviceAccountName":"g"}}' --command -- sh -c 'tail -f /dev/null'
    c04_value 'projected expirationSeconds' 3607 kubectl -n gateprobe get pod gp -o jsonpath='{range .spec.volumes[*]}{.projected.sources[*].serviceAccountToken.expirationSeconds}{end}'
    printf '%s\n' '[WARN] Parity gap: jq absence is a Windows recording-image assumption, not a Linux gate.'
    c04_deny 'TokenRequest 10-minute floor' 'less than 10 minutes' kubectl -n gateprobe create token g --duration=5m
    c04_deny 'missing SA refused at admission' 'Forbidden.*error looking up service account' \
        kubectl -n gateprobe run ghostgate --image=registry.k8s.io/pause:3.10 --restart=Never --overrides='{"spec":{"serviceAccountName":"nope"}}'
    c04_value 'missing-SA Pod not persisted' '' kubectl -n gateprobe get pod ghostgate --ignore-not-found -o name
    kubectl -n gateprobe wait --for=condition=Ready pod/gp --timeout=150s
    token=$(kubectl -n gateprobe exec gp -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    lifetime=$(printf '%s' "$token" | python3 -c '
import base64, json, sys
parts = sys.stdin.read().strip().split(".")
assert len(parts) == 3, "Malformed projected JWT"
payload = parts[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
assert isinstance(claims.get("exp"), int) and isinstance(claims.get("iat"), int), "JWT lifetime claims missing"
assert claims.get("kubernetes.io", {}).get("pod", {}).get("uid"), "Not a Pod-bound token"
print(claims["exp"] - claims["iat"])')
    [[ $lifetime =~ ^[0-9]+$ && $lifetime -ge 2592000 ]] || { printf '[ERROR] Projected token lifetime is not extended: %s seconds\n' "$lifetime" >&2; return 1; }
    printf '[OK] GATE PASS actual projected token lifetime extended: %s seconds\n' "$lifetime"
    c04_value 'SA still has no token Secret' '' kubectl -n gateprobe get sa g -o jsonpath='{.secrets}'
}

c04_main "$@"