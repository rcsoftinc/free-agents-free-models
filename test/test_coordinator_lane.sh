#!/usr/bin/env bash
# Proves workers leave the coordinator's own wallet alone. The coordinator - the
# agent the director is talking to - spends requests on its wallet while it
# talks; a worker on the same wallet races it into one rate limit, and the
# director's conversation starts failing exactly while a build runs. Since
# --detach the coordinator keeps talking during builds, so this is the normal
# case, not a corner.
#
# fa finds the coordinator by walking up its own process tree to the first
# agent CLI (common.sh). Every case below puts a fake agent NEAREST in that
# tree - or a fake claude above the shape under test - so the answer never
# depends on which agent the developer happens to run this suite from.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "workers leave the coordinator's own wallet alone"
fixture_registry 3 || exit 1     # b0 -> opencode, b1 -> kilo, b2 -> hermes
sandbox_on
unset FA_COORDINATOR             # the harness switches detection off; this suite is about it

FA="$REPO/bin/fa"
COMMON="$REPO/bin/lib/common.sh"
FAKE="$(mktemp -d)"; PROJ="$(mktemp -d)"
trap 'rm -rf "$FAKE" "$PROJ" "$FIXTURE_DIR"' EXIT
# Fake agent CLIs that only run what they are given - shaped like the real ones:
# an executable named after the agent (opencode, kilo, agy), a script run by an
# interpreter (copilot and pi are node scripts), a real process living in a
# directory named after the agent (cursor-agent), and an agent fa cannot drive.
mkdir -p "$FAKE/cursor-agent/v1" "$FAKE/proj/pi"
for n in opencode kilo claude; do printf '#!/usr/bin/env bash\n"$@"\n' > "$FAKE/$n"; chmod +x "$FAKE/$n"; done
printf '"$@"\n' > "$FAKE/pi"
printf '"$@"\n' > "$FAKE/cursor-agent/v1/index.js"
printf '"$@"\n' > "$FAKE/proj/pi/tool.sh"
who() { bash -c '. "$1"; coordinator_agent' _ "$COMMON"; }
export -f who; export COMMON

# --- 1. finding the coordinator ----------------------------------------------
assert_eq "an agent's own executable is found"          "$("$FAKE/opencode" bash -c who)" "opencode"
assert_eq "so is a script an interpreter runs (node)"    "$(bash "$FAKE/pi" bash -c who)" "pi"
assert_eq "so is a process inside the agent's own dir"   "$(bash "$FAKE/cursor-agent/v1/index.js" bash -c who)" "cursor"
assert_eq "the NEAREST agent is the coordinator"         "$("$FAKE/opencode" "$FAKE/kilo" bash -c who)" "kilo"
assert_eq "an agent fa cannot drive is on none of its lanes: nothing to hold" \
  "$("$FAKE/opencode" "$FAKE/claude" bash -c who)" ""
assert_eq "a two-letter name never matches a mere directory" \
  "$("$FAKE/claude" bash "$FAKE/proj/pi/tool.sh" bash -c who)" ""
assert_eq "FA_COORDINATOR=none switches it off" "$(FA_COORDINATOR=none "$FAKE/opencode" bash -c who)" ""
assert_eq "FA_COORDINATOR names it outright"     "$(FA_COORDINATOR=kilo "$FAKE/claude" bash -c who)" "kilo"

# --- 2. which wallets are held back --------------------------------------------
held() { bash -c '. "$1"; coordinator_buckets | tr "\n" " "' _ "$COMMON"; }
export -f held
assert_eq "under opencode, its wallet is held back" "$("$FAKE/opencode" bash -c held)" "b0:fp0 "
assert_eq "under kilo, kilo's is"                   "$("$FAKE/kilo" bash -c held)" "b1:fp1 "
assert_eq "under an agent with no lane, nothing is" "$("$FAKE/claude" bash -c held)" ""
ONE="$(mktemp -d)"
jq '.buckets |= with_entries(select(.key == "b0:fp0"))' "$FIXTURE_DIR/buckets.json" > "$ONE/buckets.json"
assert_eq "never every lane: when the coordinator's is the only one, it is shared" \
  "$(FREE_AGENTS_STATE="$ONE" "$FAKE/opencode" bash -c held)" ""

# --- 3. the candidate chain ----------------------------------------------------
rank() { ( cd "$PROJ" && "$@" "$FA" rank coding </dev/null 2>&1 ); }
out="$(rank "$FAKE/opencode")"
assert_not_contains "under opencode, no candidate uses its wallet" "$out" "^b0:fp0"
assert_contains "the chain says why it is missing" "$out" "held back for the coordinator (opencode) - its own wallet"
assert_contains "the other lanes are untouched" "$out" "^b1:fp1"
out="$(rank env FA_COORDINATOR=none)"
assert_contains "with the reservation off, the wallet is a candidate again" "$out" "^b0:fp0"
out="$( cd "$PROJ" && "$FAKE/opencode" "$REPO/bin/run.sh" --dry-run -b b0:fp0 -c coding </dev/null 2>&1 )"
assert_contains "pinning it with -b is an explicit choice, and wins" "$out" "^b0:fp0"
# Everything else cooling down: sharing beats failing.
COOL="$(mktemp -d)"
jq --argjson t "$(( $(date +%s) + 3600 ))" \
  '.buckets |= with_entries(if .key != "b0:fp0" then .value.health.cooldown_until = $t else . end)' \
  "$FIXTURE_DIR/buckets.json" > "$COOL/buckets.json"
out="$(FREE_AGENTS_STATE="$COOL" rank "$FAKE/opencode")"
assert_contains "when nothing else can take the work, the lane is shared" "$out" "^b0:fp0"
assert_contains "  ...and it says so" "$out" "sharing it"

# --- 4. counting lanes -----------------------------------------------------------
lanes() { ( cd "$PROJ" && "$@" </dev/null 2>/dev/null ); }
assert_eq "the inventory still counts every lane"         "$(lanes "$FAKE/opencode" "$REPO/bin/buckets.sh" lanes)" "3"
assert_eq "--workers counts only what a worker may take"  "$(lanes "$FAKE/opencode" "$REPO/bin/buckets.sh" lanes --workers)" "2"
assert_contains "lanes -v marks the coordinator's wallet" \
  "$(lanes "$FAKE/opencode" "$REPO/bin/buckets.sh" lanes -v)" "b0:fp0.*held for the coordinator"
assert_contains "fa doctor says which wallet is held back and why" \
  "$(lanes "$FAKE/opencode" timeout 90 "$FA" doctor)" "you are talking to opencode: workers leave its wallet alone (b0:fp0)"

# --- 5. the gate, and the orchestrator's width ------------------------------------
TWO="$(mktemp -d)"
jq '.buckets |= with_entries(select(.key == "b0:fp0" or .key == "b1:fp1"))' "$FIXTURE_DIR/buckets.json" > "$TWO/buckets.json"
mkdir -p "$PROJ/.orch"
printf '%s\n' '{"tasks":[{"id":"a","prompt":"a","deps":[],"files":[]},{"id":"b","prompt":"b","deps":[],"files":[]}]}' > "$PROJ/.orch/tasks.json"
out="$( cd "$PROJ" && FREE_AGENTS_STATE="$TWO" "$FAKE/opencode" "$FA" dispatch </dev/null 2>&1 )"
assert_contains "two lanes, one of them the coordinator's: the gate sees one" "$out" "lanes=1"
assert_contains "  ...so two independent tasks are done directly" "$out" "-> DIRECT"
assert_contains "  ...and the gate says why" "$out" "is held back for the coordinator (opencode)"
out="$( cd "$PROJ" && "$FAKE/opencode" "$REPO/bin/orch.sh" run --dry-run </dev/null 2>&1 )"
assert_contains "the orchestrator's width leaves the coordinator's lane out" "$out" "parallel=2"
assert_contains "  ...and logs what it held back" "$out" "held back for the coordinator (opencode)"

# --- 6. a background job keeps knowing who started it ------------------------------
# Detaching reparents the job, so its process tree no longer leads back to the
# coordinator: the coordinator must be read at detach time and handed down.
out="$( cd "$PROJ" && "$FAKE/opencode" "$FA" run --detach --dry-run -c coding "x" </dev/null 2>&1 )"
id="$(grep -o 'job j[0-9]*' <<<"$out" | head -1 | cut -d' ' -f2)"
J="$PROJ/.orch/jobs/$id"
for _ in $(seq 1 100); do [[ -f "$J/rc" ]] && break; sleep 0.2; done
assert_eq "the job records who started it" "$(cat "$J/coordinator" 2>/dev/null)" "opencode"
assert_contains "and its reparented run still holds that wallet back" "$(cat "$J/log" 2>/dev/null)" \
  "held back for the coordinator (opencode)"
assert_contains "fa jobs <id> says so" "$( cd "$PROJ" && "$FA" jobs "$id" 2>&1 )" "started from opencode"
out="$( cd "$PROJ" && FA_COORDINATOR=none "$FA" run --detach --dry-run -c coding "y" </dev/null 2>&1 )"
id2="$(grep -o 'job j[0-9]*' <<<"$out" | head -1 | cut -d' ' -f2)"
assert_eq "a job started outside any agent holds nothing back" "$(cat "$PROJ/.orch/jobs/$id2/coordinator" 2>/dev/null)" "none"
for _ in $(seq 1 100); do [[ -f "$PROJ/.orch/jobs/$id2/rc" ]] && break; sleep 0.2; done

rm -rf "$ONE" "$COOL" "$TWO"
end_suite
final_report
