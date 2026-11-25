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

## Re-provisioning test (2026-11-15)

`lab.sh reprovision <node>` wipes a node's root disk and boots it with a new
cloud-init instance. The admin VM's second disk, mounted at
`/rhev/data-center/mnt/cephfs`, stands in for the site's CephFS and is kept
([reprovisioning.md](reprovisioning.md)). Production defaults: no homes,
`hpc_pod_identity: name`.

| Step | Result |
|------|--------|
| fresh lab, `site.yml`, `verify.yml` | 99 checks passed |
| `reprovision c2`, `site.yml`, `verify.yml` | 99 passed; c2 rejoined under its old name (fixed node password) |
| `reprovision a1` with no snapshot while c1-c3 still belong to the cluster | `site.yml` stops before RKE2 starts, with the "Refuse to start a second cluster" message |
| `reprovision a1`, `site.yml`, `verify.yml` | etcd restored from the newest snapshot, compute nodes refreshed, accounting history restored: 101 checks passed, no manual step |
| `site.yml` + `verify.yml` with `-e @inventories/lab/group_vars/all.yml-with-user-home.example` | uid/gid + NFS homes on the persistent storage: 106 checks passed |

Found on the way: right after an etcd restore, watchers on the compute nodes
(Calico, a CoreDNS replica) kept the pre-restore view and missed new objects.
New Services did not resolve and network policy was stale until they
restarted. The restore now recreates those pods.

## Own certificates, re-runs, site RPMs, rollback (2026-11-24)

Started from the lab as the 2026-11-15 tests left it (cluster deployed,
RKE2 v1.36.6+rke2r1). A made-up "Example Corp" root and issuing CA signed
`own/ingress.crt` (Rancher, Keycloak) and `own/admin.crt` (registries,
repository); `own/ca.crt` held both CA certificates.

| Step | Result |
|------|--------|
| `site.yml` with the own certificates | installed; every endpoint serves them (new verify checks), the loopback push endpoints keep the internal `local` certificate. RKE2 not reinstalled, images not re-published. Bundle fetched once (new manifest format) |
| `site.yml` again | 89 s; bundle and image publishing skipped, nothing changed on the compute nodes |
| `verify.yml` | Rancher could not log users in through Keycloak: it reads the trust bundle only at start. Fixed: Rancher and Keycloak restart when their pods are older than the bundle. Then **108 checks passed** |
| `import-rpms.sh` with an x86_64 RPM | refused on the admin node: "architecture x86_64, the nodes are aarch64" |
| `import-rpms.sh --install hpc-hello,tree` (site-built RPM + one from the distro) | `hpc-local` on every node, both installed everywhere |
| import `hpc-hello` 1.1, `--install hpc-hello --on c1` | c1 updated to 1.1, c2 kept 1.0 |
| `site.yml -e hpc_rke2_version=v1.36.6+rke2r2` | RKE2 left at r1 on every node, with the notice; the r2 images published |
| same with `-e hpc_rke2_upgrade=true` and `hpc_local_packages_compute: [words]` | 236 s: snapshot `hpc-pre-upgrade-*` (local + backup dir), record written (and copied to `secrets/state/rollback.json`), server then agents on r2, `words` on the compute nodes. verify: 108 passed |
| ConfigMap `rollback-marker` created, then `rollback.yml` previous | back on r1 everywhere, marker gone (state of the pre-upgrade snapshot) |
| previous with `hpc_rollback_snapshot=hpc-pre-rollback-*` and `hpc_rollback_rke2_version=v1.36.6+rke2r2` (undo the rollback) | r2 again, marker back |
| previous (defaults) again, `site.yml`, `verify.yml` | r1; site.yml changed nothing on the compute nodes; 108 passed |
| node re-provisioned (`lab.sh reprovision c3`), `site.yml` | c3 back with RKE2 at exactly `hpc_rke2_version`; its original `chrony.conf` and the repositories it disabled recorded |
| `rollback.yml` uninstall `--limit c3` | c3: RKE2 RPMs and state gone, Rocky repositories enabled again, original `chrony.conf` back, hosts block and CA removed; Node deleted from the cluster. `site.yml` added it back |
| `rollback.yml` uninstall (all) | final snapshot `hpc-pre-uninstall-*` in the backup dir; every service and file of the deployment gone from a1; warnings on c1, c2, a1 (set up before originals were recorded). Re-run after a failed run finished cleanly |
| `site.yml` after the uninstall, `verify.yml` | 288 s: the backup dir's newest `hpc-backup-*` restored, the old cluster back (as the uninstall notice says); 108 passed |
| own certificates removed again, `site.yml`, `verify.yml` | internal certificates re-issued (new keys), Rancher and Keycloak restarted for the smaller bundle; 108 passed |

Found on the way:

- The rollback checks ran `run_once` on the admin node. When a check
  failed, only that host stopped: the compute nodes went on to the next
  plays. Every rollback play is now `any_errors_fatal`.
- Rancher could not log users in through Keycloak after the CA bundle
  changed: it reads the bundle only at start. Rancher and Keycloak now
  restart when their pods are older than `/etc/pki/hpc/ca.crt`.
- After a restore onto a cluster whose compute nodes were also wiped
  (uninstall all, then `site.yml`), the refresh waited for platform pods on
  nodes that had not joined yet. It now refreshes only compute nodes that
  have rke2-agent.
- A comment in the bundle manifest template was part of the manifest, so
  editing it meant a new download. Comments are now Jinja comments.
- Going back from an own ingress certificate to the internal one, Traefik
  kept serving the old one for Keycloak: it picks by SNI from every ingress
  secret, and Rancher's secret (updated later, by the rancher role) still
  covered both names. The platform role now updates Rancher's and
  Keycloak's ingress secrets together.

## Process improvements, charts, upstream IdP, Trivy, Harvester (2026-11-25)

Started from the lab as the 2026-11-24 tests left it. Lab settings added in
`inventories/lab/group_vars/all.yml`: `hpc_agent_batch: 1`,
`hpc_enable_trivy`, `hpc_enable_harvester` (UI extension only),
`hpc_upstream_oidc_spoof`.

| Step | Result |
|------|--------|
| `CHECK_UVX=1 ./check.sh inventories/lab/hosts.yml` | syntax of 7 playbooks, flat file, 11 scripts, 6 Python files, yamllint, ansible-lint, shellcheck: all passed |
| `site.yml --check --diff` on the deployed cluster | 88 s, no failure; predicted exactly the new nginx locations and chart values |
| `bundle.yml` | charts (5, incl. trivy-operator and the Harvester extension), `rke2-images-harvester`, Trivy images and DBs, extension files fetched and pushed |
| `site.yml` | chart repository indexed and served, Rancher catalog `hpc-local` Downloaded, Trivy operator, Harvester extension `cached` by Rancher from the admin node, upstream IdP |
| `site.yml` again | 107 s; 0 changes on compute nodes; Helm revisions of Rancher, NFS, CephFS, Trivy, Harvester unchanged (before: every run made a new Rancher revision; it had reached 17) |
| `verify.yml` | **126 checks passed** (108 before + 18 new: chart repository, upstream login linked / stranger refused, Trivy reports offline, Harvester extension) |
| node label change on the agents with `hpc_agent_batch: 1` | c1, c2, c3 restarted one after another (about 21 s apart, each waiting for its kubelet) |
| c3 unreachable (fake address), `--check -e hpc_compute_max_failed=0` | listed as not deployed; run stopped after the RKE2 stage |
| same with the default (`-1`) | run went to the end on a1, c1, c2; run log `finished=3/4 not_finished=c3` |
| `site.yml --limit c3` | c3's `/etc/hosts` still lists every node; nothing changed; run log `limit=c3 finished=1/1` |
| upstream IdP from a saved flat file (the simulated realm's endpoints) | configured from the file; editing an endpoint in the file updated Keycloak, restoring it updated it back; verify passed with it (broker login) |
| file whose issuer differs from `hpc_upstream_oidc_issuer` | stopped with "is for issuer ..., but hpc_upstream_oidc_issuer is ..." |
| `hpc_upstream_oidc_discovery_url` (good / 404) | configured / warning, then a clear error naming the URL |
| `-e hpc_trivy_db_refresh=true` | DB fetched again; unchanged upstream, so not re-published; after overwriting `trivy-db:2` in the registry with another image, the refresh re-published the real DB |

Found on the way:

- Rancher's `ClusterRepo.spec.caBundle` wants one DER certificate; a PEM
  bundle gives "x509: malformed certificate". Rancher now trusts the site CA
  itself (`additionalTrustedCAs`), and the catalog needs no `caBundle`.
- The Trivy chart's `sslCertDir` reaches only the scan container, not the
  init containers that log in to the registry and download the DB, and it
  is a host path that SELinux does not let containers read. The CA bundle
  is now a ConfigMap mounted over the image's default CA file.
- Scan jobs run one Trivy per container over one on-disk cache. Pods with
  several containers failed with "cache may be in use by another process";
  the scan cache is now in memory.
- Images with JAR files (Keycloak) cannot be scanned without the Java DB at
  all, so the Java DB is bundled by default.
- The Trivy operator reads its settings only at start: the role restarts it
  when they change.
- A compute node that does not answer used to stop the whole run at
  `/etc/hosts` on every other node, and the CephFS kernel-module probe (run
  from the admin node against every node) stopped the admin node. Both now
  carry on.
- Rancher shows UI extensions only to logged-in users; the check logs in.
