# Design: enforcing run time and restricting workload types

**Status: not implemented. Nothing in this document is installed or enforced.**

Today projects may run any workload for any length of time, and `hpc-acct`
only measures it (see [accounting.md](accounting.md)). This document describes
how the cluster could instead be made to behave like a batch scheduler:

- A. refuse long-running services (Deployments and similar);
- B. require every job to state a time limit, and stop it at that limit;
- C. cap the time limit per project;
- D. give each project a CPU-hour budget and refuse new jobs when it is used up.

Each part is independent and builds on what is already deployed. An earlier
iteration of this repository had A–D running and passing acceptance tests on
RKE2 v1.36 before being removed, so the mechanisms below are known to work as
described; the notes under "Verified behaviour" come from that.

## Contents

1. [What already exists to build on](#1-what-already-exists-to-build-on)
2. [The mechanism: admission policies](#2-the-mechanism-admission-policies)
3. [A. Batch only](#3-a-batch-only)
4. [B. Mandatory time limit](#4-b-mandatory-time-limit)
5. [C. Maximum time per job](#5-c-maximum-time-per-job)
6. [D. CPU-hour budget](#6-d-cpu-hour-budget)
7. [What users would see](#7-what-users-would-see)
8. [Differences from Slurm](#8-differences-from-slurm)
9. [If services must stay: a softer variant](#9-if-services-must-stay-a-softer-variant)
10. [Rollout plan](#10-rollout-plan)
11. [Decisions to make first](#11-decisions-to-make-first)

---

## 1. What already exists to build on

| Piece | Where | Used for |
|-------|-------|----------|
| Project namespaces labelled `hpc.io/tenant=true` | tenants module | scoping any policy to projects only |
| `hpc.io/user` stamp on workloads and pods | tenants module (mutating admission) | knowing who submitted |
| The recorder and its database | `hpc-acct` | per-project CPU-hours used, per job state |
| The yearly allocation per project | flat file field `CPU_HOURS`, `hpc-acct budget` | would become the enforced budget |
| The accounting year (1 October) | `ACCT_PERIOD_START` | would become the budget reset |
| `ValidatingAdmissionPolicy` in use | tenants module (ingress hosts, network policies, volumes) | same mechanism, more rules |

So enforcement is a matter of adding admission rules and one feedback path from
the recorder to admission. No new component, image or controller is needed for
A–D.

## 2. The mechanism: admission policies

Kubernetes' built-in `ValidatingAdmissionPolicy` evaluates CEL expressions
inside `kube-apiserver` on each create/update, before the object is stored, and
can refuse it with a message. The repository already uses it. Properties that
matter here:

- It is scoped by a `namespaceSelector`, so platform namespaces are untouched.
- A policy can take a ConfigMap as **parameters** (`paramKind`/`paramRef`). The
  expressions see it as `params`. This is how per-project numbers that change
  over time (remaining budget) can reach admission without a webhook.
- `failurePolicy: Fail` plus `parameterNotFoundAction: Deny` makes it fail
  closed: if the parameters are missing, submissions are refused rather than
  let through unchecked.

Stopping a job at its time limit needs no policy at all: `activeDeadlineSeconds`
is enforced by the Job controller (for Jobs) and the kubelet (for Pods).

## 3. A. Batch only

**Rule:** in project namespaces, refuse creation of Deployments, StatefulSets,
DaemonSets, ReplicaSets, ReplicationControllers and (optionally) CronJobs.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: hpc-tenant-batch-only}
spec:
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector: {matchLabels: {hpc.io/tenant: "true"}}
    resourceRules:
    - {apiGroups: [apps], apiVersions: ["*"], operations: [CREATE],
       resources: [deployments, statefulsets, daemonsets, replicasets]}
    - {apiGroups: [""], apiVersions: ["*"], operations: [CREATE], resources: [replicationcontrollers]}
    - {apiGroups: [batch], apiVersions: ["*"], operations: [CREATE], resources: [cronjobs]}
  validations:
  - expression: "false"
    message: "projects run batch work only: submit a Job (or a Pod) with a time limit instead"
```

plus a `ValidatingAdmissionPolicyBinding` with `validationActions: [Deny]`.

Also required, or bare pods become a loophole for "run forever":

- Pods created by a person must have `restartPolicy` `Never` or `OnFailure`
  (Jobs already require this of their pods).

**Existing workloads** are not removed by a policy; it only affects new
submissions. Deployments already running would have to be deleted by their
owners or by an admin (`hpc-acct jobs --active` lists them with their owners).

**Verified behaviour:** the Rancher UI still shows the Deployment/StatefulSet
menus; submitting one fails with the message above.

## 4. B. Mandatory time limit

**Rule:** every Job, and every Pod created directly by a person, must set
`spec.activeDeadlineSeconds` (the equivalent of Slurm's `--time`).

```
has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds > 0
```

Two policies are needed because the rule differs by who is submitting:

- **Jobs** — on create, from anyone.
- **Pods** — on create, only when the requester is a person
  (`matchConditions: !request.userInfo.username.startsWith('system:')`). Pods
  created by the Job controller are exempt: their Job was checked and its
  deadline covers them.

A third policy stops the limit being extended afterwards (a Job's deadline is
mutable in Kubernetes):

```
object.spec.activeDeadlineSeconds <= oldObject.spec.activeDeadlineSeconds
```

and, for the same reason, forbids raising `spec.parallelism` after submission.

**What happens at the limit** (Kubernetes behaviour, no extra code):

- Job: the Job controller marks it `Failed` / `DeadlineExceeded` and deletes its
  running pods; no retry.
- Pod: the kubelet kills the containers; the pod becomes `Failed` /
  `DeadlineExceeded`.
- Containers get `SIGTERM`, then `SIGKILL` after
  `terminationGracePeriodSeconds` (30 s by default), so a process that ignores
  `SIGTERM` runs up to 30 s past its limit.
- `hpc-acct` already records both cases as `TIMEOUT`.

**Verified behaviour:** a job with a 12-second limit running `sleep 300` was
recorded as `TIMEOUT` after 11 s (with a 1-second grace period set).
`kubectl run` defaults to `restartPolicy: Always` and no limit, so interactive
use needs `--restart=Never --overrides='{"spec":{"activeDeadlineSeconds":600}}'`.

**Friendlier alternative:** instead of refusing a job with no limit, a
*mutating* policy could fill in a default (say 1 hour). That removes friction
but stops being "an argument chosen by the user".

## 5. C. Maximum time per job

**Rule:** the requested limit may not exceed a per-project maximum.

- Flat file: add a field, e.g. `GROUP:CPU:MEM:STORAGE:MAX_JOB_HOURS:CPU_HOURS: users`.
- The recorder (or the tenants module) publishes `maxjob.<namespace>` in
  seconds into a parameter ConfigMap, e.g. `kube-system/hpc-accounting`.
- The time-limit policies take that ConfigMap as `params` and add:

```
object.spec.activeDeadlineSeconds <= int(params.data['maxjob.' + namespaceObject.metadata.name])
```

If one cluster-wide maximum is enough, no parameters are needed: the number can
be written into the expression.

## 6. D. CPU-hour budget

**Rule:** when a project has consumed its allocation for the accounting year,
refuse new jobs. Running jobs are left to finish.

This is the only part that needs the recorder in the loop.

### 6.1 Feedback path

```
recorder ──► ConfigMap kube-system/hpc-accounting ──► admission policy (params)
              remaining.<namespace> = CPU-seconds a new job may still reserve
```

The recorder already computes used CPU-hours per project and year; it would add
one `kubectl apply` of this ConfigMap whenever a value changes.

### 6.2 Reservation

Checking only "is anything left?" lets many long jobs start at once on the last
CPU-minute and overrun without bound. The remedy is to charge a job's whole
request up front and refund what it does not use:

```
cost of a new job  = time limit × CPU cores requested × parallelism
reserved           = Σ over active jobs (their cost − what they have used so far)
remaining          = allocation − used − reserved
admit the job only if cost ≤ remaining
```

This makes B a prerequisite for D: without a time limit a job has no bounded
cost. As a job runs, `used` grows and its reservation shrinks by the same
amount; when it ends early the unused part returns. The sum of what admitted
jobs can consume never exceeds the allocation, which is why nothing has to be
killed for budget reasons.

The admission expression, for a Job:

```
double(object.spec.activeDeadlineSeconds)
  * object.spec.template.spec.containers.map(c,
        has(c.resources) && has(c.resources.requests) && 'cpu' in c.resources.requests
        ? quantity(c.resources.requests['cpu']).asApproximateFloat() : 0.5).sum()
  * double(has(object.spec.parallelism) ? object.spec.parallelism : 1)
  <= double(int(params.data['remaining.' + namespaceObject.metadata.name]))
```

(`0.5` stands for the namespace's default CPU request.) For a directly created
Pod the same with `object.spec.containers` and no parallelism.

### 6.3 Yearly reset and manual changes

Both already exist in `hpc-acct`: usage is summed per accounting year, so it
starts from zero on 1 October with history kept, and `hpc-acct budget --add /
--set` adjusts the current year with a ledger entry. Under enforcement those
adjustments would take effect at admission within one recorder pass.
`hpc-acct budget <project> --set 0` would suspend a project.

### 6.4 Known weaknesses

| Weakness | Consequence | Mitigation |
|----------|-------------|------------|
| The recorder publishes every few seconds | two jobs submitted within one pass are both checked against the same number; overrun of at most one job's reservation | acceptable, or shorten the interval |
| Recorder down | jobs are admitted against the last published value | alert on `hpc-acct status` showing `STALE`; or have the policy refuse when a published timestamp is old (needs the timestamp compared outside CEL, e.g. a watchdog that deletes the ConfigMap) |
| CPU-hours are by *request*, not use | an idle 8-core job costs 8 cores | this is how Slurm charges too |
| Only CPU is budgeted | memory- or GPU-heavy work is not limited by the budget | extend the cost formula with other resources |

**Verified behaviour:** with a 1 CPU-hour allocation, two 30-minute 1-core jobs
were admitted, the third was refused with "project time budget exhausted",
cancelling one returned its unused reservation within one pass.

## 7. What users would see

| Submission | Refused with |
|------------|--------------|
| a Deployment, StatefulSet, DaemonSet, CronJob | `projects run batch work only: submit a Job (or a Pod) with a time limit instead` |
| no time limit | `every job needs a time limit: set spec.activeDeadlineSeconds to the number of seconds it may run` |
| limit above the maximum | `the time limit exceeds this project's maximum of 3600 seconds per job` |
| not enough budget | `project time budget exhausted: this job would reserve 2 CPU-hours (time limit x CPU cores), but only 0.4 remain` |
| Pod with `restartPolicy: Always` | `project pods are batch jobs: set restartPolicy to Never or OnFailure` |
| raising the limit of a submitted job | `the time limit of a submitted job can be lowered but not raised or removed` |

Visibility for users would be what exists now (`hpc.io/jobid` label,
`project-usage` ConfigMap) with two more lines in the ConfigMap: reserved and
maximum time per job. In Rancher the Job form has a field for the active
deadline; bare pods need the YAML editor. (The exact Rancher screens were not
checked.)

## 8. Differences from Slurm

- **No queue.** A job that does not fit the quota or the budget is refused at
  submission, not held pending. Real queueing needs an add-on such as Kueue: it
  admits suspended Jobs when quota frees up, and the time limit would then
  count from admission. That is a new component and image to carry.
- **The clock on a Job starts at creation**, not when its pod starts running;
  on a bare Pod it starts when the kubelet starts it. Without a queue the gap
  is scheduling and image-pull time.
- **No priorities, fair-share or preemption** between projects or users.
- **Grace period.** `SIGTERM` then `SIGKILL` after the pod's grace period, like
  Slurm's `KillWait`, but set per pod by the user (default 30 s).

## 9. If services must stay: a softer variant

If some projects need long-running services (notebooks, dashboards), A cannot
be applied to them, and Kubernetes has no native deadline for a Deployment (its
controller simply replaces a killed pod). Options:

1. **Per-project switch.** A flat-file flag that leaves a project out of the
   batch-only policy (label the namespace, exclude it in the policy's
   `namespaceSelector`). Its services are then only measured, as today.
2. **Declared lifetime + reaper.** Require an annotation such as
   `hpc.io/walltime: 8h` on Deployments (admission policy), and have the
   recorder scale the workload to zero (or delete it) when it expires. The
   recorder already knows each workload's start time and owner, so this is a
   small addition to it, but it is the one place where `hpc-acct` would start
   *acting* on workloads rather than observing.
3. **Budget only.** Skip time limits for services and, when a project is over
   its allocation, refuse new workloads of any kind. Without reservations this
   can overrun, and running services keep consuming, so it is a soft stop.

## 10. Rollout plan

Each step is separately reversible (delete the policy and its binding).

1. **Report first.** Run the current accounting for a while; use
   `hpc-acct jobs --active` and `hpc-acct users` to see what would be affected
   (long-running services, jobs without limits, projects near their
   allocation).
2. **Warn before deny.** Bind each policy with
   `validationActions: [Warn, Audit]` first. Users get a warning on submission
   and nothing is refused; the API server's audit log shows what would have
   been.
3. **A + B** (batch only, mandatory limit) with `Deny`. Announce a date;
   existing services must be removed by then.
4. **C** (maximum per job) once sensible maxima are known from the history.
5. **D** (budget) last: add the parameter ConfigMap to the recorder, the
   reservation columns to `hpc-acct status`, and the budget expression.
6. Extend `verify.yml` with a check per rule (the earlier iteration had 16:
   each refusal message, a `TIMEOUT`, budget exhaustion and restoration).

Where the code would go: policies generated and applied by `hpc-acct` in the
`accounting` role (so enforcement and measurement ship together), the
extra flat-file field (a `Field` line in `roles/tenants/files/hpc_flatfile.py`, see flatfile.md).

## 11. Decisions to make first

1. Batch only for every project, or a per-project switch (section 9)?
2. Are CronJobs allowed? (Each run is an ordinary Job with a limit.)
3. Refuse jobs without a limit, or fill in a default?
4. One maximum time per job for the whole cluster, or per project?
5. Budget in CPU-hours (recommended, as recorded today) or wall-clock hours?
6. At exhaustion: block new jobs only (as designed here), or also stop running
   ones?
7. May a user lower a running job's limit to get reservation back? (Designed:
   yes.) May an admin extend one? (Would need an exemption for the admin group
   in the "frozen" policy.)
8. Is queueing wanted (Kueue), or is refuse-when-full acceptable?
