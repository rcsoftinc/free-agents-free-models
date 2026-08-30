#!/usr/bin/env bash
# Proves the cheap handoff path and the prompt-bloat warning.
#
# The handoff exists because a worker is isolated by design and therefore cannot
# learn what the task it depends on DECIDED - only what file that task left. The
# risk of adding it is the opposite failure: leaking context into tasks that did
# not ask for it, which is what makes weak models worse. Both directions are
# asserted here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "handoffs and prompt bloat"
fixture_registry 3 || exit 1
sandbox_on
clear_modes

mkproj() { local p; p="$(mktemp -d)"; mkdir -p "$p/.orch"; printf '%s' "$1" > "$p/.orch/tasks.json"; printf '%s' "$p"; }
run_orch() { ( cd "$1" && TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" run .orch/tasks.json ) >"$1/out.log" 2>&1; printf '%s' "$?"; }

# --- 1. a chain: the dependency is asked, the dependent receives -------------
P="$(mkproj '{"tasks":[
 {"id":"config","deps":[],"files":[],"prompt":"write config"},
 {"id":"auth","deps":["config"],"files":[],"prompt":"write auth"},
 {"id":"lonely","deps":[],"files":[],"prompt":"unrelated work"}]}')"
rc="$(run_orch "$P")"
assert_eq "the chain completes" "$rc" "0"
assert_true "a handoff was captured from the dependency" '[[ -s "$P/.orch/handoffs/config.txt" ]]'
assert_contains "the dependent received that context" "$(cat "$P/.orch/results/auth.out")" "SAW_CONTEXT"

# The failure mode that would make things WORSE: context leaking everywhere.
assert_not_contains "the dependency itself got no context" \
  "$(cat "$P/.orch/results/config.out")" "SAW_CONTEXT"
assert_not_contains "an unrelated task got no context" \
  "$(cat "$P/.orch/results/lonely.out")" "SAW_CONTEXT"

# A task nothing depends on is never asked for a handoff - the ask is not free,
# it is a line in every worker's prompt.
assert_true "no handoff is requested from a task with no dependents" \
  '[[ ! -e "$P/.orch/handoffs/lonely.txt" ]]'
assert_contains "the capture is journaled" \
  "$(cat "$P/.orch/journal.ndjson")" '"event":"handoff"'

# --- 2. a worker that writes no handoff must not break anything -------------
# Degrading to the old behaviour is the whole point of the cheap version.
P="$(mkproj '{"tasks":[
 {"id":"silent","deps":[],"files":[],"prompt":"say nothing useful"},
 {"id":"after","deps":["silent"],"files":[],"prompt":"carry on"}]}')"
mode_for opencode ratelimit   # make lane 0 useless so a plain success path is used
clear_modes
rc="$(run_orch "$P")"
assert_eq "a chain still completes when no handoff is emitted" "$rc" "0"

# --- 3. a long handoff is truncated -----------------------------------------
LONG="$(head -c 900 /dev/zero | tr '\0' 'z')"
P="$(mkproj '{"tasks":[
 {"id":"verbose","deps":[],"files":[],"prompt":"write it"},
 {"id":"next","deps":["verbose"],"files":[],"prompt":"continue"}]}')"
mkdir -p "$P/.orch/handoffs"
printf '%s' "$LONG" > "$P/.orch/handoffs/verbose.txt"
HANDOFF_MAX_CHARS=100 run_orch "$P" >/dev/null
sz=$(wc -c < "$P/.orch/handoffs/verbose.txt")
assert_true "a handoff is bounded, not unbounded (got ${sz} bytes)" '[[ ${sz:-0} -le 900 ]]'

# --- 4. prompt bloat is reported --------------------------------------------
W="$(mktemp -d)"
meta="$(timeout 60 "$REPO/bin/run.sh" -w "$W" "a short task" 2>&1 >/dev/null | sed -n 's/^---RUN-META--- //p' | tail -1)"
est="$(printf '%s' "$meta" | jq -r '.est_prompt_tokens // 0')"
assert_true "every run reports an estimated prompt size (got ${est})" '[[ ${est:-0} -gt 0 ]]'
assert_true "a small prompt estimates small" '[[ ${est:-0} -lt 200 ]]'

BIG="$(head -c 60000 /dev/zero | tr '\0' 'x')"
out="$(timeout 60 "$REPO/bin/run.sh" -w "$W" "$BIG" 2>&1 >/dev/null)"
assert_contains "an oversized prompt is called out" "$out" "prompt is large"
assert_contains "and the likely cause is named" "$out" "leaked into it"

small="$(timeout 60 "$REPO/bin/run.sh" -w "$W" "tiny" 2>&1 >/dev/null)"
assert_not_contains "a small prompt is not called out" "$small" "prompt is large"

# The threshold is tunable, and lowering it must actually change behaviour.
out="$(BLOAT_WARN_TOKENS=1 timeout 60 "$REPO/bin/run.sh" -w "$W" "tiny" 2>&1 >/dev/null)"
assert_contains "the warning threshold is configurable" "$out" "prompt is large"

end_suite
final_report
