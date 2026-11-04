#!/usr/bin/env bash
# Proves each adapter launches a worker that can act with nobody there to approve
# anything, the way real dispatch does: with FA_WORKDIR set.
#
# A liveness probe only asks for text and sets no workdir, so it passes either way.
# A real task on 2026-11-04 showed two lanes answering probes but unable to work:
# agy auto-denied every command, exited 0 and was scored "ok", and pi rejected
# --add-dir, so every real task failed before it started.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "workers act unattended"
sandbox_on

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"
WORK="$(cd "$T/work" && pwd)"

# --- every agent, launched exactly as a dispatch launches it ------------------
while IFS= read -r agent; do
  bin="$(bash -c ". '$REPO/bin/lib/common.sh'; adapter_field '$agent' VERSION_BIN")"
  cat > "$T/bin/$bin" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" > "$T/args.$agent"
pwd > "$T/cwd.$agent"
echo OK
EOF
  chmod +x "$T/bin/$bin"
  PATH="$T/bin:$PATH" FA_WORKDIR="$WORK" INVOKE_TIMEOUT=5 \
    bash -c ". '$REPO/bin/lib/common.sh'; adapter_invoke '$agent' some-model prov 'a task'" >/dev/null 2>&1
done < <(bash -c ". '$REPO/bin/lib/common.sh'; printf '%s\n' \"\${FA_AGENTS[@]}\"")

# --- 1. whoever would ask for approval is told not to -------------------------
# opencode and pi are absent because real runs act with no flag.
assert_contains "kilo does not wait for approval" "$(cat "$T/args.kilo")" "--auto"
assert_contains "copilot does not wait for approval" "$(cat "$T/args.copilot")" "--allow-all"
assert_contains "cursor does not wait for approval" "$(cat "$T/args.cursor")" "-f"
assert_contains "hermes does not wait for approval" "$(cat "$T/args.hermes")" "--yolo"
assert_contains "agy does not wait for approval" "$(cat "$T/args.agy")" "--dangerously-skip-permissions"

# A probe only asks for text, so the daily refresh never runs agy with its checks off.
PATH="$T/bin:$PATH" INVOKE_TIMEOUT=5 \
  bash -c "unset FA_WORKDIR; . '$REPO/bin/lib/common.sh'; adapter_invoke agy some-model prov 'reply'" >/dev/null 2>&1
assert_not_contains "and a text-only probe gets no such grant" "$(cat "$T/args.agy")" "--dangerously-skip-permissions"

# --- 2. pi has no --add-dir: it works where it is started ---------------------
assert_not_contains "pi is not given a flag it rejects" "$(cat "$T/args.pi")" "--add-dir"
assert_eq "pi runs in the task's workdir" "$(cat "$T/cwd.pi")" "$WORK"

# --- 3. the stub rejects it too, so the suite would catch it coming back ------
out="$(pi --add-dir "$WORK" --model m --print hi 2>&1)"; rc=$?
assert_eq "the pi stub refuses --add-dir like the real one" "$rc" "1"
assert_contains "with the real message" "$out" "Unknown option: --add-dir"

# --- 4. a worker that was refused is not a success ----------------------------
denied='jetski: no output produced — a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied.'
assert_eq "agy's headless denial exits 0 but is not ok" \
  "$(bash -c ". '$REPO/bin/lib/common.sh'; . '$REPO/bin/lib/classify.sh'; classify 0 '${denied//\'/}'")" "dead"

end_suite
final_report
