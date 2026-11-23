# CKA Lab Linux Scripts

Bash equivalents of every entry point in `../windows`, using Vagrant/libvirt
instead of Hyper-V. Run them as your normal user with permission for
`qemu:///system`; do not run Vagrant as root. Commands resolve the lab root from
their own location, so they also work when launched from this directory or Fish.

Host requirements: Bash 4.3+, Ruby (also used by Vagrant), Python 3, Vagrant with
`vagrant-libvirt`, `virsh`, `ip`, `tar`, coreutils and `flock`. Recording and
initializer workflows also require the repository's `exercise-files` tree,
guest Python 3 where JSON/token checks use it, and guest package/network access.
See [the Linux tutorial](../TUTORIAL-LIBVIRT.md) for host setup and DNS/UFW repair.

## Daily Use

Run from the lab root:

```bash
# First installation includes provisioning, but not kubeadm init.
vagrant up --provider=libvirt
bash linux/Test-CkaLabReady.sh

# Save the prerequisites-only baseline; every VM is halted first.
bash linux/Save-CkaSnapshot.sh pre-cluster --yes
bash linux/Start-CkaLab.sh

bash linux/Get-CkaConnectionInfo.sh
bash linux/Get-CkaLabStatus.sh
bash linux/Stop-CkaLab.sh

# Restore leaves every VM halted; start only after a successful restore.
bash linux/Restore-CkaSnapshot.sh pre-cluster --yes
bash linux/Start-CkaLab.sh
```

Start never re-provisions. Build the cluster using the tutorial's bootstrap/join
commands, then use `Test-CkaLabReady.sh --cluster` to check node readiness.

Every entry point supports `--help` and `--dry-run`. Snapshot dry runs perform
read-only VM/snapshot preflights and therefore require existing lab VMs and
libvirt access; other dry runs print their plan without guest/VM operations.
Mutating snapshot/recording/initializer commands ask for confirmation unless
`--yes` is supplied. The destructive M02 builder always requires `--yes`, even
for its dry run. Recording demos pause between beats; `--non-interactive`
disables those pauses. Arguments use GNU-style flags, not PowerShell switches.

## Script Equivalents

Each Bash basename matches its Windows counterpart; change `.ps1` to `.sh`.

| Linux Entry Point | Behavior |
|-------------------|----------|
| `Start-CkaLab.sh` | Boot all guests without provisioning. |
| `Stop-CkaLab.sh` | Graceful halt, never destroy. |
| `Get-CkaLabStatus.sh` | Read-only Vagrant state/memory; `--quiet` exits 1 if a guest is running. No teardown prompt. |
| `Get-CkaConnectionInfo.sh` | Node lab IPs, states, Vagrant commands and live SSH configuration. |
| `Test-CkaLabReady.sh` | All-node validator via SSH stdin; optional `--cluster` gate. |
| `Save-CkaSnapshot.sh` | Preflight all guests and reject an existing name, halt, save sequentially. |
| `Restore-CkaSnapshot.sh` | Require the named snapshot on every guest before halting or restoring. |
| `Get-CkaSnapshot.sh` | Exact libvirt snapshot-name inventory, with partial sets marked. No creation-time sorting. |
| `Remove-CkaSnapshot.sh` | Read-only by default; names or `--prune` delete unprotected snapshots. |
| `Build-M02UpgradeLab.sh` | Destroy, provision v1.34, bootstrap/join, verify, save baseline. |
| `Invoke-M02Upgrade.sh` | Verify source minor, back up etcd, upgrade control plane then workers, verify exact target patch. |
| `Invoke-M03Lab.sh` | Helm, Kustomize and CRD recording phases with full exercise uploads. |
| `Invoke-KubeletFlagRepair.sh` | Unique backup, exact stale-flag removal, restart, verify from control plane. |
| `Initialize-C04M01Lab.sh` | Stage RBAC assets, run gates, reset, save. |
| `Initialize-C04M02Lab.sh` | Stage ServiceAccount assets, run token/admission gates, reset, save. |
| `Initialize-C04M03Lab.sh` | Stage admission assets, run LimitRange/quota/PSA gates, reset, save. |
| `create-nat-switch.sh` | Check libvirt networks; `--create --yes` delegates creation and guest provisioning to Vagrant. |
| `Repair-CkaNatSwitch.sh` | Verify both existing networks, start/autostart them, verify bridge gateways. |

## Snapshot Safety

These are **sequential operations, not atomic transactions**. All required VMs
and named snapshots are checked before save/restore writes. Save, restore and
deletion halt every VM first and leave all halted, even after partial failure.
Do not start a partially restored cluster; inspect the inventory and resolve
the failure first. Host-side locks coordinate Linux management wrappers, not
manual Vagrant/virsh commands or a second checkout.

```bash
bash linux/Get-CkaSnapshot.sh
bash linux/Remove-CkaSnapshot.sh --prune --dry-run
bash linux/Remove-CkaSnapshot.sh --prune --keep pre-cluster --keep m01-cluster-ready --yes
```

Default protected names are `pre-cluster` and `m02-pre-upgrade`. Repeated `--keep`
flags replace that list; `--keep-none` explicitly removes protection. Save never
silently replaces an existing snapshot, including recording-boundary snapshots.

Snapshots and in-guest etcd backups are not portable exports and are lost when
guests are destroyed. `Build-M02UpgradeLab.sh --export-baseline` deliberately
refuses before destruction: no verified libvirt equivalent of Hyper-V export
is implemented. Preserve and restore-test independent offline disks/configuration
before rebuilding a baseline you need to keep.

## Recording Examples

```bash
bash linux/Build-M02UpgradeLab.sh --yes --dry-run
bash linux/Build-M02UpgradeLab.sh --yes
bash linux/Invoke-M02Upgrade.sh --yes

# A cluster at v1.35 must already exist for this save point.
bash linux/Save-CkaSnapshot.sh m03-pre-helm --yes
bash linux/Invoke-M03Lab.sh --yes

bash linux/Initialize-C04M01Lab.sh --bootstrap --yes
bash linux/Initialize-C04M02Lab.sh --yes
bash linux/Initialize-C04M03Lab.sh --yes
bash linux/Invoke-KubeletFlagRepair.sh --node worker1 --yes
```

Initializers boot without provisioning, so `--bootstrap` requires installed
prerequisites. They merge the current admin kubeconfig while preserving unrelated
contexts, stage every module asset, and snapshot only after gates and cleanup
succeed. They reset module demo state: review their help before using them on
anything other than this disposable lab. M02 verifies the actual Pod-projected
token lifetime. Linux does not enforce the Windows demo's absence-of-jq gate
or automatically bounce Calico after restoring.

Network repair never edits network XML, global forwarding policies, UFW, or
libvirt-managed firewall tables. It does not prove guest DNS/HTTPS or cluster
connectivity. The legacy networking filenames are retained for correspondence;
no Hyper-V switch is created on Linux.

## Offline Checks

```bash
ruby tests/linux_scripts_test.rb
ruby tests/vagrant_config_test.rb
```

The suite checks syntax/help, entry-point coverage, dry-run isolation, readiness
retries, network XML/gateway parsing and mocked snapshot failure paths. It does
not replace running validators or rehearsal on live guests. Shared topology is
defined in `../lib/nodes.json`; Bash, PowerShell and Vagrant read that same file.