#!/usr/bin/env bash
# Proves hermes_endpoints() reads a real nous credential out of
# .providers.nous (the OAuth "singleton provider state" hermes's own login
# check trusts) even when .credential_pool.nous is empty or stale - a real
# machine showed hermes itself saying "Already signed in" for nous while fa
# saw no credential at all, traced to exactly this gap in
# hermes_cli/auth_nous.py's own installed source (persist_nous_credentials()).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "hermes: nous singleton credential (.providers.nous)"

COMMON="$REPO/bin/lib/common.sh"

# An unsigned JWT is enough - jwt_subject() only decodes the payload, it
# never verifies a signature.
fake_jwt() { # $1=sub -> header.payload.sig
  local sub="$1" header payload
  header="$(printf '{"alg":"none"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  payload="$(printf '{"sub":"%s"}' "$sub" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  printf '%s.%s.sig' "$header" "$payload"
}

write_auth() { # $1=file $2=credential_pool.nous(json array) $3=providers.nous(json object)
  jq -n --argjson pool "$2" --argjson prov "$3" '
    {active_provider:"nous", version:1, updated_at:"2026-09-27T00:00:00Z",
     credential_pool:{nous:$pool}, providers:{nous:$prov}}' > "$1"
}

run_endpoints() { # $1=auth_file -> hermes_endpoints() stdout
  env -i PATH="$PATH" HOME="$(mktemp -d)" HERMES_AUTH="$1" HERMES_ENV="/nonexistent" bash -c '
    set -euo pipefail
    . '"$COMMON"'
    hermes_endpoints
  '
}

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT

# --- 1. the exact real-world case: pool empty, singleton has a live token --
SUBJ1="user-singleton-only"
write_auth "$D/a1.json" '[]' \
  "$(jq -n --arg t "$(fake_jwt "$SUBJ1")" \
    '{access_token:$t, refresh_token:"r1", token_type:"Bearer",
      inference_base_url:"https://inference.nousresearch.com/v1",
      portal_base_url:"https://portal.nousresearch.com", client_id:"c1"}')"
out="$(run_endpoints "$D/a1.json")"
assert_true "a nous row is produced from the singleton alone" '[[ -n "$out" ]]'
assert_contains "with the singleton's inference base_url" "$out" "inference.nousresearch.com"
prov="$(printf '%s' "$out" | cut -d $'\x1f' -f1)"
assert_eq "provider is nous" "$prov" "nous"

# --- 2. both empty/absent: no row, no crash (this machine's actual state) --
write_auth "$D/a2.json" '[]' '{}'
out="$(run_endpoints "$D/a2.json")"
assert_eq "nothing logged in produces no row" "$out" ""

# --- 3. pool has a (possibly stale) entry too: singleton still wins, ------
#        and there is exactly ONE nous row, never two
SUBJ_POOL="user-pool-stale"
SUBJ_SINGLETON="user-singleton-fresh"
write_auth "$D/a3.json" \
  "$(jq -n --arg t "$(fake_jwt "$SUBJ_POOL")" \
    '[{access_token:$t, inference_base_url:"https://stale.example/v1"}]')" \
  "$(jq -n --arg t "$(fake_jwt "$SUBJ_SINGLETON")" \
    '{access_token:$t, inference_base_url:"https://inference.nousresearch.com/v1"}')"
out="$(run_endpoints "$D/a3.json")"
assert_eq "exactly one nous row when both sources have a token" \
  "$(printf '%s\n' "$out" | grep -c .)" "1"
assert_contains "the fresher singleton's base_url is the one used" "$out" "inference.nousresearch.com"
assert_not_contains "the stale pool entry's base_url is NOT used" "$out" "stale.example"

# --- 4. singleton absent/empty, pool populated: old behaviour still works -
SUBJ_POOL_ONLY="user-pool-only"
write_auth "$D/a4.json" \
  "$(jq -n --arg t "$(fake_jwt "$SUBJ_POOL_ONLY")" \
    '[{access_token:$t, inference_base_url:"https://inference.nousresearch.com/v1"}]')" \
  '{}'
out="$(run_endpoints "$D/a4.json")"
assert_true "the pre-existing pool-only path still works" '[[ -n "$out" ]]'
assert_contains "pool base_url is used when there is no singleton" "$out" "inference.nousresearch.com"

# --- 5. end to end: hermes_identify() turns the singleton into a real bucket
#        identity, with a fingerprint derived from the JWT subject
out="$(env -i PATH="$PATH" HOME="$(mktemp -d)" HERMES_AUTH="$D/a1.json" HERMES_ENV="/nonexistent" bash -c '
  set -euo pipefail
  . '"$COMMON"'
  hermes_identify
')"
assert_contains "hermes_identify() reaches the singleton too" "$out" "hermes"
assert_contains "identified as the nous provider" "$out" $'\x1fnous\x1f'
expected_fp="$(printf '%s' "$SUBJ1" | sha256sum | cut -c1-12)"
assert_contains "fingerprint is derived from the JWT subject, not the token" "$out" "$expected_fp"

# --- 6. other providers are completely unaffected by this change ----------
write_auth "$D/a6.json" '[]' '{}'
jq '.credential_pool.kilocode = [{"api_key":"kc-key-1","base_url":"https://openrouter.ai/api/v1"}]' \
  "$D/a6.json" > "$D/a6.json.tmp" && mv "$D/a6.json.tmp" "$D/a6.json"
out="$(run_endpoints "$D/a6.json")"
assert_contains "a plain gateway-key provider still works exactly as before" "$out" "openrouter.ai"

end_suite
final_report
