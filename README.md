<img src="assets/icon.svg" width="64" height="64" alt="">

# rke2hpc

A redeployable, air-gap-friendly foundation for running RKE2 + Rancher as a
multi-tenant service on an HPC-style cluster: one login node, one admin node,
N compute nodes, project groups with shared quotas driven by a flat file.

It is plain bash + ssh (plus one stdlib-only Python tool on the admin node). It
does not care how the nodes were provisioned: it needs an inventory, an ssh
config, and EL9 hosts.

> **Ansible deployment:** [`ansible-rke2/`](ansible-rke2/README.md) is a
> self-contained Ansible version of this platform for other sites: inventory-driven
> admin/compute nodes, management traffic on `bond0` and pod traffic on the HSN,
> a pluggable flat-file format, CephFS CSI images in the registry, no login node.
> Copy that directory and follow its README; the bash deployer below is unchanged.

## Layout

| Host | Role | What runs there |
|------|------|-----------------|
| `l1` | login | user accounts (uid ≥ 5001), `/c/home` over NFS, `kubectl` + OIDC login plugin. Not a cluster node. |
| `a1` | admin | RKE2 server, both registries, offline dnf repo, NFS server, DNS + time for the cluster, Keycloak, Rancher, ingress |
| `c1..c3` | compute | RKE2 agents. The only nodes project pods can run on. |

`a1` and `c*` have no route to the internet. Everything they need is collected
into a bundle on the deployer (and one internet-connected EL host for RPMs) and
carried over.

```
user laptop ──ssh -D──► l1 ──► a1:443   rancher / keycloak / <app>.<project>.apps   (Traefik)
                        │      a1:6443  Kubernetes API (OIDC)
                        │      a1:5000  system registry  (TLS, basic auth, read-only on the network)
                        │      a1:5001  user registry    (TLS, anonymous, read-only)
                        └─NFS─ a1:/c/home
```

## Quick start (QEMU lab on Apple silicon)

```sh
brew install qemu skopeo            # vde ships with qemu; python3, rsync, openssl are already on macOS
lab/lab.sh up                       # 5 Rocky 9 aarch64 VMs, isolated cluster network, ~1 min
bin/hpcctl deploy                   # everything, in order (~15 min first time; downloads ~3.5 GB once)
bin/hpcctl verify                   # 94 acceptance checks, run as real users
```

Then, as a user:

```sh
bin/hpcctl secret users/bob                      # bob's initial password
ssh -p 2222 -D 1080 bob@127.0.0.1                # login node + SOCKS5 proxy
#   on l1:   kubectl get pods                    # prompts for the cluster login (device code)
#   browser: SOCKS5 127.0.0.1:1080 with remote DNS -> https://rancher.hpc.internal  ("Log in with Keycloak")
#   trust secrets/pki/ca.crt in the browser
```

Admin entry points: `bin/hpcctl kubectl ...`, `bin/hpcctl ssh a1`,
`bin/hpcctl secret rancher-admin` (local Rancher `admin`),
`bin/hpcctl secret keycloak-admin` (Keycloak `admin`),
`bin/hpcctl secret users/opsadmin` (platform admin through Keycloak).

`lab/lab.sh destroy` removes the VMs; the bundle cache, ssh key and `secrets/`
survive, so the next `up` + `deploy` is quick and keeps the same CA and
passwords. Delete `secrets/` for a truly fresh identity.

## Modules

`bin/hpcctl list` shows them; `bin/hpcctl run <name>` runs one. Each is
idempotent and can be re-run on its own.

| Module | Does |
|--------|------|
| `10-pki` | Private CA, service certificates, generated credentials — all under `secrets/` (gitignored). Drop your own `secrets/pki/ca.{crt,key}` in first to use a site CA. |
| `20-bundle` | `fetch`: RKE2 image tarballs, binaries (registry, helm, kubectl, kubelogin), charts, extra images, and an RPM repo with full dependency closure. `push`: rsync to `a1:/srv/hpc/bundle`. Checksums verified where upstream publishes them. |
| `30-base` | `/etc/hosts` block, CA trust, offline dnf repo (nginx on `a1:8443`, TLS, GPG-checked), distro repos disabled on air-gapped roles, dnsmasq + chrony on `a1`. |
| `40-registry` | Two CNCF `distribution` registries run from the release binary under systemd (no container runtime needed). Loads every bundled image. |
| `50-nfs` | `/c/home` (root-squashed, login nodes only) and `/c/k8s` (cluster nodes only) exported from `a1`; `/c/home` mounted on `l1`. |
| `60-rke2` | RKE2 from RPM (SELinux enforcing). Server on `a1`, agents on `c*`, `system-default-registry` + `registries.yaml` point at `a1`. OIDC and the `PodNodeSelector` admission plugin configured on the API server. |
| `70-platform` | NFS-backed default StorageClass, ingress certificates, Keycloak + PostgreSQL, Rancher. Sub-steps: `base`, `keycloak`, `rancher`. |
| `80-identity` | Keycloak realm, `kubernetes` and `rancher` OIDC clients, Rancher ↔ Keycloak login, platform admin group. |
| `85-login` | kubectl + kubelogin on `l1`, per-user kubeconfig generator, sshd policy. |
| `88-tenants` | Reconciles `config/projects.txt`. Re-run after every edit. |
| `89-accounting` | Usage accounting: job IDs, who ran what and for how long, CPU-hours per project, and the `hpc-acct` admin tool. Measures only; enforces nothing. See [docs/accounting.md](docs/accounting.md). |
| `90-verify` | Acceptance checks (`hpcctl verify`). |

Adding a capability later means adding a numbered directory under `modules/`
with a `run.sh` (deployer side) and optional `node/*.sh` (run as root on a host
via `node_run`, with every `site.env` setting in scope). See `lib/common.sh`.

## Configuration

| File | Purpose |
|------|---------|
| `config/site.env` | Versions, names, CIDRs, toggles. Override per site in `config/site.local.env` (gitignored). |
| `config/inventory` | `name role ip` per host. |
| `config/projects.txt` | The flat file. |
| `config/images-platform.txt` | Extra images for the system registry. |
| `config/images-user.txt` | Images published in the user registry. |
| `config/rpms.txt` | Packages carried into the offline repo. |

### The flat file

```
GROUP:CPU:MEMORY_MIB:STORAGE_GIB:CPU_HOURS: user, user, ...
BS0001:24:16000:20:1: bob, alice, amy
```

`CPU_HOURS` is an optional yearly CPU-hour allocation that usage is reported
against. It is not enforced.

For each group `hpcctl run tenants` creates/updates:

- unix group (gid from 6001) and users (uid from 5001) on the login node, homes
  in `/c/home/$USER`. Ids are allocated once and recorded on `a1`
  (`/var/lib/hpc/idmap.json`) — **back this file up**; it is what keeps uids
  stable across redeploys.
- namespace `bs0001`, pinned to compute nodes, pod security `baseline`
- one `ResourceQuota` for the whole group (cpu and memory as both requests and
  limits, `requests.storage`, no NodePort/LoadBalancer) plus a `LimitRange` so
  pods without explicit resources still count
- `NetworkPolicy`: pods reach their own namespace, DNS, the ingress controller
  and addresses outside the pod network; nothing from another project gets in
- pod defaults (admission policy): see "What every project pod gets" below
- RBAC: Kubernetes `edit` in that namespace for OIDC group `oidc:BS0001`
- Rancher project `BS0001` containing the namespace, visible to Keycloak group
  `BS0001` with a role that cannot create namespaces
- Keycloak group + users (username = unix name), same initial password as the
  unix account (`secrets/users/<name>`)
- TLS for `*.bs0001.apps.hpc.internal`; project ingresses may only use hosts
  under that name

Removing a user disables the Keycloak account and locks the unix account (uid
and home are kept). Removing a group revokes access and prints a warning; the
namespace and its data are left for an admin to delete deliberately.

## What every project pod gets

Filled in at admission, whether the pod comes from `kubectl`, a Deployment/Job
or the Rancher UI:

- `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
  `seccompProfile: RuntimeDefault` — unless the pod sets them itself.
- **Identity**: the pod runs as the unix uid of the person who submitted it,
  primary gid `hpc-users`, plus the project's gid. A pod that sets `runAsUser`
  itself keeps its choice (including `0`), but root is squashed on the home.
- **Home**: `/c/home/$USER` is mounted at the same path as on the login node
  and `HOME` points at it. Files are owned by the user on both sides.
- Volumes are limited to configMap, secret, emptyDir, projected, downwardAPI,
  ephemeral and persistentVolumeClaim; inline NFS and friends are rejected.
- Pods cannot open connections to the node network except the API, ingress and
  user registry on the admin node.

The uid/gid map the policy uses is the `hpc-identities` ConfigMap in
`kube-system`, rewritten by `hpcctl run tenants`. Pods that already exist are
not touched; they pick the defaults up when recreated.

## Usage accounting

Every workload a project runs (Deployment, Job, Pod, …) is recorded with a job
ID, the user who submitted it, start, stop, elapsed time and CPU-hours. Nothing
is limited or stopped by it. Admins use `bin/hpcctl acct`:

```sh
bin/hpcctl acct status                       # allocation / used / remaining CPU-hours per project
bin/hpcctl acct jobs --project BS0001        # job id, user, start, end, elapsed hh:mm:ss, CPU-hours
bin/hpcctl acct job 47                       # one job and its pods
bin/hpcctl acct budget BS0001 --add 10 --reason "extra allocation"
```

The accounting year starts on 1 October; history is kept across years.

- How it works, including its interaction with RKE2: [docs/accounting.md](docs/accounting.md)
- How time limits, batch-only projects and enforced budgets *could* be added
  (design only, not installed): [docs/time-limits-design.md](docs/time-limits-design.md)
- A job to try it with: [docs/examples/long-job.yaml](docs/examples/long-job.yaml)

## How the requirements are met

| Requirement | Mechanism |
|-------------|-----------|
| Secured registry for RKE2 images | `registry.hpc.internal:5000`: TLS from the site CA + basic auth. The network-facing process runs with storage in read-only mode, so the `pull` account nodes use cannot push. Publishing goes through a second process bound to `127.0.0.1:5010` on `a1` with a separate `push` account. All RKE2, Rancher, Keycloak images are pulled from it; `verify` asserts no running image comes from anywhere else. |
| Read-only registry for users | `hub.hpc.internal:5001`: same design, anonymous pull, loopback-only push on `:5011`. Unqualified image names (`busybox:1.37`) resolve to it first. Add images to `config/images-user.txt`, then `hpcctl run bundle && hpcctl run registry load`. |
| Users run only on `c[1-3]` | `PodNodeSelector` forces `hpc.io/role=compute` onto every pod in a project namespace; conflicting selectors are rejected, and an admission policy rejects `spec.nodeName`. Platform namespaces are pinned to `a1` the same way. |
| Separate namespace + network, can't see others | Namespace-scoped RBAC only (no cluster-wide list), NetworkPolicy per project, admission policy stops members editing NetworkPolicies, Rancher shows only the user's project. |
| Login node has only kubectl; dashboards via SOCKS5 | `l1` is not a cluster node and holds no admin credentials. `ssh -D` is allowed for project users; Rancher/Keycloak resolve and route from `l1`. |
| Keycloak, OIDC name = unix name | `preferred_username` is the Kubernetes username with no prefix; groups get `oidc:`. An upstream OIDC provider can be brokered later (`UPSTREAM_OIDC_*` in `site.env`): upstream authenticates, the flat file authorises. |
| uids from 5001, homes on NFS from admin node | `50-nfs` + `88-tenants`. |
| Quota shared by the group | One namespace per group, one ResourceQuota, members cannot create further namespaces. |

## Moving to a real site (x86_64)

1. `config/site.local.env`: `ARCH=amd64`, your domain/CIDRs, `HPC_SSH_CONFIG=`
   an ssh config that reaches every host by inventory name as a sudo-capable
   user, `RPM_FETCH_HOST=` an EL9 x86_64 box with internet.
2. `config/inventory`: your hosts.
3. Nodes must resolve the service names through DNS (pods do not read
   `/etc/hosts`). Either point the nodes' resolver at the admin node
   (`MANAGE_DNS=true` runs dnsmasq there) or add the records to site DNS
   (including the `*.apps` wildcard) and set `MANAGE_DNS=false`.
4. `bin/hpcctl deploy`.

`lab/` is the only arch-specific part and nothing in `modules/` depends on it.

## Known limits

- Single RKE2 server and single Keycloak/Rancher replica: `a1` is a single point
  of failure, matching the one-admin-node layout. etcd snapshots are on (local
  disk, 10 kept) — copy `/var/lib/rancher/rke2/server/db/snapshots` off the node.
- No host firewall is configured. The air gap and ssh policy are the perimeter.
- NFS volumes do not enforce their size; the quota limits what can be
  *requested*. Ephemeral storage is not quota'd.
- Keycloak's `admin` is the bootstrap account. Create a named admin and remove
  it before production use.
- No job queue and no run-time limits: a job that does not fit the CPU/memory
  quota is refused at submission; anything admitted may run indefinitely.
- User passwords: unix and Keycloak start equal but are separate afterwards
  (`passwd` on `l1` vs. the Keycloak account page). PAM/SSSD against Keycloak
  would be a follow-on module.
- On the login node, `*.apps` names need site DNS (in the lab `l1` uses the NAT
  resolver, so only the fixed service names in `/etc/hosts` resolve there).
- `KEYCLOAK_ALLOW_PASSWORD_GRANT=true` and `LOGIN_SSH_PASSWORD_AUTH=true` are
  lab conveniences (`verify` needs the former). Review both for production.
