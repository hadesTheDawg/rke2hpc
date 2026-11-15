#!/usr/bin/env python3
"""hpc_flatfile: read the project flat file (projects.txt).

    THE FILE FORMAT IS DEFINED IN ONE PLACE: the FIELDS table below.

Every other part of the deployment (hpc-sync, hpc-acct, the Ansible roles, the
verify checks) gets its records from parse() and reads fields by *key*, so the
format can change without touching any of them.

  Remove a column (example: CPU_HOURS)
      1. delete (or comment out) its one line in FIELDS
      2. remove that column from every line of projects.txt
      3. python3 hpc_flatfile.py check projects.txt
    A removed field reads as its `default` everywhere else. For cpu_hours that
    means every project reports against TENANT_DEFAULT_CPU_HOURS; for a quota
    field (cpu, mem, storage) it means that limit is simply not set.

  Add a column (example: a GPU quota)
      1. add  Field("gpu", "GPUS", positive_int, required=False, default=None)
         at the position the column has in the file
      2. map it to the quota in QUOTA:  "gpu": {"requests.nvidia.com/gpu": "{}"}

  Change separators: SEPARATOR / USER_SEPARATOR.

Optional fields may be left out of a line entirely when every optional field
is left out (the line then has exactly the required columns), as the old
5-column lines without CPU_HOURS did.

Standalone use (on your laptop, before deploying an edited file):
    python3 hpc_flatfile.py check projects.txt     # validate + summary table
    python3 hpc_flatfile.py json  projects.txt     # parsed records as JSON
    python3 hpc_flatfile.py format                 # print the expected line format

Python 3.6+ standard library only.
"""
import json
import os
import re
import sys

SEPARATOR = ":"          # between columns
USER_SEPARATOR = ","     # between user names in the USERS column
COMMENT = "#"


# --------------------------------------------------------------------------- value parsers
# Each takes the raw (stripped) text and returns the value or raises ValueError(message).
GROUP_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]{0,30}[A-Za-z0-9]$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")


def group_name(text):
    if not GROUP_RE.match(text):
        raise ValueError("invalid group name '%s' (letters, digits, '-'; 2-32 chars)" % text)
    return text


def positive_int(text):
    if not text.isdigit() or int(text) <= 0:
        raise ValueError("must be a positive integer (got '%s')" % text)
    return int(text)


def positive_number(text):
    try:
        v = float(text)
    except ValueError:
        v = 0
    if v <= 0:
        raise ValueError("must be a positive number (got '%s')" % text)
    return v


def user_list(text):
    users = [u.strip() for u in text.split(USER_SEPARATOR) if u.strip()]
    bad = [u for u in users if not USER_RE.match(u)]
    if bad:
        raise ValueError("invalid username(s): %s" % ", ".join(bad))
    if len(set(users)) != len(users):
        raise ValueError("duplicate username")
    if not users:
        raise ValueError("no users")
    return users


class Field:
    def __init__(self, key, column, parse, required=True, default=None, help=""):
        self.key, self.column, self.parse = key, column, parse
        self.required, self.default, self.help = required, default, help


def env_default(name, fallback):
    """Default taken from the deployment settings (environment) when present."""
    return lambda: os.environ.get(name, fallback)


# --------------------------------------------------------------------------- THE FORMAT
# Columns in file order. key = name used by the rest of the deployment.
FIELDS = [
    #     key          column         parser           required/default                                          what it is
    Field("group",     "GROUP",       group_name,                                                                help="project group; namespace = lower case"),
    Field("cpu",       "CPU",         positive_int,                                                              help="cores the group may hold at once (shared quota)"),
    Field("mem",       "MEMORY_MIB",  positive_int,                                                              help="memory the group may hold at once, MiB"),
    Field("storage",   "STORAGE_GIB", positive_int,                                                              help="volume claims the group may request, GiB"),
    Field("cpu_hours", "CPU_HOURS",   positive_number, required=False, default=env_default("TENANT_DEFAULT_CPU_HOURS", "1000"), help="yearly CPU-hour allocation, reported against (not enforced)"),
    Field("users",     "USERS",       user_list,                                                                 help="members, comma separated"),
]

# Flat-file field -> ResourceQuota entries. "{}" is replaced by the value.
# A field that is absent (removed from FIELDS, or default None) sets nothing.
QUOTA = {
    "cpu":     {"requests.cpu": "{}", "limits.cpu": "{}"},
    "mem":     {"requests.memory": "{}Mi", "limits.memory": "{}Mi"},
    "storage": {"requests.storage": "{}Gi"},
}
# Always part of every project quota (not from the file).
QUOTA_FIXED = {"services.nodeports": "0", "services.loadbalancers": "0"}


# --------------------------------------------------------------------------- parsing
def line_format():
    return SEPARATOR.join(f.column if f.required else "[%s]" % f.column for f in FIELDS)


def _default(f):
    return f.default() if callable(f.default) else f.default


def parse_line(text):
    """One non-comment line -> record dict. Raises ValueError."""
    parts = [p.strip() for p in text.split(SEPARATOR)]
    required = [f for f in FIELDS if f.required]
    if len(parts) == len(FIELDS):
        cols = FIELDS
    elif len(parts) == len(required) and len(required) != len(FIELDS):
        cols = required
    else:
        raise ValueError("expected %d columns (%s), got %d" % (len(FIELDS), line_format(), len(parts)))
    rec, errs = {}, []
    for f, raw in zip(cols, parts):
        try:
            rec[f.key] = f.parse(raw)
        except ValueError as e:
            errs.append("%s: %s" % (f.column, e))
    for f in FIELDS:
        if f.key not in rec and not f.required:
            d = _default(f)
            rec[f.key] = f.parse(str(d)) if d not in (None, "") else None
    if errs:
        raise ValueError("; ".join(errs))
    return rec


def parse(path):
    """Whole file -> list of records. Raises ValueError listing every problem."""
    out, errors, seen_ns = [], [], {}
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            text = raw.split(COMMENT, 1)[0].strip()
            if not text:
                continue
            try:
                rec = parse_line(text)
            except ValueError as e:
                errors.append("line %d: %s" % (n, e))
                continue
            rec["ns"] = rec["group"].lower()
            if rec["ns"] in seen_ns:
                errors.append("line %d: group '%s' collides with '%s'" % (n, rec["group"], seen_ns[rec["ns"]]))
            seen_ns[rec["ns"]] = rec["group"]
            rec.setdefault("users", [])
            out.append(rec)
    if errors:
        raise ValueError("invalid %s:\n  %s" % (path, "\n  ".join(errors)))
    if not out:
        raise ValueError("%s contains no project groups" % path)
    return out


def quota_hard(rec):
    """ResourceQuota spec.hard for one record."""
    hard = dict(QUOTA_FIXED)
    for key, entries in QUOTA.items():
        if rec.get(key) is not None:
            for name, tmpl in entries.items():
                hard[name] = tmpl.format(rec[key])
    return hard


def describe(rec):
    """Short human text, e.g. for the Rancher project description."""
    bits = ["%s %s" % (f.column.lower(), rec[f.key]) for f in FIELDS
            if f.key in QUOTA and rec.get(f.key) is not None]
    return ", ".join(bits) or "no quota"


def users(records):
    return sorted({u for r in records for u in r["users"]})


# --------------------------------------------------------------------------- CLI
def main(argv):
    if len(argv) >= 2 and argv[1] == "format":
        print(line_format())
        for f in FIELDS:
            print("  %-12s %-9s %s" % (f.column, "required" if f.required else "optional", f.help))
        return 0
    if len(argv) != 3 or argv[1] not in ("check", "json"):
        print("usage: hpc_flatfile.py check|json <projects.txt> | format", file=sys.stderr)
        return 2
    try:
        recs = parse(argv[2])
    except (ValueError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    if argv[1] == "json":
        json.dump({"projects": recs, "users": users(recs)}, sys.stdout, indent=1, sort_keys=True)
        print()
        return 0
    keys = [f.key for f in FIELDS if f.key != "users"]
    rows = [[f.column for f in FIELDS if f.key != "users"] + ["USERS"]]
    rows += [[str(r.get(k)) for k in keys] + [",".join(r["users"])] for r in recs]
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for r in rows:
        print("  ".join(c.ljust(w[i]) for i, c in enumerate(r)).rstrip())
    print("ok: %d projects, %d users" % (len(recs), len(users(recs))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
