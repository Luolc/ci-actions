#!/usr/bin/env bash
# Tests for changes/changes.sh. Each test builds its own git repo and fakes
# `gh` with a stub on PATH, so nothing here talks to GitHub.

GROUPS_INPUT='src: src/**
docs: docs/** *.md
other: other/**'

# Starts a repo with one commit on main, plus a `gh` stub that answers the
# runs query with $STUB_GH_SHA, or fails when $STUB_GH_FAIL is set.
setup_repo() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$TMP/repo" "$TMP/bin"
  cd "$TMP/repo" || exit 1
  git init -q -b main
  commit README.md

  cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_GH_LOG"
if [[ -n ${STUB_GH_FAIL:-} ]]; then
  echo "HTTP 502: Bad Gateway" >&2
  exit 1
fi
printf '%s\n' "${STUB_GH_SHA:-}"
STUB
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH" STUB_GH_LOG=$TMP/gh.log
  : >"$STUB_GH_LOG"

  export GITHUB_REPOSITORY=owner/repo
  export GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/heads/main
  export GITHUB_EVENT_PATH=$TMP/event.json
  export CHANGES_GROUPS=$GROUPS_INPUT CHANGES_RUN_ALL_ON='.github/** docs/shared/**'
}

# Commits a change to each file named.
commit() {
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "$file")"
    echo "$RANDOM" >>"$file"
    git add "$file"
  done
  git commit -q -m "change $*"
}

# Sets up a push of HEAD to main.
push_event() {
  export GITHUB_EVENT_NAME=push GITHUB_REF=${1:-refs/heads/main}
  echo '{"repository":{"default_branch":"main"}}' >"$GITHUB_EVENT_PATH"
}

# Runs changes.sh; sets $status, $out (the log) and $groups (the output).
changes() {
  export GITHUB_OUTPUT=$TMP/output
  : >"$GITHUB_OUTPUT"
  status=0
  out=$(bash "$ROOT/changes/changes.sh" 2>&1) || status=$?
  groups=$(sed -n 's/^groups=//p' "$GITHUB_OUTPUT")
}

ALL='{"src":true,"docs":true,"other":true}'

test_pr_diffs_against_the_first_parent_of_the_merge_commit() {
  setup_repo
  git checkout -q -b feature
  commit docs/a.md
  git checkout -q main
  commit src/a.go # main moves on after the PR branched off
  git checkout -q --detach main
  git merge -q --no-ff --no-edit feature
  export GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge
  echo "{\"pull_request\":{\"head\":{\"sha\":\"$(git rev-parse feature)\"}}}" >"$GITHUB_EVENT_PATH"
  changes
  assert_eq "$status" 0 "exit status"
  assert_eq "$groups" '{"src":false,"docs":true,"other":false}' "groups"
}

test_pr_runs_all_when_head_is_not_the_test_merge_commit() {
  setup_repo
  git checkout -q -b feature
  commit docs/a.md
  export GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge
  echo "{\"pull_request\":{\"head\":{\"sha\":\"$(git rev-parse feature)\"}}}" >"$GITHUB_EVENT_PATH"
  changes
  assert_eq "$groups" "$ALL" "groups"
  assert_contains "$out" "not the test merge commit"
}

test_push_diffs_against_the_last_green_commit() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  commit src/a.go # red, say
  commit docs/a.md
  push_event
  changes
  assert_eq "$status" 0 "exit status"
  # src is in: the last green commit is before the src change, not HEAD^.
  assert_eq "$groups" '{"src":true,"docs":true,"other":false}' "groups"
  assert_eq "$(cat "$STUB_GH_LOG")" "api repos/owner/repo/actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=1 --jq .workflow_runs[0].head_sha // empty" "gh call"
}

test_push_runs_all_when_the_last_green_commit_is_not_an_ancestor() {
  setup_repo
  git checkout -q -b gone
  commit src/a.go
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  git checkout -q main
  commit docs/a.md
  push_event
  changes
  assert_eq "$groups" "$ALL" "groups"
  assert_contains "$out" "is not an ancestor of HEAD"
}

test_push_runs_all_when_the_query_fails() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD) STUB_GH_FAIL=1
  export STUB_GH_SHA STUB_GH_FAIL
  commit docs/a.md
  push_event
  changes
  assert_eq "$status" 0 "exit status"
  assert_eq "$groups" "$ALL" "groups"
  assert_contains "$out" "could not query"
}

test_push_runs_all_when_there_is_no_green_run() {
  setup_repo
  export STUB_GH_SHA=''
  commit docs/a.md
  push_event
  changes
  assert_eq "$groups" "$ALL" "groups"
  assert_contains "$out" "no green run"
}

test_push_runs_all_when_head_is_the_last_green_commit() {
  setup_repo
  commit docs/a.md
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  push_event
  changes
  assert_eq "$groups" "$ALL" "groups"
}

test_push_to_another_branch_runs_all_without_a_query() {
  setup_repo
  commit docs/a.md
  push_event refs/heads/feature
  changes
  assert_eq "$groups" "$ALL" "groups"
  assert_eq "$(cat "$STUB_GH_LOG")" "" "gh calls"
}

test_schedule_runs_all() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  commit docs/a.md
  export GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/main
  echo '{}' >"$GITHUB_EVENT_PATH"
  changes
  assert_eq "$groups" "$ALL" "groups"
}

test_a_file_in_no_group_runs_all() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  commit docs/a.md misc/a.txt
  push_event
  changes
  assert_eq "$groups" "$ALL" "groups"
  assert_contains "$out" "misc/a.txt is in no group"
}

test_a_file_in_run_all_on_runs_all() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  commit docs/shared/a.md # also in docs, so only run-all-on makes it run all
  push_event
  changes
  assert_eq "$groups" "$ALL" "groups"
  assert_contains "$out" "docs/shared/a.md is in run-all-on"
}

test_a_non_ascii_path_matches_its_group() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  commit docs/é.md
  push_event
  changes
  assert_eq "$groups" '{"src":false,"docs":true,"other":false}' "groups"
}

test_star_matches_within_one_directory_only() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  export CHANGES_GROUPS='root_md: *.md
any_md: **/*.md
src: src/**'
  commit src/deep/a.md
  push_event
  changes
  assert_eq "$groups" '{"root_md":false,"any_md":true,"src":true}' "groups"
}

test_double_star_slash_also_matches_the_top_directory() {
  setup_repo
  STUB_GH_SHA=$(git rev-parse HEAD)
  export STUB_GH_SHA
  export CHANGES_GROUPS='root_md: *.md
any_md: **/*.md
src: src/**'
  commit NOTES.md
  push_event
  changes
  assert_eq "$groups" '{"root_md":true,"any_md":true,"src":false}' "groups"
}
