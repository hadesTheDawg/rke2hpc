# Trivy operator (vulnerability and configuration reports)

`hpc_enable_trivy: true` installs the
[Trivy operator](https://aquasecurity.github.io/trivy-operator/) from the
bundle. It scans what runs in the cluster and keeps the results as Kubernetes
objects. **It reports only**: there is no admission webhook, and nothing is
blocked or changed because of a finding.

| Report (`kubectl get <kind> -A`) | What |
|------|------|
| `vulnerabilityreports` | CVEs in every container image of every workload |
| `configauditreports` | risky settings in workloads, Services, Roles, NetworkPolicies, ... |
| `rbacassessmentreports`, `clusterrbacassessmentreports` | over-broad RBAC |
| `exposedsecretreports` | secrets baked into images |
| `sbomreports` | software bill of materials per image |
| `clustercompliancereports` | NSA, PSS baseline/restricted, RKE2 CIS views over the above |

Role: `trivy` (`site.yml --tags trivy`), runs on the admin node after Rancher.
The operator and its scan jobs run in `trivy-system` (`hpc_trivy_namespace`), which
is pinned to the admin node like every platform namespace. Scans never take
compute-node capacity away from projects.

## Offline: what the bundle carries

The bundle always carries Trivy, as it does CephFS (`hpc_bundle_trivy: true`), so it can
be switched on later without a new download:

| | System registry path |
|-|-|
| chart `trivy-operator-<hpc_trivy_operator_chart_version>.tgz` | in the chart repository ([charts.md](charts.md)) |
| operator image `aquasec/trivy-operator:<hpc_trivy_operator_version>` | `registry.<domain>:5000/aquasec/trivy-operator` |
| scanner image `aquasec/trivy:<hpc_trivy_version>` | `registry.<domain>:5000/aquasec/trivy` |
| `aquasecurity/node-collector` | (unused, see below) |
| vulnerability DB `aquasec/trivy-db:2` (about 140 MB) | `registry.<domain>:5000/aquasec/trivy-db:2` |
| Java DB `aquasec/trivy-java-db:1` (about 1 GB), with `hpc_trivy_java_db` (default `true`) | `registry.<domain>:5000/aquasec/trivy-java-db:1` |

The scanners run with `offlineScan` and with the built-in policies. They pull
the images they scan **themselves**, not through containerd, so the role gives
them what the nodes have in `registries.yaml`:

- the same mirrors: `docker.io` to the user registry, then the system
  registry; `quay.io`, `ghcr.io`, `registry.k8s.io`, `mirror.gcr.io` to the
  system registry;
- the system registry's read-only `pull` account (in the operator's
  `trivy-operator-trivy-config` ConfigMap and Secret, readable by cluster
  administrators only, the same account every node already has);
- the CA bundle: the admin node's `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` (system CAs plus the site bundle) as ConfigMap `hpc-ca-bundle`, mounted over `/etc/ssl/certs/ca-certificates.crt` in every scan-job container. The chart's `sslCertDir` is not used, for two reasons: the operator passes it only to the scan container, not to the init containers that log in and download the DB; and it is a host directory, which SELinux does not let containers read.

## Keeping the vulnerability DB current

The DB in the registry is the one downloaded when the bundle was built.
Upstream publishes a new one every few hours, under the same tag. To bring
today's DB to the site (needs internet on the deployer, as for a bundle):

```sh
ansible-playbook -i inventories/<site>/hosts.yml site.yml --tags bundle,registry,trivy -e hpc_trivy_db_refresh=true
```

This forgets the cached DB on the deployer, downloads the current one,
pushes the bundle and re-publishes the DB over the old one; only the DB, other
images are skipped. It then deletes the existing vulnerability reports so
that every image is scanned again with the new DB. Reports also refresh by
themselves after `hpc_trivy_report_ttl` (24 h), with the DB that is in the
registry then.

Monthly or after a major advisory is a sensible rhythm for an offline site.

## Settings

| Variable | Default | |
|----------|---------|-|
| `hpc_enable_trivy` | `false` | install the operator |
| `hpc_trivy_namespace` | `trivy-system` | |
| `hpc_trivy_target_namespaces` | `''` | comma-separated namespaces to scan; `''` = all |
| `hpc_trivy_exclude_namespaces` | `''` | comma-separated glob patterns not to scan |
| `hpc_trivy_severity` | `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL` | severities kept in reports |
| `hpc_trivy_concurrent_scans` | `2` | scan jobs at a time (on the admin node) |
| `hpc_trivy_report_ttl` | `24h` | a report is redone after this |
| `hpc_trivy_java_db` | `true` | bundle and use the Java DB. With `false` the bundle is about 1 GB smaller, but every image that contains JAR files (Keycloak, for one) fails to scan: Trivy will not skip the Java DB on a first run |
| `hpc_trivy_db_refresh` | `false` | `-e` only: bring today's DB (above) |
| `hpc_trivy_extra_values` | `{}` | merged into the chart values (`roles/trivy/templates/values.yaml.j2`) |
| `hpc_trivy_*_version`, `hpc_trivy_operator_chart_version` | | in `roles/hpc_common/defaults/main.yml`; bump them, then build a new bundle |

**Infrastructure assessment** (the node-collector job, CIS checks of each
node's files) is off: it has to run on every node, but `trivy-system` is
pinned to the admin node. To turn it on, unpin the namespace and enable it:

```yaml
hpc_unpinned_namespaces: [kube-system, kube-public, kube-node-lease, default, ceph-csi-cephfs, trivy-system]
hpc_trivy_extra_values:
  operator: {infraAssessmentScannerEnabled: true}
  trivyOperator: {scanJobNodeSelector: {hpc.io/role: admin}}   # image scans stay on the admin node
```

## Reading the reports

```sh
k=/var/lib/rancher/rke2/bin/kubectl; export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
$k get vulnerabilityreports -A -o wide           # counts per severity, per workload/container
$k get vulnerabilityreports -n BS0001 -o json \
  | jq -r '.items[] | .metadata.labels["trivy-operator.resource.name"] + " " + .report.artifact.repository + ":" + .report.artifact.tag
           + "  critical=" + (.report.summary.criticalCount|tostring) + " high=" + (.report.summary.highCount|tostring)'
$k get configauditreports -A -o wide
$k get clustercompliancereports                  # k8s-nsa-1.0, k8s-pss-baseline-0.1, rke2-cis-1.24, ...
```

Rancher shows the same objects under *More Resources > aquasecurity.github.io*.
Project members can read the reports of their own namespaces and of no
others: the chart aggregates read access into the built-in `view`, `edit` and
`admin` roles, and project groups have `edit` in their namespaces.

verify.yml checks that the operator runs from the internal registry, that
reports appear (so images and the DB were pulled offline), that Keycloak's
image (a Java image) has a vulnerability report, that a project can read
its own reports and not kube-system's, and that no admission webhook exists.

After a failed scan (for example before the DB was in the registry), the
operator does not always come back to that workload by itself. The role
restarts it whenever its settings change; by hand:
`kubectl -n trivy-system rollout restart deploy/trivy-operator`.

## Enforcement (not done)

Turning findings into admission decisions, such as refusing images with
critical CVEs, is a separate decision. It would use an admission policy
that reads the reports. Nothing here does that.
