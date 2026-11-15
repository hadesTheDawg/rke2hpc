# Runs on the admin node. Submits work as a project member (impersonation, so
# admission sees an ordinary user) and checks what hpc-acct recorded about it.
NS_A=${GROUP_A,,}
ACCT=/usr/local/sbin/hpc-acct
run=$(date +%H%M%S)                        # names are unique per run: history keeps every earlier one
OK=acct-ok-$run; TO=acct-limit-$run; SVC=acct-svc-$run
ku() { $KUBECTL --as="$USER_A" --as-group="${OIDC_GROUP_PREFIX}$GROUP_A" --as-group=system:authenticated -n "$NS_A" "$@"; }
job() { # <name> <command> [time limit the user chose]
  cat <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $1}
spec:
  ${3:+activeDeadlineSeconds: $3}
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 1
      containers:
      - {name: main, image: "busybox:1.37", command: [sh, -c, "$2"]}
YAML
}
submit() { job "$@" | ku apply -f -; }
field() { $ACCT jobs --project "$GROUP_A" --json -n 500 | jq -r --arg n "$1" "[.[] | select(.name==\$n)] | last | .$2"; }
until_state() { local i; for i in $(seq 40); do [ "$(field "$1" state)" = "$2" ] && return 0; sleep 3; done; return 1; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN {exit !(v>=lo && v<=hi)}'; }

t  "recorder service is running"                           systemctl is-active -q hpc-acct
t  "nothing is enforced: a job without a time limit is accepted" submit "$OK" "sleep 8"
t  "a long-running Deployment is accepted"                 ku create deployment "$SVC" --image=busybox:1.37 --replicas=2 -- sleep 3600
t  "a job with a user-chosen time limit is accepted"       submit "$TO" "sleep 300" 12
t  "finished job is recorded as COMPLETED"                 until_state "$OK" COMPLETED
t  "job that hit its own limit is recorded as TIMEOUT"     until_state "$TO" TIMEOUT
t  "the Deployment is recorded as RUNNING"                 until_state "$SVC" RUNNING
id_ok=$(field "$OK" jobid); id_svc=$(field "$SVC" jobid)
t  "each has its own job id ($id_ok, $id_svc)"             test "$id_ok" -gt 0 -a "$id_svc" -gt 0 -a "$id_ok" != "$id_svc"
t  "the job id is visible on the Kubernetes object"        test "$(ku get deploy "$SVC" -o jsonpath='{.metadata.labels.hpc\.io/jobid}')" = "$id_svc"
t  "the submitting user is recorded ($(field "$SVC" user))" test "$(field "$OK" user)" = "$USER_A" -a "$(field "$SVC" user)" = "$USER_A"
el=$(field "$OK" elapsed_seconds); cs=$(field "$OK" cpu_seconds)
t  "elapsed time matches the work done (${el%.*}s for an 8s job)" between "$el" 7 20
t  "CPU-hours = elapsed x cores requested (${cs%.*} CPU-seconds)" between "$cs" "$(awk -v e="$el" 'BEGIN {print e*0.45}')" "$(awk -v e="$el" 'BEGIN {print e*0.55}')"
sleep 12
e1=$(field "$SVC" elapsed_seconds); c1=$(field "$SVC" cpu_seconds)
t  "the Deployment's runtime keeps counting, across both replicas (${e1%.*}s, ${c1%.*} CPU-seconds)" between "$c1" "$(awk -v e="$e1" 'BEGIN {print e*0.8}')" "$(awk -v e="$e1" 'BEGIN {print e*1.1}')"
tm "admin tool shows the job with its pods"                "$SVC" $ACCT job "$id_svc"
tm "admin tool reports per-project usage"                  "$GROUP_A" $ACCT status
tm "project members can read their usage summary"          "used-cpu-hours" ku get configmap project-usage -o yaml
ku delete deployment "$SVC" --wait=false >/dev/null 2>&1
t  "after deletion the Deployment is recorded as STOPPED with an end time" until_state "$SVC" STOPPED
t  "its end time is set"                                   test "$(field "$SVC" end)" != "-"

# the allocation is a number to report against, and can be changed
before=$($ACCT status --json | jq -r --arg p "$GROUP_A" '.projects[] | select(.project==$p) | .budget / 3600')
$ACCT budget "$GROUP_A" --add 5 --reason "hpcctl verify: add" >/dev/null
after=$($ACCT status --json | jq -r --arg p "$GROUP_A" '.projects[] | select(.project==$p) | .budget / 3600')
t  "the allocation can be changed ($before -> $after CPU-hours)" between "$after" "$(awk -v b="$before" 'BEGIN {print b+4.99}')" "$(awk -v b="$before" 'BEGIN {print b+5.01}')"
$ACCT budget "$GROUP_A" --set 0.000001 --reason "hpcctl verify: below usage" >/dev/null
t  "a project over its allocation can still submit (reporting only)" submit "acct-over-$run" true
$ACCT budget "$GROUP_A" --set "$before" --reason "hpcctl verify: restore" >/dev/null
tm "allocation changes are kept in the ledger"             "hpcctl verify: add" $ACCT ledger "$GROUP_A"
ku delete job "$OK" "$TO" "acct-over-$run" --ignore-not-found --wait=false >/dev/null 2>&1
summary
