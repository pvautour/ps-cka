# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Scope of This File

When users want to **DO** things (run the lab, drive a snapshot/restore loop, practice the exam workflow), point them at `TUTORIAL-HYPERV.md` (hands-on walkthrough) or `RECORDING-WORKFLOW.md` (per-module recording loop). When users want to **UNDERSTAND or MODIFY** the code, this CLAUDE.md is the entry point -- it explains architecture, invariants, and the patterns you must preserve when editing.

## What This Is

CKA (Certified Kubernetes Administrator) lab environment for Tim Warner's Pluralsight training content. **Vagrant with Hyper-V on Windows or libvirt/KVM on Linux** -- three Ubuntu 22.04 VMs with real kubeadm v1.35, systemd, apt, and a snapshot-and-rollback practice loop. There is no Docker-based/KIND path; an earlier KIND-based lab was retired because it doesn't teach real `kubeadm init`/CNI-install muscle memory, which the CKA exam demands.

## Repository Layout

```
cka-lab/
├── README.md                  # Landing page
├── CLAUDE.md                  # This file -- code/architecture guidance
├── TUTORIAL-HYPERV.md         # Hands-on walkthrough + practice loop
├── RECORDING-WORKFLOW.md      # Per-module recording loop (snapshot/restore, on-rails demos)
│
├── windows/                  # Hyper-V PowerShell entry points
│   ├── Start-CkaLab.ps1       # Boot all 3 VMs (no re-provision)
│   ├── Stop-CkaLab.ps1        # Graceful halt of all 3 VMs
│   ├── Get-CkaLabStatus.ps1   # Read-only Hyper-V state, optional teardown prompt
│   ├── Get-CkaConnectionInfo.ps1  # Connection table with live UP/DOWN status
│   ├── Test-CkaLabReady.ps1   # Health check across all 3 VMs via stdin pipe
│   ├── Save-CkaSnapshot.ps1  # Save all 3 VMs (atomic preflight)
│   ├── Restore-CkaSnapshot.ps1  # Restore all 3 VMs (atomic preflight)
│   ├── Get-CkaSnapshot.ps1   # Checkpoint inventory
│   ├── Remove-CkaSnapshot.ps1  # Inventory/prune checkpoint cruft
│   ├── Build-M02UpgradeLab.ps1  # Clean v1.34 rebuild and M02 snapshot
│   ├── Invoke-M02Upgrade.ps1 # On-rails v1.34 -> v1.35 upgrade
│   ├── Invoke-M03Lab.ps1     # On-rails Helm, Kustomize, CRDs demo
│   ├── Invoke-KubeletFlagRepair.ps1  # Stale kubelet flag repair demo
│   ├── Initialize-C04M01Lab.ps1  # RBAC lab initializer
│   ├── Initialize-C04M02Lab.ps1  # ServiceAccounts lab initializer
│   ├── Initialize-C04M03Lab.ps1  # Admission controls lab initializer
│   ├── create-nat-switch.ps1 # CKA-NAT switch preflight and creation
│   └── Repair-CkaNatSwitch.ps1  # Repair the Hyper-V NAT adapter
├── linux/                    # Bash equivalents and Linux-specific helpers
│
├── lib/
│   ├── CkaLab.ps1             # Shared module (output helpers, lab topology, UTF-8/PATH setup, host info)
│   ├── nodes.json             # Single source of node names and IPs
│   └── validate-node.sh       # Node-level health checks (piped over stdin)
│
├── Vagrantfile                # Shared 3-VM Hyper-V/libvirt cluster
├── bootstrap_cp.sh            # kubeadm init for Vagrant control plane
├── join_worker.sh             # Self-sufficient worker join (fetches fresh token)
├── join_worker.sh.template    # Legacy template (preserved)
├── archive/                   # Stale scripts (legacy multi-action snapshot.ps1)
└── docs/                      # Architecture diagrams
```

## Architecture

### Shared Module: `lib/CkaLab.ps1`

Windows wrappers dot-source this file via `..\lib\CkaLab.ps1` relative to
`$PSScriptRoot`; the standalone NAT switch creator does not use it. It provides:

- **Output helpers**: `Write-Step`, `Write-Success`, `Write-Info`, `Write-Warn`, `Write-ErrorMsg` -- every line is labeled (`[OK]`/`[INFO]`/`[WARN]`/`[ERROR]`) on the Wong colorblind-safe palette, so meaning never depends on color alone
- **Lab topology**: `Get-CkaLabNodes` (Name+IP objects) and `Get-CkaLabVMs` (names only) read `lib/nodes.json`, the single source of truth also used by Vagrant and Linux wrappers. Do not hardcode the three names again
- **Environment**: `Initialize-LabEncoding` (forces UTF-8 console/pipeline so vagrant/ssh/kubectl output doesn't garble on the default Windows code page), `Initialize-LabPath` (PATH refresh for winget/Vagrant/System32; uses a HashSet-based dedup so repeat dot-sources don't stack duplicate segments)
- **Host info**: `Get-HostMemoryInfo`, `Write-HostMemory`

There is no `$Script:CkaLabRoot`. Windows scripts use `$PSScriptRoot` for sibling
wrappers and its parent for shared lab resources. The validator resolves
`..\lib\validate-node.sh`; baseline exports stay in `..\baseline-exports` at the
lab root. Run Windows commands from `src/cka-lab/`, not `windows/`. C04
initializers explicitly push the parent lab root for their Vagrant commands.

Entry-point scripts live in `windows/` and `linux/`, with shared resources at the
lab root (`src/cka-lab/`). A course-specific demo belongs in its platform
directory, not in a duplicated lab engine.

### Vagrant / Hyper-V Path

On Linux, the Vagrantfile defaults to libvirt and skips the Windows switch trigger
and Windows netplan provisioner. The Linux `libvirt-network` provisioner sets
hostnames and configures the box's lab NIC (`eth1`) using netplan, preserving
management DHCP on `eth0`. Vagrant manages a static `cka-lab` network on
192.168.50.0/24 plus a DHCP `cka-management` network on 172.28.50.0/24 for SSH.
Keep management outside Calico's pod range. Kubelet uses the configured lab IP,
bootstrap prefers that address, and Calico selects Kubernetes `NodeInternalIP`.
The default synced folder is disabled on Linux. See `TUTORIAL-LIBVIRT.md` for the
Linux workflow; the PowerShell wrappers remain Hyper-V-specific, and Vagrant's
per-VM snapshots do not inherit their all-or-nothing guarantees.

`Vagrantfile` provisions 3 Ubuntu 22.04 VMs (control1, worker1, worker2) on a dedicated NAT switch (`CKA-NAT`, 192.168.50.0/24) with static IPs. Key design points to preserve:

- **Interface picker in provisioning**: the script prefers `eth0` and explicitly excludes `docker*`, `cni*`, `veth*`, `virbr*`, `br-*`, `flannel*`, `cali*`. Previously a naive "first non-loopback" pick could grab a cluster-internal interface after a previous test run.
- **`netplan try --timeout 30`**: netplan is applied with auto-revert so a misconfig that breaks SSH rolls back automatically instead of bricking the VM.
- **`auto_config: false` in Vagrant**: Vagrant is not allowed to touch the interface -- netplan is authoritative. This prevents Vagrant's `ifdown`/`ifup` dance from fighting cloud-init.
- **Pinned K8s packages**: `kubelet/kubeadm/kubectl` are installed at exactly `1.35.0-1.1` and then `apt-mark hold`'d. Version drift would invalidate exam-parity. The version is **parameterized** via host env vars `CKA_K8S_MINOR` / `CKA_K8S_PKG_VERSION` (defaults `1.35` / `1.35.0-1.1`); set them before `vagrant up` to build the **v1.34** cluster for the Module 2 upgrade demo. Unset, the defaults reproduce the current lab byte-for-byte.
- **No password logging**: the `vagrant` user's password is set via a method that doesn't echo to `/var/log/cka-provision.log`.
- **`bootstrap_cp.sh` hardening**: `set -euo pipefail`; Calico pinned to `v3.29.1`, installed via the Tigera operator on pod CIDR `192.168.0.0/16` to match C02 M03 and every recorded module since; a comment block at the top documents how to swap in another CNI.

`join_worker.sh` is **self-sufficient** -- it SSHes to control1 at 192.168.50.10, pulls a fresh `kubeadm token create --print-join-command`, and runs the join locally. The old static template is preserved at `join_worker.sh.template` for comparison.

`create-nat-switch.ps1` uses exact-match (`Get-NetAdapter -Name "vEthernet ($SwitchName)"`) instead of `-like` to avoid matching `vEthernet (WSL)` or other lookalikes, and preflights for a /24 collision on 192.168.50.0/24 before touching Hyper-V.

### Snapshot / Restore Atomicity

`Save-CkaSnapshot.ps1` and `Restore-CkaSnapshot.ps1` are **all-or-nothing**. Both scripts preflight *every* target VM (and, for restore, every named checkpoint) before making a single change. If one VM is missing or one checkpoint doesn't exist, neither script writes anything -- both fail closed with a per-VM summary of what was found vs. expected. This prevents half-restored clusters where control1 is at `pre-cluster` but worker1 is current.

### Recording-Specific Controls

`Build-M02UpgradeLab.ps1`, `Invoke-M02Upgrade.ps1`, `Invoke-M03Lab.ps1`, and `Invoke-KubeletFlagRepair.ps1` are on-rails demo scripts written for recording sessions, not generic lab plumbing. Invariants to preserve:

- **Recording loop**: `Save-CkaSnapshot <name>` before a take, `Restore-CkaSnapshot <name>` to re-record. M02 builds at v1.34 (env vars above), upgrades to v1.35 on camera -- which is exactly M03's starting state.
- **`windows/Invoke-M03Lab.ps1` pushes exercise-files, not a synced folder**: it resolves `..\..\..\exercise-files\course-03-lifecycle-upgrades\m03-helm-kustomize-crds` relative to `$PSScriptRoot` (repo root is three levels up from `src/cka-lab/windows`). C04 initializers use the same three-parent prefix. The tree is copied onto the node over the stdin->ssh path the validator uses. One source of truth, no Vagrant synced-folder dependency.
- **`Build-M02UpgradeLab.ps1 -ExportBaseline`**: exports the current v1.35 checkpoint to disk BEFORE `vagrant destroy`, since destroy removes the VMs and all their checkpoints. Without this flag, a v1.34 rebuild would permanently lose the v1.35 baseline that M01 re-records and M03 both depend on.
- Human workflow: [`RECORDING-WORKFLOW.md`](RECORDING-WORKFLOW.md).

### Validator: `Test-CkaLabReady.ps1` + `lib/validate-node.sh`

`Test-CkaLabReady.ps1` SSHes into each VM and runs the node-level health checks in `lib/validate-node.sh`. The script is **piped over stdin**:

```powershell
Get-Content -Raw $ScriptPath | vagrant ssh $vm -c "bash -s"
```

This matters because `vagrant ssh -c "<long inlined script>"` has argv-length limits and causes `$LASTEXITCODE` to reflect only the outer `vagrant` process -- the inner script could fail silently. Stdin delivery propagates the inner bash exit correctly. After all three nodes run, the PowerShell wrapper prints an aggregate PASS/WARN/FAIL summary.

## Safety Headers

- All Hyper-V PowerShell scripts carry `#Requires -RunAsAdministrator`. Hyper-V cmdlets fail confusingly without elevation; this fails clearly.
- `Get-CkaConnectionInfo.ps1` carries `#Requires -Version 7.0` (uses PS7 formatting/operators).

## Naming Conventions

Node names and IPs are single-sourced in `lib/nodes.json`, read by Vagrant,
`lib/CkaLab.ps1` (`Get-CkaLabVMs` / `Get-CkaLabNodes`), and `linux/lib/cka.sh`.
If a node is renamed or added, change that JSON file rather than duplicating the
topology in platform wrappers. Windows entry points live in `windows/`; Bash
equivalents live in `linux/` and resolve all paths from the parent lab root.
See `linux/README.md` for Linux behavior and limits. Linux snapshots preflight
all guests and snapshot names, halt all guests, operate sequentially and leave
all halted on partial failure; they are not transactional or portable exports.

Every entry-point script uses PowerShell **Verb-Noun** naming (`Start-CkaLab.ps1`, `Save-CkaSnapshot.ps1`, `Invoke-M02Upgrade.ps1`) so the script's action is legible without opening it. This is a deliberate muscle-memory convention -- don't introduce a differently-shaped name (e.g. `cka-up.ps1`) for a new entry point.

## Platform Notes

- PowerShell scripts require PS 7.0+
- Kubernetes version target: v1.35
- `.gitignore` excludes `*.deb`, `*.zip`, `temp/`, `.vagrant/`
- `bootstrap_cp.sh` auto-detects the CP IP via `hostname -I` (DHCP-compatible)
- Vagrant VMs: 2 CPU / 2 GB RAM each, static IPs on `CKA-NAT`, checkpoints enabled
