# Rollback

`rollback.yml` (role `roles/rollback`) has three modes:

| Mode | What it does |
|------|--------------|
| `list` | Shows the restore points. Changes nothing. |
| `previous` | Takes the cluster back to an earlier state: by default the one before the last RKE2 version change, or any etcd snapshot you name. RKE2 goes back to the version of that state. |
| `uninstall` | Removes what `site.yml` installed: from every node, or only from some compute nodes, which then leave the cluster. |

`previous` and `uninstall` change the cluster. They stop unless you confirm
them with the cluster's name (`hpc_cluster_name`):
`-e hpc_rollback_confirm=<name>`.

## Version changes and their restore point

`site.yml` never reinstalls or changes an RKE2 that is already installed.
Raising `hpc_rke2_version` alone only prints a notice. To move an installed
cluster to `hpc_rke2_version`, newer or older, ask for it explicitly:

```sh
$EDITOR inventories/<site>/group_vars/all.yml                 # hpc_rke2_version: v1.36.6+rke2r2
ansible-playbook -i inventories/<site>/hosts.yml bundle.yml   # gets the new version's RPMs and images
ansible-playbook -i inventories/<site>/hosts.yml site.yml -e hpc_rke2_upgrade=true
```

Before it changes the server, the rke2 role:

1. saves an etcd snapshot, `hpc-pre-upgrade-<node>-<time>`, and copies it into
   `hpc_backup_dir/etcd/` when there is one;
2. records the old and new version, the Rancher chart version and the
   snapshot in `/var/lib/hpc/rollback/state.json`, with a copy in
   `inventories/<site>/secrets/state/rollback.json`.

Then it installs the new RPMs on the server, then on the compute nodes (their
play runs after the server's), and restarts RKE2 on each.

## list

```sh
ansible-playbook -i inventories/<site>/hosts.yml rollback.yml -e hpc_rollback_mode=list
```

From the lab, after an upgrade:

```
installed: RKE2 v1.36.6+rke2r2; hpc_rke2_version v1.36.6+rke2r2
in the repository: 1.36.6~rke2r1, 1.36.6~rke2r2
last version change 2026-11-24T22:21:15Z: RKE2 v1.36.6+rke2r1 -> v1.36.6+rke2r2, Rancher was 2.15.3, snapshot hpc-pre-upgrade-a1-1795558875
snapshots, newest first:
  hpc-backup-a1-1795559075           2026-11-24 22:24  backup+local
  hpc-pre-upgrade-a1-1795558875      2026-11-24 22:21  local+backup
  hpc-backup-a1-1795558129           2026-11-24 22:08  backup+local
  etcd-snapshot-a1-1794873602        2026-11-17 00:00  local
  ...
  ... and 23 older (-e hpc_rollback_list_max=38 shows all)
```

Snapshots are looked for in two places:

- `local`: RKE2's snapshot directory on the admin node,
  `/var/lib/rancher/rke2/server/db/snapshots`. It holds RKE2's scheduled
  `etcd-snapshot-*` and every `hpc-*`;
- `backup`: `hpc_backup_dir/etcd`, with the hourly `hpc-backup-*` and copies
  of `hpc-pre-upgrade-*`.

## previous

```sh
# back to the state before the last version change, with the old RKE2 version
ansible-playbook -i inventories/<site>/hosts.yml rollback.yml -e hpc_rollback_mode=previous -e hpc_rollback_confirm=hpc

# back to a chosen snapshot (name from list, or a path on the admin node)
ansible-playbook -i ... rollback.yml -e hpc_rollback_mode=previous -e hpc_rollback_snapshot=hpc-backup-a1-1795604400 -e hpc_rollback_confirm=hpc

# a chosen snapshot and a chosen RKE2 version
ansible-playbook -i ... rollback.yml -e hpc_rollback_mode=previous -e hpc_rollback_snapshot=... -e hpc_rollback_rke2_version=v1.36.6+rke2r1 -e hpc_rollback_confirm=hpc
```

Which version: `hpc_rollback_rke2_version` if given. Otherwise the recorded
old version when the snapshot is the recorded pre-upgrade one. Otherwise the
installed version stays.

Steps:

1. **Checks, before anything changes.** The snapshot exists. The RKE2
   version is in the package repository (`rke2-server` and `rke2-agent`).
   The play covers every node. It prints the plan.
2. **Admin node.** Saves `hpc-pre-rollback-<node>-<time>`, a snapshot of the
   current state, so the rollback itself can be undone. Stops RKE2 and every
   container on the node (`rke2-killall.sh`). Installs the RKE2 version
   (downgrade). Runs `rke2 server --cluster-reset
   --cluster-reset-restore-path=<snapshot>` and starts the server.
3. **Compute nodes.** If the version changes, stops `rke2-agent` and
   installs the server's version. Project pods keep running while the agent
   is stopped.
4. **Refresh.** Restarts `rke2-agent` and kube-proxy on the compute nodes,
   and recreates the platform pods there, as after an automatic restore
   (docs/reprovisioning.md). Then waits until every node is Ready.

Afterwards:

- **Put the versions back in `group_vars`.** The last message prints the
  lines, e.g. `hpc_rke2_version: v1.36.6+rke2r1` and `hpc_rancher_version:
  2.15.3`. Otherwise the next `site.yml` warns about the mismatch, and the
  rancher role upgrades Rancher again.
- **Run `site.yml`.** It re-applies what lives outside etcd.

What a snapshot does **not** take back: the Keycloak database (users and
groups created since stay; `site.yml` reconciles them against the flat file),
NFS/CephFS volume contents, the accounting database, and images in the
registries. The registries never delete images, so the old Rancher and RKE2
images are still there after a rollback.

When the old version's RPMs are gone from the repository, the checks say
so. Bring them back with
`bundle.yml -e hpc_rke2_version=<old> -e hpc_bundle_force=true`, or import
the `rke2-server`, `rke2-agent` and `rke2-common` RPMs of that version with
`./import-rpms.sh`.

## uninstall

```sh
# everything
ansible-playbook -i inventories/<site>/hosts.yml rollback.yml -e hpc_rollback_mode=uninstall -e hpc_rollback_confirm=hpc
# only some compute nodes: they are also deleted from the cluster
ansible-playbook -i ... rollback.yml -e hpc_rollback_mode=uninstall -e hpc_rollback_confirm=hpc --limit cn003,cn004
```

The admin node can only be uninstalled together with every other node.

Before the server goes, a last etcd snapshot `hpc-pre-uninstall-*` is saved
into `hpc_backup_dir/etcd`. Without a backup directory it goes to
`secrets/snapshots/` on the deployer. `-e hpc_rollback_final_snapshot=false`
skips it.

Removed from **every selected node**:

- RKE2 (`rke2-uninstall.sh`: the `rke2-*` RPMs, `/etc/rancher`,
  `/var/lib/rancher/rke2` with etcd, kubelet and CNI state, every container);
- the NetworkManager rule for the CNI interfaces, `kubectl`/`helm` in
  `/usr/local/bin`, the root `KUBECONFIG` profile;
- the `hpc-offline` and `hpc-local` repositories. Distro repositories that
  `site.yml` disabled are enabled again;
- the managed block in `/etc/hosts`, and the site CA in the system trust
  store;
- `chrony.conf`: the original goes back.

Also removed from the **admin node**:

- the registries, the accounting recorder, the backup timer, and their
  units;
- `hpc-sync`, `hpc-acct`, `hpc-backup`, `/etc/hpc`, `/etc/pki/hpc`;
- the dnsmasq configuration, and the NFS exports. nfs-server is stopped if
  it exports nothing else;
- nginx, stopped, with its original configuration back.

Kept unless you ask:

- `hpc_data_root` (bundle copy, registry storage, repositories) and
  `/var/lib/hpc`. `-e hpc_rollback_purge_data=true` deletes them, and the
  Keycloak database when it is on the admin node's local disk.

Never touched: `hpc_persist_root` and the exported directories (homes,
volumes), `hpc_backup_dir`, the deployer's `secrets/`, and packages other
than RKE2 (nginx, dnsmasq, chrony, nfs-utils... stay installed).

The original `chrony.conf` and `nginx.conf` and the list of disabled
repositories are recorded by `site.yml` before it first changes them. Nodes
set up by an older version of this directory have no such record; for those,
uninstall prints a warning naming what to fix by hand.

### Re-deploying after an uninstall

`site.yml` builds the cluster again, with the same CA, tokens and passwords
from `secrets/`. **With `hpc_backup_dir` set, the new admin node restores the
newest `hpc-backup-*` snapshot**, the same automatic restore as after a
re-provision. That brings the old cluster back. For a new, empty cluster,
move `<backup dir>/etcd` away first or set `hpc_rke2_restore: false`.

## Settings

| Variable | Default | |
|----------|---------|-|
| `hpc_rollback_mode` | `''` | `list`, `previous`, `uninstall` |
| `hpc_rollback_confirm` | `''` | must equal `hpc_cluster_name` |
| `hpc_rollback_snapshot` | recorded pre-upgrade snapshot | previous: name or path |
| `hpc_rollback_rke2_version` | recorded / installed | previous: version after the restore |
| `hpc_rollback_final_snapshot` | `true` | uninstall: snapshot before removing the server |
| `hpc_rollback_purge_data` | `false` | uninstall: delete `hpc_data_root`, `/var/lib/hpc` |
| `hpc_rke2_upgrade` | `false` | site.yml: change the version of installed RKE2 nodes |
