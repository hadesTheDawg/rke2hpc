# Networks: management on bond0, pods on the HSN

Nodes typically have a management network (`bond0`) and one or more
high-speed interfaces (`hsn0`, `hsn1`). The deployment splits traffic:

| Traffic | Network | How |
|---------|---------|-----|
| ssh from the deployer (your laptop) | management | inventory `ansible_host` = bond0 address |
| Kubernetes node IP: API server, kubelet, `kubectl logs/exec`, node registration | management | RKE2 `node-ip` / `advertise-address` = address of `hpc_mgmt_iface` |
| Image pulls from the admin node's registries | management | registry names resolve to the admin node's bond0 address |
| NFS (homes, NFS StorageClass), DNS, NTP, package repo | management | served on the admin node's bond0 address |
| **Pod-to-pod between nodes** (incl. Service traffic to a pod on another node) | **HSN** | canal's flannel VXLAN overlay is bound to `hpc_pod_iface` (`flannel.iface`) |
| Pod-to-pod on the same node | local bridge | never leaves the node |

The laptop only ever talks to bond0 addresses. It never needs a route to the HSN.

## Settings

```yaml
hpc_mgmt_iface: bond0       # node IP and every host service
hpc_pod_iface: hsn0         # VXLAN overlay for pods ('' = use bond0 as well)
hpc_pod_iface_regex: ""     # instead of a name, e.g. "^hsn[01]$" when nodes differ
hpc_pod_mtu: 0              # 0 = chart default 1450. 9000-byte HSN: 8950
```

Per-node differences go in `host_vars/<node>.yml` (`hpc_mgmt_iface`,
`hpc_mgmt_ip` to pin an address). The overlay interface is a cluster-wide
setting of canal; if names differ between nodes use `hpc_pod_iface_regex`.

Addresses are read from each node's interface facts at the start of every
playbook (role `preflight`), which also fails early if an interface is missing
or has no IPv4 address. Subnets (`hpc_mgmt_cidr`, `hpc_pod_net_cidr`) are read
from the admin node; `hpc_node_cidrs` (default: both) lists the node networks
project pods may not connect to. Add storage or BMC networks there.

### Two HSN ports (hsn0 + hsn1)

The VXLAN overlay uses one interface per node. Options:

- bond / team the two HSN ports at the OS level and set `hpc_pod_iface` to the bond;
- or use `hsn0` for pods and leave `hsn1` for storage (e.g. Ceph public network)
  by routing; add its subnet to `hpc_node_cidrs` so pods cannot reach it directly.

### MTU

Canal gives pod interfaces MTU 1450 by default. With jumbo frames on the HSN
set `hpc_pod_mtu` to the HSN MTU minus 50 (VXLAN overhead), e.g. 8950. Every
node's HSN must have the same MTU.

## What is configured where

- `roles/rke2/templates/config-*.yaml.j2`: `node-ip` (= management address).
- `roles/rke2/templates/hpc-canal-config.yaml.j2`: `HelmChartConfig rke2-canal`
  with `flannel.iface` (or `regexIface`) and `calico.vethuMTU`. RKE2 applies it
  from `/var/lib/rancher/rke2/server/manifests/` on the admin node; changing it
  re-rolls the canal DaemonSet.
- `roles/rke2/templates/hpc-coredns-config.yaml.j2`: cluster DNS forwards the
  site domain to the admin node (`hpc_coredns_forward_domain`), so pods resolve
  `registry.<domain>`, `keycloak.<domain>` etc. without changing the nodes'
  resolvers.
- `roles/hpc_common/files/hpc-sync.py`: the project NetworkPolicy excludes the
  pod CIDR and every entry of `hpc_node_cidrs` from "outside", and only allows
  the admin node's API (6443), ingress (443) and user registry.

## How it is checked (`verify.yml`)

- every node's Kubernetes InternalIP is its management address;
- every node's flannel endpoint (`flannel.alpha.coreos.com/public-ip`) is its
  pod-interface address;
- the `flannel.1` VXLAN device on every compute node is bound to the pod interface;
- a 64 MiB transfer between two project pods on different compute nodes
  increases the receiving node's pod-interface byte counter by ≥ 60 MiB and
  its management-interface counter by < 8 MiB;
- project pods cannot open ssh to a compute node's management or HSN address,
  nor NFS on the admin node, but reach the API;
- pods resolve the platform names through cluster DNS.
