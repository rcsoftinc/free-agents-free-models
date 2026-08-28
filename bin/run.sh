#!/usr/bin/env bash
set -euo pipefail

# run.sh - THE dispatch engine. One task in, one result out, never blocked by a
# single rate limit.
#
# It walks a ranked chain of (bucket, model, agent) candidates until one answers.
# Everything the project needs from a fallback engine lives here, so there is one
# implementation and one learning store rather than three.
#
#   usage: run.sh [options] "prompt"
#          run.sh [options] -            # prompt on stdin
#
#   -c, --category NAME   coding | reasoning | research | general | fast
#   -w, --workdir DIR     run the agent in DIR (default: cwd)
#   -b, --bucket ID       pin to one bucket (used by the scheduler to hold a lane)
#   -x, --exclude ID      skip a bucket (repeatable)
#       --max-attempts N  default 6
#       --timeout SEC     per-attempt timeout (default 300)
#       --dry-run         print the candidate chain and exit
#
# Exit: 0 ok | 2 all candidates exhausted | 3 setup error | 4 network down
#       5 no lane available right now (every candidate wallet is in use) - the
#         caller should REQUEUE, not fail: nothing was tried and nothing is broken
#
# stdout is the agent's output. A machine-readable footer goes to stderr:
#   ---RUN-META--- {"bucket":...,"model":...,"agent":...,"attempts":N,"state":"ok"}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG=run
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"
# shellcheck source=lib/classify.sh
. "${HERE}/lib/classify.sh"

CATEGORY="general"
WORKDIR="$(pwd)"
PIN_BUCKET=""
EXCLUDES=()
MAX_ATTEMPTS="${MAX_ATTEMPTS:-6}"
ATTEMPT_TIMEOUT="${ATTEMPT_TIMEOUT:-300}"
DRY_RUN=0
PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--category) CATEGORY="$2"; shift 2 ;;
    -w|--workdir)  WORKDIR="$2"; shift 2 ;;
    -b|--bucket)   PIN_BUCKET="$2"; shift 2 ;;
    -x|--exclude)  EXCLUDES+=("$2"); shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --timeout)     ATTEMPT_TIMEOUT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '6,26p' "$0"; exit 0 ;;
    -)             PROMPT="$(cat)"; shift ;;
    -*)            die "unknown option: $1" ;;
    *)             PROMPT="$1"; shift ;;
  esac
done

# Flags contain WHERE the agent starts, but nothing stops a model from writing
# to an absolute path of its own choosing - observed: kilo, given --dir, wrote to
# "/gamma.txt". Stating the contract in the prompt is the cheap half of the fix;
# the other half is the caller VERIFYING the work landed (see bin/orch.sh).
workdir_preamble() {
  printf 'Your working directory is %s\nCreate and edit files only inside it, using paths relative to it. Do not use absolute paths.\n\n' "$1"
}

have jq    || die "jq is required"
have flock || die "flock is required"
[[ $DRY_RUN -eq 1 || -n "$PROMPT" ]] || die "no prompt given"
[[ -d "$WORKDIR" ]] || die "workdir does not exist: $WORKDIR"

LEASE_DIR="${STATE_DIR}/leases"
mkdir -p "$LEASE_DIR"

# ---------------------------------------------------------------- candidates --
# Ordering rules, in priority order:
#   1. skip buckets in cooldown (the breaker) and explicit excludes
#   2. prefer the least-recently-used bucket, so load spreads across wallets
#      instead of draining the best one first
#   3. within a bucket, prefer models with the best observed record
#
# Only free models are ever offered. A model whose own cooldown has not expired
# is skipped, which is how a hang demotes one endpoint without touching its wallet.
candidates() {
  local now; now="$(now_epoch)"
  local ex_json; ex_json="$(printf '%s\n' "${EXCLUDES[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')"
  registry_read '
    [ .buckets[]
      | select(($pin == "") or (.id == $pin))
      | select((.health.cooldown_until // 0) <= ($now|tonumber))
      | select((.id | IN($ex[])) | not)
      | . as $b
      | .models[]
      | select(.free)
      | select((.cooldown_until // 0) <= ($now|tonumber))
      | . as $m
      | ($m.routes[] | select(.agent == $b.preferred_agent)) as $r
      | { bucket: $b.id,
          agent:  $r.agent,
          model:  $r.model_arg,
          provider: ($r.provider // ""),
          bucket_last_used: ($b.health.last_used // 0),
          score: ( ($m.stats.ok // 0) - 2 * ($m.stats.fail // 0)
                   + (if $m.probe.state == "ok" then 5 else 0 end) ) }
    ]
    | sort_by(.bucket_last_used, -.score)
    | .[] | [.bucket, .agent, .model, .provider] | @tsv
  ' --arg pin "$PIN_BUCKET" --arg now "$now" --argjson ex "$ex_json"
}

# ------------------------------------------------------------------- leasing --
# ONE LANE PER BUCKET. Several agents may be able to reach a wallet, but they all
# spend the same quota, so a second concurrent task there buys no throughput and
# only races the first into a 429. The lease is held on the BUCKET, never on the
# agent or the model.
lease_acquire() { # $1=bucket -> 0 if we hold it
  local f="${LEASE_DIR}/$(printf '%s' "$1" | tr '/:' '__').lock"
  exec {LEASE_FD}>"$f" || return 1
  flock -n "$LEASE_FD" || { exec {LEASE_FD}>&-; LEASE_FD=""; return 1; }
  return 0
}
lease_release() {
  [[ -n "${LEASE_FD:-}" ]] || return 0
  flock -u "$LEASE_FD" 2>/dev/null || true
  # NOTE: no redirection may be attached to this `exec`. With no command, exec
  # applies its redirections to THE SHELL - `exec {FD}>&- 2>/dev/null` silences
  # the script's own stderr for the rest of the run, swallowing every log line,
  # the RUN-META footer, and even set -x output.
  exec {LEASE_FD}>&-
  LEASE_FD=""
}
trap lease_release EXIT

# ------------------------------------------------------------------ invoking --
# A route is (agent, model, PROVIDER). hermes resolves a bare -m against its
# active provider only, so omitting --provider turns every model from another
# gateway into a 404 that looks exactly like a dead model.
invoke() { # $1=agent $2=model $3=provider $4=prompt
  local agent="$1" model="$2" provider="$3" prompt="$4" rc=0 out=""
  # WORKDIR MUST BE PASSED EXPLICITLY. `cd` alone does not contain these agents:
  # kilo, launched from a temp dir with cwd set, still wrote its file to $HOME.
  # Each CLI has its own flag (opencode/kilo --dir, hermes --in) and that is the
  # only thing that actually decides where the agent works. This is defect B1,
  # and it is why an orchestrator run once left JWT_AUTH_GUIDE.md in this repo.
  case "$agent" in
    opencode)
      out="$(timeout "$ATTEMPT_TIMEOUT" opencode run --dir "$WORKDIR" -m "$model" "$prompt" \
        </dev/null 2>&1)" || rc=$? ;;
    kilo)
      out="$(timeout "$ATTEMPT_TIMEOUT" kilo run --dir "$WORKDIR" -m "$model" --auto "$prompt" \
        </dev/null 2>&1)" || rc=$? ;;
    hermes)
      # hermes honours NEITHER cwd NOR --in: it resolves relative paths against
      # $HOME, so both forms wrote to /root in testing. HOME is what actually
      # contains it - and HERMES_HOME keeps its config and credentials where they
      # really live, so nothing is symlinked into the user's project.
      local henv=(env "HOME=$WORKDIR" "HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}")
      if [[ -n "$provider" ]]; then
        out="$(timeout "$ATTEMPT_TIMEOUT" "${henv[@]}" hermes --provider "$provider" \
          -m "$model" --in "$WORKDIR" --yolo -z "$prompt" </dev/null 2>&1)" || rc=$?
      else
        out="$(timeout "$ATTEMPT_TIMEOUT" "${henv[@]}" hermes -m "$model" \
          --in "$WORKDIR" --yolo -z "$prompt" </dev/null 2>&1)" || rc=$?
      fi ;;
    *) return 3 ;;
  esac
  printf '%s' "$out"
  return $rc
}

# -------------------------------------------------------------------- record --
# The single write path into the learning store. Nothing else writes outcomes,
# and nothing at all is written for local_network.
record() { # $1=bucket $2=model $3=state $4=ms $5=output(optional)
  local bucket="$1" model="$2" state="$3" ms="$4" out="${5:-}" cd_secs until_ts=0 hint
  [[ "$state" == "local_network" ]] && return 0
  cd_secs="$(cooldown_for "$state")"
  # A window the provider stated itself beats our guess in both directions:
  # retrying sooner burns an attempt, retrying later idles a usable lane.
  hint="$(retry_after_secs "$out")"
  if [[ -n "$hint" && "$hint" -gt 0 ]]; then
    log "  provider asked for $((hint/60))m - using that instead of ${cd_secs}s"
    cd_secs="$hint"
  fi
  [[ "$cd_secs" -gt 0 ]] && until_ts=$(( $(now_epoch) + cd_secs ))

  local bucket_fault=false
  is_bucket_fault "$state" && bucket_fault=true

  registry_txn '
    .buckets[$b].health.last_used = ($now|tonumber)
  | .buckets[$b].models |= map(
      if ([.routes[].model_arg] | index($m)) != null then
        .probe = {state:$s, at:$at, ms:($ms|tonumber)}
      | .stats = ((.stats // {ok:0, fail:0})
                  | if $s == "ok" then .ok += 1 else .fail += 1 end)
      # A model cooldown parks one endpoint; it never touches the wallet.
      | .cooldown_until = (if ($fault|not) and $s != "ok" and ($until|tonumber) > 0
                           then ($until|tonumber) else (.cooldown_until // 0) end)
      else . end)
  | .buckets[$b].health |= (
      if $s == "ok" then
        {state:"ok", consecutive_failures:0, cooldown_until:0,
         last_used:($now|tonumber)}
      elif $fault then
        ((.consecutive_failures // 0) + 1) as $n
        | {state:$s, consecutive_failures:$n,
           # The breaker: one bad answer can be noise, a second from the same
           # wallet is the wallet. Tripping early is what turns "walk 20 models
           # to learn the account is limited" into two attempts.
           cooldown_until: (if $n >= ($trip|tonumber) then ($until|tonumber)
                            else (.cooldown_until // 0) end),
           last_used:($now|tonumber)}
      else . + {last_used:($now|tonumber)} end)
  ' --arg b "$bucket" --arg m "$model" --arg s "$state" --arg ms "$ms" \
    --arg at "$(iso_now)" --arg now "$(now_epoch)" --arg until "$until_ts" \
    --arg trip "${BREAKER_TRIP:-2}" --argjson fault "$bucket_fault"
}

# ---------------------------------------------------------------------- main --
mapfile -t CHAIN < <(candidates)
[[ ${#CHAIN[@]} -gt 0 ]] && [[ -n "${CHAIN[0]}" ]] || {
  log "no candidates: every bucket is in cooldown, excluded, or has no free models"
  exit 2
}

if [[ $DRY_RUN -eq 1 ]]; then
  printf '%s\n' "${CHAIN[@]}" | head -20 \
    | awk -F'\t' '{printf "%-28s %-9s %-46s %s\n", $1,$2,$3,$4}'
  echo "(${#CHAIN[@]} candidates)" >&2
  exit 0
fi

attempt=0
# Buckets written off for the rest of this run: either another task holds the
# lane, or the wallet itself answered with a bucket-level fault. Both are facts
# about the WALLET, so every remaining candidate on it is dead weight - walking
# its other 20 models would just re-learn the same thing 20 times.
declare -A SKIP=()

for row in "${CHAIN[@]}"; do
  [[ $attempt -ge $MAX_ATTEMPTS ]] && break
  IFS=$'\t' read -r bucket agent model provider <<<"$row"
  [[ -z "$bucket" ]] && continue
  [[ -n "${SKIP[$bucket]:-}" ]] && continue

  # Someone else is already using this wallet - move to another lane rather than
  # queueing, which is the whole point of having several.
  lease_acquire "$bucket" || { log "lane busy: $bucket"; SKIP[$bucket]=busy; continue; }

  attempt=$((attempt+1))
  t0=$(date +%s%3N); rc=0
  out="$(invoke "$agent" "$model" "$provider" \
          "$(workdir_preamble "$WORKDIR")$PROMPT")" || rc=$?
  t1=$(date +%s%3N); ms=$((t1-t0))
  state="$(classify "$rc" "$out")"

  # Our own network dying is not evidence about anyone's model. Confirm before
  # believing it, and never write it down.
  if [[ "$state" == "local_network" ]] || { [[ "$state" != "ok" ]] && ! network_up; }; then
    lease_release
    log "network appears down - not recording, and not blaming $model"
    network_up || { log "still offline; giving up without touching the store"; exit 4; }
    continue
  fi

  record "$bucket" "$model" "$state" "$ms" "$out"
  lease_release

  if [[ "$state" == "ok" ]]; then
    printf '%s\n' "$out"
    printf '%s %s\n' '---RUN-META---' \
      "$(jq -cn --arg b "$bucket" --arg m "$model" --arg a "$agent" \
              --arg p "$provider" --argjson n "$attempt" --argjson ms "$ms" \
              '{bucket:$b, model:$m, agent:$a, provider:$p, attempts:$n, ms:$ms, state:"ok"}')" >&2
    exit 0
  fi

  log "$(printf 'attempt %d: %-26s %-8s %-40s -> %s' "$attempt" "$bucket" "$agent" "$model" "$state")"
  if is_bucket_fault "$state"; then
    SKIP[$bucket]="$state"
    log "  ${bucket} is at fault (${state}) - skipping its remaining models"
  fi
done

# Nothing was actually attempted and every skip was contention: this task is not
# failing, it is waiting for a lane. Distinguishing the two is what lets the
# scheduler requeue instead of burning the task's retry budget on a busy moment.
if [[ $attempt -eq 0 ]]; then
  all_busy=1
  for b in "${!SKIP[@]}"; do [[ "${SKIP[$b]}" == "busy" ]] || all_busy=0; done
  if [[ ${#SKIP[@]} -gt 0 && $all_busy -eq 1 ]]; then
    log "no lane available (all candidate wallets in use)"
    printf '%s %s\n' '---RUN-META---' \
      "$(jq -cn '{attempts:0, state:"no_lane"}')" >&2
    exit 5
  fi
fi

log "exhausted after ${attempt} attempt(s)"
printf '%s %s\n' '---RUN-META---' \
  "$(jq -cn --argjson n "$attempt" '{attempts:$n, state:"exhausted"}')" >&2
exit 2
