#!/usr/bin/env bash
# Passes only when the `changes` job succeeded and every other job either
# succeeded or was skipped because `changes` said its group need not run.
# Prints one line per job with its result and verdict.
#
# Input (environment): ALL_GREEN_NEEDS, the caller's `toJSON(needs)`.
set -euo pipefail

needs=${ALL_GREEN_NEEDS:?ALL_GREEN_NEEDS is not set}
line() { printf '%-24s %-10s %s\n' "$@"; }

line JOB RESULT VERDICT
changes=$(jq -r '.changes.result // "missing"' <<<"$needs")
if [[ $changes != success ]]; then
  line changes "$changes" "FAIL: changes must succeed"
  exit 1
fi
if ! groups=$(jq -ce '.changes.outputs.groups | fromjson | objects' <<<"$needs" 2>/dev/null); then
  line changes "$changes" "FAIL: its output groups is not a JSON object"
  exit 1
fi
line changes "$changes" ok

status=0
while IFS=$'\t' read -r job result; do
  case $result in
    success) verdict=ok ;;
    skipped)
      case $(jq -r --arg job "$job" '.[$job]' <<<"$groups") in
        false) verdict="ok: group $job need not run" ;;
        true) verdict="FAIL: skipped, but group $job had to run" ;;
        *) verdict="FAIL: skipped, and no group is named $job" ;;
      esac
      ;;
    *) verdict=FAIL ;;
  esac
  [[ $verdict == ok* ]] || status=1
  line "$job" "$result" "$verdict"
done < <(jq -r 'to_entries[] | select(.key != "changes") | [.key, .value.result] | @tsv' <<<"$needs")
exit "$status"
