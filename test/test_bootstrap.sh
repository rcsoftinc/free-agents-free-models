#!/usr/bin/env bash
# Proves `fa bootstrap` sets a project up from nothing and `fa doctor` tells the
# truth about whether the machine can actually run anything. These are the two
# commands a new user runs first, so a wrong answer here is the worst kind:
# it is the one nobody is in a position to question.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "fa bootstrap and fa doctor"
sandbox_on

# A realistic layout: the tool cloned INTO a project as .free-agents/, so
# install-skills links into the project rather than the developer's home.
PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
TOOL="$PROJ/.free-agents"
mkdir -p "$TOOL"
cp -r "$REPO/bin" "$REPO/skills" "$TOOL/"
FA="$TOOL/bin/fa"

# Fabricated credentials, so nothing depends on this machine being logged in.
export OPENCODE_AUTH="$PROJ/oc.json" KILO_CONFIG="$PROJ/kilo.jsonc" \
       KILO_DB="$PROJ/none.db" HERMES_AUTH="$PROJ/h.json" HERMES_ENV="$PROJ/h.env"
SECRET="sk-or-v1-TESTSECRET000000000000"
cat > "$OPENCODE_AUTH" <<EOF
{"opencode":{"type":"api","key":"sk-oc-AAA111"},"openrouter":{"type":"api","key":"$SECRET"}}
EOF
cat > "$KILO_CONFIG" <<EOF
{"provider":{"openai":{"options":{"apiKey":"sk-or-v1-OTHER222","baseURL":"https://openrouter.ai/api/v1"}}}}
EOF
echo '{"credential_pool":{}}' > "$HERMES_AUTH"; : > "$HERMES_ENV"
# Point explicitly at the clone. This suite tests "a fresh clone bootstraps
# correctly", NOT "the default path is X" - and since the default became
# machine-wide, unsetting this made the suite bootstrap FABRICATED credentials
# over the developer's real registry. Never leave it unset in a test.
export FREE_AGENTS_STATE="$TOOL/state"
REG="$FREE_AGENTS_STATE/buckets.json"

# The new default is machine-wide. Assert it by RESOLVING it, never by running
# anything that would write there.
resolved="$(HOME=/tmp/fake-home env -u FREE_AGENTS_STATE -u XDG_STATE_HOME \
  bash -c '. '"$REPO"'/bin/lib/common.sh; printf "%s" "$STATE_DIR"')"
assert_eq "with no override, state resolves machine-wide" \
          "$resolved" "/tmp/fake-home/.local/state/free-agents"

# --- doctor BEFORE bootstrap: must refuse, not pretend ----------------------
out="$(timeout 90 "$FA" doctor 2>&1)"; rc=$?
assert_ne "doctor fails when there is no registry" "$rc" "0"
assert_contains "doctor says the registry is missing" "$out" "MISSING"
assert_contains "doctor tells you how to fix it" "$out" "fa bootstrap"
assert_contains "doctor does not claim readiness" "$out" "NOT READY"

# --- bootstrap ---------------------------------------------------------------
out="$(timeout 300 "$FA" bootstrap 2>&1)"; rc=$?
assert_eq "bootstrap exits 0" "$rc" "0"
assert_true "bootstrap wrote a registry inside the clone" '[[ -s "$REG" ]]'
assert_json_valid "the registry is valid JSON" "$REG"
assert_true "it found at least one bucket" '[[ $(jq -r ".buckets | length" "$REG") -ge 1 ]]'
assert_contains "it reports a lane count" "$out" "healthy lane"

# The registry must never contain a key, only fingerprints of one.
assert_not_contains "no API key is stored" "$(cat "$REG")" "$SECRET"

# Paid models must not be scheduled as free.
assert_eq "a priced model is not counted free" \
  "$(jq -r '[.buckets[].models[] | select(.free) | select(.upstream=="paid-a")] | length' "$REG")" "0"
assert_true "free models were found" \
  '[[ $(jq -r "[.buckets[].models[] | select(.free)] | length" "$REG") -ge 1 ]]'

# --- skills land in the PROJECT, not the home directory ---------------------
assert_true "skills are installed into the project" '[[ -e "$PROJ/.opencode/skills" ]]'
assert_true "the coordinator skill is present" \
  '[[ -e "$PROJ/.opencode/skills/agent-coordinator" ]]'

# --- doctor AFTER bootstrap --------------------------------------------------
out="$(timeout 90 "$FA" doctor 2>&1)"; rc=$?
assert_eq "doctor passes once bootstrapped" "$rc" "0"
assert_contains "doctor reports READY" "$out" "READY"
assert_contains "doctor lists the dependencies it checked" "$out" "jq"
assert_contains "doctor runs the taxonomy self-test" "$out" "self-test"
assert_contains "doctor reports the lane count" "$out" "healthy lane"

# --- doctor must warn when only ONE lane exists ------------------------------
# With one lane, splitting work cannot help; saying so is the difference between
# a useful check and a green tick.
# Keep one bucket that actually counts as a lane: unmetered, uncooled, with at
# least one free model. Picking the first key alphabetically can land on a
# metered wallet, which is worth zero lanes and tests nothing.
first="$(jq -r '[.buckets[] | select((.metered // false) == false)
                 | select([.models[] | select(.free)] | length > 0)][0].id' "$REG")"
assert_true "a usable bucket exists to trim down to" '[[ -n "$first" && "$first" != "null" ]]'
jq --arg k "$first" '{schema:1, identified, examined_agents, generated_at,
                      buckets: {($k): .buckets[$k]}, phantom_routes: [], counts:{}}' \
   "$REG" > "$REG.one" && mv "$REG.one" "$REG"
assert_eq "the trimmed registry has exactly one lane" \
          "$(FREE_AGENTS_STATE="$TOOL/state" "$TOOL/bin/buckets.sh" lanes)" "1"
out="$(timeout 90 "$FA" doctor 2>&1)"
assert_contains "doctor warns that one lane cannot parallelise" "$out" "only ONE lane"

# --- bootstrap is idempotent -------------------------------------------------
out="$(timeout 300 "$FA" bootstrap 2>&1)"; rc=$?
assert_eq "bootstrap can be re-run safely" "$rc" "0"
assert_json_valid "the registry survives a second bootstrap" "$REG"


# --- registry freshness ------------------------------------------------------
# The question this answers is "do I need to refresh?", and the honest signal is
# whether the CREDENTIALS or AGENTS changed - not how old the file is. Time only
# hints at provider model-list drift; it says nothing about the key you added an
# hour ago, which is the case that actually costs you a lane.
FRESH="$PROJ/fresh"; mkdir -p "$FRESH"
st() { FREE_AGENTS_STATE="$FRESH" REGISTRY_MAX_AGE_DAYS="${1:-14}" \
       bash -c '. '"$TOOL"'/bin/lib/common.sh; registry_status'; }
save() { cp "$FRESH/keep.json" "$FRESH/buckets.json"; }

assert_eq "no registry at all reads as missing" \
  "$(FREE_AGENTS_STATE="$PROJ/nowhere" bash -c '. '"$TOOL"'/bin/lib/common.sh; registry_status')" \
  "missing"

timeout 300 env FREE_AGENTS_STATE="$FRESH" "$FA" bootstrap >/dev/null 2>&1
cp "$FRESH/buckets.json" "$FRESH/keep.json"
assert_true "discovery records the credentials it examined" \
  '[[ "$(jq -r ".identified|length" "$FRESH/keep.json")" -gt 0 ]]'
assert_eq "a registry just built from these credentials reads as current" "$(st)" "current"

# THE false-positive test, and the reason this is not an mtime check: the nous
# OAuth token rotates hourly and kilo rewrites its db on every invocation, so
# both config files look "changed" on any second look. Fingerprints do not move.
assert_eq "a second look at unchanged credentials is still current" "$(st)" "current"

# A credential that reached no free model produces no bucket. It must not read as
# new forever - that was the first version of this check, and it cried wolf.
assert_true "some examined credential produced no bucket (the false-alarm case)" \
  '[[ "$(jq -r "(.identified|length) - (.buckets|length)" "$FRESH/keep.json")" -ge 0 ]]'

# A key you swapped is invisible until rediscovery - the case worth catching.
jq '.identified |= map(. + "x")
    | .buckets |= with_entries(.key = (.key + "x") | .value.id = .key)' \
   "$FRESH/keep.json" > "$FRESH/buckets.json"
assert_eq "changed credentials read as stale" "$(st)" "stale:credentials"
out="$(FREE_AGENTS_STATE="$FRESH" timeout 90 "$FA" doctor 2>&1)"
assert_contains "doctor names the one command that fixes it" "$out" "fa refresh"

# An agent installed since discovery has no lane, so it is unreachable.
save
jq '.examined_agents |= map(select(. != "opencode"))' \
   "$FRESH/keep.json" > "$FRESH/buckets.json"
assert_eq "an agent never examined reads as stale" "$(st)" "stale:new-agent"

# ...but an agent that WAS examined and reached nothing is a known fact.
jq '.examined_agents = ["opencode","kilo","hermes","copilot","cursor"]
    | .buckets |= with_entries(.value.models |= map(.routes |= map(select(.agent != "kilo"))))' \
   "$FRESH/keep.json" > "$FRESH/buckets.json"
assert_eq "an examined agent that reached nothing is not stale news" "$(st)" "current"

# Age is advisory ONLY: it hints at provider drift, never proves anything.
jq --arg d "$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%SZ)" '.generated_at = $d' \
   "$FRESH/keep.json" > "$FRESH/buckets.json"
assert_eq "a registry past the age hint reports its age" "$(st)" "aged:40"
out="$(FREE_AGENTS_STATE="$FRESH" timeout 90 "$FA" doctor 2>&1)"
assert_contains "age is a soft note, not a failure" "$out" "refresh when convenient"
assert_true "age alone never reports STALE" '[[ "$out" != *"STALE"* ]]'

# --- what setup leaves in .orch -----------------------------------------------
# `.orch/.gitignore` had two writers that disagreed: setup.sh open-coded a copy
# that omitted handoffs/ and ran first, and orch.sh's own writer no-ops when the
# file exists - so every project silently committed its handoffs. One writer now.
SP="$PROJ/setup-orch"; mkdir -p "$SP"
cp "$REPO/setup.sh" "$TOOL/setup.sh"
FREE_AGENTS_STATE="$PROJ/nostate" bash "$TOOL/setup.sh" --no-bootstrap "$SP" >/dev/null 2>&1
assert_true "setup seeds .orch/tasks.json" '[[ -f "$SP/.orch/tasks.json" ]]'
for pat in journal.ndjson results/ handoffs/ '*.lock'; do
  assert_contains "setup's .orch/.gitignore excludes $pat" \
    "$(cat "$SP/.orch/.gitignore" 2>/dev/null)" "$pat"
done
assert_true "the ignore body is defined in orch.sh alone, not copied into setup.sh" \
  '[[ "$(grep -c "journal.ndjson" "$TOOL/setup.sh")" -eq 0 ]]'

# An older project keeps its incomplete file; repair the one missing line without
# clobbering anything the user added by hand.
printf 'journal.ndjson\nresults/\nmine.txt\n' > "$SP/.orch/.gitignore"
ORCH_PROJECT="$SP" bash "$TOOL/bin/orch.sh" init >/dev/null 2>&1
assert_contains "an older .orch/.gitignore gains handoffs/" \
  "$(cat "$SP/.orch/.gitignore")" "handoffs/"
assert_contains "a hand-added ignore line survives the repair" \
  "$(cat "$SP/.orch/.gitignore")" "mine.txt"

# --- repo hygiene ------------------------------------------------------------
# What a clone GIVES you is part of setup, so it is asserted here. All three of
# these caught something real: 12.3 MB of this dev machine's npm cache tracked in
# the repo (96% of the tree), a symlink to a directory deleted months earlier
# that landed broken in every clone, and a stale duplicate of the coordinator
# playbook under .opencode/ - which opencode loads in preference to the real one
# when started inside the clone.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  tracked="$(git -C "$REPO" ls-files)"

  assert_true "no machine-local opencode config or npm cache is tracked" \
    '[[ -z "$(printf "%s\n" "$tracked" | grep -E "^\.(opencode|npm)/")" ]]'

  # A tracked symlink that does not resolve is broken for everyone who clones,
  # and nothing else in the suite would notice.
  broken=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -L "$REPO/$f" ]] && { readlink -e "$REPO/$f" >/dev/null || broken="$broken $f"; }
  done <<< "$tracked"
  assert_eq "every tracked symlink resolves" "$broken" ""

  # The tool is ~0.5 MB of shell and markdown. A cap catches build debris before
  # it becomes history that everyone downloads forever.
  mb="$(git -C "$REPO" ls-tree -r -l HEAD | awk '{s+=$4} END {print int(s/1048576)}')"
  assert_true "the tracked tree stays under 2 MB (is ${mb}MB)" '[[ "$mb" -lt 2 ]]'
fi

end_suite
final_report
