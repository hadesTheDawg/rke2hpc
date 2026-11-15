# Usage accounting (`hpc-acct`)

`hpc-acct` records what every project runs: a job ID, who submitted it, when it
started and stopped, how long it ran (`hh:mm:ss`) and how many CPU-hours it
used. It covers Deployments and other long-running workloads as well as Jobs and
Pods.

**It measures and reports. It does not limit, stop or refuse anything.** How
time limits and budgets *could* be enforced is described separately in
[time-limits-design.md](time-limits-design.md); none of that is installed.

- Role: `roles/accounting` (`ansible-playbook ... site.yml --tags accounting`)
- Tool and recorder: `roles/accounting/files/hpc-acct.py`, installed as `/usr/local/sbin/hpc-acct` on the admin node
- From the deployer: `ansible-playbook -i inventories/<site>/hosts.yml acct.yml -e 'acct="<command>"'`, or `ssh <admin node> sudo hpc-acct <command>`

## Contents

1. [What is recorded](#1-what-is-recorded)
2. [The allocation in the flat file](#2-the-allocation-in-the-flat-file)
3. [Admin tool reference](#3-admin-tool-reference)
4. [How it works with RKE2](#4-how-it-works-with-rke2)
5. [How time is measured](#5-how-time-is-measured)
6. [The accounting year](#6-the-accounting-year)
7. [Where everything lives](#7-where-everything-lives)
8. [Failure modes and limits](#8-failure-modes-and-limits)
9. [Trying it by hand](#9-trying-it-by-hand)

---

## 1. What is recorded

A **job** is whatever a user submits to a project namespace:

| Submitted object | Recorded as | Ends when |
|------------------|-------------|-----------|
| Job | one job, all its pods rolled up | it completes, fails, or is deleted |
| Pod created directly | one job | it finishes or is deleted |
| Deployment | one job, every pod it ever had rolled up | it is deleted |
| StatefulSet, DaemonSet | same as a Deployment | it is deleted |
| CronJob | each run (each Job it creates) is its own job | per run |

For each job:

| Field | Meaning |
|-------|---------|
| JOBID | sequential number, assigned when first seen; also put on the object as label `hpc.io/jobid` |
| PROJECT | the project group (from the namespace) |
| USER | the unix name of the person who submitted it |
| KIND, NAME | what it is in Kubernetes |
| STATE | see below |
| SUBMIT / START / END | when it was created, when its first container started, when its last one stopped (UTC) |
| ELAPSED | true wall-clock run time, `hh:mm:ss`; for a job still running, the time so far |
| CPUS | CPU cores requested (per pod × replicas) |
| CPU_HOURS | for each pod, run time × cores requested, summed |

States:

| State | Meaning |
|-------|---------|
| `PENDING` | submitted; no container has started yet |
| `RUNNING` | at least one container has started and the object still exists |
| `COMPLETED` | a Job or Pod that finished successfully |
| `FAILED` | a Job or Pod that failed |
| `TIMEOUT` | a Job or Pod stopped by a time limit **its owner chose to set** (`activeDeadlineSeconds`) |
| `OOM` | a directly created Pod killed for exceeding its memory limit |
| `CANCELLED` | a Job or Pod deleted before it finished |
| `STOPPED` | a Deployment, StatefulSet or DaemonSet that was deleted |

## 2. The allocation in the flat file

```
GROUP:CPU:MEMORY_MIB:STORAGE_GIB:CPU_HOURS: user, user, ...
BS0001:24:16000:20:1: bob, alice, amy
```

`CPU_HOURS` is the project's yearly CPU-hour allocation. It is optional (a
five-field line gets `hpc_tenant_default_cpu_hours`; see flatfile.md) and it
is **only a number to report against**: `hpc-acct status` shows used, remaining
and percent used, and `REMAINING` simply goes negative when a project exceeds
it. Jobs keep being accepted.

`tenants.yml` parses the flat file and writes
`/var/lib/hpc/projects.json` on the admin node; the recorder picks changes up on
its next pass. The flat file is the **base** allocation. Changes made with
`hpc-acct budget` are **adjustments** on top of it for the current accounting
year and are kept in a ledger, so editing the flat file never silently discards
a grant.

## 3. Admin tool reference

Run on the admin node as root (`sudo hpc-acct …`) or from the deployer
(`acct.yml` or `sudo hpc-acct …` on the admin node). All times are UTC. `--help` works on every command.

### `hpc-acct status [--period YYYY-MM-DD] [--json]`

One line per project for the current accounting year, plus the recorder's
health.

```
accounting year starting 2026-10-01 (UTC)    recorder: ok, last pass 2s ago

PROJECT  ALLOCATION  USED  REMAINING  USED%      WALL  JOBS  ACTIVE
BS0001         1.00  0.02       0.98     2%  00:01:29     2       0
ML0004      2000.00  0.06    1999.94     0%  00:03:13    27       0
```

| Column | Meaning |
|--------|---------|
| ALLOCATION | flat-file allocation + adjustments, CPU-hours |
| USED | CPU-hours consumed this year, including what is still running |
| REMAINING | ALLOCATION − USED (negative = over allocation) |
| WALL | true elapsed time summed over the project's jobs, `hh:mm:ss` |
| JOBS / ACTIVE | jobs this year / pending or running now |

`recorder: STALE` means the service has not completed a pass for over a minute
(see [failure modes](#8-failure-modes-and-limits)).

### `hpc-acct jobs [filters] [--json | --csv]`

The job history, newest last.

```
JOBID  PROJECT  USER  KIND        NAME   STATE      SUBMIT               START                END                   ELAPSED  CPUS  CPU_HOURS
   47  BS0001   bob   Deployment  web    RUNNING    2026-11-14 11:20:01  2026-11-14 11:20:03  -                    02:14:55     1     2.2486
   49  BS0001   bob   Job         prep   COMPLETED  2026-11-14 11:20:01  2026-11-14 11:20:02  2026-11-14 11:20:10  00:00:08   0.5     0.0011
```

Filters: `--project P`, `--user U`, `--state S`, `--active` (pending and
running only), `--period YYYY-MM-DD`, `--all-years`, `-n N` (default 50).
`--csv` and `--json` add `reason`, `period`, `namespace` and the raw seconds
(`elapsed_seconds`, `cpu_seconds`) for spreadsheets and scripts.

### `hpc-acct job <jobid>`

Everything about one job, and each of its pods: node, state, start, end and how
long it ran. For a Deployment this lists every pod it has had, including
replaced ones.

### `hpc-acct budget <project> [--add H | --set H] --reason "…"`

Without options, shows the project's allocation breakdown. `--add` grants that
many CPU-hours for the current accounting year (a negative number takes away);
`--set` makes the year's total exactly that. `--reason` is mandatory and is
stored with the change and your username.

```sh
hpc-acct budget BS0001
hpc-acct budget BS0001 --add 10 --reason "extra allocation, ticket 1234"
```

Adjustments apply to the current accounting year only. To change a project's
allocation permanently, edit the flat file and run `tenants.yml`.

### `hpc-acct ledger [project]`

Every allocation change: when, how much, who, why.

### `hpc-acct history [project]`

Jobs, CPU-hours and elapsed time per accounting year. Nothing is ever deleted.

### `hpc-acct users [--project P] [--period YYYY-MM-DD]`

Usage per user within each project.

### `hpc-acct cancel <jobid>`

Deletes the Kubernetes object behind an active job (the one administrative
action the tool can take). It is then recorded as `CANCELLED` or `STOPPED`.

### `hpc-acct daemon [--once]`

The recorder itself, run by `hpc-acct.service`.

## 4. How it works with RKE2

`hpc-acct` does not modify RKE2 and does not run inside the cluster. It is an
ordinary read-mostly client of the Kubernetes API on the admin node, using the
cluster-admin kubeconfig RKE2 writes to `/etc/rancher/rke2/rke2.yaml` and the
`kubectl` RKE2 ships in `/var/lib/rancher/rke2/bin`.

```
 user ──kubectl / Rancher──►  kube-apiserver (RKE2 static pod on the admin node)
                                 │  1. authentication (Keycloak OIDC)
                                 │  2. mutating admission: stamps hpc.io/user on the workload   (from hpc-sync)
                                 ▼
                              etcd ──► controllers ──► kubelet on a compute node runs the pods
                                                              │
                                 workload + pod objects, with container start/finish times
                                                              │  read every 5 s
                                                              ▼
                                         hpc-acct recorder (systemd, admin node)
                                           ├─ SQLite: jobs, pods, ledger            ◄── hpc-acct <command> (admin)
                                           ├─ label hpc.io/jobid on the objects
                                           └─ ConfigMap <namespace>/project-usage   ◄── project members, Rancher UI
```

### 4.1 Who submitted it

Kubernetes does not remember who created an object. The tenants module
(`roles/hpc_common/files/hpc-sync.py`) installs mutating admission policies in the API server
that write the authenticated submitter's unix name into the annotation
`hpc.io/user`:

- on the pod template of Deployments, StatefulSets, DaemonSets, ReplicaSets,
  Jobs and CronJobs (so every pod the controllers create carries it);
- on Pods created directly.

A user cannot choose the value: it is overwritten with their own name on every
create and update, whether they came in through `kubectl` or Rancher. The
recorder reads the user from this annotation. This is the same stamp that
decides which uid a pod runs as and whose home it mounts.

### 4.2 What the recorder does on each pass

Every `ACCT_POLL_SECONDS` (default 5):

1. Reads `/var/lib/hpc/projects.json` (the parsed flat file) into its
   `projects` table.
2. Makes one API call —
   `kubectl get deployments.apps,statefulsets.apps,daemonsets.apps,replicasets.apps,jobs.batch,pods -A -o json`
   — and keeps the objects in project namespaces.
3. **Finds what the user submitted.** For each object it follows the
   `ownerReferences` upward (Pod → ReplicaSet → Deployment; Pod → Job). The top
   of the chain is the job. A Job created by a CronJob is its own job.
4. **New job** → inserts a row in `jobs`, which assigns the next job ID, and
   labels the object (and its pods) `hpc.io/jobid=<id>`. That label is what
   `kubectl get … -L hpc.io/jobid` and Rancher show.
5. **Every pod** → upserts a row in `pods` with its node, its CPU request, and
   its container start and finish times from `status.containerStatuses`.
6. **Pods that have disappeared** while still open are closed at the time they
   were last seen. A job whose object has disappeared becomes `CANCELLED`
   (Job/Pod) or `STOPPED` (services).
7. **Recomputes each active job**: state, elapsed time, CPU-seconds.
8. **Publishes** a `project-usage` ConfigMap into each project namespace with
   that project's allocation, usage and active jobs (refreshed at most once a
   minute while things run). Project members can read it; nothing in the
   cluster consumes it.

The only things the recorder writes to the cluster are the `hpc.io/jobid` label
and the `project-usage` ConfigMaps. It never touches a workload's spec.

### 4.3 What users can see

```sh
kubectl get deploy,jobs,pods -L hpc.io/jobid     # the JOBID column
kubectl get configmap project-usage -o yaml      # allocation, used, remaining, active jobs
```

In Rancher the same ConfigMap is listed under the project's ConfigMaps, and the
job ID appears among each workload's labels. The detailed history
(`hpc-acct jobs`) is admin-only for now.

### 4.4 Dependencies on other modules

The recorder needs two things that `tenants.yml` provides: the
`hpc.io/user` stamp on workloads, and `/var/lib/hpc/projects.json` (the list of
projects and their allocations). Run order is the `tenants` role, then
`accounting`. After adding a project to the flat file, `run tenants` is
enough; the recorder starts covering it on its next pass.

## 5. How time is measured

- **Start** is when the first container of the job actually started. Time spent
  pending (waiting for a node, pulling an image) is not counted.
- **End** is when the last container stopped. For anything that finishes by
  itself these timestamps come from the kubelet, so the polling interval does
  not affect accuracy.
- Anything **deleted while running** (including every pod of a Deployment that
  is deleted or scaled down) is closed at the last pass that saw it, so it can
  be under-counted by up to one polling interval (5 s) per pod.
- **ELAPSED** is first start to last stop for the job as a whole, not the sum
  over pods. A Deployment with three replicas running for an hour has
  `ELAPSED 01:00:00`.
- **CPU_HOURS** is the sum over pods of run time × the pod's CPU *request*. The
  same Deployment with 2-core pods has 6 CPU-hours. It is what the project had
  reserved on the nodes, not measured CPU utilisation; an idle pod is charged
  its request. A container without a CPU request counts as
  `TENANT_DEFAULT_CPU_REQUEST` (which is what the namespace's LimitRange gives
  it anyway).
- A Deployment that is scaled to zero and back keeps one record; `ELAPSED`
  spans first start to latest stop, while CPU_HOURS only counts time pods
  actually ran.
- Timestamps have one-second resolution; a pod that runs for under a second
  records `00:00:00`.

## 6. The accounting year

`hpc_acct_period_start: "10-01"`: years start on 1 October, 00:00
UTC, and are named by their start date (`2026-10-01`).

- A job belongs to the year in which it was **submitted**. A Deployment created
  in September and still running in November counts entirely toward the old
  year.
- At the boundary nothing runs and nothing is deleted. `USED` starts from zero
  because it sums the new year's jobs, and adjustments made with
  `hpc-acct budget` (recorded against a year) no longer apply: each project
  starts the new year with its flat-file allocation.
- **History is kept forever**: `hpc-acct history`, `hpc-acct jobs --all-years`,
  `hpc-acct jobs --period 2025-10-01`, `hpc-acct status --period 2025-10-01`.

To change the date, edit `ACCT_PERIOD_START` and run
`site.yml --tags accounting`. Existing jobs keep the year they were recorded
under.

## 7. Where everything lives

| What | Where |
|------|-------|
| tool / recorder | `/usr/local/sbin/hpc-acct` (admin node) |
| service | `hpc-acct.service`; `journalctl -u hpc-acct` has one line per job submitted and one per job ended |
| settings | `/etc/hpc/acct.env` (written from the inventory settings) |
| database | `/var/lib/hpc/acct/acct.db` (SQLite, WAL mode) — **back this up** |
| parsed flat file | `/var/lib/hpc/projects.json` |
| user-visible summary | ConfigMap `project-usage` in each project namespace |
| job ID on objects | label `hpc.io/jobid` |
| submitter on objects | annotation `hpc.io/user` |

Tables: `jobs` (one row per job, never deleted), `pods` (the pods of each job),
`ledger` (allocation changes), `projects` (mirror of the flat file), `meta`
(recorder heartbeat). The database can be queried directly for custom reports:

```sh
sudo python3 -c "import sqlite3; print(sqlite3.connect('/var/lib/hpc/acct/acct.db').execute(
  'select project, user, sum(cpu_seconds)/3600, sum(wall_seconds) from jobs group by 1,2').fetchall())"
```

Backup: copy the file with the service stopped, or use SQLite's online backup.
The database cannot be rebuilt from the cluster: if it is lost, history and
this year's usage are lost and job IDs restart from 1.

## 8. Failure modes and limits

| Situation | Effect |
|-----------|--------|
| Recorder stopped | Nothing in the cluster is affected. Work that starts *and* is deleted entirely during the outage is not recorded. Anything still present when it restarts is recorded with correct start times; pods deleted during the outage are closed at the last time they were seen (under-counted). `hpc-acct status` shows `STALE`. |
| API server restarting | The recorder logs `cycle failed` and retries. |
| Admin node rebooted | The service starts after RKE2 and picks up where it was. |
| A member removes the `hpc.io/jobid` label | Cosmetic; the recorder puts it back. Records are keyed by the object's UID. |
| Project removed from the flat file | Its history stays; `status` shows it as `(removed)`. New activity in the leftover namespace is not recorded. |
| Many pods | One API call lists every tracked object each pass. Fine for hundreds to a few thousand pods; beyond that, raise `ACCT_POLL_SECONDS`. |

Not covered: memory-hours or GPU-hours (only CPU is accounted), measured CPU
utilisation (that needs a metrics stack), and work in platform namespaces.

## 9. Trying it by hand

```sh
# on the login node, as bob
kubectl create -f long-job.yaml               # docs/examples/long-job.yaml
kubectl create deployment web --image=python:3.13-slim -- python -m http.server 8080
kubectl get deploy,jobs,pods -L hpc.io/jobid
kubectl get configmap project-usage -o yaml
```

```sh
# on the deployer, as admin
sudo hpc-acct status
sudo hpc-acct jobs --project BS0001 --active
sudo hpc-acct job <jobid>
sudo hpc-acct users --project BS0001
sudo hpc-acct budget BS0001 --add 2 --reason "testing"
```

`ELAPSED` and `CPU_HOURS` of the running job and the Deployment grow each time
you look; delete them and they show `CANCELLED` / `STOPPED` with an end time.
