#!/usr/bin/env bash
set -euo pipefail

# buckets.sh - Credential-bucket registry for free-model orchestration.
#
# A BUCKET is one wallet: (provider, stable-credential-identity). It is the unit
# of rate limiting, and therefore the unit of scheduling. Several agents may be
# able to reach the same bucket; that is still ONE lane, and running two agents
# against it concurrently buys nothing while doubling rate-limit pressure.
#
# Bucket id is derived from the CREDENTIAL, never from the agent, so if the same
# key is later added to a second agent the two collapse into one bucket
# automatically and the scheduler stops treating them as independent.
#
# Identity is deliberately STABLE, not the raw secret:
#   api key   -> sha256(key)[:12]
#   oauth     -> sha256(subject-claim)[:12]   (tokens rotate hourly; subjects do not)
#   none      -> "anon"
#
# Produces: ${STATE_DIR}/buckets.json   (default ~/.local/state/free-agents)
#
# Subcommands:
#   identify           credential identities only, no network
#   discover           identities + model inventory (+ --probe to prove liveness)
#   probe              prove reachability for existing registry entries
#   show               human-readable summary
#
# Exit: 0 ok | 2 no live bucket | 3 environment/setup error

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG=buckets
# One taxonomy, one set of paths - shared with bin/run.sh so a classification
# can never drift between the prober and the dispatcher.
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"
# shellcheck source=lib/classify.sh
. "${HERE}/lib/classify.sh"

PROBE_TIMEOUT="${PROBE_TIMEOUT:-90}"
PROBE_PROMPT='reply with exactly: OK'

OPENCODE_AUTH="${OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"
HERMES_AUTH="${HERMES_AUTH:-$HOME/.hermes/auth.json}"
HERMES_CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"
KILO_DB="${KILO_DB:-$HOME/.local/share/kilo/kilo.db}"
KILO_CONFIG="${KILO_CONFIG:-$HOME/.config/kilo/kilo.jsonc}"
HERMES_ENV="${HERMES_ENV:-$HOME/.hermes/.env}"

# Models that are reachable but pathological (hang instead of erroring, so they
# burn a full attempt timeout on every try). Kept out of the registry entirely.
# Observed to HANG rather than error, burning a full attempt timeout every time
# they are tried. A hang is the worst failure mode here because it costs the most
# and teaches the least, so these are kept out of the registry entirely.
# A model must be able to do the job before quality is even a question. These
# rules are about SUITABILITY, not skill, and they are answered entirely by
# metadata the provider already hands us - no leaderboard could supply them.
CONTEXT_FLOOR="${CONTEXT_FLOOR:-200000}"

# The `models --verbose` listings publish no modality, so a metadata-only check
# lets audio and image models through: google/lyria-* generates MUSIC and sat in
# the schedulable free set with a 1M context, which no context floor would catch.
# Matched on the family name, which is the only signal those listings give.
NONTEXT_FAMILIES="${NONTEXT_FAMILIES:-lyria|whisper|dall-?e|imagen|stable-?diffusion|flux|sora|veo|tts|音|voyage-(multimodal|code|[0-9])}"

# Seed of last resort for cold ordering. Optional, absent by default, and NEVER
# fetched at runtime: it is a place to park human or leaderboard opinion where it
# cannot break a run and is overridden the moment real results exist.
MODEL_SEED="${MODEL_SEED:-${_FA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/data/model-seed.json}"

BLOCKLIST_DEFAULT="opencode/big-pickle opencode/mimo-v2.5-free opencode/hy3-free opencode/muse-spark-1.2-contributor-free"
BLOCKLIST="${BUCKETS_BLOCKLIST:-$BLOCKLIST_DEFAULT}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

have jq   || die "jq is required"
have curl || die "curl is required"

# Wallet namespace: the API host the credential actually talks to, so two agents
# naming the same vendor differently still land in one bucket.
host_of() { # $1=base_url $2=fallback
  local h; h="$(printf '%s' "${1:-}" | sed -E 's|^https?://||; s|/.*$||')"
  printf '%s' "${h:-$2}"
}

fp() { # stable 12-char fingerprint; never prints the input
  local v="${1:-}"
  [[ -z "$v" ]] && { printf 'anon'; return; }
  printf '%s' "$v" | sha256sum | cut -c1-12
}

# Subject claim out of a JWT payload, without verifying it (identity only).
jwt_subject() {
  local tok="${1:-}" payload
  [[ -z "$tok" || "$tok" != *.*.* ]] && return 1
  payload="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in 2) payload+='==' ;; 3) payload+='=' ;; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null \
    | jq -er '.sub // .email // empty' 2>/dev/null
}

# ---------------------------------------------------------------- identities --
# Each line (\x1f-separated):
#   agent | local_provider | wallet_ns | identity_fp | source | extra_json
#
# local_provider is what the CLI calls it in `models --verbose` - the JOIN key.
# wallet_ns is what the credential actually talks to (an API host when known) -
# the BUCKET-ID namespace. They differ whenever a CLI names a provider after its
# protocol rather than its vendor: kilo calls OpenRouter "openai". Keeping them
# apart is what lets the same key in two agents collapse to one bucket even when
# each agent labels it differently.

identities_opencode() {
  have opencode || return 0
  [[ -f "$OPENCODE_AUTH" ]] || return 0
  local provider key
  while IFS=$'\x1f' read -r provider key; do
    [[ -z "$provider" ]] && continue
    printf 'opencode\x1f%s\x1f%s\x1f%s\x1f%s\x1f{}\n' \
      "$provider" "$provider" "$(fp "$key")" "opencode:auth.json"
  done < <(jq -r 'to_entries[]
                  | [.key, (.value.key // .value.apiKey // .value.access // "")]
                  | join("\u001f")' "$OPENCODE_AUTH" 2>/dev/null)
}

identities_hermes() {
  have hermes || return 0
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

# Free-tier providers often publish their own limits inside the token.
jwt_limits() {
  local tok="${1:-}" payload
  [[ -z "$tok" || "$tok" != *.*.* ]] && { printf '{}'; return; }
  payload="$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in 2) payload+='==' ;; 3) payload+='=' ;; esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -c '
    { rpm: .rate_limit_rpm, tpm: .rate_limit_tpm,
      rph: .rate_limit_rph, tph: .rate_limit_tph,
      paid: .paid_access, source: .rate_limit_source }
    | with_entries(select(.value != null))' 2>/dev/null || printf '{}'
}

identities_kilo() {
  have kilo || return 0
  local key=""
  # kilo keeps its own gateway credential in sqlite; an empty store means the
  # gateway is serving this machine unauthenticated, which is still a distinct
  # wallet from any account-backed one.
  if [[ -f "$KILO_DB" ]] && have sqlite3; then
    key="$(sqlite3 "$KILO_DB" \
      "SELECT COALESCE(access_token,'') FROM account LIMIT 1;" 2>/dev/null || true)"
  fi
  printf 'kilo\x1fkilo\x1fkilo\x1f%s\x1f%s\x1f{}\n' "$(fp "$key")" \
    "$([[ -n "$key" ]] && echo 'kilo:kilo.db' || echo 'kilo:unauthenticated')"

  # Extra OpenAI-compatible providers configured in kilo.jsonc (e.g. OpenRouter).
  # The provider NAME is local config ("openai"); the wallet is the base URL's
  # host plus the key, so the same key in another agent still collapses to one
  # bucket regardless of what each agent calls the provider.
  [[ -f "$KILO_CONFIG" ]] || return 0
  jq -e . "$KILO_CONFIG" >/dev/null 2>&1 || {
    log "warning: $KILO_CONFIG is not plain JSON (comments?) - skipping its providers"
    return 0
  }
  local name pkey base
  while IFS=$'\x1f' read -r name pkey base; do
    [[ -z "$name" || -z "$pkey" ]] && continue
    printf 'kilo\x1f%s\x1f%s\x1f%s\x1f%s\x1f{}\n' \
      "$name" "$(host_of "$base" "$name")" "$(fp "$pkey")" "kilo:kilo.jsonc[$name]"
  done < <(jq -r '.provider // {} | to_entries[]
                  | [.key, (.value.options.apiKey // ""), (.value.options.baseURL // "")]
                  | join("\u001f")' "$KILO_CONFIG" 2>/dev/null)
}

# METERED agents: copilot and cursor route through an "Auto" model chosen by the
# vendor, so there is no model list to enumerate - each is one bucket with a
# single pseudo-model. Their free tiers are a DEPLETING ALLOWANCE rather than an
# unlimited free pool, so they are marked metered and are excluded from
# scheduling unless explicitly allowed. They cannot overspend into a bill
# (GitHub reports overage_permitted:false) - the cost of using them carelessly is
# exhausting a small monthly budget, not money.
identities_copilot() {
  have copilot || return 0
  local ident="anon" extra='{"metered":true}'
  if have gh; then
    local info
    info="$(gh api /copilot_internal/user 2>/dev/null || true)"
    if [[ -n "$info" ]]; then
      ident="$(fp "$(printf '%s' "$info" | jq -r '.login // ""')")"
      extra="$(printf '%s' "$info" | jq -c '{metered:true,
        plan: .access_type_sku,
        renews: .quota_reset_date,
        overage_permitted: (.quota_snapshots.chat.overage_permitted // false),
        credits_remaining: (.quota_snapshots.chat.remaining // null),
        credits_entitlement: (.quota_snapshots.chat.entitlement // null)}' 2>/dev/null || echo '{"metered":true}')"
    fi
  fi
  printf 'copilot\x1fcopilot\x1fcopilot\x1f%s\x1f%s\x1f%s\n' \
    "$ident" "copilot:github" "$extra"
}

identities_cursor() {
  have cursor-agent || return 0
  local ident="anon" who
  who="$(timeout 20 cursor-agent status 2>/dev/null | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | head -1 || true)"
  [[ -n "$who" ]] && ident="$(fp "$who")"
  printf 'cursor\x1fcursor\x1fcursor\x1f%s\x1f%s\x1f{"metered":true}\n' \
    "$ident" "cursor:status"
}

collect_identities() {
  identities_opencode
  identities_hermes
  identities_kilo
  identities_copilot
  identities_cursor
}

# ------------------------------------------------------------------- models --

blocked() {
  local m="$1" b
  for b in $BLOCKLIST; do [[ "$m" == "$b" ]] && return 0; done
  return 1
}

# opencode/kilo: `<cli> models --verbose` emits "id" then a JSON object.
models_from_verbose() { # $1=cli  -> provider<TAB>model_arg<TAB>upstream<TAB>free
  local cli="$1" raw
  raw="${TEMP_DIR}/${cli}.verbose"
  timeout 120 "$cli" models --verbose >"$raw" 2>/dev/null || return 0
  awk '/^[^ {}]/ {if (id!="") {print id "\x1f" buf; buf=""} id=$0; next} {buf=buf $0}
       END {if (id!="") print id "\x1f" buf}' "$raw" \
  | while IFS=$'\x1f' read -r id json; do
      [[ -z "$id" ]] && continue
      blocked "$id" && continue
      local provider upstream free ctx maxout
      provider="$(printf '%s' "$json" | jq -r '.providerID // empty' 2>/dev/null)"
      upstream="$(printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null)"
      free="$(printf '%s' "$json" | jq -r '
                if (.cost.input // 1) == 0 and (.cost.output // 1) == 0
                then "true" else "false" end' 2>/dev/null)"
      # Already in the JSON we parse; previously discarded. A model too small to
      # hold a real task, or that cannot emit a whole file, fails every time it
      # is drawn - and each draw costs a request on the resource that is scarce.
      ctx="$(printf '%s' "$json" | jq -r '.limit.context // 0' 2>/dev/null)"
      maxout="$(printf '%s' "$json" | jq -r '.limit.output // 0' 2>/dev/null)"
      [[ -z "$provider" || -z "$upstream" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t\n' \
        "$provider" "$id" "$upstream" "${free:-false}" "${ctx:-0}" "${maxout:-0}"
    done
}

# hermes reaches several gateways. Emit (provider, token, base_url) triples from
# BOTH sources: OAuth entries carry their own token; env-var-backed entries carry
# only a base_url and point at a key in ~/.hermes/.env.
hermes_endpoints() { # -> provider<TAB>token<TAB>base_url
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

# Ask each gateway what THIS credential can actually see, and use whichever free
# signal that gateway publishes:
#   isFree            authoritative when present (kilo gateway)
#   pricing == 0      OpenAI-style catalogues
#   ":free" suffix    naming convention; last resort (nous prices nothing)
# Pricing alone is not enough - the kilo gateway reports "-1" for models whose
# price is dynamic, which would read as non-zero and hide genuinely free models.
models_hermes() { # -> provider<TAB>model_arg<TAB>upstream<TAB>free
  have hermes || return 0
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
           | @tsv' "$out" 2>/dev/null
  done < <(hermes_endpoints)
}

# ------------------------------------------------------------------- probing --

# Invoke one model through one agent. Echoes output, returns rc.
# stdin is closed: these CLIs read stdin, and would otherwise drain the caller's
# loop input (a read-loop over probes would run exactly once).
# NOTE: exit codes are unreliable (hermes returns 0 on HTTP 404 and on billing
# refusal), so callers MUST classify on content, not on rc alone.
invoke() { # $1=agent $2=model_arg $3=prompt $4=provider(optional)
  local agent="$1" model="$2" prompt="$3" provider="${4:-}" rc=0 out=""
  case "$agent" in
    opencode) out="$(timeout "$PROBE_TIMEOUT" opencode run -m "$model" "$prompt" </dev/null 2>&1)" || rc=$? ;;
    kilo)     out="$(timeout "$PROBE_TIMEOUT" kilo run -m "$model" --auto "$prompt" </dev/null 2>&1)" || rc=$? ;;
    hermes)
      # hermes resolves a bare -m against its ACTIVE provider only, so a model
      # from any other configured gateway 404s unless --provider names it.
      if [[ -n "$provider" ]]; then
        out="$(timeout "$PROBE_TIMEOUT" hermes --provider "$provider" -m "$model" -z "$prompt" </dev/null 2>&1)" || rc=$?
      else
        out="$(timeout "$PROBE_TIMEOUT" hermes -m "$model" -z "$prompt" </dev/null 2>&1)" || rc=$?
      fi
      ;;
    *) return 3 ;;
  esac
  printf '%s' "$out"
  return $rc
}

probe_one() { # $1=agent $2=model_arg $3=provider -> "state<TAB>ms"
  local agent="$1" model="$2" provider="${3:-}" out rc=0 t0 t1
  t0=$(date +%s%3N)
  out="$(invoke "$agent" "$model" "$PROBE_PROMPT" "$provider")" || rc=$?
  t1=$(date +%s%3N)
  printf '%s\t%s\n' "$(classify "$rc" "$out")" "$((t1 - t0))"
}

# ------------------------------------------------------------------ commands --

cmd_identify() {
  local rows; rows="$(collect_identities)"
  [[ -z "$rows" ]] && die "no agents or credentials found"
  # Apply the SAME canonical-wallet rule discover uses, so what is printed here
  # is the bucket id that will actually exist. These drifted apart once already;
  # a listing that disagrees with the registry is worse than no listing.
  local canon; canon="$(printf '%s\n' "$rows" \
    | awk -F'\x1f' '$4 != "anon" { if (length($3) > length(best[$4])) best[$4]=$3 }
                     END { for (k in best) print k "\x1f" best[k] }')"
  printf '%s\n' "$rows" | while IFS=$'\x1f' read -r agent lp wallet ident source extra; do
    local w="$wallet"
    if [[ "$ident" != "anon" ]]; then
      local c; c="$(printf '%s\n' "$canon" | awk -F'\x1f' -v k="$ident" '$1==k{print $2}')"
      [[ -n "$c" ]] && w="$c"
    fi
    printf '%-9s %-12s bucket=%-30s source=%s\n' \
      "$agent" "$lp" "${w}:${ident}" "$source"
  done
}

cmd_discover() {
  # One identify pass, reused: it names both the credentials and the agents this
  # discovery actually looked at, which is what staleness is measured against.
  local _ident; _ident="$(cmd_identify 2>/dev/null || true)"

  local do_probe=0
  [[ "${1:-}" == "--probe" ]] && do_probe=1

  mkdir -p "$STATE_DIR"
  local idfile="${TEMP_DIR}/ids.tsv" modfile="${TEMP_DIR}/models.tsv"
  collect_identities > "$idfile"
  [[ -s "$idfile" ]] || die "no agents or credentials found"

  : > "$modfile"
  if have opencode; then
    models_from_verbose opencode | sed 's/^/opencode\t/' >> "$modfile" || true
  fi
  if have kilo; then
    models_from_verbose kilo | sed 's/^/kilo\t/' >> "$modfile" || true
  fi
  if have hermes; then
    models_hermes | sed 's/^/hermes\t/' >> "$modfile" || true
  fi
  # Auto-routed agents expose no model list - the vendor picks per request. One
  # pseudo-model each, so the scheduler has something to address.
  # Vendor-routed: no model list, no published context. Unknown is kept.
  have copilot      && printf 'copilot\tcopilot\tauto\tauto\ttrue\t0\t0\t\n' >> "$modfile"
  have cursor-agent && printf 'cursor\tcursor\tauto\tauto\ttrue\t0\t0\t\n' >> "$modfile"
  log "identities: $(wc -l < "$idfile"), model rows: $(wc -l < "$modfile")"

  # Join models to buckets by (agent, provider). A model with no matching
  # credential is a PHANTOM ROUTE - advertised by the CLI but unreachable -
  # and is recorded as such rather than silently entering the schedulable set.
  jq -Rn \
    --slurpfile prev "$( [[ -f "$REGISTRY" ]] && echo "$REGISTRY" || echo /dev/null )" \
    --rawfile ids "$idfile" --rawfile models "$modfile" '
    def tsv($s): $s | split("\n") | map(select(length>0) | split("\u001f"));

    (tsv($ids)  | map({agent:.[0], provider:.[1], wallet:.[2], ident:.[3],
                       source:.[4], extra:(.[5] // "{}" | fromjson)})) as $ids
  | ($models | split("\n") | map(select(length>0) | split("\t"))
      | map({agent:.[0], provider:.[1], model_arg:.[2],
             upstream:.[3], free:(.[4]=="true"),
             context:((.[5] // "0")|tonumber? // 0),
             max_output:((.[6] // "0")|tonumber? // 0),
             modality:(.[7] // "")})) as $models
  | ($ids | map({key:(.agent+"|"+.provider), value:.}) | from_entries) as $byap

  # CANONICAL WALLET NAME PER FINGERPRINT.
  # The same credential can be described differently by different agents:
  # the opencode auth.json calls it "openrouter" (no base URL to derive a host
  # from), while kilo reports the host "openrouter.ai". Identical fingerprints
  # would then land in different namespaces and NOT collapse - defeating the one
  # guarantee this design exists to provide, that a shared key is one lane.
  # So every fingerprint gets a single canonical name: the most specific one
  # seen (longest, which is the host form when a host is known).
  # "anon" is excluded - it means "no credential", and two unauthenticated
  # gateways are NOT the same wallet.
  # The context and modality of a model belong to the MODEL, not to whichever
  # wallet lists it. One source may publish them and another not: the kilo
  # verbose listing gives no context for its openai provider, while the same
  # model on the kilocode gateway reports 65K. Without pooling, the identical
  # model is filtered on one lane and schedulable on another.
  | ($models | group_by(.upstream)
      | map({ key: .[0].upstream,
              value: { context:    (map(.context)    | max),
                       max_output: (map(.max_output) | max),
                       modality:   (map(.modality) | map(select(. != "")) | first // "") } })
      | from_entries) as $meta

  | ($ids | group_by(.ident)
      | map({ key: .[0].ident,
              value: (if .[0].ident == "anon" then null
                      else (map(.wallet) | unique | sort_by(length) | last) end) })
      | from_entries) as $canon
  | ($prev[0].buckets // {}) as $old

  | ($models | map(select($byap[.agent+"|"+.provider] == null))) as $phantom
  | ($models | map(select($byap[.agent+"|"+.provider] != null))) as $real

  | ($real | group_by($byap[.agent+"|"+.provider]
                      | (($canon[.ident] // .wallet) + ":" + .ident))
      | map(
          ($byap[.[0].agent+"|"+.[0].provider]) as $id
        | (($canon[$id.ident] // $id.wallet) + ":" + $id.ident) as $bid
        | { key: $bid,
            value: {
              id: $bid,
              provider: ($canon[$id.ident] // $id.wallet),
              local_providers: ([.[].provider] | unique),
              credential_fp: $id.ident,
              credential_sources: ([.[] | $byap[.agent+"|"+.provider].source] | unique),
              reachable_via: ([.[].agent] | unique),
              preferred_agent: ([.[].agent] | unique | .[0]),
              limits: ($id.extra.limits // {}),
              metered: ($id.extra.metered // false),
              meter: ($id.extra | del(.limits, .metered) | if length > 0 then . else null end),
              health: ($old[$bid].health //
                       {state:"unknown", consecutive_failures:0, cooldown_until:null}),
              models: ([ .[] | . as $m | {
                  upstream: $m.upstream,
                  free: $m.free,
                  context: (if $m.context > 0 then $m.context else ($meta[$m.upstream].context // 0) end),
                  max_output: (if $m.max_output > 0 then $m.max_output else ($meta[$m.upstream].max_output // 0) end),
                  modality: (if $m.modality != "" then $m.modality else ($meta[$m.upstream].modality // "") end),
                  # A vendor router works, but the model behind it changes per
                  # request - so it can never be ranked, only tolerated.
                  router: ($m.upstream | test("(^|/)auto(-beta)?$|^kilo-auto/|^openrouter/auto")),
                  seed_tier: ($seed[$m.upstream].tier // null),
                  # First rule that fires wins. Unknown context is KEPT.
                  suitable: (
                    ($meta[$m.upstream] // {}) as $x
                    | (if $m.modality != "" then $m.modality else ($x.modality // "") end) as $mod
                    | (if $m.context > 0 then $m.context else ($x.context // 0) end) as $ctx
                    | if ($mod != "" and ($mod | test("text") | not)) then false
                    elif ($m.upstream | test($nontext)) then false
                    elif ($m.upstream | test("content-safety|guard|moderation|embedding|^embed|rerank")) then false
                    elif ($ctx > 0 and $ctx < ($floor|tonumber)) then false
                    else true end),
                  unsuitable_reason: (
                    ($meta[$m.upstream] // {}) as $x
                    | (if $m.modality != "" then $m.modality else ($x.modality // "") end) as $mod
                    | (if $m.context > 0 then $m.context else ($x.context // 0) end) as $ctx
                    | if ($mod != "" and ($mod | test("text") | not)) then "non_text_output"
                    elif ($m.upstream | test($nontext)) then "non_text_output"
                    elif ($m.upstream | test("content-safety|guard|moderation|embedding|^embed|rerank")) then "not_a_generalist"
                    elif ($ctx > 0 and $ctx < ($floor|tonumber)) then "context_too_small"
                    else null end),
                  routes: [{agent:$m.agent, model_arg:$m.model_arg,
                            provider:$m.provider}],
                  probe: (($old[$bid].models // []
                           | map(select(.upstream == $m.upstream)) | .[0].probe)
                          // {state:"unprobed", at:null, ms:null})
                } ] | group_by(.upstream)
                    | map(.[0] + {routes: (map(.routes[0]) | unique)}) )
            } } ) | from_entries) as $buckets

  | { schema: 2,
      generated_at: (now | todate),
      context_floor: ($floor|tonumber),
      # Every credential this pass LOOKED at, including the ones that reached no
      # model and so produced no bucket. Without this a genuinely new key is
      # indistinguishable from a known-empty one, and staleness checks either
      # cry wolf forever or never fire at all.
      identified: $identified,
      # Every agent this pass INSPECTED - installed-but-unauthenticated included,
      # since "looked, found no key" is a finding, not an omission. An agent
      # missing from here has never been looked at, and only that warrants a
      # refresh; one present but on no route was looked at and reached nothing,
      # which refreshing will not change.
      examined_agents: $examined,
      buckets: $buckets,
      phantom_routes: ($phantom | map({agent, provider, model_arg})),
      counts: {
        buckets: ($buckets | length),
        free_models: ([$buckets[].models[] | select(.free)] | length),
        usable_models: ([$buckets[].models[] | select(.free and .suitable)] | length),
        phantom: ($phantom | length)
      } }
  ' --arg floor "$CONTEXT_FLOOR" --arg nontext "$NONTEXT_FAMILIES" \
    --argjson identified "$(printf '%s\n' "$_ident" \
        | grep -oE 'bucket=[^ ]+' | sed 's/bucket=//' | sort -u | jq -R . | jq -sc . )" \
    --argjson examined "$( { printf '%s\n' "$_ident" | awk 'NF{print $1}'
        for _a in opencode kilo hermes copilot cursor; do
          command -v "$_a" >/dev/null 2>&1 && printf '%s\n' "$_a"
        done; } | sort -u | jq -R . | jq -sc . )" \
    --argjson seed "$( [[ -f "$MODEL_SEED" ]] \
        && jq -c 'with_entries(select(.key | startswith("_") | not))' "$MODEL_SEED" 2>/dev/null \
        || echo '{}' )" \
    > "${REGISTRY}.tmp" || die "failed to build registry"

  mv "${REGISTRY}.tmp" "$REGISTRY"
  log "wrote ${REGISTRY}"

  [[ $do_probe -eq 1 ]] && cmd_probe
  return 0
}

# Prove liveness.
#   default        walk each bucket's free models until one answers (max
#                  $LIVENESS_TRIES). One bad model must not leave a good wallet
#                  looking dead, so a hang moves to the next candidate.
#   --all          probe every free model (slow; full refresh)
#   --bucket ID    restrict to one bucket
LIVENESS_TRIES="${LIVENESS_TRIES:-3}"

record_probe() { # $1=bucket $2=model_arg $3=state $4=ms
  local bid="$1" model="$2" state="$3" ms="$4"
  # A local_network result is our fault, not the model's - never record it.
  [[ "$state" == "local_network" ]] && { log "  network fault - not recorded"; return; }
  jq --arg b "$bid" --arg u "$model" --arg s "$state" --argjson ms "${ms:-0}" '
    .buckets[$b].models |= map(
      if ([.routes[].model_arg] | index($u)) != null
      then .probe = {state:$s, at:(now|todate), ms:$ms} else . end)
    | .buckets[$b].health |=
        (if $s == "ok" then {state:"ok", consecutive_failures:0, cooldown_until:null}
         # Only bucket-attributable signals may condemn the whole wallet.
         # Keep this list in sync with is_bucket_fault() in lib/classify.sh -
         # jq cannot call it, so it is restated here. Anything not listed
         # (timeout, dead, provider_error) demotes the MODEL only.
         elif ($s == "rate_limited" or $s == "no_credits" or $s == "auth_error")
         then {state:$s, consecutive_failures:((.consecutive_failures//0)+1),
               cooldown_until:null}
         # timeout/dead demote the MODEL; the bucket keeps its prior state.
         else . end)
  ' "$REGISTRY" > "${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "$REGISTRY"
}

# Free models of a bucket, reachable through its preferred agent, best-known first.
candidates() { # $1=bucket_id
  jq -r --arg b "$1" '.buckets[$b] as $bk
    | $bk.models[] | select(.free)
    | . as $m
    | ($m.routes[] | select(.agent == $bk.preferred_agent)) as $r
    | [ (if $m.probe.state == "ok" then 0
         elif $m.probe.state == "unprobed" then 1
         elif $m.probe.state == "timeout" then 3
         else 2 end), $r.model_arg, ($r.provider // "") ] | @tsv' "$REGISTRY" \
    | sort -n | cut -f2,3
}

cmd_probe() {
  local all=0 only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)    all=1; shift ;;
      --bucket) only="${2:-}"; shift 2 ;;
      *) die "probe: unknown option $1" ;;
    esac
  done
  [[ -f "$REGISTRY" ]] || die "no registry; run: $0 discover"

  local bids bid agent state ms live=0 tried model
  bids="$(jq -r --arg o "$only" '.buckets | keys[] | select($o == "" or . == $o)' "$REGISTRY")"
  [[ -n "$bids" ]] || die "no such bucket: $only"

  for bid in $bids; do
    agent="$(jq -r --arg b "$bid" '.buckets[$b].preferred_agent' "$REGISTRY")"
    tried=0
    while IFS=$'\t' read -r model provider; do
      [[ -z "$model" ]] && continue
      if [[ $all -eq 0 && $tried -ge $LIVENESS_TRIES ]]; then break; fi
      tried=$((tried+1))
      IFS=$'\t' read -r state ms < <(probe_one "$agent" "$model" "$provider")
      log "$(printf '%-26s %-8s %-46s %-14s %sms' "$bid" "$agent" "$model" "$state" "$ms")"
      record_probe "$bid" "$model" "$state" "$ms"
      if [[ "$state" == "ok" ]]; then
        live=1
        [[ $all -eq 0 ]] && break   # wallet proven; stop spending quota on it
      fi
      # A limited/refused wallet fails identically on every model - stop early.
      if [[ $all -eq 0 && ( "$state" == "no_credits" || "$state" == "auth_error" \
                         || "$state" == "rate_limited" ) ]]; then
        log "  bucket-level failure - skipping remaining models"
        break
      fi
    done < <(candidates "$bid")
  done

  [[ $live -eq 1 ]] || { log "no bucket answered"; return 2; }
  return 0
}

# Cheap, offline answer to "how many independent lanes do I have right now?"
# The coordinator consults this BEFORE deciding to fan out, so it must never
# touch the network - it reads recorded health only.
cmd_lanes() {
  [[ -f "$REGISTRY" ]] || { echo 0; return 0; }
  local now; now="$(now_epoch)"
  local n
  n="$(registry_read '[ .buckets[]
        | select($metered == "1" or (.metered // false) == false)
        | select((.health.cooldown_until // 0) <= ($now|tonumber))
        | select(.health.state != "no_credits" and .health.state != "auth_error")
        | select([.models[] | select(.free)
                  | select((.cooldown_until // 0) <= ($now|tonumber))] | length > 0)
      ] | length' --arg now "$now" --arg metered "${FA_ALLOW_METERED:-0}")"
  if [[ "${1:-}" == "-v" ]]; then
    printf 'healthy lanes: %s\n' "$n"
    # Same predicate as the count, so the listing can never disagree with it.
    registry_read '.buckets[]
      | . as $b
      | ([$b.models[] | select(.free)
          | select((.cooldown_until // 0) <= ($now|tonumber))] | length) as $usable
      | (($b.health.cooldown_until // 0) <= ($now|tonumber)
         and $b.health.state != "no_credits" and $b.health.state != "auth_error"
         and ($metered == "1" or ($b.metered // false) == false)
         and $usable > 0) as $live
      | ([$b.models[] | select(.free and .suitable == false)] | group_by(.unsuitable_reason)
         | map("\(length) \(.[0].unsuitable_reason)") | join(" · ")) as $cut
      | ([$b.models[] | select(.free and .suitable != false)] | length) as $ok
      | "  \(if $live then "LANE    " elif ($b.metered // false) then "metered " else "unusable" end) \($b.id)  \($b.preferred_agent)  \($ok) usable\(if $cut != "" then " (\($cut) filtered)" else "" end)  health=\($b.health.state)"' \
      --arg now "$now" --arg metered "${FA_ALLOW_METERED:-0}"
  else
    printf '%s\n' "$n"
  fi
}

cmd_show() {
  [[ -f "$REGISTRY" ]] || die "no registry; run: $0 discover"
  jq -r '
    "registry: \(.generated_at)   buckets=\(.counts.buckets)  free_models=\(.counts.free_models)  phantom=\(.counts.phantom)",
    "",
    (.buckets | to_entries[] | .value as $b |
      "\($b.id)",
      "   health=\($b.health.state)   agents=\($b.reachable_via | join(","))   preferred=\($b.preferred_agent)",
      "   free models: \([$b.models[] | select(.free)] | length)   probed ok: \([$b.models[] | select(.probe.state=="ok")] | length)",
      (if ($b.limits | length) > 0 then "   limits: \($b.limits | to_entries | map("\(.key)=\(.value)") | join(" "))" else empty end),
      (if ($b.metered // false) then
        "   METERED - a depleting monthly allowance, not an unlimited pool. Off unless FA_ALLOW_METERED=1, and always tried last."
        + (if $b.meter.credits_remaining != null then
             "\n   credits: \($b.meter.credits_remaining)/\($b.meter.entitlement // $b.meter.credits_entitlement) - renews \($b.meter.renews // "?") - overage \(if $b.meter.overage_permitted then "PERMITTED" else "blocked (it stops, it cannot bill you)" end)"
           else "" end)
       else empty end),
      (if ($b.reachable_via | length) > 1 then
        "   ** SHARED WALLET: \($b.reachable_via | join(" + ")) hit the same credential - ONE lane, never run them in parallel **"
       else empty end),
      ""),
    (if (.phantom_routes | length) > 0 then
      "phantom routes (advertised but no credential - NOT schedulable):",
      (.phantom_routes | group_by(.agent+"/"+.provider)
        | .[] | "   \(.[0].agent)/\(.[0].provider): \(length) models")
     else empty end)
  ' "$REGISTRY"
}

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <command>

  identify            show credential identities (no network)
  discover [--probe]  build the registry from real credentials + model lists
  probe [--all]       prove reachability (default: one free model per bucket)
  show                human-readable summary

state: ${REGISTRY}
EOF
  exit 3
}

case "${1:-}" in
  identify) shift; cmd_identify "$@" ;;
  lanes)    shift; cmd_lanes "$@" ;;
  discover) shift; cmd_discover "$@" ;;
  probe)    shift; cmd_probe "$@" ;;
  show)     shift; cmd_show "$@" ;;
  *) usage ;;
esac
