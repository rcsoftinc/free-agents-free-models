#!/usr/bin/env bash
# Proves the bucket lease holds under a real fan-out: many more tasks than lanes,
# all racing. The lease is the one invariant that cannot be allowed to slip -
# two tasks on one credential do not go faster, they race that credential into
# its own rate limit, which is the failure this whole design exists to avoid.
#
# Detection is done inside the stub agent: it takes an atomic mkdir lock per lane
# and records a violation if a second invocation arrives while the first is still
# running. Only the stub knows the true start and end of an invocation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "concurrency fan-out"
fixture_registry 3 || exit 1
sandbox_on
clear_modes

NTASKS="${NTASKS:-12}"
CONC="$(mktemp -d)"; PROJ="$(mktemp -d)"
trap 'rm -rf "$CONC" "$PROJ"' EXIT
export STUB_CONC_DIR="$CONC" STUB_HOLD=0.4

mkdir -p "$PROJ/.orch"
python3 - "$NTASKS" > "$PROJ/.orch/tasks.json" <<'PY'
import json,sys
n=int(sys.argv[1])
print(json.dumps({"tasks":[{"id":"t%02d"%i,"prompt":"work %d"%i,
                            "deps":[],"files":[],"category":"coding"} for i in range(n)]}))
PY

( cd "$PROJ" && timeout 300 "$REPO/bin/orch.sh" run .orch/tasks.json ) >"$PROJ/out.log" 2>&1
rc=$?

# --- everything completes ----------------------------------------------------
assert_eq "the fan-out completes" "$rc" "0"
done_n="$(jq -r 'select(.event=="done")|.task' "$PROJ/.orch/journal.ndjson" 2>/dev/null | sort -u | wc -l)"
assert_eq "every task finishes" "$done_n" "$NTASKS"

# --- THE INVARIANT: never two tasks on one credential at once ---------------
violations="$(cat "$CONC/violations" 2>/dev/null | wc -l)"
assert_eq "no two tasks ever shared a lane (stub-detected overlaps)" "$violations" "0"

# --- and it really was concurrent, not accidentally serial -------------------
# A serial run would satisfy the invariant trivially, so prove lanes overlapped.
overlaps="$(python3 - "$CONC/timeline" <<'PY'
import sys
ivals={}
cur={}
for line in open(sys.argv[1]):
    kind,lane,ts=line.split()
    ts=int(ts)
    if kind=="start": cur.setdefault(lane,[]).append(ts)
    else:
        s=cur[lane].pop(0)
        ivals.setdefault(lane,[]).append((s,ts))
flat=[(s,e,l) for l,v in ivals.items() for s,e in v]
n=0
for i in range(len(flat)):
    for j in range(i+1,len(flat)):
        a,b=flat[i],flat[j]
        if a[2]!=b[2] and a[0] < b[1] and b[0] < a[1]: n+=1
print(n)
PY
)"
assert_true "different lanes ran at the same time (${overlaps} overlapping pairs)" \
            '[[ ${overlaps:-0} -ge 1 ]]'

# --- work was spread, not funnelled into one lane ---------------------------
lanes_used="$(awk '$1=="start"{print $2}' "$CONC/timeline" | sort -u | wc -l)"
assert_eq "all three lanes were used" "$lanes_used" "3"

# --- and no lane was left idle while tasks queued ---------------------------
per_lane="$(awk '$1=="start"{c[$2]++} END{for(l in c) print c[l]}' "$CONC/timeline" | sort -n)"
min_lane="$(printf '%s\n' "$per_lane" | head -1)"
assert_true "no lane sat idle (min ${min_lane} tasks per lane)" '[[ ${min_lane:-0} -ge 1 ]]'

# --- churn under pressure ----------------------------------------------------
no_lane="$(jq -r 'select(.event=="no_lane")|.task' "$PROJ/.orch/journal.ndjson" 2>/dev/null | wc -l)"
assert_true "no fan-out churn at the default width (got ${no_lane})" '[[ ${no_lane:-0} -le 2 ]]'

# The assertion above passes trivially while MAX_PARALLEL equals the lane count -
# the width cap alone prevents over-dispatch, so it does not exercise the
# free-lane check at all. Force the width ABOVE the number of lanes: now only the
# free-lane check stands between the scheduler and a task launched into a full
# house, which is exactly the churn that produced 9 requeues for one task.
PROJ2="$(mktemp -d)"; mkdir -p "$PROJ2/.orch"
cp "$PROJ/.orch/tasks.json" "$PROJ2/.orch/tasks.json"
rm -rf "$CONC"; mkdir -p "$CONC"
( cd "$PROJ2" && timeout 300 "$REPO/bin/orch.sh" run .orch/tasks.json --max-parallel 8 ) \
  >"$PROJ2/out.log" 2>&1
rc2=$?
assert_eq "an over-wide fan-out still completes" "$rc2" "0"
churn="$(jq -r 'select(.event=="no_lane")|.task' "$PROJ2/.orch/journal.ndjson" 2>/dev/null | wc -l)"
assert_true "width above lane count does not cause churn (got ${churn})" '[[ ${churn:-0} -le 2 ]]'
v2="$(cat "$CONC/violations" 2>/dev/null | wc -l)"
assert_eq "the lease still holds when width exceeds lanes" "$v2" "0"
rm -rf "$PROJ2"

end_suite
final_report
