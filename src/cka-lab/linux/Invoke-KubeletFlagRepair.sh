#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/cka.sh"

usage() {
    printf '%s\n' 'Usage: bash linux/Invoke-KubeletFlagRepair.sh [options]
Six phases: symptom/logs, locate flag, backed-up edit, restart, health, takeaway.
  --node NAME        Target to repair (default: control-plane topology node)
  --stale-flag FLAG  Exact flag (default: --pod-infra-container-image)
  --flags-file PATH  Default: /var/lib/kubelet/kubeadm-flags.env
  --yes             Authorize file edit and kubelet restart
  --non-interactive  Disable recording pauses
  --dry-run          Print commands only; no SSH, edit or restart
  --help             Show help
Kubernetes queries always run on the control plane, even for a worker repair.
Requires a responding API, SSH, sudo and Python 3 on the target. No fault is
injected. Only the exact flag token and its =value or separate value are removed.
Unrelated arguments are preserved, including similarly prefixed flags. The
editor accepts one quoted KUBELET_KUBEADM_ARGS assignment with plain tokens;
embedded quotes/escapes/expansions are refused for manual review before writing.
Only regular, non-symlink files under /var/lib/kubelet or /etc are accepted.
An actual edit gets a unique .bak.TIMESTAMP backup and atomic replacement.
No match is an explicit no-op. Other errors stop; completion requires an active
kubelet and target Ready=True, not just a successful restart command.'
}
node=$CP_NODE
stale_flag=--pod-infra-container-image
flags_file=/var/lib/kubelet/kubeadm-flags.env
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --node|--stale-flag|--flags-file)
            (($# >= 2)) && [[ -n $2 ]] || lab_die "Missing value for $1"
            case $1 in --node) node=$2 ;; --stale-flag) stale_flag=$2 ;; --flags-file) flags_file=$2 ;; esac
            shift ;;
        *) lab_die "Unknown option: $1 (use --help)" ;;
    esac
    shift
done
lab_node "$node"
[[ $stale_flag =~ ^--[a-z][a-z0-9-]*$ ]] || lab_die 'Stale flag must be an exact --lowercase-flag name, without a value.'
[[ $flags_file =~ ^/(var/lib/kubelet|etc)/[a-zA-Z0-9/_.-]+$ && $flags_file != */../* && $flags_file != */.. && $flags_file != */./* ]] || lab_die 'Unsafe flags-file path.'
printf -v quoted_file '%q' "$flags_file"
printf -v quoted_flag '%q' "$stale_flag"
beat() { lab_beat "$1" "$2" "set -euo pipefail
$3"; }
lab_confirm "Edit $flags_file and restart kubelet on $node?"
beat '1/6: API answers; inspect target state FROM control plane' "$CP_NODE" "kubectl get node '$node' -o wide"
beat '1/6: Read target kubelet logs' "$node" 'sudo journalctl -u kubelet -n 12 --no-pager'
beat '2/6: Locate stale flag; no match is an expected rerun result' "$node" "if sudo grep -RnF -- $quoted_flag /var/lib/kubelet /etc/systemd/system /etc/default; then
    :
else
    status=\$?
    [[ \$status == 1 ]] || exit \"\$status\"
    printf '[INFO] No matching stale flag found.\\n'
fi"
repair_python=$(printf '%s\n' 'import os
import pathlib
import re
import shutil
import sys
import tempfile
import time

path = pathlib.Path(sys.argv[1])
flag = sys.argv[2]
if path.is_symlink() or not path.is_file() or path.resolve() != path:
    sys.exit("Refusing symlink, non-regular or non-canonical flags file")
original = path.read_bytes()
text = original.decode("utf-8")
assignments = list(re.finditer(r"^KUBELET_KUBEADM_ARGS=.*$", text, re.MULTILINE))
if len(assignments) != 1:
    sys.exit("Expected exactly one KUBELET_KUBEADM_ARGS assignment")
assignment = assignments[0]
line = assignment.group()
if len(line) < 23 or line[21] not in (chr(34), chr(39)) or line[-1] != line[21]:
    sys.exit("Expected a single quoted KUBELET_KUBEADM_ARGS value")
args = line[22:-1]
if any(character in args for character in (chr(34), chr(39), chr(92), "$", "`", "\r")):
    sys.exit("Complex quoting/escapes/expansions require manual review; nothing written")
tokens = list(re.finditer(r"\S+", args))
spans = []
token_index = 0
while token_index < len(tokens):
    token = tokens[token_index]
    value = token.group()
    if value == flag or value.startswith(flag + "="):
        end = token.end()
        if value == flag and token_index + 1 < len(tokens) and not tokens[token_index + 1].group().startswith("--"):
            token_index += 1
            end = tokens[token_index].end()
        spans.append((token.start(), end))
    token_index += 1
if not spans:
    print("[INFO] Exact stale flag absent; file unchanged")
    sys.exit(0)
for start, end in reversed(spans):
    args = args[:start] + args[end:]
replacement = line[:22] + args + line[-1]
updated = (text[:assignment.start()] + replacement + text[assignment.end():]).encode("utf-8")
backup = pathlib.Path(str(path) + ".bak." + str(time.time_ns()))
with backup.open("xb") as backup_file:
    backup_file.write(original)
    backup_file.flush()
    os.fsync(backup_file.fileno())
shutil.copystat(path, backup)
os.chown(backup, path.stat().st_uid, path.stat().st_gid)
descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
try:
    with os.fdopen(descriptor, "wb") as output:
        output.write(updated)
        output.flush()
        os.fsync(output.fileno())
    shutil.copystat(path, temporary)
    os.chown(temporary, path.stat().st_uid, path.stat().st_gid)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("[INFO] Backup:", backup)
print("[INFO] Removed exact flag occurrences:", len(spans))')
beat '3/6: Inspect, back up, remove only the specified flag, inspect again' "$node" "sudo cat -- $quoted_file
sudo python3 - $quoted_file $quoted_flag <<'PYTHON'
$repair_python
PYTHON
sudo cat -- $quoted_file"
beat '4/6: Reload and restart target kubelet' "$node" 'sudo systemctl daemon-reload
sudo systemctl restart kubelet
sudo systemctl is-active kubelet'
beat '5/6: Wait for target heartbeat FROM control plane' "$CP_NODE" "kubectl wait --for=condition=Ready node/'$node' --timeout=180s
kubectl get node '$node' -o wide
kubectl get node '$node' -o jsonpath='{.status.conditions}'"
beat '5/6: Confirm target kubelet stayed active and review logs' "$node" 'sudo systemctl is-active kubelet
sudo journalctl -u kubelet -n 8 --no-pager'
lab_step '6/6: NotReady is a heartbeat symptom; diagnose logs, configuration, then verify'
if [[ $DRY_RUN == 1 ]]; then
    lab_info 'Dry run complete; no repair or health verification was performed.'
else
    lab_info "Repair verified: $node is Ready and kubelet is active. Any backup remains beside the flags file."
fi