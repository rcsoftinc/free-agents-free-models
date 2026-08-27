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

STATE_DIR="${FREE_AGENTS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/free-agents}"
REGISTRY="${STATE_DIR}/buckets.json"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-90}"
PROBE_PROMPT='reply with exactly: OK'

OPENCODE_AUTH="${OPENCODE_AUTH:-$HOME/.local/share/opencode/auth.json}"
HERMES_AUTH="${HERMES_AUTH:-$HOME/.hermes/auth.json}"
HERMES_CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"
KILO_DB="${KILO_DB:-$HOME/.local/share/kilo/kilo.db}"

# Models that are reachable but pathological (hang instead of erroring, so they
# burn a full attempt timeout on every try). Kept out of the registry entirely.
BLOCKLIST_DEFAULT="opencode/big-pickle opencode/mimo-v2.5-free"
BLOCKLIST="${BUCKETS_BLOCKLIST:-$BLOCKLIST_DEFAULT}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

log()  { printf '[buckets] %s\n' "$*" >&2; }
die()  { printf '[buckets] ERROR: %s\n' "$*" >&2; exit 3; }
have() { command -v "$1" >/dev/null 2>&1; }

have jq   || die "jq is required"
have curl || die "curl is required"

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
# Each line: agent<TAB>provider<TAB>identity_fp<TAB>source<TAB>extra_json

identities_opencode() {
  have opencode || return 0
  [[ -f "$OPENCODE_AUTH" ]] || return 0
  local provider key
  while IFS=$'\t' read -r provider key; do
    [[ -z "$provider" ]] && continue
    printf 'opencode\t%s\t%s\t%s\t{}\n' \
      "$provider" "$(fp "$key")" "opencode:auth.json"
  done < <(jq -r 'to_entries[]
                  | [.key, (.value.key // .value.apiKey // .value.access // "")]
                  | @tsv' "$OPENCODE_AUTH" 2>/dev/null)
}

identities_hermes() {
  have hermes || return 0
  [[ -f "$HERMES_AUTH" ]] || return 0
  local provider tok subj ident base limits
  while IFS=$'\t' read -r provider tok base; do
    [[ -z "$provider" ]] && continue
    # OAuth access tokens rotate hourly - identify by the subject they carry.
    subj="$(jwt_subject "$tok" || true)"
    ident="$(fp "${subj:-$tok}")"
    limits="$(jwt_limits "$tok")"
    printf 'hermes\t%s\t%s\t%s\t%s\n' \
      "$provider" "$ident" "hermes:auth.json" \
      "$(jq -cn --arg b "$base" --argjson l "$limits" '{base_url:$b, limits:$l}')"
  done < <(jq -r '.credential_pool // {} | to_entries[]
                  | . as $e | ($e.value[0] // {})
                  | [$e.key,
                     (.access_token // .api_key // ""),
                     (.inference_base_url // "")]
                  | @tsv' "$HERMES_AUTH" 2>/dev/null)
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
  # kilo keeps credentials in sqlite; an empty store means the gateway is
  # serving this machine unauthenticated, which is still a distinct wallet.
  if [[ -f "$KILO_DB" ]] && have sqlite3; then
    key="$(sqlite3 "$KILO_DB" \
      "SELECT COALESCE(access_token,'') FROM account LIMIT 1;" 2>/dev/null || true)"
  fi
  printf 'kilo\tkilo\t%s\t%s\t{}\n' "$(fp "$key")" \
    "$([[ -n "$key" ]] && echo 'kilo:kilo.db' || echo 'kilo:unauthenticated')"
}

collect_identities() {
  identities_opencode
  identities_hermes
  identities_kilo
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
      local provider upstream free
      provider="$(printf '%s' "$json" | jq -r '.providerID // empty' 2>/dev/null)"
      upstream="$(printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null)"
      free="$(printf '%s' "$json" | jq -r '
                if (.cost.input // 1) == 0 and (.cost.output // 1) == 0
                then "true" else "false" end' 2>/dev/null)"
      [[ -z "$provider" || -z "$upstream" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$provider" "$id" "$upstream" "${free:-false}"
    done
}

# hermes/nous: ask the inference API what this credential can actually see.
models_hermes() { # -> provider<TAB>model_arg<TAB>upstream<TAB>free
  [[ -f "$HERMES_AUTH" ]] || return 0
  local provider tok base out
  while IFS=$'\t' read -r provider tok base; do
    [[ -z "$provider" || -z "$tok" || -z "$base" ]] && continue
    out="${TEMP_DIR}/hermes.${provider}.models"
    curl -sS --max-time 45 -H "Authorization: Bearer ${tok}" \
      "${base%/}/models" -o "$out" 2>/dev/null || continue
    jq -e '.data' "$out" >/dev/null 2>&1 || continue
    # Free tier: only ":free" models are actually served on a $0 balance.
    jq -r --arg p "$provider" '.data[].id
           | select(test(":free$"))
           | [$p, ., ., "true"] | @tsv' "$out" 2>/dev/null
  done < <(jq -r '.credential_pool // {} | to_entries[]
                  | . as $e | ($e.value[0] // {})
                  | [$e.key, (.access_token // ""), (.inference_base_url // "")]
                  | @tsv' "$HERMES_AUTH" 2>/dev/null)
}

# ------------------------------------------------------------------- probing --

# Invoke one model through one agent. Echoes output, returns rc.
# stdin is closed: these CLIs read stdin, and would otherwise drain the caller's
# loop input (a read-loop over probes would run exactly once).
# NOTE: exit codes are unreliable (hermes returns 0 on HTTP 404 and on billing
# refusal), so callers MUST classify on content, not on rc alone.
invoke() { # $1=agent $2=model_arg $3=prompt
  local agent="$1" model="$2" prompt="$3" rc=0 out=""
  case "$agent" in
    opencode) out="$(timeout "$PROBE_TIMEOUT" opencode run -m "$model" "$prompt" </dev/null 2>&1)" || rc=$? ;;
    kilo)     out="$(timeout "$PROBE_TIMEOUT" kilo run -m "$model" --auto "$prompt" </dev/null 2>&1)" || rc=$? ;;
    hermes)   out="$(timeout "$PROBE_TIMEOUT" hermes -m "$model" -z "$prompt" </dev/null 2>&1)" || rc=$? ;;
    *) return 3 ;;
  esac
  printf '%s' "$out"
  return $rc
}

# Content-first classification. Returns one of:
#   ok | rate_limited | no_credits | auth_error | context_overflow |
#   local_network | timeout | dead
#
# local_network is NEVER attributable to a model or bucket and must not be
# written to any learning store - a failure we caused is not evidence.
classify() { # $1=rc $2=output
  local rc="$1" t; t="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$t" | grep -qE 'could not resolve host|name or service not known|network is unreachable|no route to host|connection refused|temporary failure in name resolution|ssl connect error|tls handshake'; then
    echo local_network; return
  fi
  if printf '%s' "$t" | grep -qE '429|rate.?limit|too many requests|temporarily rate-limited|try again later|in-flight requests'; then
    echo rate_limited; return
  fi
  if printf '%s' "$t" | grep -qE 'insufficient balance|model access is unavailable|subscribe or add credits|exceed your available credits|quota|billing|payment required|402'; then
    echo no_credits; return
  fi
  if printf '%s' "$t" | grep -qE 'unauthorized|forbidden|invalid api key|authentication|401|403'; then
    echo auth_error; return
  fi
  if printf '%s' "$t" | grep -qE 'context length|too large|maximum context|token limit exceeded'; then
    echo context_overflow; return
  fi
  if printf '%s' "$t" | grep -qE 'not found|does not exist|unknown model|unrecognized arguments|404'; then
    echo dead; return
  fi
  # 124 = timeout(1) killed it; 143 = SIGTERM. A hang is the model's fault, not
  # the bucket's - it demotes this model only.
  if [[ "$rc" == "124" || "$rc" == "143" ]]; then echo timeout; return; fi
  [[ "$rc" == "0" ]] && { echo ok; return; }
  echo dead
}

probe_one() { # $1=agent $2=model_arg -> "state<TAB>ms"
  local agent="$1" model="$2" out rc=0 t0 t1
  t0=$(date +%s%3N)
  out="$(invoke "$agent" "$model" "$PROBE_PROMPT")" || rc=$?
  t1=$(date +%s%3N)
  printf '%s\t%s\n' "$(classify "$rc" "$out")" "$((t1 - t0))"
}

# ------------------------------------------------------------------ commands --

cmd_identify() {
  local rows; rows="$(collect_identities)"
  [[ -z "$rows" ]] && die "no agents or credentials found"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r agent provider ident source extra; do
    printf '%-9s %-12s bucket=%-24s source=%s\n' \
      "$agent" "$provider" "${provider}:${ident}" "$source"
  done
}

cmd_discover() {
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
  log "identities: $(wc -l < "$idfile"), model rows: $(wc -l < "$modfile")"

  # Join models to buckets by (agent, provider). A model with no matching
  # credential is a PHANTOM ROUTE - advertised by the CLI but unreachable -
  # and is recorded as such rather than silently entering the schedulable set.
  jq -Rn \
    --slurpfile prev "$( [[ -f "$REGISTRY" ]] && echo "$REGISTRY" || echo /dev/null )" \
    --rawfile ids "$idfile" --rawfile models "$modfile" '
    def tsv($s): $s | split("\n") | map(select(length>0) | split("\t"));

    (tsv($ids)  | map({agent:.[0], provider:.[1], ident:.[2], source:.[3],
                       extra:(.[4] // "{}" | fromjson)})) as $ids
  | (tsv($models)| map({agent:.[0], provider:.[1], model_arg:.[2],
                        upstream:.[3], free:(.[4]=="true")})) as $models
  | ($ids | map({key:(.agent+"|"+.provider), value:.}) | from_entries) as $byap
  | ($prev[0].buckets // {}) as $old

  | ($models | map(select($byap[.agent+"|"+.provider] == null))) as $phantom
  | ($models | map(select($byap[.agent+"|"+.provider] != null))) as $real

  | ($real | group_by($byap[.agent+"|"+.provider].ident + "|" + .provider)
      | map(
          ($byap[.[0].agent+"|"+.[0].provider]) as $id
        | (.[0].provider + ":" + $id.ident) as $bid
        | { key: $bid,
            value: {
              id: $bid,
              provider: .[0].provider,
              credential_fp: $id.ident,
              credential_sources: ([.[] | $byap[.agent+"|"+.provider].source] | unique),
              reachable_via: ([.[].agent] | unique),
              preferred_agent: ([.[].agent] | unique | .[0]),
              limits: ($id.extra.limits // {}),
              health: ($old[$bid].health //
                       {state:"unknown", consecutive_failures:0, cooldown_until:null}),
              models: ([ .[] | . as $m | {
                  upstream: $m.upstream,
                  free: $m.free,
                  routes: [{agent:$m.agent, model_arg:$m.model_arg}],
                  probe: (($old[$bid].models // []
                           | map(select(.upstream == $m.upstream)) | .[0].probe)
                          // {state:"unprobed", at:null, ms:null})
                } ] | group_by(.upstream)
                    | map(.[0] + {routes: (map(.routes[0]) | unique)}) )
            } } ) | from_entries) as $buckets

  | { schema: 1,
      generated_at: (now | todate),
      buckets: $buckets,
      phantom_routes: ($phantom | map({agent, provider, model_arg})),
      counts: {
        buckets: ($buckets | length),
        free_models: ([$buckets[].models[] | select(.free)] | length),
        phantom: ($phantom | length)
      } }
  ' > "${REGISTRY}.tmp" || die "failed to build registry"

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
    | ($m.routes[] | select(.agent == $bk.preferred_agent) | .model_arg) as $arg
    | [ (if $m.probe.state == "ok" then 0
         elif $m.probe.state == "unprobed" then 1
         elif $m.probe.state == "timeout" then 3
         else 2 end), $arg ] | @tsv' "$REGISTRY" | sort -n | cut -f2
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
    while IFS= read -r model; do
      [[ -z "$model" ]] && continue
      if [[ $all -eq 0 && $tried -ge $LIVENESS_TRIES ]]; then break; fi
      tried=$((tried+1))
      IFS=$'\t' read -r state ms < <(probe_one "$agent" "$model")
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
  discover) shift; cmd_discover "$@" ;;
  probe)    shift; cmd_probe "$@" ;;
  show)     shift; cmd_show "$@" ;;
  *) usage ;;
esac
