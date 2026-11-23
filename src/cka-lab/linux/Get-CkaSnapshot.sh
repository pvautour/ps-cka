#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
source "$LAB_ROOT/linux/lib/snapshots.sh"
snapshot_main Get "$@"