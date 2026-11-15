# The flat file and how to change its format

`inventories/<site>/projects.txt` (path: `hpc_projects_file`) defines the
project groups. Apply changes with:

```sh
python3 roles/tenants/files/hpc_flatfile.py check inventories/<site>/projects.txt   # validate, no changes
ansible-playbook -i inventories/<site>/hosts.yml tenants.yml                         # apply
```

## Default format

```
GROUP:CPU:MEMORY_MIB:STORAGE_GIB:CPU_HOURS: user, user, ...
BS0001:24:16000:20:1: bob, alice, amy
```

| Column | Meaning |
|--------|---------|
| GROUP | project; unix group, Keycloak group, namespace (`bs0001`), Rancher project |
| CPU | cores the whole group may hold at once (ResourceQuota `requests.cpu` + `limits.cpu`) |
| MEMORY_MIB | memory the group may hold at once (`requests.memory` + `limits.memory`) |
| STORAGE_GIB | volume claims the group may request (`requests.storage`) |
| CPU_HOURS | optional yearly CPU-hour allocation that usage is *reported* against; not enforced. Lines may leave it out (then `hpc_tenant_default_cpu_hours`) |
| USERS | members, comma separated; a user may be in several groups |

`python3 roles/tenants/files/hpc_flatfile.py format` prints the format the
script currently expects.

## One script owns the format

`roles/tenants/files/hpc_flatfile.py` is the only code that reads the file.
Everything else (hpc-sync on the admin node, the accounting tool, the Ansible
roles, verify) gets parsed records from it and reads fields by **key**. The
format is the `FIELDS` table near the top, one line per column, in file order:

```python
FIELDS = [
    #     key          column         parser           required/default
    Field("group",     "GROUP",       group_name,      ...),
    Field("cpu",       "CPU",         positive_int,    ...),
    Field("mem",       "MEMORY_MIB",  positive_int,    ...),
    Field("storage",   "STORAGE_GIB", positive_int,    ...),
    Field("cpu_hours", "CPU_HOURS",   positive_number, required=False, default=...),
    Field("users",     "USERS",       user_list,       ...),
]
```

Below it, `QUOTA` maps fields to ResourceQuota entries:

```python
QUOTA = {
    "cpu":     {"requests.cpu": "{}", "limits.cpu": "{}"},
    "mem":     {"requests.memory": "{}Mi", "limits.memory": "{}Mi"},
    "storage": {"requests.storage": "{}Gi"},
}
```

### Example: remove CPU_HOURS

1. In `hpc_flatfile.py`, delete (or put `#` in front of) the `Field("cpu_hours", ...)` line.
2. Remove that column from every line of `projects.txt`
   (`BS0001:24:16000:20:1: bob` → `BS0001:24:16000:20: bob`).
3. `python3 roles/tenants/files/hpc_flatfile.py check inventories/<site>/projects.txt`
4. `ansible-playbook -i inventories/<site>/hosts.yml tenants.yml`

Every project then reports against `hpc_tenant_default_cpu_hours`. Nothing
else needs editing. (Lines with the old number of columns are rejected with a
message naming the expected format, so a half-edited file cannot be applied.)

### Example: remove a quota column (e.g. STORAGE_GIB)

Delete its `Field` line and its column. The `requests.storage` quota is then
simply not set; the other quotas stay. Deleting its `QUOTA` entry instead
(keeping the column) keeps the value in the records but stops enforcing it.

### Example: add a GPU quota

```python
    Field("gpu", "GPUS", positive_int, required=False, default=None, help="GPUs the group may hold"),
```

placed where the column sits in the file, and in `QUOTA`:

```python
    "gpu": {"requests.nvidia.com/gpu": "{}"},
```

An optional field with `default=None` sets nothing for lines that leave it out.

### Other knobs in the same file

- `SEPARATOR` (`:`), `USER_SEPARATOR` (`,`), `COMMENT` (`#`)
- `GROUP_RE`, `USER_RE`: allowed group/user names
- parsers (`positive_int`, `positive_number`, `user_list`, ...): write a new
  one for a new column type; it takes the text and returns the value or raises
  `ValueError("message")`

The script runs with plain Python 3.6+ (laptop or admin node, no packages).
After editing it, run `tenants.yml` (it installs the new version to
`/usr/local/lib/hpc/hpc_flatfile.py` on the admin node) or `site.yml`.

## What applying the file does

- uids from 5001, gids from 6001, allocated once and never reused
  (`/var/lib/hpc/idmap.json` on the admin node, backed up to
  `inventories/<site>/secrets/state/idmap.json` and restored from there if
  the admin node is rebuilt)
- home directories `<hpc_home_root>/<user>` on the NFS export, mode 700
- per group: namespace pinned to compute nodes, ResourceQuota, LimitRange,
  NetworkPolicy, RBAC, Rancher project, Keycloak group; per user: Keycloak
  account with the initial password `inventories/<site>/secrets/users/<user>`
- removed users are disabled in Keycloak (uid and home kept); removed groups
  lose access, their namespace and data are left for an admin to delete
- `secrets/state/accounts.json`: users, uids, groups for login nodes / LDAP
