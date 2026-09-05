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
#       --allow-metered   force-include metered wallets (copilot, cursor). They
#                         spend a small MONTHLY ALLOWANCE, not money - GitHub
#                         reports overage_permitted:false, so they stop rather
#                         than bill. Default (FA_METERED=auto) is to include them
#                         only when a token was detected and credits remain.
#                         When included they are tried LAST.
#       --no-metered      force-exclude metered wallets (FA_METERED=0)
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
# shellcheck source=lib/findings.sh
. "${HERE}/lib/findings.sh"

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
    --allow-metered) export FA_ALLOW_METERED=1; shift ;;
    --no-metered)    export FA_METERED=0; shift ;;
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

# A rough token estimate from character count. Deliberately crude: every runtime
# tokenises differently and most will not tell us in advance, so an approximation
# that is always available beats an exact figure that is usually missing.
# ~4 chars/token is the standard rule of thumb for English + code.
est_tokens() { local n=${#1}; printf '%s' "$(( (n + 3) / 4 ))"; }

# Oversized prompts are the usual upstream cause of context_overflow and of
# free-model calls that are mysteriously slow or wrong. One observed call in this
# project's own history sent ~31,875 input tokens without anyone noticing.
BLOAT_WARN_TOKENS="${BLOAT_WARN_TOKENS:-8000}"

have jq    || die "jq is required"
have flock || die "flock is required"
[[ $DRY_RUN -eq 1 || -n "$PROMPT" ]] || die "no prompt given"
[[ -d "$WORKDIR" ]] || die "workdir does not exist: $WORKDIR"

# The adapters apply each harness's own containment flag when they see a workdir.
export FA_WORKDIR="$WORKDIR"

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
  local metered_include; metered_include="$(metered_include_pred)"
  registry_read '
    [ .buckets[]
      | select(($pin == "") or (.id == $pin))
      | select((.health.cooldown_until // 0) <= ($now|tonumber))
      | select((.id | IN($ex[])) | not)
      # A metered wallet spends a small monthly allowance rather than an
      # unlimited free pool. In auto mode it appears only when a token was
      # detected and credits are not spent; it still sorts LAST (below) and is
      # marked, so it never crowds out genuinely free capacity.
      | select( '"$metered_include"' )
      | . as $b
      | .models[]
      | select(.free)
      # A model that cannot do the job at all - wrong modality, too little
      # context, a classifier rather than a generalist - is excluded before it
      # can waste a request. Records lacking the field (an older registry) are
      # kept, so an upgrade never silently empties a lane.
      | select(.suitable != false)
      | select((.cooldown_until // 0) <= ($now|tonumber))
      | . as $m
      | ($m.routes[] | select(.agent == $b.preferred_agent)) as $r
      | { bucket: $b.id,
          agent:  $r.agent,
          model:  $r.model_arg,
          provider: ($r.provider // ""),
          # Metered lanes sort AFTER every unmetered one, so an allowance is only
          # spent once the genuinely free capacity is busy or cold.
          metered: (if ($b.metered // false) then 1 else 0 end),
          bucket_last_used: ($b.health.last_used // 0),
          # Ranking is LEARNED from observed outcomes, per category. A model that
          # is good at coding is not automatically good at reasoning, and free
          # models vary wildly between the two. Evidence from THIS category counts
          # double; overall evidence still counts, so a model with no category
          # history is not stranded at the bottom forever.
          # Observed results dominate. The prior only decides the order of models
          # nothing is yet known about - which today is nearly all of them, since
          # a fresh registry has stats for none. Weights are set so ONE observed
          # success (+4) outranks the best possible prior: evidence beats opinion
          # the moment evidence exists.
          score: ( 4 * ( (($m.cat_stats[$cat].ok   // 0))
                       - 2 * (($m.cat_stats[$cat].fail // 0)) )
                   + 2 * ( (($m.stats.ok   // 0))
                         - 2 * (($m.stats.fail // 0)) )
                   + (if $m.probe.state == "ok" then 5 else 0 end)
                   # The prior applies ONLY to a model nothing is yet known
                   # about. Clamping it below the value of one success is not
                   # enough: the prior SPREAD between two models (+3 vs -3) can
                   # still offset an evidence gap. Gating it on "no stats at all"
                   # makes the rule exact - opinion orders the unknown, evidence
                   # orders everything else, and the two never compete.
                   + ( (if (($m.stats.ok // 0) + ($m.stats.fail // 0)
                            + ($m.cat_stats[$cat].ok // 0)
                            + ($m.cat_stats[$cat].fail // 0)) > 0
                        then 0 else 1 end)
                     * ( [ [ (if   ($m.context // 0) >= 400000 then 2
                            elif ($m.context // 0) >= 200000 then 1
                            else 0 end)
                         + (if ($m.max_output // 0) >= 32000 then 1 else 0 end)
                         + (if ($m.upstream | test("ultra|405b|550b|large|max")) then 2
                            elif ($m.upstream | test("nano|mini|small|tiny|[0-9]b\\b")) then -2
                            else 0 end)
                         + (if ($m.router // false) then -1 else 0 end)
                           + (($m.seed_tier // 1) - 1), 3 ] | min, -3 ] | max ) ) ) }
    ]
    | sort_by(.metered, .bucket_last_used, -.score)
    | .[] | [.bucket, .agent, .model, .provider] | @tsv
  ' --arg pin "$PIN_BUCKET" --arg now "$now" --argjson ex "$ex_json" \
    --arg cat "$CATEGORY"
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
# The invocation shape for each harness lives in the adapter list
# (bin/lib/adapters.sh) - the container flag, the timeout, the `--auto`/`--yolo`
# requirements are all per-adapter and all in one file per harness.
invoke() { # $1=agent $2=model $3=provider $4=prompt
  adapter_invoke "$@"
}

# -------------------------------------------------------------------- record --
# The single write path into the learning store. Nothing else writes outcomes,
# and nothing at all is written for local_network.
# NOTE on what counts as evidence: a bucket-level failure (rate limit, billing)
# says nothing about whether this model is good at this category, so it must not
# be scored against the model. Only ok / timeout / dead / provider_error do.
record() { # $1=bucket $2=model $3=state $4=ms $5=output(optional)
  local bucket="$1" model="$2" state="$3" ms="$4" out="${5:-}" cd_secs until_ts=0 hint
  [[ "$state" == "local_network" ]] && return 0
  # Pass the failure count so a first, possibly transient failure gets a short
  # window and only a repeatedly-failing wallet earns the long one.
  local nfail
  nfail="$(registry_read --arg b "$bucket" '(.buckets[$b].health.consecutive_failures // 0) + 1' 2>/dev/null || echo 1)"
  cd_secs="$(cooldown_for "$state" "$nfail")"
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
      | .stats = (if $fault then (.stats // {ok:0, fail:0})
                  else (.stats // {ok:0, fail:0})
                  | if $s == "ok" then .ok += 1 else .fail += 1 end end)
      | .cat_stats = (if $fault then (.cat_stats // {})
                      else ((.cat_stats // {})
                            | .[$cat] = ((.[$cat] // {ok:0, fail:0})
                                         | if $s == "ok" then .ok += 1 else .fail += 1 end)) end)
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
    --arg trip "${BREAKER_TRIP:-2}" --argjson fault "$bucket_fault" \
    --arg cat "$CATEGORY"
}

# ---------------------------------------------------------------------- main --
mapfile -t CHAIN < <(candidates)
[[ ${#CHAIN[@]} -gt 0 ]] && [[ -n "${CHAIN[0]}" ]] || {
  log "no candidates: every bucket is in cooldown, excluded, or has no free models"
  exit 2
}

if [[ $DRY_RUN -eq 1 ]]; then
  # DRY_RUN_LIMIT=0 shows the whole chain; the default keeps output readable
  # without hiding buckets, which once made `lanes` look inconsistent with it.
  lim="${DRY_RUN_LIMIT:-20}"
  if [[ "$lim" -eq 0 ]]; then printf '%s\n' "${CHAIN[@]}"
  else printf '%s\n' "${CHAIN[@]}" | head -n "$lim"; fi \
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
  full_prompt="$(workdir_preamble "$WORKDIR")$PROMPT"
  est="$(est_tokens "$full_prompt")"
  if [[ $attempt -eq 1 && "$est" -gt "$BLOAT_WARN_TOKENS" ]]; then
    log "prompt is large: ~${est} tokens (warn above ${BLOAT_WARN_TOKENS})."
    log "  a spec this size usually means a file listing leaked into it; workers"
    log "  are meant to receive a self-contained instruction, not context."
  fi
  t0=$(date +%s%3N); rc=0
  out="$(invoke "$agent" "$model" "$provider" "$full_prompt")" || rc=$?
  t1=$(date +%s%3N); ms=$((t1-t0))
  IFS=$'\t' read -r state matched <<<"$(classify_ex "$rc" "$out")"
  # Nothing in the taxonomy recognised this. It is still handled as dead - the
  # safe default - but the text is kept, because a silent default is how every
  # classification bug in this project stayed hidden.
  if [[ "$matched" == "no" && "$state" != "ok" ]]; then
    record_finding unclassified \
      "provider output that no taxonomy rule matched" "$out" \
      "model=$model" "provider=$provider" "assigned=$state" "rc=$rc"
  fi

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
              --argjson est "${est:-0}" \
              '{bucket:$b, model:$m, agent:$a, provider:$p, attempts:$n, ms:$ms,
                est_prompt_tokens:$est, state:"ok"}')" >&2
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

# Every healthy lane was tried and every one failed on this same task. A wallet
# fault would have moved us to the next lane and succeeded there; failing on all
# of them points at the task, not the credentials - usually a spec too big or too
# vague for a free model. That judgement is invisible in the journal, which
# records each attempt separately and never says "and none of them worked".
if [[ $attempt -gt 1 ]]; then
  record_finding all_lanes_failed \
    "every available lane failed on the same task" \
    "$(printf '%s' "$PROMPT" | head -c 300)" \
    "attempts=${attempt}" "prompt_tokens=${est:-?}" "category=${CATEGORY}" \
    "task=${FA_TASK_ID:-}"
fi

log "exhausted after ${attempt} attempt(s)"
printf '%s %s\n' '---RUN-META---' \
  "$(jq -cn --argjson n "$attempt" '{attempts:$n, state:"exhausted"}')" >&2
exit 2
