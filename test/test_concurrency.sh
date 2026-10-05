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
# Zero, not "a few": every run measured used to land on exactly 2 - the first
# burst launched tasks into lanes only on their way to being taken (see below)
# - and an off-by-one in counting those shows up here as a 1.
PROJ2="$(mktemp -d)"; mkdir -p "$PROJ2/.orch"
cp "$PROJ/.orch/tasks.json" "$PROJ2/.orch/tasks.json"
rm -rf "$CONC"; mkdir -p "$CONC"
( cd "$PROJ2" && timeout 300 "$REPO/bin/orch.sh" run .orch/tasks.json --max-parallel 8 ) \
  >"$PROJ2/out.log" 2>&1
rc2=$?
assert_eq "an over-wide fan-out still completes" "$rc2" "0"
churn="$(jq -r 'select(.event=="no_lane")|.task' "$PROJ2/.orch/journal.ndjson" 2>/dev/null | wc -l)"
assert_eq "width above lane count does not cause churn" "${churn:-0}" "0"
v2="$(cat "$CONC/violations" 2>/dev/null | wc -l)"
assert_eq "the lease still holds when width exceeds lanes" "$v2" "0"
rm -rf "$PROJ2"

# The same race, made wide. The free-lane check sees only leases already held,
# and a task just launched has not taken its lane yet - so until it does, that
# lane still looks free and the loop launches another task into it, which
# finds every lane busy and requeues. The check above only ever saw a few
# milliseconds of that window, and it failed whenever the window grew by a few
# more. Here every start takes a second (a copy of bin/ whose run.sh waits
# first): counted only by held leases, the whole width launched at once.
TOOL="$(mktemp -d)"; cp -r "$REPO/bin" "$TOOL/"
mv "$TOOL/bin/run.sh" "$TOOL/bin/run-real.sh"
printf '#!/usr/bin/env bash\necho "${FA_LEASED_SIGNAL:-}" >> "$STUB_CONC_DIR/signals"\nsleep 1\nexec "$(dirname "$0")/run-real.sh" "$@"\n' \
  > "$TOOL/bin/run.sh"
chmod +x "$TOOL/bin/run.sh"
PROJ3="$(mktemp -d)"; mkdir -p "$PROJ3/.orch"
cp "$PROJ/.orch/tasks.json" "$PROJ3/.orch/tasks.json"
rm -rf "$CONC"; mkdir -p "$CONC"
( cd "$PROJ3" && timeout 300 "$TOOL/bin/orch.sh" run .orch/tasks.json --max-parallel 8 ) \
  >"$PROJ3/out.log" 2>&1
rc3=$?
assert_eq "a fan-out whose tasks are slow to start completes" "$rc3" "0"
churn3="$(jq -r 'select(.event=="no_lane")|.task' "$PROJ3/.orch/journal.ndjson" 2>/dev/null | wc -l)"
assert_eq "  ...and never launches a task into a lane another is about to take" "$churn3" "0"
# The handshake behind it, both halves: orch tells each task where to signal,
# and run.sh signals once it holds a lane. Without either, nothing churns -
# every task just counts as still on its way, and lanes sit idle.
assert_eq "orch gives every task a place to say it holds its lane" \
  "$(grep -c "^${PROJ3}/.orch/results/t[0-9]*\.leased$" "$CONC/signals" 2>/dev/null)" "$NTASKS"
sig="$(mktemp -u)"
( cd "$PROJ3" && FA_LEASED_SIGNAL="$sig" "$REPO/bin/run.sh" -w "$PROJ3" "one more" ) >/dev/null 2>&1
assert_true "  ...and run.sh says so once it has one" '[[ -e "$sig" ]]'
rm -f "$sig"
rm -rf "$PROJ3" "$TOOL"

end_suite
final_report
