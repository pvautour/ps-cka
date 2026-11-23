#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/cka.sh"
source "$LAB_ROOT/linux/lib/c04.sh"

C04_MODULE=01
C04_FOLDER=m01-rbac-fundamentals
C04_REQUIRED=(lab.sh frontend-dev-csr.yaml pod-reader.yaml)
C04_GATE_PLAN='basic-user authenticated binding; view excludes Secrets and includes Namespaces; edit reads/writes Secrets and aggregates by label'

c04_module_gates() {
    kubectl get clusterrolebinding system:basic-user -o json | python3 -c '
import json, sys
binding = json.load(sys.stdin)
assert any(subject.get("kind") == "Group" and subject.get("name") == "system:authenticated" for subject in binding.get("subjects", [])), "basic-user authenticated binding missing"
print("[OK] GATE PASS system:basic-user binds system:authenticated")'
    kubectl get clusterrole view -o json | python3 -c '
import json, sys
role = json.load(sys.stdin)
rules = role["rules"]
assert not any("secrets" in rule.get("resources", []) or "*" in rule.get("resources", []) for rule in rules), "view can reach Secrets"
assert any("namespaces" in rule.get("resources", []) and "" in rule.get("apiGroups", []) for rule in rules), "view lacks Namespaces"
print("[OK] GATE PASS view excludes Secrets and includes Namespaces")'
    kubectl get clusterrole edit -o json | python3 -c '
import json, sys
role = json.load(sys.stdin)
verbs = set()
for rule in role["rules"]:
    if "" in rule.get("apiGroups", []) and "secrets" in rule.get("resources", []):
        verbs.update(rule.get("verbs", []))
assert "*" in verbs or {"get", "list", "watch", "create", "delete", "patch", "update"}.issubset(verbs), "edit lacks Secret read/write verbs"
selectors = role.get("aggregationRule", {}).get("clusterRoleSelectors", [])
assert any(selector.get("matchLabels", {}).get("rbac.authorization.k8s.io/aggregate-to-edit") == "true" for selector in selectors), "edit aggregation selector missing"
print("[OK] GATE PASS edit reads/writes Secrets and aggregates by label")'
}

c04_main "$@"