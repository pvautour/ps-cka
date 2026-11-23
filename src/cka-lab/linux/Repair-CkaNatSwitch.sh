#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/cka.sh"
source "$LAB_ROOT/linux/lib/networks.sh"
lab_network_main Repair-CkaNatSwitch "$@"