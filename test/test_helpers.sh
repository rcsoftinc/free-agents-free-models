#!/usr/bin/env bash
# Proves the two helper scripts behave. kilo-add-openrouter.sh rewrites a config
# that holds a live credential, so its failure modes are destructive: the version
# this replaced silently erased the apiKey it depended on and discarded every
# existing entry. Those exact regressions are pinned here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "helper scripts"
sandbox_on          # stub curl answers openrouter.ai and models.dev

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
KEY="sk-or-v1-EXISTINGKEY0000000000"
CFG="$WORK/kilo.jsonc"
addor() { KILO_CONFIG="$CFG" OPENROUTER_API_KEY="${2:-$KEY}" \
          timeout 60 "$REPO/bin/kilo-add-openrouter.sh" ${1:+$1} 2>&1; }

seed() { cat > "$CFG" <<EOF
{"permission":{"bash":{"kilo *":"allow"}},
 "provider":{"openai":{"options":{"apiKey":"$KEY","baseURL":"https://openrouter.ai/api/v1"},
 "models":{"keep/me":{"name":"Keep Me"}},"whitelist":["keep/me"],"blacklist":["nope/one"]}}}
EOF
}

# --- 1. it must not destroy the credential it depends on --------------------
seed; addor "" >/dev/null
assert_eq "the existing apiKey survives" \
          "$(jq -r '.provider.openai.options.apiKey' "$CFG")" "$KEY"

# --- 2. it must MERGE, not replace ------------------------------------------
# The version this replaced read a dead path (.provider.provider.openai.*), so
# every pre-existing model, whitelist and blacklist entry was silently dropped.
assert_true "a pre-existing model is kept" \
  '[[ $(jq -r ".provider.openai.models[\"keep/me\"].name" "$CFG") == "Keep Me" ]]'
assert_contains "a pre-existing blacklist entry is kept" \
  "$(jq -c '.provider.openai.blacklist' "$CFG")" "nope/one"
assert_contains "unrelated config is untouched" \
  "$(jq -c '.permission' "$CFG")" "kilo *"

# --- 3. free models only, and an EXPLICIT whitelist -------------------------
# whitelist ["*"] would expose the paid catalogue while everything downstream
# treats this provider as free - the one failure mode here that costs money.
assert_contains "a zero-priced model is registered" \
  "$(jq -r '.provider.openai.models | keys | join(",")' "$CFG")" "openai/gpt-4o"
assert_not_contains "a priced model is NOT registered" \
  "$(jq -r '.provider.openai.models | keys | join(",")' "$CFG")" "claude-3.5-sonnet"
# NOTE: assert_not_contains globs, so a needle of "*" matches almost any string.
# Ask jq the actual question instead.
assert_eq "the whitelist is not a wildcard" \
  "$(jq -r '[.provider.openai.whitelist[] | select(. == "*")] | length' "$CFG")" "0"
assert_contains "the whitelist names the free model" \
  "$(jq -c '.provider.openai.whitelist' "$CFG")" "openai/gpt-4o"

# --- 4. --all is the deliberate opt-in --------------------------------------
seed; out="$(addor --all)"
assert_contains "--all restores the wildcard" "$(jq -c '.provider.openai.whitelist' "$CFG")" '"*"'
assert_contains "--all warns that paid models become reachable" "$out" "WARNING"

# --- 5. --dry-run changes nothing -------------------------------------------
seed; before="$(md5sum "$CFG" | cut -d' ' -f1)"
out="$(addor --dry-run)"
assert_eq "dry run leaves the file untouched" "$(md5sum "$CFG" | cut -d' ' -f1)" "$before"
assert_not_contains "dry run does not print the key" "$out" "$KEY"

# --- 6. safety rails --------------------------------------------------------
seed; addor "" >/dev/null
assert_true "a timestamped backup is written" '[[ -n "$(ls "$WORK"/kilo.jsonc.bak.* 2>/dev/null)" ]]'
assert_eq "the config holding a secret is chmod 600" "$(stat -c '%a' "$CFG")" "600"

# jq cannot round-trip comments, so a real .jsonc must be refused rather than
# silently rewritten into something lossy.
printf '{\n  // a comment\n  "provider": {}\n}\n' > "$CFG"
out="$(addor "" 2>&1)"; rc=$?
assert_ne "a commented jsonc is refused, not mangled" "$rc" "0"
assert_contains "and it says why" "$out" "comments"

# --- 7. find-free-providers ranks by free-model count -----------------------
out="$(timeout 60 "$REPO/bin/find-free-providers.sh" 5 2>&1)"
assert_contains "a provider with free models is listed" "$out" "alpha"
assert_contains "so is the other one" "$out" "beta"
assert_not_contains "a provider with only paid models is omitted" "$out" "gamma"
assert_contains "the env var to set is shown" "$out" "ALPHA_API_KEY"
pos_a=$(printf '%s\n' "$out" | grep -n 'alpha' | head -1 | cut -d: -f1)
pos_b=$(printf '%s\n' "$out" | grep -n 'beta'  | head -1 | cut -d: -f1)
assert_true "the provider with MORE free models ranks first" '[[ $pos_a -lt $pos_b ]]'

# --- 8. its "next steps" must point at real commands -------------------------
# This used to say `bash scripts/bootstrap.sh` (a script that never existed) and
# `.env` (a file nothing reads). Pinned so the pointers can't rot again.
assert_not_contains "no reference to the nonexistent scripts/bootstrap.sh" "$out" "scripts/bootstrap.sh"
assert_contains "the follow-up command is the real one" "$out" "fa refresh"
assert_contains "the credential locations are real" "$out" "auth.json"

end_suite
final_report
