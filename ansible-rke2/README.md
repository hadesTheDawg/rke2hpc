# ansible-rke2

Ansible deployment of the HPC multi-tenant RKE2 platform: an admin node (RKE2
server, registries, offline package repo, NFS, DNS/time, Keycloak, Rancher)
and any number of compute nodes (RKE2 agents, the only place project pods
run), with project groups, quotas and users driven by a flat file.

This directory is self-contained. Copy it anywhere (your laptop, a bastion)
and run it from there; nothing outside it is used.

```
laptop (ansible) ──ssh over bond0──► admin node  rke2-server, registries :5000/:5001, repo :8443,
                                     │            NFS, dnsmasq, chrony, Keycloak, Rancher, ingress
                                     └─► compute nodes  rke2-agent
           bond0 (management): node IP, API, kubelet, registry pulls, NFS, ssh
           hsn0  (high-speed): every pod-to-pod packet between nodes (VXLAN overlay)
```

## Requirements

On the machine you run ansible from:

- `ansible-core` 2.16 or newer (`pipx install ansible-core` or `uv tool install ansible-core`).
  No collections are needed; only `ansible.builtin` is used.
- `python3`, `openssl`, `rsync`, `curl`, `tar`, `unzip`, and `skopeo` (to download images).
- ssh access to every node's management address as a user with sudo.
  The deployer does not need to reach the HSN or any other network.

The nodes: EL9 (Rocky/Alma/RHEL) on the architecture given by `hpc_arch`,
SELinux enforcing is fine. Nodes can be fully offline; the bundle carries
everything (RPMs, images, binaries, charts). Downloading the bundle needs
internet on the laptop and an internet-connected EL9 host of the same
architecture (inventory group `rpm_fetch`) to resolve the RPMs, unless the
nodes use their own repositories (`hpc_offline_repo: false`).

## Quick start

```sh
cp -r inventories/example inventories/mysite
$EDITOR inventories/mysite/hosts.yml           # admin node, compute nodes, rpm_fetch host
$EDITOR inventories/mysite/group_vars/all.yml  # domain, interfaces, storage
$EDITOR inventories/mysite/projects.txt        # the flat file

python3 roles/tenants/files/hpc_flatfile.py check inventories/mysite/projects.txt
ansible-playbook -i inventories/mysite/hosts.yml site.yml      # ~20 min the first time
ansible-playbook -i inventories/mysite/hosts.yml verify.yml    # acceptance checks
```

Generated state goes next to the inventory: `inventories/mysite/secrets/`
(CA, certificates, every password, a backup of the uid/gid map). **Keep and
back up that directory**; it is what makes a redeploy keep the same CA, uids
and passwords. The download cache is `.bundle/<arch>/` (several GB).

| Playbook | Use |
|----------|-----|
| `site.yml` | Everything, in order. Idempotent; re-run any time. `--tags rke2,platform` etc. for parts. |
| `bundle.yml` | Download and push the offline bundle only (`-e hpc_bundle_fetch=false`: push only). |
| `tenants.yml` | Apply an edited flat file. |
| `verify.yml` | Acceptance checks, run as real users (needs `hpc_keycloak_allow_password_grant: true`). |
| `acct.yml` | Accounting reports: `-e 'acct="jobs --project BS0001"'`. |

Credentials: `inventories/<site>/secrets/rancher-admin` (Rancher `admin`),
`keycloak-admin` (Keycloak `admin`), `users/<name>` (initial password of each
user and of the platform admin `opsadmin`).

## Documentation

| | |
|-|-|
| [docs/networking.md](docs/networking.md) | bond0 / HSN split: what goes where, and how it is configured and checked |
| [docs/flatfile.md](docs/flatfile.md) | The flat file, and how to add/remove columns (e.g. drop CPU_HOURS) |
| [docs/ceph.md](docs/ceph.md) | CephFS CSI: what the registry carries, turning it on, homes on CephFS |
| [docs/variables.md](docs/variables.md) | Every setting and where it is defined |
| [docs/extending.md](docs/extending.md) | Switching components off, replacing them, adding new ones |
| [docs/lab-testing.md](docs/lab-testing.md) | The QEMU lab used to test this, and what was verified |
| [docs/accounting.md](docs/accounting.md) | Usage accounting (measures only, enforces nothing) |

## What gets deployed

Same platform as the bash deployer in the parent repository, minus the login
node (manage those yourself; `secrets/state/accounts.json` lists the unix
users/groups with their uids/gids):

- **Registries** on the admin node: `registry.<domain>:5000` (TLS + basic auth,
  read-only over the network; RKE2, Rancher, Keycloak, CephFS CSI images) and
  `hub.<domain>:5001` (anonymous, read-only; user images). Publishing only
  through loopback ports on the admin node.
- **RKE2** from RPM, SELinux on, every image from the system registry, OIDC
  against Keycloak, `PodNodeSelector` pinning project namespaces to compute
  nodes and platform namespaces to the admin node.
- **Keycloak** (+PostgreSQL) and **Rancher**, logins through Keycloak.
- **Projects** from the flat file: one namespace per group with a shared
  ResourceQuota, LimitRange, NetworkPolicy isolation, RBAC for the Keycloak
  group, Rancher project, Keycloak users and groups, uids from 5001 / gids from
  6001, home directories on NFS mounted into every pod, pods run as the
  submitting user.
- **Accounting**: job ids, users, elapsed time, CPU-hours per project.
- **Storage**: NFS StorageClass from the admin node, and/or CephFS CSI.
