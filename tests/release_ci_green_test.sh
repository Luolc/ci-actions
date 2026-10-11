#!/usr/bin/env bash
# Tests for release-ci-green/release-ci-green.sh. A `gh` stub on PATH answers
# the n-th call with the n-th answer given to `answers` (the last one
# repeats), so nothing here talks to GitHub.

SHA=0123456789abcdef0123456789abcdef01234567

# Installs the stub; each argument is one answer, FAIL for an API error.
answers() {
  mkdir -p "$TMP/bin" "$TMP/answers"
  local i=0 answer
  for answer in "$@"; do
    i=$((i + 1))
    printf '%s\n' "$answer" >"$TMP/answers/$i"
  done
  cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMP/gh.log"
n=$(($(wc -l <"$TMP/gh.log")))
[[ -e $TMP/answers/$n ]] || n=$(ls "$TMP/answers" | sort -n | tail -n 1)
if [[ $(<"$TMP/answers/$n") == FAIL ]]; then
  echo "HTTP 502: Bad Gateway" >&2
  exit 1
fi
cat "$TMP/answers/$n"
STUB
  chmod +x "$TMP/bin/gh"
  export TMP PATH="$TMP/bin:$PATH"
  : >"$TMP/gh.log"
}

# One run: <id> <status> <conclusion or null> <run_attempt> [<created_at>].
run() {
  local c=$3
  [[ $c == null ]] || c="\"$c\""
  printf '{"id":%s,"status":"%s","conclusion":%s,"run_attempt":%s,"created_at":"%s"}' \
    "$1" "$2" "$c" "$4" "${5:-2026-10-10T01:00:00Z}"
}

# The API's answer listing the runs given.
runs() {
  local IFS=,
  printf '{"total_count":%s,"workflow_runs":[%s]}' "$#" "$*"
}

# Runs the script; sets $status, $out (the log) and $calls (gh calls made).
# The outer timeout stops a script whose own deadline is broken.
release_ci_green() {
  status=0
  out=$(RELEASE_CI_GREEN_SHA=${SHA_INPUT-$SHA} RELEASE_CI_GREEN_REPO=${REPO_INPUT-owner/repo} \
    RELEASE_CI_GREEN_INTERVAL=0 RELEASE_CI_GREEN_TIMEOUT=${TIMEOUT:-5} \
    timeout 20 bash "$ROOT/release-ci-green/release-ci-green.sh" 2>&1) || status=$?
  calls=$(wc -l <"$TMP/gh.log")
}

test_green_first_attempt_passes() {
  answers "$(runs "$(run 7 completed success 1)")"
  release_ci_green
  assert_eq "$status" 0 "exit status"
  assert_contains "$out" "run 7 of $SHA: conclusion success, run_attempt 1"
  assert_eq "$(<"$TMP/gh.log")" "api repos/owner/repo/actions/workflows/ci.yml/runs?head_sha=$SHA&event=push&branch=main" "query"
}

test_failed_run_fails() {
  answers "$(runs "$(run 7 completed failure 1)")"
  release_ci_green
  assert_eq "$status" 1 "exit status"
}

test_cancelled_run_fails() {
  answers "$(runs "$(run 7 completed cancelled 1)")"
  release_ci_green
  assert_eq "$status" 1 "exit status"
}

test_green_rerun_fails() {
  answers "$(runs "$(run 7 completed success 2)")"
  release_ci_green
  assert_eq "$status" 1 "exit status"
}

test_no_run_fails() {
  answers "$(runs)"
  release_ci_green
  assert_eq "$status" 1 "exit status"
  assert_contains "$out" "no ci.yml run for a push of $SHA to main in owner/repo"
}

# The newest run decides, whichever place the API lists it in.
test_newest_of_two_runs_decides() {
  local old new
  old=$(run 7 completed failure 1 2026-10-10T01:00:00Z)
  new=$(run 8 completed success 1 2026-10-10T02:00:00Z)
  answers "$(runs "$old" "$new")"
  release_ci_green
  assert_eq "$status" 0 "exit status, newest listed last"
  answers "$(runs "$new" "$old")"
  release_ci_green
  assert_eq "$status" 0 "exit status, newest listed first"
  answers "$(runs "$(run 8 completed failure 1 2026-10-10T02:00:00Z)" "$(run 7 completed success 1)")"
  release_ci_green
  assert_eq "$status" 1 "exit status, newest is red"
}

test_waits_until_the_run_completes() {
  answers "$(runs "$(run 7 queued null 1)")" "$(runs "$(run 7 in_progress null 1)")" \
    "$(runs "$(run 7 completed success 1)")"
  release_ci_green
  assert_eq "$status" 0 "exit status"
  assert_eq "$calls" 3 "gh calls"
}

# A green run follows the gap: without the check for a vanished run, the
# script would wait it out and pass.
test_run_gone_while_waiting_fails() {
  answers "$(runs "$(run 7 in_progress null 1)")" "$(runs)" "$(runs "$(run 7 completed success 1)")"
  release_ci_green
  assert_eq "$status" 1 "exit status"
  assert_contains "$out" "is gone"
}

test_run_that_never_completes_fails() {
  answers "$(runs "$(run 7 in_progress null 1)")"
  TIMEOUT=0 release_ci_green
  assert_eq "$status" 1 "exit status"
  assert_contains "$out" "gave up waiting"
}

test_api_error_exits_4() {
  answers FAIL
  release_ci_green
  assert_eq "$status" 4 "exit status"
}

test_api_error_while_waiting_exits_4() {
  answers "$(runs "$(run 7 in_progress null 1)")" FAIL
  release_ci_green
  assert_eq "$status" 4 "exit status"
}

test_unreadable_answers_exit_4() {
  local answer
  for answer in '<html>rate limited</html>' '{"message":"Not Found"}' \
    '{"workflow_runs":[{"id":7,"status":"completed","conclusion":"success"}]}' \
    '{"workflow_runs":[{"id":7,"status":"completed","conclusion":1,"run_attempt":1}]}'; do
    answers "$answer"
    release_ci_green
    assert_eq "$status" 4 "exit status for $answer"
  done
}

# An empty head_sha would make the API return other commits' runs; a short
# one would find no run and fail for the wrong reason.
test_sha_must_be_full_and_lowercase() {
  local sha
  answers "$(runs "$(run 7 completed success 1)")"
  for sha in '' 0123456 "${SHA^^}" "${SHA}0"; do
    SHA_INPUT=$sha release_ci_green
    assert_eq "$status" 2 "exit status for sha [$sha]"
    assert_eq "$calls" 0 "gh calls for sha [$sha]"
  done
}

test_empty_repo_exits_2() {
  answers "$(runs "$(run 7 completed success 1)")"
  REPO_INPUT='' release_ci_green
  assert_eq "$status" 2 "exit status"
}
