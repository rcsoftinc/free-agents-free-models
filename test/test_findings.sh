#!/usr/bin/env bash
# Proves the feedback path from a real project back to this tool.
#
# A finding is not an error. Errors are handled - a rate limit cools a wallet, a
# hang parks a model. A finding is the tool admitting it did not understand
# something, or that it did the same unhelpful thing twice, or that a human saw
# something no heuristic could. That last channel matters most: every
# classification bug in this project so far was found from real error text, not
# invented test data.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "findings: the feedback path"
fixture_registry 3 || exit 1
sandbox_on
clear_modes

FA="$REPO/bin/fa"
fresh() { FREE_AGENTS_STATE="$(mktemp -d)"; export FREE_AGENTS_STATE; }
rec() { bash -c '. '"$REPO"'/bin/lib/common.sh; . '"$REPO"'/bin/lib/findings.sh; record_finding "$@"' _ "$@"; }

# --- the store ---------------------------------------------------------------
fresh
rec unclassified "provider said something new" "HTTP 418: I am a teapot" model=m1 provider=p1
assert_eq "a finding is stored" "$("$FA" findings --count)" "1"
assert_contains "and is shown" "$("$FA" findings)" "teapot"

# Twenty occurrences of one failure are one row with a count, or the report is
# unreadable exactly when things are going worst.
for i in $(seq 1 20); do rec unclassified "same thing" "request 40$i failed after 3s" ; done
assert_eq "repeats collapse into one row" "$("$FA" findings --count)" "2"
assert_contains "and the count is shown" "$("$FA" findings)" "20x"

# --- redaction: a finding is meant to be pasteable into a public issue -------
fresh
rec unclassified "leak check" "auth failed for sk-or-v1-deadbeefcafe and Bearer abc.def.ghi from a@b.com"
out="$("$FA" findings)"
assert_not_contains "an API key never reaches the store" "$out" "deadbeefcafe"
assert_not_contains "nor a bearer token"                 "$out" "abc.def.ghi"
assert_not_contains "nor an email address"               "$out" "a@b.com"
assert_contains     "but enough remains to be useful"    "$out" "REDACTED"

# --- ack ---------------------------------------------------------------------
assert_eq "everything is new before acking" "$("$FA" findings --count new)" "1"
"$FA" findings --ack >/dev/null
assert_eq "acking clears the new list" "$("$FA" findings --count new)" "0"
assert_eq "but does not delete the record" "$("$FA" findings --count all)" "1"

# --- the manual channel ------------------------------------------------------
# The tool cannot detect "the spec was ambiguous" or "the plan split this wrong".
# Without somewhere to put those they are lost when the terminal closes.
fresh
"$FA" findings --note >/dev/null 2>&1
assert_eq "a note with no text is refused" "$?" "3"

"$FA" findings --note "the plan split auth across two tasks that both edit login.py" task=t3 >/dev/null
assert_contains "a note is recorded" "$("$FA" findings)" "both edit login.py"
assert_eq "and carries its structured field" \
  "$(jq -r 'select(.kind=="note").task' "$FREE_AGENTS_STATE/findings.ndjson")" "t3"
assert_eq "and is marked as hand-written" \
  "$(jq -r 'select(.kind=="note").source' "$FREE_AGENTS_STATE/findings.ndjson")" "manual"

"$FA" findings --note "spec assumed a key I do not have" "stripe, still waiting" task=t7 >/dev/null
assert_contains "free text becomes the evidence" "$("$FA" findings)" "still waiting"

# A hand-written note goes through the same redaction as everything else.
"$FA" findings --note "worker echoed a key" "it printed sk-or-v1-secretvalue99" >/dev/null
assert_not_contains "a note cannot leak a key either" "$("$FA" findings)" "secretvalue99"

# --- the issue report names the next step ------------------------------------
fresh
rec all_lanes_failed "every available lane failed on the same task" "build the whole payment subsystem" attempts=4 task=t5
rec missing_handoff "a task with dependents ended without the handoff line it was asked for" "task=t2 dependents=t4" task=t2
"$FA" findings --note "the result compiled but missed the point" >/dev/null
iss="$("$FA" findings --issue)"
assert_contains "all_lanes_failed blames the task, not the wallets" "$iss" "the task is"
assert_contains "missing_handoff explains the silent damage"        "$iss" "quietly worse"
assert_contains "a note says no heuristic could have caught it"     "$iss" "could not have detected"
assert_contains "and each is a pasteable issue"                     "$iss" '## '

# --- missing_handoff fires from a real run -----------------------------------
# The stub writes no handoff line, so a task with dependents must produce one
# finding - and a task with none must produce nothing, because the handoff was
# never asked for in the first place.
fresh
P="$(mktemp -d)"; mkdir -p "$P/.orch"
cat > "$P/.orch/tasks.json" <<'EOF'
{"tasks":[{"id":"lonely","deps":[],"files":[],"prompt":"unrelated work"}]}
EOF
( cd "$P" && TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" run .orch/tasks.json ) >/dev/null 2>&1
assert_eq "a task with no dependents never reports a missing handoff" \
  "$("$FA" findings --count)" "0"

end_suite
final_report
