#!/usr/bin/env bash
# Proves a new plan starts a new run record. Plans name their tasks with short
# slugs ("api", "tests"), and the journal is the only record of what is done:
# a second plan's "api" read as already done and never ran. Now `orch run` on
# a plan other than the journal's puts that journal aside in .orch/history/;
# `resume`, and `run` on the same plan, keep it - done tasks stay done.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "a new plan starts a new run record"
fixture_registry 1 || exit 1
sandbox_on

FAKE="$(mktemp -d)"; P="$(mktemp -d)"; trap 'rm -rf "$FAKE" "$P" "$FIXTURE_DIR"' EXIT
# A fake agent that writes, in its workdir, the word after WRITE: in its prompt
# into out.txt - and counts its calls.
cat > "$FAKE/opencode" <<'EOF'
#!/usr/bin/env bash
dir=""; prev=""
for a in "$@"; do [[ "$prev" == "--dir" ]] && dir="$a"; prev="$a"; done
echo x >> "$FAKE_DIR/calls"
w="$(grep -oE 'WRITE:[a-z0-9]+' <<<"${@: -1}" | head -1)"
printf '%s\n' "${w#WRITE:}" > "${dir:-.}/out.txt"
printf '{"ok":true,"agent":"opencode","summary":"wrote %s"}' "${w#WRITE:}"
EOF
chmod +x "$FAKE/opencode"
export FAKE_DIR="$FAKE" PATH="$FAKE:$PATH"
mkdir -p "$P/.orch"

plan() { # $1 = the word task "api" writes; $2 = extra task JSON (optional)
  jq -n --arg w "$1" --argjson more "${2:-[]}" \
    '{tasks: ([{id:"api", prompt:("WRITE:" + $w), deps:[], files:["out.txt"], category:"general"}] + $more)}' \
    > "$P/.orch/tasks.json"
}
orch() { ( cd "$P" && TASK_RETRIES=0 timeout 120 "$REPO/bin/orch.sh" "$@" </dev/null >/dev/null 2>&1 ); }
calls() { grep -c . "$FAKE/calls" 2>/dev/null || echo 0; }
history() { find "$P/.orch/history" -name 'journal-*.ndjson' 2>/dev/null | wc -l | tr -d ' '; }

plan one; orch run
assert_eq "the first plan runs its task" "$(cat "$P/out.txt" 2>/dev/null)" "one"
orch run
assert_eq "run on the same plan again: done stays done" "$(calls)" "1"
assert_eq "  ...and the run record stays" "$(history)" "0"

plan two; orch run --dry-run
assert_eq "a dry run of a new plan changes nothing" "$(history)" "0"
orch run
assert_eq "a NEW plan whose task has the same id runs it" "$(cat "$P/out.txt" 2>/dev/null)" "two"
assert_eq "  ...the old run record is put aside, not lost" "$(history)" "1"
assert_true "  ...and holds what the old plan did" \
  'grep -q "\"event\":\"done\",\"task\":\"api\"" "$P"/.orch/history/journal-*.ndjson'

plan three '[{"id":"ui","prompt":"WRITE:never","deps":[],"files":["ui.txt"],"category":"general","blocked":"needs a design"}]'
orch run
before="$(calls)"
jq '(.tasks[] | select(.id == "ui")) |= del(.blocked)' "$P/.orch/tasks.json" > "$P/t" && mv "$P/t" "$P/.orch/tasks.json"
orch resume
assert_eq "resume after editing the plan keeps the record: api is not redone" \
  "$(( $(calls) - before ))" "1"
assert_eq "  ...and nothing new is put aside" "$(history)" "2"

# A journal from before plans were recorded.
rm -rf "$P/.orch/history" "$P/.orch/journal.ndjson"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"done","task":"api"}' > "$P/.orch/journal.ndjson"
plan four; before="$(calls)"; orch run
assert_eq "an old journal whose tasks this plan all has is kept: api stays done" "$(( $(calls) - before ))" "0"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"done","task":"setup"}' >> "$P/.orch/journal.ndjson"
jq 'del(.[] | select(.event == "plan"))' -s "$P/.orch/journal.ndjson" | jq -c '.[]' > "$P/j" && mv "$P/j" "$P/.orch/journal.ndjson"
plan five; orch run
assert_eq "an old journal naming a task this plan lacks is another plan's: api runs" "$(cat "$P/out.txt")" "five"

assert_contains "history/ is kept out of git" "$(cat "$P/.orch/.gitignore")" "history/"

end_suite
final_report
