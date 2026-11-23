# CKA Lab -- Vagrant with Hyper-V or libvirt

> *The CKA exam doesn't care how you got here. It only cares whether `kubeadm init`
> is muscle memory and whether you can debug a crashlooping pod before the timer beeps.*

Three Ubuntu 22.04 VMs on Hyper-V (Windows) or libvirt/KVM (Linux)
(**control1**, **worker1**, **worker2**), real
systemd, real kubeadm, real containerd. No Docker-in-Docker shortcuts -- this is
the exam-shaped lab.

---

## Quickstart

### Linux (libvirt/KVM)

With Vagrant and the `vagrant-libvirt` plugin installed and access to
`qemu:///system` configured:

```bash
vagrant up --provider=libvirt
vagrant ssh control1 -c 'bash -s' < lib/validate-node.sh
vagrant halt
vagrant snapshot save pre-cluster
vagrant up --provider=libvirt --no-provision
vagrant ssh control1
```

Setup, validation of all nodes, bootstrap, and snapshot/restore:
**[TUTORIAL-LIBVIRT.md](TUTORIAL-LIBVIRT.md)**.
PowerShell wrappers live in `windows/`. Their Linux Bash equivalents, including
recording and C04 initializers, are documented in
**[linux/README.md](linux/README.md)**.

```bash
bash linux/Test-CkaLabReady.sh
bash linux/Save-CkaSnapshot.sh pre-cluster --yes
bash linux/Start-CkaLab.sh
bash linux/Get-CkaLabStatus.sh
bash linux/Stop-CkaLab.sh
```

Linux snapshots halt all guests and leave them halted; start explicitly after a
successful save or restore. They are preflighted, sequential operations, not
atomic transactions.

### Windows (Hyper-V)

Run from the lab root, not from `windows/`, so Vagrant uses the shared lab.

```powershell
# Admin PowerShell (Hyper-V cmdlets require elevation, every time)
cd src/cka-lab
./windows/Start-CkaLab.ps1          # boots all 3 VMs (or: vagrant up --provider=hyperv on first run)
./windows/Test-CkaLabReady.ps1      # confirms all 9 categories pass on every node
./windows/Save-CkaSnapshot.ps1      # save the "pre-cluster" baseline
vagrant ssh control1              # your canvas -- kubeadm init is on you
./windows/Restore-CkaSnapshot.ps1   # atomic rollback when you want to redrill
./windows/Stop-CkaLab.ps1           # graceful shutdown of all 3 VMs
```

Deep dive and the practice loop: **[TUTORIAL-HYPERV.md](TUTORIAL-HYPERV.md)**

Recording a module? See **[RECORDING-WORKFLOW.md](RECORDING-WORKFLOW.md)** for the
per-module snapshot/restore loop and the on-rails upgrade/Helm demos.

---

## What's in the Box

| File | What It Does |
|------|-------------|
| `README.md` | This page -- the landing pad |
| `CLAUDE.md` | Architecture/code-level guidance for editors and AI agents |
| `TUTORIAL-HYPERV.md` | Hands-on VM walkthrough + practice loop |
| `RECORDING-WORKFLOW.md` | Per-module snapshot/restore loop for recording sessions |
| `Vagrantfile` | 3 headless Ubuntu 22.04 VMs (control1, worker1, worker2), all prereqs installed, pinned to Kubernetes `1.35.0-1.1`. Stops *before* `kubeadm init`. |
| `windows/create-nat-switch.ps1` | Builds the `CKA-NAT` switch on `192.168.50.0/24`. Exact-match adapter lookup, /24 collision preflight. |
| `bootstrap_cp.sh` | kubeadm init on control1 (`set -euo pipefail`, Calico pinned `v3.29.1` via the Tigera operator, pod CIDR `192.168.0.0/16`, CNI-swap comments). |
| `windows/Repair-CkaNatSwitch.ps1` | Rebuilds the `vEthernet (CKA-NAT)` adapter when Hyper-V drops it -- the usual cause of VMs booting unreachable. |
| `join_worker.sh` | Self-sufficient -- SSHes to control1, fetches a fresh kubeadm token, runs the join locally. |
| `join_worker.sh.template` | Placeholder form (`<TOKEN>` / `<HASH>`) kept for reference; no real token is ever committed. |
| `windows/Start-CkaLab.ps1` / `windows/Stop-CkaLab.ps1` | Boot / graceful shutdown for all VMs. |
| `windows/Get-CkaLabStatus.ps1` | Read-only Hyper-V state probe -- reports per-VM Running/Off/Saved/Missing plus IP reachability, offers `windows/Stop-CkaLab.ps1` if anything is Running. CI-safe with `-Quiet`. |
| `windows/Get-CkaConnectionInfo.ps1` | Live UP/DOWN table + SSH cheat sheet. |
| `windows/Test-CkaLabReady.ps1` | 9-category health check across all 3 VMs. Pipes `lib/validate-node.sh` over stdin so `$LASTEXITCODE` reflects the inner bash exit. |
| `windows/Save-CkaSnapshot.ps1` / `windows/Restore-CkaSnapshot.ps1` | Atomic, all-or-nothing Hyper-V checkpoints. Preflight every VM and every checkpoint before writing anything. |
| `windows/Get-CkaSnapshot.ps1` | Read-only checkpoint inventory across all three VMs -- what save points exist and when they were taken. |
| `windows/Remove-CkaSnapshot.ps1` | Inventory (default) then prune checkpoint cruft -- keeps the VMs and your save points. |
| `windows/Build-M02UpgradeLab.ps1` | Rebuild the 3 VMs clean at v1.34 and auto-snapshot for the Module 2 upgrade demo. |
| `windows/Invoke-M02Upgrade.ps1` | On-rails Module 2 demo: restore v1.34, upgrade to v1.35 live, phase by phase. |
| `windows/Invoke-M03Lab.ps1` | On-rails Module 3 demo: Helm, Kustomize, CRDs + the exam doc technique, live. |
| `windows/Invoke-KubeletFlagRepair.ps1` | On-rails repair demo for a stale kubelet flag. |
| `windows/Initialize-C04M01Lab.ps1` | Course 4 Module 1 (RBAC): boot, health-check, stage the module folder, fact-gate the deck against the live cluster, snapshot. |
| `windows/Initialize-C04M02Lab.ps1` | Course 4 Module 2 (ServiceAccounts): same shape as M01, staged for the token demos. |
| `windows/Initialize-C04M03Lab.ps1` | Course 4 Module 3 (admission control): same shape, staged for LimitRange/ResourceQuota/PSA. |
| `lib/CkaLab.ps1` | Shared module -- output helpers, lab topology (`Get-CkaLabNodes`/`Get-CkaLabVMs`), UTF-8/PATH setup, host memory info. |
| `lib/validate-node.sh` | Node-level health checks, piped over stdin during `windows/Test-CkaLabReady.ps1`. |

### Housekeeping

| Path | What It Does |
|------|-------------|
| `archive/` | Retired scripts (legacy multi-action `snapshot.ps1`). Preserved for reference. |
| `docs/` | Architecture diagrams (HTML, drop into a browser), `vagrant-commands.txt`, and a vim cheat sheet. |

---

## Prerequisites

For Linux prerequisites, see **[TUTORIAL-LIBVIRT.md](TUTORIAL-LIBVIRT.md)**.
The following prerequisites apply to Windows:

- **Windows 11 Pro / Enterprise** (Hyper-V is gated out of Home)
- **Hyper-V** feature enabled (reboot required)
- **[Vagrant](https://developer.hashicorp.com/vagrant/install)** 2.4.x+
- **Admin PowerShell 7+** -- Hyper-V cmdlets require elevation, every time, no exceptions
- ~6 GB free RAM for the 3 VMs

One-shot install (run the first two lines elevated; reboot after Hyper-V):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
winget install --id Microsoft.PowerShell --source winget
winget install --id Hashicorp.Vagrant    --source winget
```

Verify:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V | Select FeatureName,State
vagrant --version; $PSVersionTable.PSVersion
```

---

## CKA Exam Prep Tips

1. **Time your cluster bootstraps.** `kubeadm init` -> CNI -> worker joins should take < 10 minutes.
2. **Practice without the docs.** The exam gives you access to kubernetes.io, but searching burns clock.
3. **Use the `k` alias.** Pre-configured on the VMs. `k get pods -A` is muscle memory on the exam.
4. **Break things on purpose.** Delete a kubelet config. Corrupt a cert. Fix it. That's where the learning lives.
5. **Snapshot after each milestone.** Pre-cluster, post-init, post-CNI, with-workloads -- build a checkpoint library.
6. **Learn `kubectl run --dry-run=client -o yaml | kubectl apply -f -`.** Imperative-first scaffolding beats writing YAML from scratch under timer.
7. **Read the question twice.** Half the exam's difficulty is parsing what's actually being asked.

---

## Common Gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `vagrant up` fails with a Hyper-V error | Not running as admin | Open a PowerShell session **as Administrator** -- no workaround exists |
| `kubelet` crashloops right after VM boot | Normal -- it's waiting for cluster config until `kubeadm init` runs | Ignore it. It settles after init. |
| `windows/Restore-CkaSnapshot.ps1` says "nothing restored" | Atomic preflight -- one VM or checkpoint is missing | Check the per-VM summary; create missing checkpoints before retrying |
| `windows/Test-CkaLabReady.ps1` exits 0 but a node actually failed | You're on an old version | Current version pipes validator over stdin; `$LASTEXITCODE` now reflects inner bash exit |

More troubleshooting in **[TUTORIAL-HYPERV.md](TUTORIAL-HYPERV.md)**.

---

## Deeper Reading

- **[TUTORIAL-LIBVIRT.md](TUTORIAL-LIBVIRT.md)** -- Linux/KVM setup, networking, bootstrap, and snapshots
- **[TUTORIAL-HYPERV.md](TUTORIAL-HYPERV.md)** -- step-by-step Hyper-V walkthrough, snapshot strategy, the practice loop
- **[RECORDING-WORKFLOW.md](RECORDING-WORKFLOW.md)** -- per-module recording loop, on-rails upgrade/Helm demos
- **[CLAUDE.md](CLAUDE.md)** -- architecture and code-level guidance (read this before editing any script)
- **[docs/](docs/)** -- architecture diagrams (open the `.html` files in a browser)
