# Running deployments: checks, dry runs, batches, logs

How to run the playbooks safely on a live site. None of this changes what
gets deployed; it changes how a run behaves.

## Before a run: `check.sh`

```sh
./check.sh inventories/<site>/hosts.yml          # syntax, flat file, scripts
CHECK_UVX=1 ./check.sh inventories/<site>/hosts.yml   # + yamllint, ansible-lint, shellcheck through uvx
```

| Check | |
|-------|-|
| `ansible-playbook --syntax-check` of every playbook | against your inventory |
| flat file | `hpc_flatfile.py check` on `projects.txt` |
| upstream IdP file | `oidc_config.py file` when `group_vars/all.yml` names `hpc_upstream_oidc_config_file` ([upstream-idp.md](upstream-idp.md)) |
| `bash -n`, `py_compile` | every script and Python file |
| `yamllint`, `ansible-lint`, `shellcheck` | when installed, or with `CHECK_UVX=1` and `uv` installed; settings in `.yamllint`, `.ansible-lint`, `.shellcheckrc` |

It touches no node. These are tools for the deployer only; the deployment
itself still needs nothing but `ansible-core`.

## Dry run: `--check --diff`

On a deployed site, preview what a run would change, without changing it:

```sh
ansible-playbook -i inventories/<site>/hosts.yml site.yml --check --diff
ansible-playbook -i inventories/<site>/hosts.yml site.yml --check --diff --tags rke2 --limit c001
```

Read-only probes (`rpm -q`, `systemctl is-active`, `kubectl get`, ...) run
for real in check mode (`check_mode: false`), so the later tasks see the
true state. Everything that would change something is reported as
"changed" with a diff for files and templates, and not done. Notes:

- A first deployment cannot be previewed: there is nothing to probe yet.
- Steps that wait for something an earlier step would create are skipped in
  check mode.
- Commands whose effect cannot be predicted (helm releases, `kubectl apply`,
  hpc-sync) are skipped and show as "skipping".
- The run log records check runs with `check=true`.

## Compute nodes in batches

When a compute node's RKE2 configuration, registry configuration, node
password or version changes, its `rke2-agent` must restart. By default all of
them restart at the same moment. Running pods keep running (containerd's
shims survive the agent restart), but every node's kubelet is away at once.
On a busy site, restart them in batches:

```yaml
hpc_agent_batch: 10              # 10 nodes at a time; 0 = all at once (default)
hpc_agent_restart_timeout: 600   # seconds a node may take to answer again
```

Each node restarts and waits until its kubelet answers its health check
(`127.0.0.1:10248/healthz`) before the next batch starts. A node that does
not come back within the timeout fails, drops out of the run, and the others
go on. Only restarts are batched: package installs, configuration files and
first starts of new nodes stay fully parallel. Upgrades
(`-e hpc_rke2_upgrade=true`) use the same batches: the server first, then the
compute nodes `hpc_agent_batch` at a time.

## When compute nodes fail

A compute node that fails or is unreachable drops out of the run; the rest
continue. After the RKE2 stage, the "All nodes Ready" play:

- lists the compute nodes that dropped out (`WARNING: not deployed in this run`);
- waits for the nodes that **did** get through the run to be Ready (before,
  one broken node made it wait 10 minutes and then fail the whole run);
- with `hpc_compute_max_failed: N` (default `-1`, never), stops the run there
  when more than N compute nodes failed, before Rancher, tenants and the
  rest are touched.

```yaml
hpc_compute_max_failed: 0    # any failed compute node stops the run after RKE2
```

Fix the node and re-run (or `--limit <node>`).

A node that is down is still listed by the others (`/etc/hosts`, NFS
exports) with the address from the inventory's `ansible_host`, when that is
an IPv4 address. Otherwise set `hpc_mgmt_ip` in its `host_vars`, or the run
stops in preflight and names it. Tasks that reach every node from the admin
node (the CephFS kernel-module probe) skip a node that is down instead of
failing the admin node.

## `--limit`

`site.yml --limit c001` deploys one node. The nodes outside the limit still
appear in `/etc/hosts`, NFS export lists and the cluster checks, so preflight
reads their facts and addresses too (delegated fact gathering; one that does
not answer gets its address from the inventory, as below). A limited run
changes only the limited nodes. After a node was re-provisioned,
`--limit <node>` is enough. The PKI play on the deployer is skipped under a
limit that leaves out `localhost`; that is fine unless certificates changed.

## Logs

| File | |
|------|-|
| `.logs/ansible.log` | full output of every run of every playbook (`log_path` in `ansible.cfg`). `no_log` tasks stay censored. Rotate or delete it as you like |
| `inventories/<site>/logs/runs.log` | one line per `site.yml` run (`hpc_run_log`): time, user, git revision of this directory, tags, limit, check mode, nodes finished |

```
2026-11-25T09:20:11Z user=ops playbook=site.yml rev=8ee0aa1-dirty tags=all skip=- limit=- check=false finished=4/4
2026-11-25T10:02:45Z user=ops playbook=site.yml rev=8ee0aa1 tags=rke2 skip=- limit=c001 check=false finished=0/1 not_finished=c001
```

A run that aborts before the end writes no line in `runs.log`; its output is
in `.logs/ansible.log`. Both are git-ignored.

## Facts and parallelism

Every playbook gathers only the facts the deployment reads (`gather_subset:
[min, network]`: OS, architecture, user, interfaces), which is quicker on
many nodes. `ansible.cfg` runs `forks = 50` hosts in parallel. On sites with
hundreds of compute nodes, raise it (`ANSIBLE_FORKS=200` or edit the file) as
far as the deployer's CPU and ssh limits allow.

## Secrets directory

`inventories/<site>/secrets/` is mode 0700. Every run (pki role) also
removes group/other permissions from anything inside it (a copied-in
certificate, a hand-edited password file) and prints what it fixed. For
values that must live in `group_vars` (the Ceph key, for example), use an
ansible-vault file: `ansible-vault create inventories/<site>/group_vars/vault.yml`,
then run with `--ask-vault-pass`.

## Handlers

nginx and chrony restart through handlers (`roles/base/handlers/main.yml`),
once at the end of the play however many of their files changed. The
admin node's play ends before the compute nodes' play starts, so they always
see the repository server with its new configuration. RKE2, NetworkManager
and the CA trust store are still changed in place, because the next tasks
need the change at once.
