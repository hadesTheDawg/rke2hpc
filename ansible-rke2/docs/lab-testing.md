# Testing in the QEMU lab

The parent repository's `lab/lab.sh` builds five Rocky 9 aarch64 VMs on an
Apple-silicon Mac from the stock GenericCloud image (cloud-init only creates
the deploy user and the network; nothing else is installed):

| VM | Role here | Networks |
|----|-----------|----------|
| l1 | jump host for the deployer + `rpm_fetch` host (has internet) | management, uplink |
| a1 | `rke2_servers` (admin node) | `bond0` 10.10.0.10 (management), `hsn0` 10.20.0.10 |
| c1-c3 | `rke2_agents` | `bond0` 10.10.0.2x, `hsn0` 10.20.0.2x |

`bond0` is a real (one-port, active-backup) bond; `hsn0` is a separate L2
switch. a1 and c* have no route to the internet. The Mac reaches only the
management network, through l1, like a laptop on the site's management VPN.

```sh
../lab/lab.sh destroy && ../lab/lab.sh up        # fresh baseline OS
ansible-playbook -i inventories/lab/hosts.yml site.yml
ansible-playbook -i inventories/lab/hosts.yml verify.yml
```

`inventories/lab/` is the only lab-specific part: it points ssh at the lab's
generated config (`../.lab/ssh_config`) and sets `hpc_arch: arm64`. The lab
installs the CephFS CSI driver without a Ceph cluster, which proves every
image it runs comes from the internal registry.

## Result of the test run (2026-11-14)

From freshly created VMs, `site.yml` then `verify.yml`:

```
PASS  VXLAN overlay on every compute node is bound to hsn0 (dev hsn0)
PASS  64 MiB pod-to-pod c1 -> c2 arrived over hsn0 (+69 MiB), not bond0 (+0 MiB)
infra       27 passed, 0 failed   registries, air gap, node IPs on bond0, flannel endpoints on hsn0,
                                  cluster DNS forwarding, placement, CephFS driver + images
tenants     51 passed, 0 failed   OIDC identity, RBAC/network isolation, quotas, pod identity and
                                  NFS homes, node networks unreachable from pods, ingress, Rancher
accounting  21 passed, 0 failed
all acceptance checks passed (101 checks)
```

A second full `site.yml` run changed nothing on the compute nodes; on the
admin node only the steps that always re-apply (helm upgrades, `kubectl
apply`, the incremental bundle sync) report "changed".

Flat-file format change, tested from a copy of this directory in another
location: with the `cpu_hours` `Field` line commented out and the column
removed from `projects.txt`, `tenants.yml` applied cleanly, every project
reported against the default allocation (1000 CPU-hours) and the CPU, memory
and storage quotas were unchanged.
