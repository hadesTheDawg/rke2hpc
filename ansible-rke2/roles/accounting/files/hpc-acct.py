#!/usr/bin/env python3
"""hpc-acct: usage accounting for project namespaces.

Installed on the admin node as /usr/local/sbin/hpc-acct by the 89-accounting
module. Python 3.9 standard library only. Full description: docs/accounting.md.

It measures and reports; it does not limit anything. Two halves share one
SQLite database (/var/lib/hpc/acct/acct.db):

  hpc-acct daemon      the recorder (systemd unit hpc-acct.service). Every few
                       seconds it reads workloads and pods from the Kubernetes
                       API and records who ran what, when, and for how long.
  hpc-acct <command>   the admin tool: read statistics, maintain each project's
                       CPU-hour allocation.

A "job" is what a user submits: a Deployment, StatefulSet, DaemonSet, Job, or a
Pod created directly. The pods a workload creates are rolled up into its record.
"""
import argparse
import csv
import datetime
import json
import os
import sqlite3
import subprocess
import sys
import time

E = os.environ
STATE_DIR = "/var/lib/hpc"
DB_FILE = STATE_DIR + "/acct/acct.db"
PROJECTS_JSON = STATE_DIR + "/projects.json"      # written by `hpc-sync tenants`
SETTINGS_FILE = "/etc/hpc/acct.env"               # written by the 89-accounting module
KUBECTL = ["/var/lib/rancher/rke2/bin/kubectl", "--kubeconfig", "/etc/rancher/rke2/rke2.yaml"]
USAGE_CM = "project-usage"       # one ConfigMap per project namespace, readable by its members
JOBID_LABEL = "hpc.io/jobid"
OWNER_ANNOTATION = "hpc.io/user"
ACTIVE = ("PENDING", "RUNNING")
# what counts as a submitted workload, and how kubectl names it
WORKLOADS = {"Deployment": "deployments.apps", "StatefulSet": "statefulsets.apps", "DaemonSet": "daemonsets.apps",
             "ReplicaSet": "replicasets.apps", "Job": "jobs.batch", "Pod": "pods"}
BATCH = ("Job", "Pod")               # these finish by themselves; the others run until deleted


def settings():
    """KEY=VALUE settings (poll interval, start of the accounting year, default CPU request)."""
    s = {"ACCT_POLL_SECONDS": "5", "ACCT_PERIOD_START": "10-01", "TENANT_DEFAULT_CPU_REQUEST": "500m"}
    if os.path.exists(SETTINGS_FILE):
        for line in open(SETTINGS_FILE):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                s[k] = v.strip().strip('"')
    return s


CFG = settings()


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------- units
def cpu_cores(q):
    """Kubernetes CPU quantity -> cores ('500m' -> 0.5)."""
    q = str(q)
    return float(q[:-1]) / 1000.0 if q.endswith("m") else float(q)


def mem_mib(q):
    q = str(q)
    for suffix, factor in (("Ki", 1 / 1024.0), ("Mi", 1.0), ("Gi", 1024.0), ("Ti", 1048576.0),
                           ("k", 1000 / 1048576.0), ("M", 1e6 / 1048576.0), ("G", 1e9 / 1048576.0)):
        if q.endswith(suffix):
            return float(q[:-len(suffix)]) * factor
    return float(q) / 1048576.0


def ts(k8s_time):
    """'2026-11-14T09:35:00Z' -> epoch seconds (None stays None)."""
    if not k8s_time:
        return None
    return datetime.datetime.strptime(k8s_time, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def hms(seconds):
    if seconds is None:
        return "-"
    seconds = int(round(seconds))
    return "%02d:%02d:%02d" % (seconds // 3600, seconds % 3600 // 60, seconds % 60)


def stamp(epoch):
    if epoch is None:
        return "-"
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def period_of(epoch):
    """Budget year containing a moment. Years start on ACCT_PERIOD_START (MM-DD, UTC)
    and are named by their start date, e.g. '2026-10-01'."""
    month, day = (int(x) for x in CFG["ACCT_PERIOD_START"].split("-"))
    d = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    year = d.year if (d.month, d.day) >= (month, day) else d.year - 1
    return "%04d-%02d-%02d" % (year, month, day)


# --------------------------------------------------------------------------- database
SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (      -- mirror of the flat file (via hpc-sync)
  project TEXT PRIMARY KEY, namespace TEXT UNIQUE, budget_cpu_hours REAL, active INTEGER DEFAULT 1);
CREATE TABLE IF NOT EXISTS jobs (          -- one row per submitted workload; never deleted
  jobid INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT UNIQUE, kind TEXT, namespace TEXT, project TEXT, name TEXT,
  user TEXT, period TEXT, submit_ts REAL, start_ts REAL, end_ts REAL, state TEXT, reason TEXT,
  limit_s INTEGER, cpu REAL, parallelism INTEGER, mem_mib REAL,
  cpu_seconds REAL DEFAULT 0, wall_seconds REAL DEFAULT 0, last_seen REAL, labelled INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS pods (          -- the pods that did the work
  uid TEXT PRIMARY KEY, jobid INTEGER, name TEXT, node TEXT, cpu REAL, start_ts REAL, end_ts REAL,
  state TEXT, last_seen REAL, labelled INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS ledger (        -- allocation changes made with `hpc-acct budget`
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, project TEXT, period TEXT, delta_cpu_hours REAL, reason TEXT, actor TEXT);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX IF NOT EXISTS jobs_project_period ON jobs(project, period);
CREATE INDEX IF NOT EXISTS pods_jobid ON pods(jobid);
"""


def db_open():
    os.makedirs(os.path.dirname(DB_FILE), mode=0o700, exist_ok=True)
    db = sqlite3.connect(DB_FILE, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")       # the admin tool can read while the recorder writes
    db.executescript(SCHEMA)
    return db


def sync_projects(db):
    """Each project's yearly CPU-hour allocation comes from the flat file, through hpc-sync."""
    if not os.path.exists(PROJECTS_JSON):
        return
    wanted = json.load(open(PROJECTS_JSON))
    db.execute("UPDATE projects SET active=0")
    for p in wanted:
        db.execute("INSERT INTO projects(project, namespace, budget_cpu_hours, active) VALUES(?,?,?,1) "
                   "ON CONFLICT(project) DO UPDATE SET namespace=excluded.namespace, "
                   "budget_cpu_hours=excluded.budget_cpu_hours, active=1",
                   (p["group"], p["ns"], float(p["budget_cpu_hours"])))
    db.commit()


def budget_state(db, project, period, now=None):
    """The numbers for one project in one accounting year, in CPU-seconds.
    The allocation is a yardstick: `remaining` goes negative when a project has
    used more than it was given; nothing is stopped."""
    p = db.execute("SELECT * FROM projects WHERE project=?", (project,)).fetchone()
    base = (p["budget_cpu_hours"] if p else 0.0) * 3600
    adj = db.execute("SELECT COALESCE(SUM(delta_cpu_hours),0) FROM ledger WHERE project=? AND period=?",
                     (project, period)).fetchone()[0] * 3600
    used, wall, njobs = db.execute("SELECT COALESCE(SUM(cpu_seconds),0), COALESCE(SUM(wall_seconds),0), COUNT(*) "
                                   "FROM jobs WHERE project=? AND period=?", (project, period)).fetchone()
    active = db.execute("SELECT COUNT(*) FROM jobs WHERE project=? AND state IN ('PENDING','RUNNING')",
                        (project,)).fetchone()[0]
    total = base + adj
    return {"project": project, "period": period, "base": base, "adjust": adj, "budget": total, "used": used,
            "remaining": total - used, "wall": wall, "jobs": njobs, "active": active}


# --------------------------------------------------------------------------- kubernetes
def kubectl(*args, stdin=None, check=True):
    p = subprocess.run(KUBECTL + list(args), input=stdin, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError("kubectl %s: %s" % (" ".join(args[:3]), p.stderr.strip()))
    return p.stdout


def apply(objs):
    kubectl("apply", "--server-side", "--force-conflicts", "--field-manager=hpc-acct", "-f", "-",
            stdin=json.dumps({"apiVersion": "v1", "kind": "List", "items": objs}))


def container_cpu(containers, default):
    total = 0.0
    for c in containers:
        res = c.get("resources", {})
        q = res.get("requests", {}).get("cpu") or res.get("limits", {}).get("cpu")
        total += cpu_cores(q) if q else default
    return total


def container_mem(containers):
    return sum(mem_mib(c.get("resources", {}).get("requests", {}).get("memory", 0)) for c in containers)


def pod_times(pod, now):
    """(start, end, state) of a pod from its container statuses. Time spent
    pending (unschedulable, pulling images) is not run time."""
    st = pod.get("status", {})
    starts, ends, running, reason = [], [], False, st.get("reason", "")
    for cs in st.get("containerStatuses", []):
        state = cs.get("state", {})
        if "running" in state:
            running = True
            starts.append(ts(state["running"].get("startedAt")))
        elif "terminated" in state:
            starts.append(ts(state["terminated"].get("startedAt")))
            ends.append(ts(state["terminated"].get("finishedAt")))
            if state["terminated"].get("reason") == "OOMKilled":
                reason = "OOMKilled"
    starts = [s for s in starts if s]
    start = min(starts) if starts else None
    phase = st.get("phase", "Pending")
    if phase == "Succeeded":
        return start, max([e for e in ends if e] or [now]), "COMPLETED", reason
    if phase == "Failed":
        end = max([e for e in ends if e] or [now])
        state = "TIMEOUT" if reason == "DeadlineExceeded" else ("OOM" if reason == "OOMKilled" else "FAILED")
        return start, end, state, reason
    return start, None, ("RUNNING" if running else "PENDING"), reason


def job_outcome(job):
    """(state, end, reason) from a Job's conditions; (None, None, '') while it is active."""
    for c in job.get("status", {}).get("conditions", []):
        if c.get("status") != "True":
            continue
        if c["type"] == "Complete":
            return "COMPLETED", ts(job["status"].get("completionTime") or c.get("lastTransitionTime")), ""
        if c["type"] == "Failed":
            state = "TIMEOUT" if c.get("reason") == "DeadlineExceeded" else "FAILED"
            return state, ts(c.get("lastTransitionTime")), c.get("reason", "")
    return None, None, ""


# --------------------------------------------------------------------------- recorder
def record(db):
    """One pass: bring the database in line with what the API shows right now."""
    sync_projects(db)
    projects = {r["namespace"]: r["project"] for r in db.execute("SELECT * FROM projects WHERE active=1")}
    now = time.time()
    default_cpu = cpu_cores(CFG["TENANT_DEFAULT_CPU_REQUEST"])
    items = json.loads(kubectl("get", ",".join(WORKLOADS.values()), "-A", "-o", "json"))["items"]
    items = [o for o in items if o["metadata"]["namespace"] in projects]
    index = {o["metadata"]["uid"]: o for o in items}

    def top(obj):
        """The object the user submitted: follow controller references upwards
        (Pod -> ReplicaSet -> Deployment). None if a parent is already gone."""
        while True:
            owners = obj["metadata"].get("ownerReferences", [])
            if not owners:
                return obj
            parent = next((index.get(o["uid"]) for o in owners if o.get("kind") in WORKLOADS), None)
            if parent is None:
                # owned by something we do not track as a workload (e.g. a CronJob's Job): count it itself;
                # owned by a tracked kind that has vanished: its row already exists, nothing to attach to
                return obj if not any(o.get("kind") in WORKLOADS for o in owners) else None
            obj = parent

    by_uid = {}

    def register(obj):
        m, spec, kind = obj["metadata"], obj["spec"], obj["kind"]
        if kind == "Pod":
            pod_spec, ann, replicas = spec, m.get("annotations", {}), 1
        else:
            pod_spec, ann = spec["template"]["spec"], spec["template"]["metadata"].get("annotations", {})
            replicas = spec.get("replicas", spec.get("parallelism", 1)) or 1
        limit = spec.get("activeDeadlineSeconds") if kind in BATCH else None    # only if the user set one
        row = db.execute("SELECT * FROM jobs WHERE uid=?", (m["uid"],)).fetchone()
        if not row:
            submit = ts(m["creationTimestamp"])
            user = ann.get(OWNER_ANNOTATION, "")
            cpu = container_cpu(pod_spec["containers"], default_cpu)
            db.execute("INSERT INTO jobs(uid, kind, namespace, project, name, user, period, submit_ts, state, "
                       "limit_s, cpu, parallelism, mem_mib, last_seen) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (m["uid"], kind, m["namespace"], projects[m["namespace"]], m["name"], user, period_of(submit),
                        submit, "PENDING", limit, cpu, replicas, container_mem(pod_spec["containers"]), now))
            row = db.execute("SELECT * FROM jobs WHERE uid=?", (m["uid"],)).fetchone()
            log("job %d: %s %s/%s submitted by %s (%.3g cpu x %d)"
                % (row["jobid"], kind, m["namespace"], m["name"], user or "?", cpu, replicas))
        else:
            db.execute("UPDATE jobs SET last_seen=?, limit_s=?, parallelism=? WHERE uid=?",
                       (now, limit, replicas, m["uid"]))
        by_uid[m["uid"]] = row["jobid"]
        if m.get("labels", {}).get(JOBID_LABEL) != str(row["jobid"]):
            kubectl("label", "--overwrite", WORKLOADS[kind], m["name"], "-n", m["namespace"],
                    "%s=%d" % (JOBID_LABEL, row["jobid"]), check=False)
        return row["jobid"]

    pods = [o for o in items if o["kind"] == "Pod"]
    for o in items:                       # workloads first, so their pods find them
        if o["kind"] != "Pod" and top(o) is o:
            register(o)

    seen_pods = set()
    for p in pods:
        m, spec = p["metadata"], p["spec"]
        owner = top(p)
        if owner is None:
            continue
        jobid = by_uid.get(owner["metadata"]["uid"]) or register(owner)
        start, end, state, _ = pod_times(p, now)
        seen_pods.add(m["uid"])
        db.execute("INSERT INTO pods(uid, jobid, name, node, cpu, start_ts, end_ts, state, last_seen) "
                   "VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(uid) DO UPDATE SET node=excluded.node, "
                   "start_ts=excluded.start_ts, end_ts=excluded.end_ts, state=excluded.state, last_seen=excluded.last_seen",
                   (m["uid"], jobid, m["name"], spec.get("nodeName", ""), container_cpu(spec["containers"], default_cpu),
                    start, end, state, now))
        if owner is not p and m.get("labels", {}).get(JOBID_LABEL) != str(jobid):
            kubectl("label", "--overwrite", "pod", m["name"], "-n", m["namespace"],
                    "%s=%d" % (JOBID_LABEL, jobid), check=False)

    # Pods that vanished while still open stopped (at the latest) when last seen.
    for r in db.execute("SELECT uid, last_seen FROM pods WHERE end_ts IS NULL").fetchall():
        if r["uid"] not in seen_pods:
            db.execute("UPDATE pods SET end_ts=?, state='DELETED' WHERE uid=?", (r["last_seen"], r["uid"]))

    for j in db.execute("SELECT * FROM jobs WHERE state IN ('PENDING','RUNNING')").fetchall():
        rows = db.execute("SELECT * FROM pods WHERE jobid=?", (j["jobid"],)).fetchall()
        started = [r["start_ts"] for r in rows if r["start_ts"]]
        ends = [r["end_ts"] for r in rows if r["end_ts"]]
        running = any(r["start_ts"] and not r["end_ts"] for r in rows)
        cpu_s = sum(((r["end_ts"] or now) - r["start_ts"]) * r["cpu"] for r in rows if r["start_ts"])
        start = min(started) if started else None
        obj = index.get(j["uid"])
        state, end, reason = j["state"], None, j["reason"] or ""
        if obj is None:                                   # the user (or an admin) deleted it
            state = "CANCELLED" if j["kind"] in BATCH else "STOPPED"
            end, reason = j["last_seen"], "deleted"
        elif j["kind"] == "Job":
            outcome, end, reason = job_outcome(obj)
            state = outcome or ("RUNNING" if started else "PENDING")
        elif j["kind"] == "Pod":
            _, end, state, reason = pod_times(obj, now)
        else:                                             # a service: runs for as long as it exists
            state = "RUNNING" if started else "PENDING"
        if state not in ACTIVE:
            end = max(ends) if ends else (end or now)     # when the work stopped, not when it was noticed
        # true elapsed time: first container start to last container stop
        last = end if state not in ACTIVE else (now if running else (max(ends) if ends else now))
        wall = (last - start) if start else 0.0
        db.execute("UPDATE jobs SET state=?, reason=?, start_ts=?, end_ts=?, cpu_seconds=?, wall_seconds=? WHERE jobid=?",
                   (state, reason, start, end if state not in ACTIVE else None, cpu_s, max(wall, 0.0), j["jobid"]))
        if state not in ACTIVE:
            log("job %d: %s after %s (%.4f CPU-hours)%s"
                % (j["jobid"], state, hms(wall), cpu_s / 3600, " [%s]" % reason if reason else ""))
    db.execute("INSERT INTO meta(key,value) VALUES('heartbeat',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
               (str(now),))
    db.commit()


def publish(db, last):
    """Write a summary ConfigMap into each project namespace so that members (and
    the Rancher UI) can see their own usage. Nothing in the cluster reads it."""
    now = time.time()
    period = period_of(now)
    summaries = {}
    for p in db.execute("SELECT * FROM projects WHERE active=1"):
        b = budget_state(db, p["project"], period, now)
        active = db.execute("SELECT jobid, user, kind, name, state, wall_seconds FROM jobs WHERE project=? AND state "
                            "IN ('PENDING','RUNNING') ORDER BY jobid", (p["project"],)).fetchall()
        summaries[p["namespace"]] = {
            "project": p["project"], "accounting-year-starts": period,
            "allocation-cpu-hours": "%.2f" % (b["budget"] / 3600),
            "used-cpu-hours": "%.2f" % (b["used"] / 3600),
            "remaining-cpu-hours": "%.2f" % (b["remaining"] / 3600),
            "wall-clock-run": hms(b["wall"]),
            "active-jobs": "\n".join("%d %s %s/%s %s %s" % (r["jobid"], r["user"] or "?", r["kind"], r["name"],
                                                           r["state"], hms(r["wall_seconds"])) for r in active) or "none",
        }
    # usage changes every second while anything runs; refresh at most once a minute unless something else changed
    structural = {ns: {k: v for k, v in s.items() if k not in ("used-cpu-hours", "remaining-cpu-hours", "wall-clock-run")}
                  for ns, s in summaries.items()}
    if structural != last.get("structural") or now - last.get("summary_ts", 0) > 60:
        apply([{"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"name": USAGE_CM, "namespace": ns, "labels": {"hpc.io/project": s["project"]}},
                "data": s} for ns, s in summaries.items()])
        last["structural"], last["summary_ts"] = structural, now


def cmd_daemon(args):
    db, last = db_open(), {}
    interval = float(CFG["ACCT_POLL_SECONDS"])
    log("hpc-acct recorder started (every %gs, accounting year starts %s)" % (interval, CFG["ACCT_PERIOD_START"]))
    while True:
        try:
            record(db)
            publish(db, last)
        except Exception as e:           # the API server restarting must not kill the recorder
            log("cycle failed: %s" % e)
            last.clear()
        if args.once:
            return
        time.sleep(interval)


# --------------------------------------------------------------------------- admin commands
def table(rows, headers, right=()):
    widths = [max(len(str(x)) for x in col) for col in zip(headers, *rows)] if rows else [len(h) for h in headers]
    for r in [headers] + rows:
        print("  ".join(str(c).rjust(w) if i in right else str(c).ljust(w) for i, (c, w) in enumerate(zip(r, widths))).rstrip())


def need_project(db, name):
    row = db.execute("SELECT * FROM projects WHERE project=? COLLATE NOCASE", (name,)).fetchone()
    if not row:
        die("unknown project '%s' (known: %s)" % (name, ", ".join(
            r["project"] for r in db.execute("SELECT project FROM projects ORDER BY project")) or "none"))
    return row


def cmd_status(args):
    db, now = db_open(), time.time()
    period = args.period or period_of(now)
    beat = db.execute("SELECT value FROM meta WHERE key='heartbeat'").fetchone()
    age = now - float(beat["value"]) if beat else None
    out = []
    for p in db.execute("SELECT * FROM projects ORDER BY project"):
        b = budget_state(db, p["project"], period, now)
        b["active_project"] = bool(p["active"])
        out.append(b)
    if args.json:
        print(json.dumps({"recorder_age_seconds": age, "period": period, "projects": out}, indent=1))
        return
    health = "never ran" if age is None else ("ok, last pass %ds ago" % age if age < 60 else "STALE, last pass %s ago" % hms(age))
    print("accounting year starting %s (UTC)    recorder: %s\n" % (period, health))
    table([[b["project"] + ("" if b["active_project"] else " (removed)"), "%.2f" % (b["budget"] / 3600),
            "%.2f" % (b["used"] / 3600), "%.2f" % (b["remaining"] / 3600),
            "%.0f%%" % (100 * b["used"] / b["budget"]) if b["budget"] else "-",
            hms(b["wall"]), b["jobs"], b["active"]] for b in out],
          ["PROJECT", "ALLOCATION", "USED", "REMAINING", "USED%", "WALL", "JOBS", "ACTIVE"],
          right=(1, 2, 3, 4, 5, 6, 7))
    print("\nALLOCATION/USED/REMAINING are CPU-hours; WALL is true elapsed time (hh:mm:ss) summed over jobs.")
    print("The allocation is informational: a negative REMAINING means the project is over it; nothing is stopped.")


JOB_COLUMNS = ["jobid", "project", "user", "kind", "name", "state", "submit", "start", "end", "elapsed", "cpus",
               "cpu_hours"]


def job_row(j, now):
    wall = j["wall_seconds"]
    return {"jobid": j["jobid"], "project": j["project"], "user": j["user"] or "?", "kind": j["kind"], "name": j["name"],
            "state": j["state"], "submit": stamp(j["submit_ts"]), "start": stamp(j["start_ts"]), "end": stamp(j["end_ts"]),
            "elapsed": hms(wall), "limit": hms(j["limit_s"]), "cpus": "%.3g" % ((j["cpu"] or 0) * (j["parallelism"] or 1)),
            "cpu_hours": "%.4f" % (j["cpu_seconds"] / 3600), "elapsed_seconds": wall, "cpu_seconds": j["cpu_seconds"],
            "reason": j["reason"] or "", "period": j["period"], "namespace": j["namespace"]}


def cmd_jobs(args):
    db, now = db_open(), time.time()
    where, vals = [], []
    if args.project:
        where.append("project=? COLLATE NOCASE"); vals.append(args.project)
    if args.user:
        where.append("user=?"); vals.append(args.user)
    if args.state:
        where.append("state=?"); vals.append(args.state.upper())
    if args.active:
        where.append("state IN ('PENDING','RUNNING')")
    if not args.all_years:
        where.append("period=?"); vals.append(args.period or period_of(now))
    sql = "SELECT * FROM jobs" + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY jobid DESC LIMIT ?"
    rows = [job_row(j, now) for j in db.execute(sql, vals + [args.limit])][::-1]
    if args.json:
        print(json.dumps(rows, indent=1))
    elif args.csv:
        w = csv.DictWriter(sys.stdout, fieldnames=JOB_COLUMNS + ["reason", "period", "namespace"], extrasaction="ignore")
        w.writeheader(); w.writerows(rows)
    else:
        table([[r[c] for c in JOB_COLUMNS] for r in rows], [c.upper() for c in JOB_COLUMNS], right=(0, 9, 10, 11))


def cmd_job(args):
    db, now = db_open(), time.time()
    j = db.execute("SELECT * FROM jobs WHERE jobid=?", (args.jobid,)).fetchone()
    if not j:
        die("no job %d" % args.jobid)
    r = job_row(j, now)
    for k in ("jobid", "project", "namespace", "user", "kind", "name", "state", "reason", "period", "submit", "start",
              "end", "elapsed", "cpus", "cpu_hours"):
        print("%-10s %s" % (k, r[k]))
    if j["limit_s"]:
        print("%-10s %s (set by the user)" % ("time limit", hms(j["limit_s"])))
    print("%-10s %.0f MiB" % ("memory", j["mem_mib"] or 0))
    print("\npods:")
    table([[p["name"], p["node"] or "-", p["state"], stamp(p["start_ts"]), stamp(p["end_ts"]),
            hms(((p["end_ts"] or now) - p["start_ts"]) if p["start_ts"] else None), "%.3g" % p["cpu"]]
           for p in db.execute("SELECT * FROM pods WHERE jobid=? ORDER BY start_ts", (args.jobid,))],
          ["POD", "NODE", "STATE", "START", "END", "RAN", "CPUS"], right=(5, 6))


def cmd_budget(args):
    db, now = db_open(), time.time()
    p = need_project(db, args.project)
    period = period_of(now)
    b = budget_state(db, p["project"], period, now)
    if args.add is not None or args.set is not None:
        delta = args.add if args.add is not None else args.set - b["budget"] / 3600
        if not args.reason:
            die("--reason is required when changing an allocation")
        db.execute("INSERT INTO ledger(ts, project, period, delta_cpu_hours, reason, actor) VALUES(?,?,?,?,?,?)",
                   (now, p["project"], period, delta, args.reason, E.get("SUDO_USER") or E.get("USER") or "root"))
        db.commit()
        b = budget_state(db, p["project"], period, now)
        print("%s: allocation changed by %+.2f CPU-hours" % (p["project"], delta))
    print("project          %s (namespace %s)" % (p["project"], p["namespace"]))
    print("accounting year  starts %s (UTC)" % period)
    print("allocation       %.2f CPU-hours  = %.2f from the flat file %+.2f adjustments"
          % (b["budget"] / 3600, b["base"] / 3600, b["adjust"] / 3600))
    print("used             %.2f CPU-hours in %d jobs (%s wall-clock)" % (b["used"] / 3600, b["jobs"], hms(b["wall"])))
    print("remaining        %.2f CPU-hours%s" % (b["remaining"] / 3600, "  (over allocation)" if b["remaining"] < 0 else ""))
    print("active now       %d" % b["active"])


def cmd_ledger(args):
    db = db_open()
    where, vals = "", []
    if args.project:
        where, vals = " WHERE project=? COLLATE NOCASE", [args.project]
    table([[stamp(r["ts"]), r["project"], r["period"], "%+.2f" % r["delta_cpu_hours"], r["actor"], r["reason"]]
           for r in db.execute("SELECT * FROM ledger" + where + " ORDER BY id", vals)],
          ["WHEN", "PROJECT", "YEAR", "CPU-HOURS", "BY", "REASON"], right=(3,))


def cmd_history(args):
    """Usage per accounting year. Nothing is ever deleted at a year change."""
    db = db_open()
    where, vals = "", []
    if args.project:
        where, vals = " WHERE project=? COLLATE NOCASE", [args.project]
    table([[r["period"], r["project"], r["n"], "%.2f" % (r["cpu"] / 3600), hms(r["wall"])] for r in db.execute(
        "SELECT period, project, COUNT(*) n, SUM(cpu_seconds) cpu, SUM(wall_seconds) wall FROM jobs" + where +
        " GROUP BY period, project ORDER BY period, project", vals)],
          ["YEAR", "PROJECT", "JOBS", "CPU-HOURS", "WALL"], right=(2, 3, 4))


def cmd_users(args):
    db, now = db_open(), time.time()
    where, vals = ["period=?"], [args.period or period_of(now)]
    if args.project:
        where.append("project=? COLLATE NOCASE"); vals.append(args.project)
    table([[r["project"], r["user"] or "?", r["n"], "%.2f" % (r["cpu"] / 3600), hms(r["wall"])] for r in db.execute(
        "SELECT project, user, COUNT(*) n, SUM(cpu_seconds) cpu, SUM(wall_seconds) wall FROM jobs WHERE " +
        " AND ".join(where) + " GROUP BY project, user ORDER BY project, cpu DESC", vals)],
          ["PROJECT", "USER", "JOBS", "CPU-HOURS", "WALL"], right=(2, 3, 4))


def cmd_cancel(args):
    db = db_open()
    j = db.execute("SELECT * FROM jobs WHERE jobid=?", (args.jobid,)).fetchone()
    if not j:
        die("no job %d" % args.jobid)
    if j["state"] not in ACTIVE:
        die("job %d is not active (%s)" % (args.jobid, j["state"]))
    kind = WORKLOADS[j["kind"]]
    live = kubectl("get", kind, j["name"], "-n", j["namespace"], "-o", "jsonpath={.metadata.uid}", check=False).strip()
    if live != j["uid"]:
        die("job %d no longer exists in the cluster" % args.jobid)
    kubectl("delete", kind, j["name"], "-n", j["namespace"], "--wait=false")
    print("job %d (%s %s/%s) cancelled" % (args.jobid, j["kind"], j["namespace"], j["name"]))


def main():
    ap = argparse.ArgumentParser(prog="hpc-acct", description="Usage accounting for project namespaces (measures and reports; limits nothing).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status", help="allocation, usage and remaining CPU-hours per project")
    s.add_argument("--period", help="accounting year by start date, e.g. 2025-10-01 (default: current)")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("jobs", help="job history: id, user, start, end, elapsed, CPU-hours")
    s.add_argument("--project"); s.add_argument("--user"); s.add_argument("--state")
    s.add_argument("--active", action="store_true", help="only pending and running jobs")
    s.add_argument("--period"); s.add_argument("--all-years", action="store_true")
    s.add_argument("-n", "--limit", type=int, default=50)
    s.add_argument("--json", action="store_true"); s.add_argument("--csv", action="store_true")
    s = sub.add_parser("job", help="one job in detail, with its pods")
    s.add_argument("jobid", type=int)
    s = sub.add_parser("budget", help="show or change a project's CPU-hour allocation for the current year")
    s.add_argument("project")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--add", type=float, metavar="CPU_HOURS", help="grant (or with a negative number, take away)")
    g.add_argument("--set", type=float, metavar="CPU_HOURS", help="make the year's total allocation exactly this")
    s.add_argument("--reason", help="recorded in the ledger")
    s = sub.add_parser("ledger", help="every allocation change, who made it and why")
    s.add_argument("project", nargs="?")
    s = sub.add_parser("history", help="usage per accounting year (kept forever)")
    s.add_argument("project", nargs="?")
    s = sub.add_parser("users", help="usage per user")
    s.add_argument("--project"); s.add_argument("--period")
    s = sub.add_parser("cancel", help="stop an active job")
    s.add_argument("jobid", type=int)
    s = sub.add_parser("daemon", help="run the recorder (normally: systemctl status hpc-acct)")
    s.add_argument("--once", action="store_true", help="one pass, then exit")
    args = ap.parse_args()
    if os.geteuid() != 0:
        die("hpc-acct must run as root on the admin node")
    {"status": cmd_status, "jobs": cmd_jobs, "job": cmd_job, "budget": cmd_budget, "ledger": cmd_ledger,
     "history": cmd_history, "users": cmd_users, "cancel": cmd_cancel, "daemon": cmd_daemon}[args.cmd](args)


if __name__ == "__main__":
    main()
