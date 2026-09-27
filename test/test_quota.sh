#!/usr/bin/env bash
# Proves `bin/buckets.sh quota` (lib/quota.sh): the one place this tool ever
# asks a provider directly how much of its own published budget is left,
# instead of inferring it from a failed attempt after the fact. Entirely
# offline via the curl stub - see test/stubs/curl's STUB_QUOTA_MODE cases.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "live quota check (OpenRouter)"

TESTKEY="sk-or-v1-QUOTATESTKEY000000000"
TESTFP="$(printf '%s' "$TESTKEY" | sha256sum | cut -c1-12)"

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
export KILO_CONFIG="$FAKE/kilo.jsonc"

write_kilo_config() { # $1=key
  cat > "$KILO_CONFIG" <<EOF
{"provider":{"openrouter":{"options":{"apiKey":"$1","baseURL":"https://openrouter.ai/api/v1"}}}}
EOF
}

# --- 1. no key configured at all: silent, successful no-op -------------------
fixture_registry 1 || exit 1
sandbox_on
rm -f "$KILO_CONFIG"
rc=0
"$REPO/bin/buckets.sh" quota >/dev/null 2>&1 || rc=$?
assert_eq "quota with no kilo openrouter key configured exits 0" "$rc" "0"
assert_eq "and writes nothing to the registry" \
  "$(jq -r '[.buckets[].health.quota] | map(select(. != null)) | length' "$FREE_AGENTS_STATE/buckets.json")" "0"

# --- 2. a key configured but not yet in the registry: reports, does not crash -
write_kilo_config "$TESTKEY"
rc=0
out="$("$REPO/bin/buckets.sh" quota 2>&1)" || rc=$?
assert_eq "an unregistered key's fingerprint returns rc=2" "$rc" "2"
assert_contains "and says to run discover" "$out" "run: "

# --- 3. the happy path: fp matches a real bucket, quota lands on it ----------
jq --arg fp "$TESTFP" '.buckets["b0:fp0"].credential_fp = $fp' \
   "$FREE_AGENTS_STATE/buckets.json" > "$FREE_AGENTS_STATE/buckets.json.tmp" \
   && mv "$FREE_AGENTS_STATE/buckets.json.tmp" "$FREE_AGENTS_STATE/buckets.json"

STUB_QUOTA_MODE=ok "$REPO/bin/buckets.sh" quota >/dev/null 2>&1
REG="$FREE_AGENTS_STATE/buckets.json"
assert_eq "usage is parsed from OpenRouter's response" \
  "$(jq -r '.buckets["b0:fp0"].health.quota.usage' "$REG")" "1.5"
assert_eq "a null limit (unlimited) is kept as null, not coerced" \
  "$(jq -r '.buckets["b0:fp0"].health.quota.limit' "$REG")" "null"
assert_eq "is_free_tier is parsed as a real boolean" \
  "$(jq '.buckets["b0:fp0"].health.quota.is_free_tier' "$REG")" "true"
assert_eq "rate_limit.requests is parsed" \
  "$(jq -r '.buckets["b0:fp0"].health.quota.rate_limit.requests' "$REG")" "20"
assert_eq "source is recorded so show can label it honestly" \
  "$(jq -r '.buckets["b0:fp0"].health.quota.source' "$REG")" "openrouter:auth/key"

showout="$("$REPO/bin/buckets.sh" show 2>&1)"
assert_contains "show surfaces the recorded quota" "$showout" "quota (openrouter:auth/key"
assert_contains "show is honest that this is not a free-tier token count" \
  "$showout" "NOT a free-tier token count"

# --- 4. a malformed/unexpected response: fails cleanly, nothing is written --
jq '.buckets["b0:fp0"].health.quota = null' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
rc=0
STUB_QUOTA_MODE=malformed "$REPO/bin/buckets.sh" quota >/dev/null 2>&1 || rc=$?
assert_eq "a malformed response returns rc=1" "$rc" "1"
assert_eq "and health.quota stays unset rather than storing garbage" \
  "$(jq -r '.buckets["b0:fp0"].health.quota' "$REG")" "null"

end_suite
final_report
