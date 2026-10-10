#!/usr/bin/env bash
# Tests for all-green/all-green.sh. Each failing case asserts both the exit
# status and the job the log blames, so that it fails for the right reason.

# Runs all-green on the needs JSON in $1; sets $status and $out.
all_green() {
  status=0
  out=$(ALL_GREEN_NEEDS=$1 bash "$ROOT/all-green/all-green.sh" 2>&1) || status=$?
}

changes_ok() {
  printf '{"result":"success","outputs":{"groups":"%s"}}' "${1//\"/\\\"}"
}

test_all_green_passes_when_every_job_succeeds() {
  all_green "{\"changes\":$(changes_ok '{"test":true}'),\"lint\":{\"result\":\"success\"},\"test\":{\"result\":\"success\"}}"
  assert_eq "$status" 0 "exit status"
}

test_all_green_passes_a_job_skipped_because_its_group_need_not_run() {
  all_green "{\"changes\":$(changes_ok '{"test":false}'),\"lint\":{\"result\":\"success\"},\"test\":{\"result\":\"skipped\"}}"
  assert_eq "$status" 0 "exit status"
  assert_contains "$out" "ok: group test need not run"
}

test_all_green_fails_when_changes_did_not_succeed() {
  # Every other job would pass on its own; only the result of changes is wrong.
  all_green '{"changes":{"result":"failure","outputs":{"groups":"{\"test\":false}"}},"lint":{"result":"success"},"test":{"result":"skipped"}}'
  assert_eq "$status" 1 "exit status"
  assert_contains "$out" "FAIL: changes must succeed"
}

test_all_green_fails_on_a_failed_job() {
  all_green "{\"changes\":$(changes_ok '{"test":true}'),\"lint\":{\"result\":\"failure\"},\"test\":{\"result\":\"success\"}}"
  assert_eq "$status" 1 "exit status"
  [[ $out =~ lint[[:space:]]+failure[[:space:]]+FAIL ]] || fail "lint not blamed: $out"
}

test_all_green_fails_on_a_cancelled_job() {
  all_green "{\"changes\":$(changes_ok '{"test":true}'),\"lint\":{\"result\":\"success\"},\"test\":{\"result\":\"cancelled\"}}"
  assert_eq "$status" 1 "exit status"
  [[ $out =~ test[[:space:]]+cancelled[[:space:]]+FAIL ]] || fail "test not blamed: $out"
}

test_all_green_fails_when_a_job_that_had_to_run_was_skipped() {
  all_green "{\"changes\":$(changes_ok '{"test":true}'),\"lint\":{\"result\":\"success\"},\"test\":{\"result\":\"skipped\"}}"
  assert_eq "$status" 1 "exit status"
  assert_contains "$out" "FAIL: skipped, but group test had to run"
}

test_all_green_fails_when_a_job_without_a_group_was_skipped() {
  all_green "{\"changes\":$(changes_ok '{"test":true}'),\"lint\":{\"result\":\"skipped\"},\"test\":{\"result\":\"success\"}}"
  assert_eq "$status" 1 "exit status"
  assert_contains "$out" "FAIL: skipped, and no group is named lint"
}
