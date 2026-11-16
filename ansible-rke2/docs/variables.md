# Settings

All defaults, with comments, live in two files:

- `roles/hpc_common/defaults/main.yml`: everything shared (layout, networks,
  versions, names, storage, identity, components, generated credentials)
- `roles/bundle/defaults/main.yml`: what goes into the offline bundle (image
  lists, RPM list)

Override in `inventories/<site>/group_vars/all.yml`, per node in
`inventories/<site>/host_vars/<node>.yml`. Secrets: an ansible-vault file in
`group_vars/`.

## The ones every site sets

| Variable | Default | |
|----------|---------|-|
| `hpc_arch` | `amd64` | `amd64` or `arm64`; must match the nodes |
| `hpc_domain` | `hpc.internal` | service names below it resolve to the admin node |
| `hpc_mgmt_iface` | `bond0` | management network: node IP, every host service |
| `hpc_pod_iface` | `hsn0` | pod-to-pod overlay; `''` = management |
| `hpc_pod_mtu` | `0` (1450) | pod MTU; HSN MTU − 50 for jumbo frames |
| `hpc_cluster_cidr`, `hpc_service_cidr` | `10.42.0.0/16`, `10.43.0.0/16` | must not overlap any node network (preflight checks) |
| `hpc_offline` / `hpc_offline_repo` | `true` / `true` | nodes have no internet / RPMs come from the bundle |
| `hpc_storage_backend` | `nfs` | default StorageClass: `nfs`, `cephfs`, `none` |
| `hpc_projects_file` | `<inventory dir>/projects.txt` | the flat file |

## Inventory

| Group | |
|-------|-|
| `rke2_servers` | exactly one host: the admin node |
| `rke2_agents` | compute nodes |
| `rpm_fetch` | optional: internet-connected EL9 host of the target arch (only for `hpc_offline_repo`) |

Hosts are named as they should appear in Kubernetes; `ansible_host` is the
address the deployer uses (management network).

## Per-node

| Variable | |
|----------|-|
| `hpc_mgmt_iface`, `hpc_pod_iface` | interface names on this node |
| `hpc_mgmt_ip`, `hpc_pod_ip` | pin addresses instead of reading them from the interfaces |

## Derived (normally left alone)

| Variable | Derived from |
|----------|--------------|
| `hpc_admin_host` | first host of `rke2_servers` |
| `hpc_admin_ip` | admin node's `hpc_mgmt_ip` |
| `hpc_mgmt_cidr`, `hpc_pod_net_cidr` | admin node's interface facts |
| `hpc_node_cidrs` | `[hpc_mgmt_cidr, hpc_pod_net_cidr]`; networks pods may not reach |
| `hpc_site_dir`, `hpc_secrets_dir` | the inventory directory, `<it>/secrets` |
| `hpc_bundle_dir` | `.bundle/<arch>` next to the playbooks |
| `hpc_registry_*_password`, `hpc_rke2_*_token`, ... | generated once in `hpc_secrets_dir` |

## Components

`hpc_enable_bundle`, `_base`, `_registry`, `_nfs_server`, `_rke2`, `_platform`,
`_ceph_csi` (off), `_keycloak`, `_rancher`, `_identity`, `_tenants`,
`_accounting`, `_backup` (on when `hpc_backup_dir` is set). See [extending.md](extending.md).

## Storage and homes

| Variable | Default | |
|----------|---------|-|
| `hpc_data_root` | `/srv/hpc` | admin node: bundle, registry storage, repo |
| `hpc_home_root` | `/c/home` | home path inside pods |
| `hpc_nfs_home_export`, `hpc_nfs_k8s_export` | `/c/home`, `/c/k8s` | exports on the admin node (under `hpc_persist_root` when set) |
| `hpc_nfs_home_extra_clients` | `[]` | more hosts/CIDRs allowed to mount homes (login nodes) |
| `hpc_pod_identity` | `name` | `name`: pods carry the submitter's unix name (label + annotation `hpc.io/user`) and run as the image's user. `uid`: they also run as the submitter's uid/gid |
| `hpc_home_volume` | `none` | `nfs`: mount the owner's home into project pods (needs `hpc_pod_identity: uid`) |
| `hpc_home_nfs_server`, `hpc_home_nfs_path` | admin node, export | where pod homes come from |
| `hpc_home_create_root` | the export when homes are on | where hpc-sync creates new homes (`''` = elsewhere) |

Turning homes on: `inventories/example/group_vars/all.yml-with-user-home.example`.
| `hpc_ceph_*` | | [ceph.md](ceph.md) |

## Re-provisioned nodes

[reprovisioning.md](reprovisioning.md).

| Variable | Default | |
|----------|---------|-|
| `hpc_persist_root` | `''` | storage that outlives the admin node; moves exports, Keycloak DB and backups there |
| `hpc_persist_require_mount` | `true` | preflight: `hpc_persist_root` must not be on `/` |
| `hpc_backup_dir` | `<persist root>/backup` | etcd + accounting backups (`''` = none) |
| `hpc_backup_schedule`, `hpc_backup_keep` | `hourly`, `48` | systemd OnCalendar, copies kept |
| `hpc_rke2_restore` | `true` | restore the newest snapshot onto an admin node that has no etcd |
| `hpc_nfs_export_fsid` | `true` with a persist root | fixed `fsid` per export (needed on CephFS) |

## Identity and tenancy

`hpc_keycloak_realm`, `hpc_uid_start` (5001), `hpc_gid_start` (6001),
`hpc_platform_admin_group`, `hpc_platform_admin_users`, `hpc_oidc_group_prefix`,
`hpc_keycloak_allow_password_grant` (true; verify.yml needs it, turn it off
afterwards), `hpc_initial_passwords_temporary`, `hpc_upstream_oidc_*`
(broker an upstream OIDC provider), `hpc_tenant_pod_security`,
`hpc_tenant_default_*` (LimitRange defaults and the default CPU-hour allocation).
