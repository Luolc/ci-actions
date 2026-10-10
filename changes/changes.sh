#!/usr/bin/env bash
# Decides which path groups a change touches and writes them to
# $GITHUB_OUTPUT as `groups=<JSON object>`. The rules are in README.md.
#
# Inputs (environment): CHANGES_GROUPS, CHANGES_RUN_ALL_ON, and the default
# GitHub Actions variables. GH_TOKEN must be able to read Actions runs.
set -euo pipefail

log() { printf 'changes: %s\n' "$*" >&2; }

# Prints an anchored ERE for a glob: `**` matches across `/`, `*` and `?` do
# not, and `**/` also matches no directory at all.
glob_to_ere() {
  local glob=$1 out='' c i=0
  while ((i < ${#glob})); do
    c=${glob:i:1}
    if [[ $c == '*' && ${glob:i+1:1} == '*' ]]; then
      if [[ ${glob:i+2:1} == / ]]; then
        out+='(.*/)?'
        ((i += 3))
      else
        out+='.*'
        ((i += 2))
      fi
      continue
    fi
    case $c in
      '*') out+='[^/]*' ;;
      '?') out+='[^/]' ;;
      [.^\$+{}\(\)\|\[\]\\]) out+="\\$c" ;;
      *) out+=$c ;;
    esac
    ((i += 1))
  done
  printf '^%s$' "$out"
}

# Prints one ERE matching any of the whitespace-separated globs in $1, or
# nothing when there are none.
globs_to_ere() {
  local -a globs
  local glob re=''
  read -ra globs -d '' <<<"$1" || true
  for glob in "${globs[@]}"; do
    re+="${re:+|}($(glob_to_ere "$glob"))"
  done
  printf '%s' "$re"
}

# Prints the commit to diff HEAD against, or nothing when every group has to
# run. The reason goes to the log either way.
find_base() {
  case $GITHUB_EVENT_NAME in
    pull_request)
      # actions/checkout checks out the test merge commit of the PR: its
      # first parent is the tip of the base branch, its second the PR head.
      local head
      head=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
      if [[ -z $head || $(git rev-parse --verify --quiet 'HEAD^2') != "$head" ]]; then
        log "HEAD is not the test merge commit of the PR"
        return
      fi
      git rev-parse 'HEAD^1'
      ;;
    push)
      local branch workflow sha
      branch=$(jq -r '.repository.default_branch' "$GITHUB_EVENT_PATH")
      if [[ $GITHUB_REF != "refs/heads/$branch" ]]; then
        log "push to $GITHUB_REF, not to the default branch $branch"
        return
      fi
      # The last commit of this branch whose run of this workflow passed, so
      # that a docs-only commit after a red one still runs what went red.
      workflow=${GITHUB_WORKFLOW_REF%@*}
      workflow=${workflow##*/}
      if ! sha=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?branch=$branch&event=push&status=success&per_page=1" \
        --jq '.workflow_runs[0].head_sha // empty'); then
        log "could not query the last green run of $workflow"
        return
      fi
      if [[ -z $sha ]]; then
        log "no green run of $workflow on $branch yet"
        return
      fi
      if ! git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        log "last green commit $sha is not an ancestor of HEAD (or not fetched)"
        return
      fi
      # A rerun of a commit that already passed is a request to check it again.
      if [[ $sha == $(git rev-parse HEAD) ]]; then
        log "HEAD is the last green commit"
        return
      fi
      printf '%s\n' "$sha"
      ;;
    *)
      log "event $GITHUB_EVENT_NAME"
      ;;
  esac
}

declare -a names=()
declare -A group_ere=() run=()
while IFS= read -r line; do
  [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
  if [[ ! $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*):(.*)$ ]]; then
    log "bad line in groups (want 'name: glob glob ...'): $line"
    exit 1
  fi
  name=${BASH_REMATCH[1]}
  if [[ -v group_ere[$name] ]]; then
    log "group $name is defined twice"
    exit 1
  fi
  names+=("$name")
  group_ere[$name]=$(globs_to_ere "${BASH_REMATCH[2]}")
  run[$name]=false
done <<<"${CHANGES_GROUPS:-}"
if ((${#names[@]} == 0)); then
  log "groups is empty"
  exit 1
fi
run_all_ere=$(globs_to_ere "${CHANGES_RUN_ALL_ON:-}")

all=false
base=$(find_base)
if [[ -z $base ]]; then
  all=true
elif ! files=$(git diff --no-renames --name-only "$base" HEAD); then
  log "git diff against $base failed"
  all=true
else
  log "base $base, $(grep -c . <<<"$files") changed file(s)"
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    if [[ -n $run_all_ere && $file =~ $run_all_ere ]]; then
      log "$file is in run-all-on"
      all=true
      break
    fi
    covered=false
    for name in "${names[@]}"; do
      if [[ -n ${group_ere[$name]} && $file =~ ${group_ere[$name]} ]]; then
        run[$name]=true
        covered=true
      fi
    done
    if [[ $covered == false ]]; then
      log "$file is in no group"
      all=true
      break
    fi
  done <<<"$files"
fi

if [[ $all == true ]]; then
  log "running every group"
  for name in "${names[@]}"; do run[$name]=true; done
fi
groups=$(for name in "${names[@]}"; do printf '%s\t%s\n' "$name" "${run[$name]}"; done |
  jq -Rcn '[inputs | split("\t") | {(.[0]): (.[1] == "true")}] | add')
log "groups $groups"
printf 'groups=%s\n' "$groups" >>"$GITHUB_OUTPUT"
