#!/usr/bin/env bash
# Runs every test_* function in tests/*_test.sh, each in its own bash process
# with `set -euo pipefail`. With an argument, runs only the tests whose name
# matches that bash pattern, e.g. `tests/run.sh 'test_push_*'`.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

filter=${1:-*}
passed=0
failed=()
for file in tests/*_test.sh; do
  # shellcheck disable=SC1090
  mapfile -t tests < <(source "$file" && declare -F | awk '$3 ~ /^test_/ { print $3 }')
  for test in "${tests[@]}"; do
    # shellcheck disable=SC2053
    [[ $test == $filter ]] || continue
    if out=$(bash -euo pipefail -c 'source tests/lib.sh; source "$1"; "$2"' _ "$file" "$test" 2>&1); then
      echo "ok    $test"
      passed=$((passed + 1))
    else
      echo "FAIL  $test"
      printf '      %s\n' "${out//$'\n'/$'\n      '}"
      failed+=("$test")
    fi
  done
done
echo "$passed passed, ${#failed[@]} failed"
((passed + ${#failed[@]} > 0)) || { echo "no test matches $filter"; exit 1; }
((${#failed[@]} == 0))
