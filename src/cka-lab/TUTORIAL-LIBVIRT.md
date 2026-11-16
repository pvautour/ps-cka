# CKA Lab on Linux with libvirt/KVM

The same three Ubuntu 22.04 guests and pinned Kubernetes packages run on Linux
using `vagrant-libvirt`. Provisioning stops before `kubeadm init`, just as on
Windows. The Hyper-V PowerShell wrappers and recording scripts are not ported;
use the Vagrant commands below instead.

## Prerequisites

- An x86-64 Linux host with hardware virtualization enabled and `/dev/kvm` available.
- Vagrant 2.4.x+, QEMU/KVM, libvirt, and the `vagrant-libvirt` plugin.
- Permission to manage `qemu:///system` and use `/dev/kvm` without running Vagrant as root.
- At least 6 GB of free RAM, plus disk space for three guests and snapshots.

For Ubuntu/Debian, install the host packages yourself:

```bash
sudo apt-get update
sudo apt-get install qemu-kvm libvirt-daemon-system libvirt-clients \
  libvirt-dev build-essential ruby-dev pkg-config
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
```

Log out and back in after changing groups. Install
[Vagrant](https://developer.hashicorp.com/vagrant/install), then:

```bash
vagrant plugin install vagrant-libvirt
virsh -c qemu:///system list --all
test -r /dev/kvm && test -w /dev/kvm
vagrant validate
```

On distributions with modular libvirt daemons, enable their QEMU and network
sockets instead of `libvirtd`. Use your distribution's packages and permission
setup if it differs from Ubuntu/Debian.

## Networking

Vagrant creates two libvirt networks automatically; no physical bridge or
Windows switch script is needed:

| Network | Subnet | Purpose |
|---------|--------|---------|
| `cka-management` | `172.28.50.0/24` | DHCP, Vagrant SSH, provisioning, and default-route internet access |
| `cka-lab` | `192.168.50.0/24` | Static node-to-node addresses, host access, gateway `192.168.50.1` |

The nodes retain `control1=192.168.50.10`, `worker1=192.168.50.11`, and
`worker2=192.168.50.12`. The `libvirt-network` provisioner sets each hostname
and writes persistent netplan configuration for the box's lab NIC (`eth1`),
leaving management DHCP on `eth0` intact. The Windows-only netplan provisioner
does not run on Linux.
Kubelet is pinned to each node's lab IP; bootstrap selects that IP and configures
Calico to use Kubernetes `NodeInternalIP` rather than the first NIC it finds.
The management subnet avoids Calico's `192.168.0.0/16` pod range.

Before booting, check `ip -4 route` and `virsh -c qemu:///system net-list --all`
for conflicting host, VPN, or existing libvirt networks. Resolve collisions
before creating guests. Do not attach these guests to an unrelated network
that already uses either subnet.

The default `/vagrant` synced folder is disabled on Linux, so NFS setup is not
required. Send scripts over SSH stdin as shown below. Libvirt domain names are
Vagrant-prefixed; use Vagrant node names rather than assuming bare `virsh` names.

## Boot and Validate

Run from this lab directory as your normal user:

```bash
vagrant up --provider=libvirt
# To boot only control1 and preserve it if setup fails:
# vagrant up control1 --provider=libvirt --no-destroy-on-error
vagrant status

failed=0
for node in control1 worker1 worker2; do
  vagrant ssh "$node" -c 'bash -s' < lib/validate-node.sh || failed=1
done
test "$failed" -eq 0
```

Linux defaults to libvirt when `VAGRANT_DEFAULT_PROVIDER` is unset, but specifying
the provider explicitly also overrides a different user default. A kubelet
waiting for cluster configuration is expected before bootstrap.

If an existing guest retains the box hostname (`ubuntu2204.localdomain`) or
lacks its lab IP, apply only the network provisioner and validate again:

```bash
vagrant provision control1 --provision-with libvirt-network
vagrant ssh control1 -c 'bash -s' < lib/validate-node.sh
```

Substitute `worker1` or `worker2` when repairing a worker. This does not install
packages or initialize Kubernetes; missing prerequisites require a full
`vagrant provision <node>` after fixing any package-access failures.

## Troubleshooting Incomplete Provisioning

If validation finds the correct hostname/IP but reports missing `containerd`,
`kubeadm`, `kubelet`, or `kubectl`, provisioning may have stopped during package
installation. "Machine already provisioned" does not prove the installation
finished. Do not destroy the guest or run `kubeadm init` to fix this.

Run these from the lab directory on the **host**, substituting the affected node:

```bash
vagrant ssh worker1 -c 'sudo tail -n 60 /var/log/cka-provision.log'
vagrant ssh worker1 -c 'timeout 15 resolvectl query mirrors.edge.kernel.org'
vagrant ssh worker1 -c 'curl --noproxy "*" -I --connect-timeout 5 --max-time 15 https://1.1.1.1/'
```

The log records the failing step. `Temporary failure resolving` indicates a DNS
problem; `resolvectl query` can identify a DNSSEC failure. An HTTP response from
the IP-only HTTPS check proves that connection worked without DNS. A timeout
requires further network investigation; it does not by itself prove UFW is the
cause. Use the actual repository hostname from the log if your box uses another
Ubuntu mirror.

### Host UFW blocks guest traffic

On a host using UFW, inspect the rules as an administrator:

```bash
sudo ufw status verbose
sudo nft list ruleset
ip -4 route show default
virsh -c qemu:///system net-info cka-management
```

UFW's default `deny (routed)` can block new guest DNS/HTTPS connections even
when libvirt's separate nftables chain accepts them. An accept in one base
chain does not override a drop in another. DNS queries to the host's libvirt
gateway also need an input allowance; a DHCP allowance alone is insufficient.

If this matches your ruleset, add scoped allowances on the **host**. The example
below uses `virbr1` for `cka-management` and `wlan0` for the default-route uplink.
Replace both with the interfaces reported above; bridge names are not fixed.
Run this block in **Bash**, not Fish:

```bash
MGMT_BRIDGE=virbr1
UPLINK=wlan0
sudo ufw route allow in on "$MGMT_BRIDGE" out on "$UPLINK" from 172.28.50.0/24
sudo ufw allow in on "$MGMT_BRIDGE" from 172.28.50.0/24 to 172.28.50.1 port 53 proto udp
sudo ufw allow in on "$MGMT_BRIDGE" from 172.28.50.0/24 to 172.28.50.1 port 53 proto tcp
sudo ufw status verbose
```

These rules retain the default deny policies. Do not disable UFW, change its
global routed policy to allow, or edit libvirt-managed nftables tables. Update
the uplink rule if you switch host interfaces. These allowances address
management-network internet/DNS access, not all possible cluster-network rules.

### Guest DNSSEC validation fails

After host connectivity is fixed, the guest resolver may still report:

```text
DNSSEC validation failed: incompatible-server
DNSSEC validation failed: missing-key
```

For this local training lab, a workaround is to disable DNSSEC validation
**inside each affected guest**. This removes DNSSEC authenticity checking for
that guest, but does not disable HTTPS certificate verification or the host
firewall. Do not apply it merely because a package download failed; first
confirm the DNSSEC error. Production environments should investigate the
resolver/upstream validation failure instead of adopting this workaround.

From the host, open the affected guest:

```bash
vagrant ssh worker1
```

Run the following **inside the guest**:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/cka-lab.conf >/dev/null <<'EOF'
[Resolve]
DNSSEC=no
EOF
sudo systemctl restart systemd-resolved
timeout 15 getent ahostsv4 mirrors.edge.kernel.org
timeout 15 getent ahostsv4 pkgs.k8s.io
curl -I --connect-timeout 5 --max-time 15 https://pkgs.k8s.io/
exit
```

Both lookups must return addresses and exit zero. The HTTPS check must complete
with an HTTP response, not a timeout or TLS error; a redirect is acceptable for
this connectivity check. If any check fails, diagnose it before provisioning.
Repeat for every affected node: changing `control1` does not change the workers.
The drop-in persists across restarts but is lost when the guest is destroyed.
To undo it, remove `/etc/systemd/resolved.conf.d/cka-lab.conf` inside that guest
and restart `systemd-resolved`.

### Resume installation and validate

Once DNS/HTTPS checks pass, run from the **host** for each affected node:

```bash
vagrant provision worker1 --provision-with cka-prereqs
vagrant ssh worker1 -c 'bash -s' < lib/validate-node.sh
```

This reruns prerequisite installation without initializing or joining Kubernetes.
Require `ALL CHECKS PASSED` on all three nodes before saving the pre-cluster
snapshot and continuing the course. A repair on one node is not evidence that
the others are ready.

Verification record (2026-11-16): the scoped UFW rules restored guest IP-only
HTTPS access; the DNSSEC workaround restored repository DNS/HTTPS access;
rerunning `cka-prereqs` on both workers completed successfully. The live node
validators reported `ALL CHECKS PASSED` for `control1`, `worker1`, and `worker2`.
This did not verify reboot persistence, cross-node connectivity, or cluster
readiness, and does not establish that every DNS failure has the same cause.

## Build a Cluster

```bash
vagrant ssh control1 -c 'bash -s' < bootstrap_cp.sh
vagrant ssh control1 -c 'sudo kubeadm token create --print-join-command'
```

Run the printed join command with `sudo` inside `vagrant ssh worker1` and
`vagrant ssh worker2`. This avoids requiring cross-node SSH credentials.
Check the result:

```bash
vagrant ssh control1 -c 'kubectl get nodes -o wide'
```

The three InternalIP values should be `192.168.50.10`, `.11`, and `.12`.

To build the Module 2 starting state instead, set the version before the first
boot of new guests:

```bash
CKA_K8S_MINOR=1.34 CKA_K8S_PKG_VERSION=1.34.6-1.1 vagrant up --provider=libvirt
```

Changing these variables does not downgrade an existing cluster or its held
packages. Use a separate lab copy for a different baseline.

## Snapshot and Restore

Stop every guest first so disks represent a quiescent cluster:

```bash
vagrant halt
vagrant snapshot save pre-cluster
vagrant snapshot list
vagrant up --provider=libvirt --no-provision
```

To restore:

```bash
vagrant halt
vagrant snapshot list
vagrant snapshot restore pre-cluster --no-start --no-provision
vagrant up --provider=libvirt --no-provision
```

Check that the named snapshot exists on all three VMs before restoring.
Vagrant processes snapshots per VM, not transactionally: if any save or restore
fails, keep every VM halted and resolve the failure before starting the cluster.
This does not provide the Hyper-V wrappers' all-or-nothing preflight guarantees.

Use `vagrant halt` for daily shutdown and `vagrant up --provider=libvirt --no-provision`
to resume. `vagrant destroy` deletes the guests and their snapshots; it is not
a shutdown command.

## Configuration Checks

These checks do not boot guests. The Ruby tests exercise both host branches,
syntax-check the embedded shell provisioners, and test bootstrap IP selection
with mocked interfaces. They do not replace a live cluster readiness check.

```bash
gem install --user-install minitest --no-document
ruby tests/vagrant_config_test.rb
vagrant validate
bash -n bootstrap_cp.sh
```
