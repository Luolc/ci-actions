# ci-actions

Two composite actions for a CI that runs only what a change touches, while a
single required check still guards the branch:

- [`changes`](changes/action.yml) decides which path groups a change touches.
- [`all-green`](all-green/action.yml) is the last job: it passes only when
  every other job passed, or was skipped because `changes` said its group need
  not run.

Both are plain bash (`git`, `gh` and `jq` from the runner image) and use no
other action.

## The shape of a workflow

```
changes ──┬── lint (always runs)
          ├── test (runs if group `test` changed)
          └── e2e  (runs if group `e2e` changed)
                              └── check (always runs; the required check)
```

1. `changes` runs first and outputs a JSON object of group name to
   `true` / `false`.
2. Every other job runs in parallel. A job that only matters for some paths
   `needs: changes` and runs `if:` its group is `true`. A job that always
   runs (lint, secret scan) needs nothing.
3. `check` needs every job, runs `if: always()`, and calls `all-green`. Make
   `check` the only required status check of the branch.

## Example

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "17 3 * * 1" # weekly run of everything

concurrency:
  group: ci-${{ github.ref }}
  # Every main commit needs its own result; only PR runs are cancelled.
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

permissions:
  contents: read
  actions: read # changes reads the past runs of this workflow

jobs:
  changes:
    runs-on: ubuntu-24.04
    outputs:
      groups: ${{ steps.changes.outputs.groups }}
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
        with:
          fetch-depth: 0
      - id: changes
        uses: Luolc/ci-actions/changes@<sha> # main, YYYY-MM-DD
        with:
          groups: |
            test: src/** tests/** go.mod go.sum
            e2e:  src/** e2e/** go.mod go.sum
            docs: docs/** *.md
          run-all-on: .github/** scripts/** .pre-commit-config.yaml

  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
      - run: make lint

  test:
    needs: changes
    if: fromJSON(needs.changes.outputs.groups).test
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
      - run: make test

  e2e:
    needs: changes
    if: fromJSON(needs.changes.outputs.groups).e2e
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
      - run: make e2e

  check:
    needs: [changes, lint, test, e2e]
    if: always()
    runs-on: ubuntu-24.04
    steps:
      - uses: Luolc/ci-actions/all-green@<sha> # main, YYYY-MM-DD
        with:
          needs: ${{ toJSON(needs) }}
```

What the example relies on:

- The job that calls `changes` is named `changes` and declares the job output
  `groups`. `all-green` reads exactly `needs.changes.result` and
  `needs.changes.outputs.groups`.
- Each group is named after the job that depends on it (`test`, `e2e`). A
  job skipped by its `if:` passes `check` only if a group of the same name is
  `false`. The `docs` group has no job: it exists so that a docs-only change
  is covered by some group (see "Rules") and skips everything else.
- `check` lists every other job under `needs`. A job left out of that list is
  not checked at all.
- `actions: read` is needed by `changes` on pushes; `contents: read` by
  checkout. Set them for the workflow, or on the `changes` job alone.
- `fetch-depth: 0`: on a push, `changes` diffs against an older commit that
  must be in the clone. A pull request needs a depth of at least 2. With a
  clone too shallow, `changes` runs every group.

## Why `check` must be `if: always()`

When a job fails, every job that needs it is skipped unless its `if:` uses a
status function. A skipped job reports success, and GitHub treats a skipped
required check as passed. Without `always()`, a failing test would skip
`check` and let the pull request merge. Do not add any other condition to
`check`'s `if:`, for the same reason.

A job whose `if:` has no status function gets `success()` added in front of
it, so when `changes` fails every gated job is skipped; `all-green` then
fails because `changes` did not succeed.

## `changes`

### Inputs

| Input | Required | Description |
| -- | -- | -- |
| `groups` | yes | One group per line: `name: glob glob ...`. Names are letters, digits, `_` and `-`, starting with a letter or `_`. Blank lines and lines starting with `#` are ignored. |
| `run-all-on` | no | Globs, separated by spaces or newlines. A changed file matching any of them runs every group. Use it for the CI itself, shared scripts, toolchain and lock files. |
| `token` | no | Token for reading this workflow's past runs. Default `github.token`; it needs `actions: read`. |

Globs match paths from the repository root. `*` and `?` do not match `/`;
`**` matches anything, `/` included; `**/` also matches no directory at all,
so `**/*.md` matches `README.md` and `docs/a/b.md`, while `*.md` matches only
`README.md`. Character classes (`[abc]`) are not supported, and a glob
cannot contain a space.

### Output

| Output | Description |
| -- | -- |
| `groups` | JSON object from each group name to `true` (run) or `false` (skip), in input order, e.g. `{"test":true,"e2e":false,"docs":true}`. Read a group with `fromJSON(needs.changes.outputs.groups).<name>`. |

### Rules

`changes` first picks a base commit and lists the files changed between it
and `HEAD` (`git diff --no-renames --name-only`, so a rename lists both
paths). Then:

- a file matching `run-all-on` runs every group;
- a file matching no group runs every group: the groups no longer cover the
  tree, and running too much is the safe mistake;
- otherwise each group runs if any changed file matches it.

The base:

| Event | Base |
| -- | -- |
| `pull_request` | `HEAD^1`. `actions/checkout` checks out the PR's test merge commit, whose first parent is the tip of the base branch, so the diff is what merging the PR would change. If `HEAD` is not that merge commit (its second parent is not the PR head), every group runs. |
| `push` to the default branch | The head commit of the latest successful `push` run of this same workflow on the default branch, provided it is an ancestor of `HEAD`. |
| anything else (`schedule`, `workflow_dispatch`, a push to another branch or a tag, ...) | none: every group runs. |

On a push, every group also runs when the query for that run fails, when no
run has succeeded yet, when the commit found is not an ancestor of `HEAD` (a
force push, or a clone too shallow), and when it is `HEAD` itself (a rerun).

The push base is the last green commit rather than `github.event.before`, the
previous tip. Suppose commit X breaks the tests and commit Y, pushed next,
only touches docs. Diffed against X, Y would skip the tests and pass, and
main would show green on top of broken code. Diffed against the last green
commit, Y runs the tests that X broke and fails like X. So a green run on
main means: compared with a commit that was entirely green, everything this
commit changed was tested and passed.

## `all-green`

### Inputs

| Input | Required | Description |
| -- | -- | -- |
| `needs` | yes | `${{ toJSON(needs) }}` of the calling job. |

### Rules

- `changes` must have succeeded, and its `groups` output must be a JSON
  object.
- Every other job passes if it succeeded, or if it was skipped and its group
  in `groups` is `false`.
- Everything else fails: `failure`, `cancelled`, a job skipped while its
  group is `true`, and a job skipped that has no group of its name.

The log has one line per job with its result and verdict:

```
JOB                      RESULT     VERDICT
changes                  success    ok
lint                     success    ok
test                     skipped    ok: group test need not run
e2e                      skipped    FAIL: skipped, but group e2e had to run
```

## Pinning

Reference both actions by a full commit SHA of this repository, never by a
branch, and write in a trailing comment where it comes from:

```yaml
uses: Luolc/ci-actions/changes@<40-character sha> # main, YYYY-MM-DD
```

A SHA cannot be moved the way a branch or tag can. Take it from a merge
commit on `main` whose CI passed. GitHub also serves commits of forks under
this repository's name, so check that the SHA is on `main`:

```sh
gh api repos/Luolc/ci-actions/compare/<sha>...main --jq .status # identical or ahead
```

Use the same SHA for `changes` and `all-green`. To upgrade, change both SHAs
in one pull request.

## Development

See [AGENTS.md](AGENTS.md).
