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
`_accounting`, `_backup` (on when `hpc_backup_dir` is set), `_charts_repo`
(on, [charts.md](charts.md)), `_upstream_idp` (on when an upstream provider is
configured, [upstream-idp.md](upstream-idp.md)), `_trivy` (off,
[trivy.md](trivy.md)), `_harvester` (off, [harvester.md](harvester.md)).
See [extending.md](extending.md).

## Running the deployment

[operations.md](operations.md).

| Variable | Default | |
|----------|---------|-|
| `hpc_agent_batch` | `0` | compute nodes restarted at a time when their RKE2 config/version changes (`0` = all) |
| `hpc_agent_restart_timeout` | `600` | seconds a restarted compute node may take to answer |
| `hpc_compute_max_failed` | `-1` | stop after the RKE2 stage when more compute nodes failed (`-1` = never) |
| `hpc_run_log` | `<inventory dir>/logs/runs.log` | one line per site.yml run |

## Helm charts

| Variable | Default | |
|----------|---------|-|
| `hpc_charts_extra` | `[]` | more chart URLs for the bundle and the local chart repository |
| `hpc_charts_url` | `https://<admin>.<domain>:8443/charts` | where the admin node serves them |
| `hpc_charts_rancher_repo` | `hpc-local` | Rancher catalog name |

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

## Bundle, packages, versions

| Variable | Default | |
|----------|---------|-|
| `hpc_bundle_fetch` | `true` | `false`: push the bundle already on the deployer, no download |
| `hpc_bundle_force` | `false` | fetch and push even when the admin node already runs this bundle (below) |
| `hpc_rke2_upgrade` | `false` | change the RKE2 version of nodes that have RKE2 installed ([rollback.md](rollback.md)) |
| `hpc_rpms_extra` | `[]` | more RPMs (with dependencies) for the offline repository |
| `hpc_bundle_trivy` | `true` | Trivy operator, scanner and vulnerability DB in the bundle |
| `hpc_trivy_db_refresh` | `false` | `-e` only: download today's vulnerability DB and publish it ([trivy.md](trivy.md)) |
| `hpc_bundle_harvester` | `hpc_enable_harvester` | RKE2 Harvester images, Harvester UI extension |
| `hpc_local_rpms_dir`, `hpc_local_rpms_gpgkey`, `hpc_local_packages*` | | your own RPMs ([rpms.md](rpms.md)) |

**What a re-run skips.** On a site that is already deployed, `site.yml`
does not repeat the expensive steps:

- **Bundle** (download, RPM resolution on `rpm_fetch`, push): skipped when
  all of these hold:
  - the admin node holds this exact bundle;
  - the registries and `rke2-server` run, and every `kube-system` pod is
    Running.

  "This exact bundle" means its manifest matches. The manifest
  (`roles/bundle/templates/MANIFEST.j2`) lists every version, image and RPM
  name, so changing any of those settings makes the next run fetch again.
  The run then needs no internet and no `rpm_fetch` host. The bundle role
  prints which check failed when it does not skip.
- **Registry publishing**: skipped while `<data root>/registry/.hpc-published`
  matches the bundle's manifest. When it does not match, for example after
  the registry storage was lost, the images are published again from the
  admin node's copy of the bundle, without a download.
- **RKE2 packages**: a node that has RKE2 is never reinstalled. Only missing
  packages are installed, RKE2 at exactly `hpc_rke2_version`. A different
  installed version is reported, and left alone unless `hpc_rke2_upgrade=true`.

## Certificates

Own certificates and a site CA are files in `secrets/pki/`, not settings:
[certificates.md](certificates.md).

## Identity and tenancy

`hpc_keycloak_realm`, `hpc_uid_start` (5001), `hpc_gid_start` (6001),
`hpc_platform_admin_group`, `hpc_platform_admin_users`, `hpc_oidc_group_prefix`,
`hpc_keycloak_allow_password_grant` (true; verify.yml needs it, turn it off
afterwards), `hpc_initial_passwords_temporary`, `hpc_upstream_oidc_*`
(broker an upstream OIDC provider), `hpc_tenant_pod_security`,
`hpc_tenant_default_*` (LimitRange defaults and the default CPU-hour allocation).

Upstream identity provider: `hpc_upstream_oidc_config_file` (saved
openid-configuration, JSON or `key: value`), `hpc_upstream_oidc_discovery_url`,
`hpc_upstream_oidc_issuer`, `hpc_upstream_oidc_client_id`, `_alias`,
`_display_name`, `_scopes`, `_username_claim`, `_client_auth`, `_spoof`:
[upstream-idp.md](upstream-idp.md).

## Trivy and Harvester

`hpc_trivy_*`: [trivy.md](trivy.md). `hpc_harvester_*`: [harvester.md](harvester.md).
