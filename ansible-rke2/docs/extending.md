# Switching, replacing and adding components

Each component is a role under `roles/`; `site.yml` runs them in order, one
play per target group. Every role depends on `hpc_common`, whose
`defaults/main.yml` holds every shared setting.

## Switch a component off

```yaml
hpc_enable_registry: false   # site already has a registry (then set hpc_registry_system_host & co.)
hpc_enable_nfs_server: false # homes/volumes come from elsewhere
hpc_enable_ceph_csi: true
hpc_enable_rancher: false
hpc_manage_dns: false        # site DNS has the records (incl. the *.apps wildcard)
hpc_manage_time: false
hpc_offline_repo: false      # nodes use their own dnf repositories
```

Or run parts: `ansible-playbook ... site.yml --tags rke2,platform`
(tags: pki, bundle, base, registry, nfs, rke2, platform, ceph, keycloak,
rancher, identity, tenants, accounting; `preflight` always runs).

## Replace a component

Keep the variables the rest relies on and turn the role off. For example an
external registry: `hpc_enable_registry: false`, set
`hpc_registry_system_host/port` (and its pull credentials in
`hpc_registry_pull_password`), and make sure it holds the images listed in
`roles/bundle/defaults/main.yml`.

## Add a component

1. `roles/<name>/meta/main.yml`:
   ```yaml
   dependencies: [{role: hpc_common}]
   ```
2. `roles/<name>/defaults/main.yml` for its own settings (prefix `hpc_<name>_`).
3. `roles/<name>/tasks/main.yml`. Useful pieces:
   - `{{ hpc_kubectl }}`, `helm` (on the admin node)
   - `include_role: {name: hpc_common, tasks_from: admin-tools}` installs the helper scripts
   - `include_role: {name: hpc_common, tasks_from: pin-namespaces}` pins new
     platform namespaces to the admin node
   - `include_role: {name: pki, tasks_from: issue}` with `cert: {name, sans}` issues a certificate (run on localhost)
   - addresses: `hpc_admin_ip`, `hostvars[h].hpc_mgmt_ip`, `hostvars[h].hpc_pod_ip`
4. Images it needs: add them to `hpc_images_system` (or a new list added to the
   `fetch-images` loop in `roles/bundle/tasks/fetch.yml`), charts to the chart
   download list; RPMs to `hpc_rpms_extra`.
5. Add a play (or a line in the last play) to `site.yml`:
   ```yaml
   - {role: <name>, when: hpc_enable_<name> | default(false) | bool, tags: [<name>]}
   ```
6. Checks: add a script under `roles/verify/files/` and to the loop in
   `roles/verify/tasks/main.yml`.

## Conventions

- Only `ansible.builtin` modules, so the directory works with a bare
  `ansible-core` and no Galaxy access.
- Idempotent: re-running must change nothing; tasks set `changed_when`.
- Secrets come from `lookup('ansible.builtin.password', hpc_secrets_dir ~ '/<name>')`
  and stay out of logs (`no_log`).
