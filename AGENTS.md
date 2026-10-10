# Agent rules

Everything in this repository is in English: code, comments, docs, commit
messages, pull requests.

## What this is

Two composite actions that other repositories pin by commit SHA: `changes`
(which path groups a change touches) and `all-green` (the required `check`
job). README.md is the interface for those repositories: inputs, outputs and
the rules both actions follow. A change of behaviour updates README.md in the
same pull request.

Repositories pin a merge commit on `main`; there are no tags or releases.
Keep the interface backward compatible: a renamed input or output, or a new
required one, breaks every caller on its next SHA bump.

## Layout

- `changes/`, `all-green/`: one action each, `action.yml` plus the bash
  script it runs. The actions use only bash, `git`, `gh` and `jq` from the
  runner image, and never `uses:` another action.
- `tests/`: `run.sh` runs every `test_*` function in `tests/*_test.sh`, each
  in its own bash process; `lib.sh` holds the shared helpers. `gh` is
  replaced by a stub, so the tests never call GitHub.
- `.github/workflows/ci.yml`: CI, built with the two actions themselves.
  `gitleaks.yml`: weekly secret scan of the whole history.

## Checks

- Hooks: run `uvx pre-commit install` once after cloning. They run gitleaks
  on the staged changes, then shellcheck.
- All hooks on all files: `uvx pre-commit run --all-files`.
- Tests: `tests/run.sh`, or `tests/run.sh '<pattern>'` for the tests whose
  name matches a bash pattern. A new behaviour gets a test that fails without
  it.

## CI

`check` in `.github/workflows/ci.yml` is the required status check of
`main`. `changes` decides whether `test` runs; `lint` always runs the
gitleaks action on the commits of the PR or push, then the hooks on all files
(gitleaks skipped). `check` runs `./all-green` from the same checkout, so a
pull request that changes `all-green/` is judged by its own version. A step
before it fails `check` on any failed or cancelled job regardless; a job
skipped although its group had to run is caught only by `./all-green`, so
review changes to `all-green/` with that in mind. External actions are
pinned by full SHA with the version in a trailing comment.
