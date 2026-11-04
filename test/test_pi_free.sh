#!/usr/bin/env bash
# Proves pi only counts OpenRouter's :free models as free.
#
# :batch is a half-price PAID tier, and pi_models once counted it as free: 40 paid
# models sat on a wallet's free list, first in its chain, where a task could have
# spent real money on the key. Only a provider error kept that from happening.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/harness.sh"
begin_suite "pi: what counts as free"
sandbox_on

rows="$(bash -c ". '$REPO/bin/lib/common.sh'; pi_models")"
free_of() { awk -F '\t' -v m="$1" '$3 == m {print $5}' <<<"$rows"; }

assert_eq ":free is free" "$(free_of qwen/qwen3-coder:free)" "true"
assert_eq ":batch is paid" "$(free_of anthropic/claude-opus-5.5:batch)" "false"
assert_eq "a plain model is paid" "$(free_of anthropic/claude-opus-paid)" "false"

end_suite
final_report
