# hermes.sh - adapter for the hermes CLI.
#
# Identity: OAuth entries carry their own token (identity = the JWT subject, not
#   the token - tokens rotate hourly, subjects do not); env-var-backed entries
#   point at a key in ~/.hermes/.env.
# Models:   hermes reaches several gateways; each is queried with `GET /models`
#   and the free signal uses whichever that gateway publishes (isFree /
#   zero pricing / ":free" suffix).
# Invoke:   hermes -m model -z prompt; hermes resolves a bare -m against its
#   ACTIVE provider only, so --provider is required for non-active gateways.
#   It honours neither cwd nor --in, so containment is HOME + HERMES_HOME.

HERMES_AUTH="${HERMES_AUTH:-$HOME/.hermes/auth.json}"
HERMES_CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"
HERMES_ENV="${HERMES_ENV:-$HOME/.hermes/.env}"

FA_hermes_BINARY="hermes"
FA_hermes_METERED=0
FA_hermes_VERIFIED_VERSION="0.20.5"
FA_hermes_VERSION_BIN="hermes"

# -> provider<TAB>token<TAB>base_url, from BOTH sources in auth.json (see header)
hermes_endpoints() {
  [[ -f "$HERMES_AUTH" ]] || return 0
  local provider tok base envvar val
  # NOTE: IFS=$'\t' would COLLAPSE consecutive tabs (tab is IFS whitespace), so a
  # row with an empty token silently shifts base_url into tok. Use a
  # non-whitespace separator wherever a field may legitimately be empty.
  while IFS=$'\x1f' read -r provider tok base; do
    [[ -z "$provider" || -z "$base" ]] && continue
    if [[ -z "$tok" && -f "$HERMES_ENV" ]]; then
      envvar="$(printf '%s' "$provider" | tr '[:lower:]' '[:upper:]')_API_KEY"
      val="$(grep -oP "(?<=^${envvar}=).*" "$HERMES_ENV" 2>/dev/null | head -1)"
      val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
      tok="$val"
    fi
    [[ -z "$tok" ]] && continue
    printf '%s\x1f%s\x1f%s\n' "$provider" "$tok" "$base"
  done < <(jq -r '.credential_pool // {} | to_entries[]
                  | . as $e | ($e.value[0] // {})
                  | [$e.key, (.access_token // .api_key // ""),
                     (.inference_base_url // .base_url // "")]
                  | join("\u001f")' "$HERMES_AUTH" 2>/dev/null)
}

hermes_identify() {
  command -v hermes >/dev/null 2>&1 || return 0
  [[ -f "$HERMES_AUTH" ]] || return 0
  local provider tok base subj ident
  while IFS=$'\x1f' read -r provider tok base; do
    # OAuth access tokens rotate hourly - identify by the subject they carry.
    subj="$(jwt_subject "$tok" || true)"
    ident="$(fp "${subj:-$tok}")"
    printf 'hermes\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$provider" "$provider" "$ident" "hermes:auth.json" \
      "$(jq -cn --arg b "$base" --argjson l "$(jwt_limits "$tok")" \
          '{base_url:$b, limits:$l}')"
  done < <(hermes_endpoints)
}

# Ask each gateway what THIS credential can actually see, and use whichever free
# signal that gateway publishes:
#   isFree            authoritative when present (kilo gateway)
#   pricing == 0      OpenAI-style catalogues
#   ":free" suffix    naming convention; last resort (nous prices nothing)
hermes_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v hermes >/dev/null 2>&1 || return 0
  local provider tok base out
  while IFS=$'\x1f' read -r provider tok base; do
    out="${TEMP_DIR}/hermes.${provider}.models"
    curl -sS --max-time 45 -H "Authorization: Bearer ${tok}" \
      "${base%/}/models" -o "$out" 2>/dev/null || continue
    jq -e '.data | type == "array"' "$out" >/dev/null 2>&1 || continue
    # These gateways publish far more than price: context, output budget, and
    # crucially output MODALITY - which is the only way to tell that a model in
    # the free set generates audio rather than text.
    jq -r --arg p "$provider" '.data[]
           | . as $m
           | (if ($m.isFree != null) then $m.isFree
              elif ($m.pricing.prompt != null and $m.pricing.completion != null
                    and ($m.pricing.prompt|tonumber?) == 0
                    and ($m.pricing.completion|tonumber?) == 0) then true
              else ($m.id | test(":free$")) end) as $free
           | select($free)
           | [$p, $m.id, $m.id, "true",
              ($m.context_length // 0),
              ($m.top_provider.max_completion_tokens // 0),
              (($m.architecture.output_modalities // []) | join("+"))]
           | @tsv' "$out" 2>/dev/null \
      | sed 's/^/hermes\t/'
  done < <(hermes_endpoints)
}

hermes_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local model="$1" provider="$2" prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    # hermes honours NEITHER cwd NOR --in: it resolves relative paths against
    # $HOME, so both wrote to /root in testing. HOME is what actually contains
    # it - and HERMES_HOME keeps its config and credentials where they live.
    local henv=(env "HOME=$FA_WORKDIR" "HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}")
    if [[ -n "$provider" ]]; then
      out="$(timeout "$t" "${henv[@]}" hermes --provider "$provider" \
        -m "$model" --in "$FA_WORKDIR" --yolo -z "$prompt" </dev/null 2>&1)" || rc=$?
    else
      out="$(timeout "$t" "${henv[@]}" hermes -m "$model" \
        --in "$FA_WORKDIR" --yolo -z "$prompt" </dev/null 2>&1)" || rc=$?
    fi
  else
    if [[ -n "$provider" ]]; then
      out="$(timeout "$t" hermes --provider "$provider" -m "$model" -z "$prompt" \
        </dev/null 2>&1)" || rc=$?
    else
      out="$(timeout "$t" hermes -m "$model" -z "$prompt" </dev/null 2>&1)" || rc=$?
    fi
  fi
  printf '%s' "$out"
  return $rc
}