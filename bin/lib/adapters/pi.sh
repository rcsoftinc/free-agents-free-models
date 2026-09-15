# pi.sh - adapter for the pi coding agent CLI.
#
# Identity: ~/.pi/agent/auth.json (api-key entries, e.g. openrouter, google).
# Models:   `pi --list-models` - space-aligned columns with human-readable sizes.
# Invoke:   pi --print, contained with --add-dir when a workdir is given.

PI_AUTH="${PI_AUTH:-$HOME/.pi/agent/auth.json}"

FA_pi_BINARY="pi"
FA_pi_METERED=0
FA_pi_VERIFIED_VERSION="0.85.1"
FA_pi_VERSION_BIN="pi"

# Convert human-readable sizes (1M, 128K) to numeric values
parse_size() {
  local val="$1"
  [[ -z "$val" ]] && { echo 0; return; }
  local num suffix
  num="$(echo "$val" | sed 's/[^0-9.]//g')"
  suffix="$(echo "$val" | sed 's/[0-9.]//g')"
  case "$suffix" in
    K|k) awk "BEGIN{printf \"%d\", $num * 1000}" ;;
    M|m) awk "BEGIN{printf \"%d\", $num * 1000000}" ;;
    *) echo "${num:-0}" ;;
  esac
}

pi_identify() { # -> identity rows (see buckets.sh for the schema)
  command -v pi >/dev/null 2>&1 || return 0
  [[ -f "$PI_AUTH" ]] || return 0
  local provider key
  while IFS=$'\x1f' read -r provider key; do
    [[ -z "$provider" ]] && continue
    printf 'pi\x1f%s\x1f%s\x1f%s\x1fpi:auth.json\x1f{}\n' \
      "$provider" "$provider" "$(fp "$key")"
  done < <(jq -r 'to_entries[] | [.key, (.value.key // .value.apiKey // .value.access // "")] | join("\u001f")' "$PI_AUTH" 2>/dev/null)
}

pi_models() { # -> model rows, agent-prefixed (see buckets.sh)
  command -v pi >/dev/null 2>&1 || return 0
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^provider ]] && continue
    local provider model ctx maxout thinking images
    read -r provider model ctx maxout thinking images <<<"$line"
    [[ -z "$provider" || -z "$model" ]] && continue
    [[ "$model" =~ ^~ ]] && continue
    local free="false"
    [[ "$model" =~ :free$ || "$model" =~ :batch$ ]] && free="true"
    ctx="$(parse_size "$ctx")"
    maxout="$(parse_size "$maxout")"
    printf 'pi\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$provider" "$model" "$model" "$free" "$ctx" "$maxout"
  done < <(pi --list-models 2>/dev/null | tail -n +2)
}

pi_invoke() { # $1=model $2=provider $3=prompt ; echoes output, returns rc
  local model="$1" prompt="$3" rc=0 out=""
  local t="${INVOKE_TIMEOUT:-${ATTEMPT_TIMEOUT:-${PROBE_TIMEOUT:-300}}}"
  if [[ -n "${FA_WORKDIR:-}" ]]; then
    out="$(timeout "$t" pi --add-dir "$FA_WORKDIR" --model "$model" --print "$prompt" </dev/null 2>&1)" || rc=$?
  else
    out="$(timeout "$t" pi --model "$model" --print "$prompt" </dev/null 2>&1)" || rc=$?
  fi
  printf '%s' "$out"
  return $rc
}