# Your own RPMs

Besides the offline repository built from the bundle (`hpc-offline`), the
admin node can serve a second repository with your own packages:
`hpc-local`. Use it for site builds, vendor drivers and agents, or anything
the nodes need that the bundle does not have. Every cluster node gets it as a
dnf repository, served by the admin node over HTTPS like `hpc-offline`.

```
deployer: inventories/<site>/rpms/*.rpm  ──rsync──►  admin node: <hpc_data_root>/local-rpms/  (createrepo_c)
                                                    https://<admin>.<domain>:8443/local/  ◄── every node: /etc/yum.repos.d/hpc-local.repo
```

## Importing

```sh
./import-rpms.sh -i inventories/<site> ~/build/mytool-2.1-1.el9.x86_64.rpm ~/vendor-rpms/
```

`import-rpms.sh`:

1. copies the files (and every `*.rpm` under a given directory) into
   `inventories/<site>/rpms/`. It refuses source RPMs and files that are not
   RPMs, and reports `added`, `replaced` or `unchanged` for each file;
2. runs `rpms.yml`, which
   - syncs that directory to the admin node,
   - checks every package there: it must be a binary RPM for the nodes'
     architecture (`hpc_arch`) or `noarch`, with intact digests, and with a
     valid signature when `hpc_local_rpms_gpgkey` is set,
   - indexes the directory (`createrepo_c`),
   - writes `hpc-local.repo` on every node and refreshes its metadata.

To install packages now, give `--install`. Repeat the option or give a comma
list. It installs the package, or updates it to the newest version in the
repositories:

```sh
./import-rpms.sh -i inventories/<site> --install mytool ~/build/mytool-2.1-1.el9.x86_64.rpm
./import-rpms.sh -i inventories/<site> --install mytool,vendor-agent --on rke2_agents   # compute nodes only
./import-rpms.sh -i inventories/<site> --install mytool --on cn001                      # one node
```

Other uses:

```sh
./import-rpms.sh -i inventories/<site> --list                     # what is in the site's repository
./import-rpms.sh -i inventories/<site> --remove 'mytool-2.0-*'    # drop files (globs allowed), then republish
./import-rpms.sh -i inventories/<site> --no-apply ~/rpms/         # only copy; publish with the next site.yml
./import-rpms.sh -i inventories/<site>                            # publish what the directory holds now
./import-rpms.sh -i inventories/<site> ~/rpms/ -- --check --diff  # arguments after -- go to ansible-playbook
```

The directory is plain files. Copying RPMs into `inventories/<site>/rpms/` by
hand and running `rpms.yml` or `site.yml` does the same thing. Like
`secrets/`, it is git-ignored. Keep a copy wherever you keep the site's
build artifacts: a node re-provisioned later needs the same RPMs.

## Installing them permanently

`--install` installs once. A node that HPCM re-provisions comes back without
the package. Packages a node must always have go into the inventory, where
`site.yml` (the `base` role) installs them on every run:

```yaml
# inventories/<site>/group_vars/all.yml
hpc_local_packages: [mytool]                 # every node
hpc_local_packages_admin: []                 # admin node only
hpc_local_packages_compute: [vendor-agent]   # compute nodes only
```

These install the package when it is missing; they do not update it. To roll
out a new version, import it and run
`./import-rpms.sh -i inventories/<site> --install mytool`.

## Dependencies

dnf resolves dependencies from every enabled repository: `hpc-offline` (the
bundle), `hpc-local`, and the site's own repositories if `hpc_offline_repo:
false`. A dependency that none of them has makes the install fail with
`nothing provides ...`. Then either:

- import the missing RPMs too, or
- add the package names to `hpc_rpms_extra` in `group_vars`. The `rpm_fetch`
  host resolves them with their full dependency closure the next time the
  bundle is fetched (`bundle.yml -e hpc_bundle_force=true`, needs internet).

## Signatures

Site-built RPMs are usually unsigned, so `hpc-local` has `gpgcheck=0` by
default, and only the digests are checked. To require signatures, put your
public key into the rpms directory and name it:

```sh
cp RPM-GPG-KEY-mysite inventories/<site>/rpms/
```
```yaml
hpc_local_rpms_gpgkey: RPM-GPG-KEY-mysite
```

`rpms.yml` then refuses unsigned or wrongly signed packages, and the nodes
check signatures on install (`gpgcheck=1`).

## Settings

| Variable | Default | |
|----------|---------|-|
| `hpc_local_rpms_dir` | `<inventory dir>/rpms` | on the deployer; if you change it, give `import-rpms.sh --dir` the same path |
| `hpc_local_rpms_gpgkey` | `''` | key file name inside that directory; set = signatures required |
| `hpc_local_packages`, `_admin`, `_compute` | `[]` | installed by `site.yml` |

With no RPMs in the directory there is no `hpc-local` repository, and nodes
that had one lose it on the next run. The repository works with
`hpc_offline_repo: false` too; the admin node then serves only `hpc-local`.
`createrepo_c` must be installable on the admin node; it is part of the
bundle's RPM list.
