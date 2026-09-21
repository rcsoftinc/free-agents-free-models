#!/usr/bin/env bash
# Proves the optional, non-interactive credential setup added to setup.sh:
#   Tier A (opencode/kilo/pi) - a keys.env line writes straight into that
#     agent's own config file, in the exact shape its identify() parser
#     expects - this project's second-worst outcome after a raw crash is a
#     "provisioned" key nothing can actually read back.
#   Tier B (copilot/cursor/agy/hermes) - real login can never be silently
#     automated, so this only proves detection (adapter_logged_in) and that
#     the notify-what's-still-outstanding path actually lists everyone.
#
# This suite caught a real bug before it shipped: kilo_provision_key's first
# two positional args did not match how the generic dispatcher in keys.sh
# calls every *_provision_key function, silently swapping the API key and the
# base URL in kilo.jsonc. Test 3 below is exactly that shape.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "credential provisioning (keys.env) and Tier B login detection"

COMMON="$REPO/bin/lib/common.sh"
KEYS="$REPO/bin/lib/keys.sh"

_fixture_dir() { mktemp -d; }

# --- 1. opencode/pi: key lands where identify() actually reads it -------------
D="$(_fixture_dir)"
out="$(env -i PATH="$PATH" HOME="$D" OPENCODE_AUTH="$D/oc.json" bash -c '
  set -euo pipefail
  . '"$COMMON"'
  . '"$KEYS"'
  opencode_provision_key openrouter sk-or-TESTKEY
  jq -r ".openrouter.key" "$OPENCODE_AUTH"
')"
assert_eq "opencode_provision_key writes the key under .openrouter.key" "$out" "sk-or-TESTKEY"
rm -rf "$D"

D="$(_fixture_dir)"
out="$(env -i PATH="$PATH" HOME="$D" PI_AUTH="$D/pi.json" bash -c '
  set -euo pipefail
  . '"$COMMON"'
  . '"$KEYS"'
  pi_provision_key openrouter sk-or-PITEST
  jq -r ".openrouter.key" "$PI_AUTH"
')"
assert_eq "pi_provision_key writes the key under .openrouter.key" "$out" "sk-or-PITEST"
rm -rf "$D"

# --- 2. provisioning PRESERVES whatever else was already in the file ----------
D="$(_fixture_dir)"
printf '{"opencode":{"type":"api","key":"sk-oc-EXISTING"}}' > "$D/oc.json"
out="$(env -i PATH="$PATH" HOME="$D" OPENCODE_AUTH="$D/oc.json" bash -c '
  set -euo pipefail
  . '"$COMMON"'
  . '"$KEYS"'
  opencode_provision_key openrouter sk-or-NEW
  jq -c "{a:.opencode.key, b:.openrouter.key}" "$OPENCODE_AUTH"
')"
assert_eq "the pre-existing opencode-account entry survives" "$out" '{"a":"sk-oc-EXISTING","b":"sk-or-NEW"}'
rm -rf "$D"

# --- 3. kilo: the exact bug this suite exists to pin ---------------------------
# keys.sh's dispatcher calls every *_provision_key as (provider, key). kilo's
# function used to take (key, baseURL) instead, so the actual key silently
# landed in the baseURL field and the literal string "openrouter" landed in
# apiKey - a completely dead credential that LOOKED provisioned.
D="$(_fixture_dir)"
out="$(env -i PATH="$PATH" HOME="$D" KILO_CONFIG="$D/kilo.jsonc" bash -c '
  set -euo pipefail
  . '"$COMMON"'
  . '"$KEYS"'
  kilo_provision_key openrouter sk-or-KILOTEST
  jq -c "{key:.provider.openrouter.options.apiKey, base:.provider.openrouter.options.baseURL}" "$KILO_CONFIG"
')"
assert_eq "kilo_provision_key(provider, key) puts the KEY in apiKey, not baseURL" \
  "$out" '{"key":"sk-or-KILOTEST","base":"https://openrouter.ai/api/v1"}'
rm -rf "$D"

# --- 4. kilo.jsonc with comments: refuse, never corrupt ------------------------
D="$(_fixture_dir)"
printf '// hand-edited\n{"provider":{}}' > "$D/kilo.jsonc"
rc=0
env -i PATH="$PATH" HOME="$D" KILO_CONFIG="$D/kilo.jsonc" bash -c '
  set -euo pipefail
  . '"$COMMON"'
  . '"$KEYS"'
  kilo_provision_key openrouter sk-or-SHOULDNOTWRITE
' >/dev/null 2>&1 || rc=$?
assert_ne "kilo_provision_key refuses a commented kilo.jsonc" "$rc" "0"
assert_contains "and leaves the file byte-for-byte untouched" "$(cat "$D/kilo.jsonc")" '// hand-edited'
rm -rf "$D"

# --- 5. the generic dispatcher: end to end via keys.env -----------------------
D="$(_fixture_dir)"
cat > "$D/keys.env" <<EOF
OPENCODE_OPENROUTER_KEY=sk-or-AAA
KILO_OPENROUTER_KEY=sk-or-BBB
PI_OPENROUTER_KEY=sk-or-CCC
EOF
out="$(env -i PATH="$PATH" HOME="$D" HERE="$D" \
  OPENCODE_AUTH="$D/oc.json" KILO_CONFIG="$D/kilo.jsonc" PI_AUTH="$D/pi.json" bash -c '
  set -euo pipefail
  say() { printf "[fa] %s\n" "$*"; }  # real setup.sh: stdout, same as here
  . '"$COMMON"'
  . '"$KEYS"'
  provision_keys >/dev/null   # status lines go to stdout by design; drop them here
  jq -r ".openrouter.key" "$OPENCODE_AUTH"
  jq -r ".provider.openrouter.options.apiKey" "$KILO_CONFIG"
  jq -r ".openrouter.key" "$PI_AUTH"
')"
assert_eq "provision_keys() from a real keys.env provisions all three distinctly" \
  "$out" "$(printf 'sk-or-AAA\nsk-or-BBB\nsk-or-CCC')"

# --- 6. duplicate key across two lines: warned, never silently accepted -------
D2="$(_fixture_dir)"
cat > "$D2/keys.env" <<EOF
OPENCODE_OPENROUTER_KEY=sk-or-SAME
KILO_OPENROUTER_KEY=sk-or-SAME
PI_OPENROUTER_KEY=sk-or-DIFFERENT
EOF
warn="$(env -i PATH="$PATH" HOME="$D2" HERE="$D2" \
  OPENCODE_AUTH="$D2/oc.json" KILO_CONFIG="$D2/kilo.jsonc" PI_AUTH="$D2/pi.json" bash -c '
  set -euo pipefail
  say() { printf "[fa] %s\n" "$*"; }
  . '"$COMMON"'
  . '"$KEYS"'
  provision_keys
' 2>&1 | grep -c "same wallet")"
assert_eq "reusing one key across two agent slots produces exactly one warning" "$warn" "1"

# --- 7. no keys.env at all: silent, successful no-op --------------------------
D3="$(_fixture_dir)"
rc=0
env -i PATH="$PATH" HOME="$D3" HERE="$D3" bash -c '
  set -euo pipefail
  say() { printf "[fa] %s\n" "$*"; }
  . '"$COMMON"'
  . '"$KEYS"'
  provision_keys
' >/dev/null 2>&1 || rc=$?
assert_eq "provision_keys() with no keys.env exits 0" "$rc" "0"
rm -rf "$D" "$D2" "$D3"

# --- 8. keys.env permissions are tightened -------------------------------------
D4="$(_fixture_dir)"
printf 'OPENCODE_OPENROUTER_KEY=sk-or-PERMTEST\n' > "$D4/keys.env"
chmod 644 "$D4/keys.env"
env -i PATH="$PATH" HOME="$D4" HERE="$D4" OPENCODE_AUTH="$D4/oc.json" bash -c '
  set -euo pipefail
  say() { printf "[fa] %s\n" "$*"; }
  . '"$COMMON"'
  . '"$KEYS"'
  provision_keys
' >/dev/null 2>&1
perm="$(stat -c '%a' "$D4/keys.env")"
assert_eq "keys.env is tightened to 600 after being read" "$perm" "600"
rm -rf "$D4"

# --- 9. Tier B: adapter_logged_in reads identify() correctly ------------------
out="$(bash -c '
  . '"$COMMON"'
  copilot_identify() { printf "copilot\x1fcopilot\x1fcopilot\x1fanon\x1fcopilot:github\x1f{}\n"; }
  cursor_identify()  { printf "cursor\x1fcursor\x1fcursor\x1ffpREAL\x1fcursor:status\x1f{}\n"; }
  hermes_identify()  { :; }
  adapter_logged_in copilot; echo "copilot:$?"
  adapter_logged_in cursor;  echo "cursor:$?"
  adapter_logged_in hermes;  echo "hermes:$?"
')"
assert_contains "copilot with ident=anon reads as NOT logged in" "$out" "copilot:1"
assert_contains "cursor with a real ident reads as logged in" "$out" "cursor:0"
assert_contains "hermes with zero identify() rows reads as NOT logged in" "$out" "hermes:1"

# --- 10. guided_logins(): reports every still-unlogged account, never hangs ---
out="$(timeout 15 env -i PATH="$PATH" HOME="$(_fixture_dir)" bash -c '
  set -euo pipefail
  say() { printf "[fa] %s\n" "$*"; }
  prompt_yn() { local ans; read -rp "$1 [y/N] " ans; [[ "${ans,,}" == "y" ]]; }
  . '"$COMMON"'
  . '"$KEYS"'
  copilot_identify() { printf "copilot\x1fcopilot\x1fcopilot\x1fanon\x1fcopilot:github\x1f{}\n"; }
  cursor_identify()  { printf "cursor\x1fcursor\x1fcursor\x1ffpREAL\x1fcursor:status\x1f{}\n"; }
  agy_identify()     { printf "agy\x1fantigravity\x1fantigravity\x1fanon\x1fagy:antigravity-cli\x1f{}\n"; }
  hermes_identify()  { :; }
  adapter_installed() { return 0; }
  guided_logins </dev/null
' 2>&1)"
rc=$?
assert_eq "guided_logins() never hangs on a non-interactive terminal" "$rc" "0"
assert_contains "already-logged-in cursor is reported as such" "$out" "cursor: already logged in"
assert_contains "the outstanding summary names copilot" "$out" "copilot - gh auth login"
assert_contains "the outstanding summary names agy" "$out" "agy - agy login"
assert_contains "the outstanding summary names hermes" "$out" "hermes - hermes login"
assert_not_contains "cursor (already logged in) is NOT in the outstanding summary" \
  "$(printf '%s\n' "$out" | grep 'not yet logged in' -A5)" "cursor -"

# --- 11. setup.sh actually calls both - a wiring regression is otherwise silent
assert_contains "setup.sh sources keys.sh" "$(cat "$REPO/setup.sh")" "bin/lib/keys.sh"
assert_contains "setup.sh calls provision_keys" "$(cat "$REPO/setup.sh")" "provision_keys"
assert_contains "setup.sh calls guided_logins" "$(cat "$REPO/setup.sh")" "guided_logins"

end_suite
final_report