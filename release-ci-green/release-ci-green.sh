#!/usr/bin/env bash
# Passes only when the push run of ci.yml on main for a commit succeeded on
# its first attempt; waits while that run has not completed. A rerun does not
# count: it can turn a flaky red into green. The rules are in README.md.
#
# Inputs (environment): RELEASE_CI_GREEN_SHA, RELEASE_CI_GREEN_REPO, and
# GH_TOKEN, which must be able to read Actions runs. RELEASE_CI_GREEN_INTERVAL
# (default 30) and RELEASE_CI_GREEN_TIMEOUT (default 1800) set the wait in
# seconds.
# Exit 0 when the run succeeded at run_attempt 1; 1 when there is no such
# run, it disappears or does not complete in time, or it ended otherwise or
# at a later attempt; 4 when the runs cannot be read; 2 on a bad input.
set -euo pipefail

log() { printf 'release-ci-green: %s\n' "$*" >&2; }

sha=${RELEASE_CI_GREEN_SHA:-}
repo=${RELEASE_CI_GREEN_REPO:-}
interval=${RELEASE_CI_GREEN_INTERVAL:-30}
deadline=$(($(date +%s) + ${RELEASE_CI_GREEN_TIMEOUT:-1800}))

# The API ignores an empty or malformed head_sha filter and returns the runs
# of other commits, so only a full SHA is accepted.
if [[ ! $sha =~ ^[0-9a-f]{40}$ ]]; then
  log "sha must be a full 40-character lowercase commit SHA, got [$sha]"
  exit 2
fi
if [[ -z $repo ]]; then
  log "repo is empty"
  exit 2
fi

# Sets id, status, conclusion and attempt from the newest run; id is empty
# when there is none. Returns 1 when the answer cannot be read. The API does
# not document the order of the runs, so they are sorted here.
latest() {
  local out run
  out=$(gh api "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$sha&event=push&branch=main") || return 1
  run=$(jq -er '
    .workflow_runs as $runs
    | if ($runs | type) != "array" then error("no workflow_runs")
      elif ($runs | length) == 0 then ""
      else $runs | sort_by(.created_at) | last | (.conclusion | type) as $c
        | if (.id | type) == "number" and (.status | type) == "string"
            and (.run_attempt | type) == "number" and ($c == "string" or $c == "null")
          then "\(.id) \(.status) \(.conclusion) \(.run_attempt)"
          else error("unexpected run") end
      end' <<<"$out") || return 1
  read -r id status conclusion attempt <<<"$run"
}

cannot_read() {
  log "cannot read the ci.yml runs of $sha in $repo; the token needs actions: read there"
  exit 4
}

latest || cannot_read
if [[ -z $id ]]; then
  log "no ci.yml run for a push of $sha to main in $repo"
  exit 1
fi
while [[ $status != completed ]]; do
  if (($(date +%s) >= deadline)); then
    log "run $id of $sha is still $status, gave up waiting"
    exit 1
  fi
  echo "release-ci-green: run $id of $sha is $status, waiting"
  sleep "$interval"
  latest || cannot_read
  if [[ -z $id ]]; then
    log "the ci.yml run of $sha is gone"
    exit 1
  fi
done
echo "release-ci-green: run $id of $sha: conclusion $conclusion, run_attempt $attempt"
if [[ $conclusion != success || $attempt != 1 ]]; then
  log "$sha passes only after a run that succeeded at run_attempt 1"
  exit 1
fi
