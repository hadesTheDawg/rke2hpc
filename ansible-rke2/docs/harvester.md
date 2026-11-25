# Harvester

[Harvester](https://harvesterhci.io) is SUSE's hyperconverged
infrastructure (KubeVirt VMs + Longhorn storage on bare metal). It is not
installed *by* this deployment: Harvester is its own appliance (ISO/PXE onto
bare-metal nodes, with hardware virtualisation). What this deployment does is
**bundle and configure the pieces that connect to one**, offline. Two cases:

| | Setting | What it does |
|-|---------|--------------|
| **Manage Harvester from this Rancher** | `hpc_harvester_ui: true` (default when Harvester is on) | installs Rancher's *Harvester UI extension* ("Virtualization Management") from the bundle; its files are served by the admin node |
| **This cluster runs on Harvester VMs** | `hpc_harvester_guest: true` | RKE2 runs with `cloud-provider-name: harvester`: the Harvester cloud provider (LoadBalancer Services through Harvester) and the Harvester CSI driver (volumes from Harvester's Longhorn); their images come from the bundle |

Switch: `hpc_enable_harvester: true`. The bundle then includes the Harvester
content (`hpc_bundle_harvester` follows it), so build the bundle again after
turning it on (`bundle.yml`, or simply `site.yml`).

> **Untested here.** The lab is QEMU VMs without nested virtualisation, so it
> cannot run Harvester. In the lab, verify.yml checks the UI extension part
> (served by the admin node, fetched and cached by Rancher, served to
> browsers). Importing a Harvester cluster and the guest-cluster mode follow
> the Harvester and RKE2 documentation, but have not been run against a real
> Harvester.

## What the bundle carries

| | Where |
|-|-------|
| `rke2-images-harvester.linux-<arch>.tar.zst` (RKE2 release asset: harvester-cloud-provider, harvester-csi-driver, kube-vip, CSI sidecars) | system registry, like the other RKE2 images |
| chart `harvester-<hpc_harvester_ui_version>.tgz` (the UI extension) | chart repository ([charts.md](charts.md)) |
| `ui-plugins/harvester-<version>.tgz` (the extension's JavaScript) | served at `https://<admin>.<domain>:8443/ui-plugins/harvester/<version>/` |

`hpc_harvester_ui_version` (default 1.9.1) must suit the Rancher version: the
chart's `catalog.cattle.io/rancher-version` annotation says which (1.9.x:
Rancher ≥ 2.15).

## Managing Harvester clusters from Rancher

With `hpc_harvester_ui: true`, site.yml installs the extension chart into
`cattle-ui-plugin-system`, pointing it at the admin node instead of GitHub.
Rancher downloads and caches it (`kubectl get uiplugin -n cattle-ui-plugin-system`
shows `cached`). For that, Rancher trusts the site CA for its own outgoing
connections (`additionalTrustedCAs`, set by the rancher role).
*Virtualization Management* then appears in Rancher's menu.

Importing an (offline) Harvester cluster, done in the Harvester and Rancher UIs:

1. Harvester must reach Rancher (`https://rancher.<domain>`) and pull
   Rancher's agent image. In Harvester, *Advanced > Settings*:
   - `containerd-registry`: a mirror for `docker.io` pointing to
     `https://registry.<domain>:5000`, with the `pull` account from
     `secrets/registry-pull`. The bundle already carries
     `rancher/rancher-agent:v<hpc_rancher_version>`;
   - `additional-ca`: the contents of `secrets/pki/ca-bundle.crt`;
   - DNS: Harvester nodes resolve `rancher.<domain>` (the admin node's
     dnsmasq, or site DNS).
2. Rancher: *Virtualization Management > Import Existing*, name it; copy the
   registration URL.
3. Harvester: *Advanced > Settings > cluster-registration-url*, paste.

Which users may manage it is Rancher RBAC (platform administrators by
default). It is unrelated to the flat-file projects.

## This cluster on Harvester VMs (guest cluster)

When the admin and compute nodes are Harvester VMs:

1. In Harvester, generate the cloud-provider configuration for this
   cluster (Harvester docs: *Generate addon configuration* / the
   `generate_addon.sh` script, with the VMs' namespace). It is a kubeconfig.
2. Save it as `inventories/<site>/harvester-cloud-config`
   (`hpc_harvester_cloud_config_file`; git-ignored, it is a credential).
3. Set, **before the first deployment**:

   ```yaml
   hpc_enable_harvester: true
   hpc_harvester_guest: true
   hpc_harvester_ui: false        # unless this Rancher also manages Harvester
   ```

4. `site.yml`. Every node gets `/etc/rancher/rke2/harvester-cloud-config`
   and, in `config.yaml`, `cloud-provider-name: harvester` and
   `cloud-provider-config: /etc/rancher/rke2/harvester-cloud-config`. RKE2
   then deploys `harvester-cloud-provider` and `harvester-csi-driver` itself
   from its built-in charts, with images from the system registry.

Switching an *existing* cluster to the Harvester cloud provider changes
every node's provider ID and restarts RKE2 everywhere (one compute node at a
time with `hpc_agent_batch`). RKE2 does not support changing a node's cloud
provider after it joined, so deploy a guest cluster with it from the start.

The CSI driver adds a StorageClass `harvester`. To make it the default for
project volumes instead of NFS: `hpc_storage_backend: none` and mark
`harvester` as default, or keep NFS and let projects ask for `harvester`
explicitly.

## Settings

| Variable | Default | |
|----------|---------|-|
| `hpc_enable_harvester` | `false` | the role and the bundle content |
| `hpc_harvester_ui` | `true` | the Rancher UI extension |
| `hpc_harvester_ui_version` | `1.9.1` | extension version (chart + files) |
| `hpc_harvester_ui_url` | `https://<admin>.<domain>:<hpc_repo_port>/ui-plugins/harvester` | where Rancher fetches it |
| `hpc_harvester_guest` | `false` | nodes are Harvester VMs: cloud provider + CSI |
| `hpc_harvester_cloud_config_file` | `<inventory dir>/harvester-cloud-config` | kubeconfig from Harvester |
| `hpc_bundle_harvester` | `hpc_enable_harvester` | bundle the Harvester content |
