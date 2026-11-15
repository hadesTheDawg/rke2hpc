# CephFS volumes

The system registry always carries everything the CephFS CSI driver needs, so
CephFS can be switched on at any time without a new bundle:

| Image (published at `registry.<domain>:5000/...`) | Used by |
|-----|---------|
| `cephcsi/cephcsi:v3.18.2` | node plugin + provisioner (the driver itself, ceph userspace) |
| `sig-storage/csi-node-driver-registrar:v2.18.0` | node plugin |
| `sig-storage/csi-provisioner:v6.3.0` | provisioner |
| `sig-storage/csi-attacher:v4.13.0` | provisioner |
| `sig-storage/csi-resizer:v2.2.1` | provisioner (volume expansion) |
| `sig-storage/csi-snapshotter:v8.6.0` | provisioner (snapshots) |

plus the `ceph-csi-cephfs-3.18.2.tgz` chart in the bundle
(`/srv/hpc/bundle/charts/` on the admin node). The snapshot CRDs and
snapshot-controller come with RKE2. The list is `hpc_images_ceph` in
`roles/bundle/defaults/main.yml`; it matches the chart's `values.yaml`. When
bumping `hpc_ceph_csi_chart_version`, update the tags there and in
`roles/ceph_csi/templates/values.yaml.j2`.

## Turning it on

```yaml
# inventories/<site>/group_vars/all.yml
hpc_enable_ceph_csi: true
hpc_ceph_cluster_id: "b5a1c2d3-...-fsid"        # ceph fsid
hpc_ceph_monitors: ["10.200.0.1:6789", "10.200.0.2:6789", "10.200.0.3:6789"]
hpc_ceph_fs_name: cephfs
hpc_ceph_subvolume_group: csi
hpc_ceph_user_id: k8s                            # client.k8s
hpc_ceph_user_key: "{{ vault_ceph_user_key }}"   # ansible-vault
hpc_storage_backend: cephfs                      # make it the default StorageClass (nfs stays available)
```

```sh
ansible-playbook -i inventories/<site>/hosts.yml site.yml --tags ceph,platform
```

This installs the driver in namespace `ceph-csi-cephfs` (provisioner on the
admin node, node plugin on every node), the Ceph secret, a `cephfs`
StorageClass and a VolumeSnapshotClass. Project pods then use CephFS through
ordinary PersistentVolumeClaims (inline volumes stay forbidden for projects),
and the project quota's `requests.storage` limits what they can claim.

Without the Ceph connection settings only the driver is installed (that is
what the lab does, to prove every image comes from the internal registry).

Ceph side, for the CSI user (see the ceph-csi docs for the current caps):

```
ceph fs subvolumegroup create cephfs csi
ceph auth get-or-create client.k8s mon 'allow r' osd 'allow rw tag cephfs metadata=*' mgr 'allow rw' mds 'allow rw'
```

## Node requirements

- The `ceph` kernel module (kernel client). The role checks `modprobe -n ceph`
  on every node and warns where it is missing (minimal images may lack the
  `kernel-modules` package; it must match the running kernel, so install it
  with the kernel, not from the bundle).
- A route from every node to the Ceph monitors and OSDs. Mounts are made by
  the node plugin, which runs in the host network, so they follow the nodes'
  routing (e.g. over an HSN port or a storage network). Add that network to
  `hpc_node_cidrs` so project pods cannot reach Ceph directly.

## Home directories on CephFS

Pods get their owner's home mounted from NFS (`hpc_home_volume: nfs`,
`hpc_home_nfs_server`, `hpc_home_nfs_path`). If the homes live on CephFS:

- export them through the Ceph NFS gateway (NFS-Ganesha) and point
  `hpc_home_nfs_server` / `hpc_home_nfs_path` at it; set
  `hpc_home_create_root: ""` if the directories are created on the Ceph side; or
- set `hpc_home_volume: none` so pods get no home mount, and let projects use
  CephFS claims for their data.

Mounting CephFS homes directly into pods would need one static PersistentVolume
per user and namespace; that is not implemented.
