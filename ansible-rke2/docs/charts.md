# Helm charts: bundled and served locally

Every Helm chart the deployment installs comes from the bundle, never from
the internet. Since the nodes are offline, that is the only way it can work.
The charts are also **served as a chart repository** from the admin node.
That lets a site's own Helm users, Fleet, and Rancher's *Apps* page install
them, and charts the site adds itself, the same way.

```
deployer: .bundle/<arch>/charts/*.tgz ──push──► admin: /srv/hpc/bundle/charts
                                                   │ rsync + helm repo index
                                                   ▼
                                  /srv/hpc/charts/{*.tgz,index.yaml}
                                  https://<admin>.<domain>:8443/charts/   (nginx, TLS, site CA)
                                     ▲                       ▲
                     helm --repo ... │       Rancher catalog │ "hpc-local" (Apps)
```

## What is in it

| Chart | Installed by | Notes |
|-------|--------------|-------|
| `rancher-<hpc_rancher_version>` | rancher role | |
| `nfs-subdir-external-provisioner-<v>` | platform role | default StorageClass `nfs` |
| `ceph-csi-cephfs-<v>` | ceph_csi role | always bundled |
| `trivy-operator-<v>` | trivy role | always bundled ([trivy.md](trivy.md)) |
| `harvester-<v>` (Rancher UI extension) | harvester role | with `hpc_enable_harvester` ([harvester.md](harvester.md)) |
| anything in `hpc_charts_extra` | you | see below |

Not in it, because they ship inside other artifacts: RKE2's own charts
(canal, CoreDNS, Traefik, metrics-server, snapshot controller, Harvester
cloud provider and CSI) are inside the RKE2 release and its image tarballs.
Rancher's system charts (fleet, webhook, turtles, CAPI, ...) are inside the
Rancher image (`useBundledSystemChart: true`).

The list is `hpc_charts` in `roles/bundle/defaults/main.yml`, a download
URL per chart. A chart no longer listed is removed from the bundle and the
repository on the next bundle build.

## Adding your own charts

```yaml
# group_vars/all.yml
hpc_charts_extra:
  - https://charts.example.org/mychart-1.2.3.tgz
  - https://github.com/org/repo/releases/download/v2.0.0/other-2.0.0.tgz
```

Then `site.yml` (or `bundle.yml` followed by `site.yml --tags base`): the chart is
downloaded, pushed and indexed. Images the chart needs go into
`hpc_images_system` / `hpc_images_user` like any other image
([extending.md](extending.md)).

## Using the repository

From the admin node or any host that trusts the site CA:

```sh
helm repo add hpc https://<admin>.<domain>:8443/charts --ca-file /etc/pki/hpc/ca.crt
helm search repo hpc
helm install x hpc/trivy-operator ...
```

In Rancher: *Apps > Repositories* lists **hpc-local** (`hpc_charts_rancher_repo`),
and *Apps > Charts* shows its charts. Rancher's default repositories
(`rancher-charts`, `rancher-partner-charts`, `rancher-rke2-charts`) point at
the internet and stay unreachable on an offline site. That is harmless.

## Settings

| Variable | Default | |
|----------|---------|-|
| `hpc_enable_charts_repo` | `true` | serve the repository (and register it in Rancher) |
| `hpc_charts_url` | `https://<admin>.<domain>:<hpc_repo_port>/charts` | its address (nginx on the admin node) |
| `hpc_charts_rancher_repo` | `hpc-local` | Rancher ClusterRepo name |
| `hpc_charts_extra` | `[]` | more chart URLs for the bundle |

## Installs only when something changed

Every chart the roles install goes through
`/usr/local/libexec/hpc/hpc-helm-release` on the admin node. It runs
`helm upgrade --install --wait` only when the chart file, the values file
(`/etc/hpc/<name>-values.yaml`) or the release itself changed (another
revision, not deployed). Otherwise it prints `unchanged` and the task reports
"ok". A re-run of site.yml therefore no longer creates a new Helm revision of
Rancher, the NFS provisioner, CephFS or Trivy, and no longer waits for their
rollouts. State: `/var/lib/hpc/helm/<namespace>.<release>`. Delete that file
to force a reinstall.
