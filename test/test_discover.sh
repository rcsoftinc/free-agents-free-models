#!/usr/bin/env bash
# Proves bin/buckets.sh discover attributes models to the CREDENTIAL that pays for
# them. This is the primitive everything else rests on: get it wrong and the
# scheduler either invents capacity that does not exist or treats one wallet as
# two and races it into its own rate limit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "discover: credentials -> buckets"
sandbox_on

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
export FREE_AGENTS_STATE="$FAKE/state"; mkdir -p "$FREE_AGENTS_STATE"
REG="$FREE_AGENTS_STATE/buckets.json"

# Point discovery at fabricated configs instead of the developer's real ones.
export OPENCODE_AUTH="$FAKE/opencode-auth.json"
export KILO_CONFIG="$FAKE/kilo.jsonc"
export KILO_DB="$FAKE/nonexistent.db"
export HERMES_AUTH="$FAKE/hermes-auth.json"
export HERMES_ENV="$FAKE/hermes.env"

SHARED_KEY="sk-or-v1-SHAREDKEY0000000000000000"
OWN_KEY="sk-oc-OWNKEY111111111111111111"

write_configs() { # $1 = key kilo should use
  cat > "$OPENCODE_AUTH" <<EOF
{"opencode":{"type":"api","key":"$OWN_KEY"},
 "openrouter":{"type":"api","key":"$SHARED_KEY"}}
EOF
  cat > "$KILO_CONFIG" <<EOF
{"provider":{"openai":{"options":{"apiKey":"$1","baseURL":"https://openrouter.ai/api/v1"},
 "models":{},"whitelist":[],"blacklist":[]}}}
EOF
  echo '{"credential_pool":{}}' > "$HERMES_AUTH"
  : > "$HERMES_ENV"
}

# Only the rows produced by OUR fabricated configs. The machine's real agents
# (copilot, cursor, kilo's own gateway) also report identities and are not
# overridable by env, so counting every row would measure the developer's
# machine rather than the behaviour under test.
ids() {
  "$REPO/bin/buckets.sh" identify 2>/dev/null \
    | grep -E 'source=(opencode:auth\.json|kilo:kilo\.jsonc)'
}
nbuckets() { ids | grep -oE 'bucket=[^ ]+' | sort -u | wc -l; }

# --- 1. distinct credentials become distinct buckets ------------------------
write_configs "sk-or-v1-DIFFERENTKEY99999999999"
out="$(ids)"
assert_contains "opencode's own account is a bucket" "$out" "opencode:"
assert_contains "opencode's openrouter key is a bucket" "$out" "openrouter:"
assert_contains "kilo's provider is attributed to its API host" "$out" "openrouter.ai:"
assert_eq "three different credentials -> three buckets" "$(nbuckets)" "3"

# --- 2. THE SHARED-WALLET CASE ---------------------------------------------
# Give kilo the SAME key opencode already uses. Two agents, one wallet: it must
# collapse to a single bucket, or the scheduler will run both against one quota
# believing it has two lanes.
write_configs "$SHARED_KEY"
out="$(ids)"
shared_fp="$(printf '%s\n' "$out" | grep -oE 'bucket=[a-z.]+:[a-f0-9]+' \
             | sed 's/.*://' | sort | uniq -d | head -1)"
assert_true "the shared key produces a repeated fingerprint" '[[ -n "$shared_fp" ]]'
# Three credential SLOTS, but only two distinct wallets once the key is shared.
assert_eq "sharing a key collapses three slots into two lanes" "$(nbuckets)" "2"

# --- 3. identity is derived from the credential, not the agent --------------
fp_oc="$(printf '%s\n' "$out" | awk '/^opencode +openrouter/  {print $3}' | sed 's/.*://')"
fp_kilo="$(printf '%s\n' "$out" | awk '/^kilo +openai/ {print $3}' | sed 's/.*://')"
assert_eq "same key via two agents yields the same fingerprint" "$fp_oc" "$fp_kilo"

# --- 4. no secret is ever stored -------------------------------------------
write_configs "sk-or-v1-DIFFERENTKEY99999999999"
timeout 120 "$REPO/bin/buckets.sh" discover >/dev/null 2>&1
if [[ -s "$REG" ]]; then
  assert_not_contains "the registry stores no API key" "$(cat "$REG")" "$SHARED_KEY"
  assert_not_contains "not even the opencode account key" "$(cat "$REG")" "$OWN_KEY"
  assert_true "buckets were written" '[[ $(jq -r ".buckets | length" "$REG") -ge 1 ]]'
else
  fail "discover wrote no registry"
fi

# --- 5. a credential-less agent is not invented into a bucket ---------------
rm -f "$OPENCODE_AUTH"
out="$(ids)"
assert_not_contains "an agent with no credentials contributes no bucket" "$out" "$OWN_KEY"

end_suite
final_report
