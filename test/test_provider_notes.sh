#!/usr/bin/env bash
# Proves the hand-maintained ToS/evidence notes (data/provider-notes.json) get
# attached to the right bucket at discover time, matched case-insensitively
# against provider/local_providers, and are surfaced by `show` and `lanes -v`.
# A provider with no note, or one rated "ok"/"unknown", must print nothing -
# the caution line exists to be noticed, so it must never become wallpaper.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "provider ToS/evidence notes"
sandbox_on

FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
export FREE_AGENTS_STATE="$FAKE/state"; mkdir -p "$FREE_AGENTS_STATE"
REG="$FREE_AGENTS_STATE/buckets.json"

export OPENCODE_AUTH="$FAKE/opencode-auth.json"
export KILO_CONFIG="$FAKE/kilo.jsonc"
export KILO_DB="$FAKE/nonexistent.db"
export HERMES_AUTH="$FAKE/hermes-auth.json"
export HERMES_ENV="$FAKE/hermes.env"

cat > "$OPENCODE_AUTH" <<'EOF'
{"opencode":{"type":"api","key":"sk-oc-OWNKEY0000000000000"}}
EOF
# kilo's provider is named "openai" locally, but its baseURL host is
# openrouter.ai - the canonical wallet name discover() assigns, and exactly
# the key provider-notes.json must match against, case-insensitively.
cat > "$KILO_CONFIG" <<'EOF'
{"provider":{"openai":{"options":{"apiKey":"sk-or-v1-NOTESKEY000000000","baseURL":"https://openrouter.ai/api/v1"},
 "models":{},"whitelist":[],"blacklist":[]}}}
EOF
echo '{"credential_pool":{}}' > "$HERMES_AUTH"
: > "$HERMES_ENV"

cat > "$FAKE/provider-notes.json" <<'EOF'
{
  "_README": "test fixture - see the real file for the format this mirrors",
  "openrouter.ai": { "tos": "caution", "evidence": "console-verified", "note": "TESTNOTE caution text" },
  "kilo": { "tos": "ok", "note": "should never print - ok is not a caution level" },
  "unmatched-provider": { "tos": "avoid", "note": "should never appear - nothing maps to this key" }
}
EOF
export PROVIDER_NOTES="$FAKE/provider-notes.json"

timeout 150 "$REPO/bin/buckets.sh" discover >/dev/null 2>&1
[[ -s "$REG" ]] || { fail "discover wrote no registry"; end_suite; final_report; exit 1; }

bid="$(jq -r '.buckets | keys[] | select(startswith("openrouter.ai:"))' "$REG" | head -1)"
assert_true "the openrouter.ai bucket exists" '[[ -n "$bid" ]]'
assert_eq "tos is attached, matched case-insensitively via local_providers" \
  "$(jq -r --arg b "$bid" '.buckets[$b].tos' "$REG")" "caution"
assert_eq "tos_evidence is carried through" \
  "$(jq -r --arg b "$bid" '.buckets[$b].tos_evidence' "$REG")" "console-verified"
assert_contains "tos_note is carried through" \
  "$(jq -r --arg b "$bid" '.buckets[$b].tos_note' "$REG")" "TESTNOTE caution text"

kbid="$(jq -r '.buckets | keys[] | select(startswith("kilo:"))' "$REG" | head -1)"
if [[ -n "$kbid" ]]; then
  assert_eq "an 'ok' rating is still recorded on the bucket" \
    "$(jq -r --arg b "$kbid" '.buckets[$b].tos' "$REG")" "ok"
fi

out="$("$REPO/bin/buckets.sh" show 2>&1)"
assert_contains "show prints a TOS CAUTION line for the caution-rated wallet" "$out" "TOS CAUTION"
assert_contains "the note text appears in show" "$out" "TESTNOTE caution text"
assert_not_contains "show never prints a line for an 'ok' rating" \
  "$(printf '%s\n' "$out" | grep -A2 "^kilo:")" "TOS OK"

vout="$("$REPO/bin/buckets.sh" lanes -v 2>&1)"
assert_contains "lanes -v tags the caution-rated bucket" "$vout" "[TOS:caution]"
assert_not_contains "lanes -v never tags an unmatched provider's rating" "$vout" "unmatched-provider"

end_suite
final_report
