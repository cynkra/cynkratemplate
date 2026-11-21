# Per-commit checks: `each-plan`, `each-shard`, `each-follow-up`

Three actions that judge every commit of a branch on its own, not only its tip,
for a package that lands long series of commits, such as vendored engine updates.
They came from duckdb/duckdb-r and igraph/rigraph, which each kept a copy of the scripts and let them drift.
The workflow that calls them, `each.yaml`, stays in each package that wants per-commit checks,
since it only pays off there; the template ships no such workflow.

- `each-plan` selects the commits the verdict store has no record for, oldest first,
  and partitions them into contiguous, cost-balanced shards, one matrix leg each.
  It uploads the plan as the artifact `each-plan`.
- `each-shard` builds one shard in one workspace: it resets the checkout to each commit,
  runs the package's gates, publishes the verdict, and sets the `rcc` commit status.
  Consecutive commits share the leg's local ccache, which is what makes a shard cheaper than a job per commit.
- `each-follow-up` dispatches the calling workflow once more when the run left commits undecided
  that a follow-up can still decide, and decided at least one itself, so that a chain of follow-ups ends.

## What the package provides

The scripts here run in the package's checkout and call scripts of the package's own, in `scripts-dir` (default `scripts`):

- `rcc-one.sh` runs the package's gates on the checked-out commit and exits non-zero for a failure.
  It writes one `<stage>\t<success|failure>` line per gate to `$EACH_STAGE_DIR/outcomes.tsv`,
  and each gate's log to `$EACH_STAGE_DIR/<stage>.log` for the job summary's excerpts.
  `each-shard` runs the copy each commit carries, so every commit is judged by the gates it carries.
- `rcc-lib.sh`, `rcc-decided.sh`, `rcc-publish.sh` and `rcc-run-fields.jq` are the verdict store on the `rcc2` branch:
  the list of decided commits, the one writer, and the run fields of a record.
  The package keeps them because its hand-run store tools, such as `rcc-drop.sh` and `rcc-consolidate.sh`, and their test use them too.
- `series-lib.sh`, sourced by `each-plan` at the branch tip, defines `series_seed_of <ref>`,
  which finds the seed of an rc strand (`<S>-rc-dev`),
  and the array `series_cost_estimator`, a command with two forms:
  `map <dir>` prints a JSON cost map of the checkout, and `batch <map>` reads `<sha> <changed paths>` lines
  and prints `<sha> <objects>` lines, the objects each commit recompiles.
  A package with an include graph worth reading derives them from it;
  another answers the same number for every commit.

What the package measures, it passes as inputs:
the four cost constants of `each-plan` (`setup-minutes`, `full-build-minutes`, `floor-minutes`, `object-seconds`),
and `ccache-hash-dir` of `each-shard` where a vignette build installs from a temporary directory.
Anything the gates need beyond R, the package's dependencies and the formatting tools,
such as system packages or an environment variable `rcc-one.sh` reads,
is set up by the package's `each.yaml` before `each-shard`.

## Which commits

On a series branch, `<S>-dev` with a sibling `<S>-green`, only the commits in `<S>-green..HEAD` are considered;
nothing is built when green is not an ancestor of HEAD.
`retry-<S>-dev` judges the tip again on its own SHA, and an rc strand, `<S>-rc-dev`, is bounded by its seed.
Elsewhere, the first-parent history since `since` is scanned.
A commit is built only if the store holds no record for it, unless `force` is set.

## Reference `each.yaml`

Copy this into the package, set the repository guard, and pass what the package measures.

```yaml
# Build every commit on a branch that has no rcc verdict yet, one shard of commits per job.
# The scripts are served by cynkra/cynkratemplate's each-plan, each-shard and each-follow-up actions;
# see .github/actions/each-shard/README.md there.

on:
  push:
    branches:
      - each-*
      - "*-dev"
  workflow_dispatch:
    inputs:
      since:
        description: "Earliest commit date to consider (ISO 8601)"
        type: string
        default: ""
      shard-budget-minutes:
        description: "Build-time target per shard, excluding setup; the GitHub job limit is 360"
        type: string
        default: ""
      max-parallel:
        description: "Shards to build concurrently"
        type: string
        default: ""
      split-factor:
        description: "Runner minutes the plan may cost, relative to the fewest-shards plan, to shorten wall clock (1.0 = never rebalance)"
        type: string
        default: ""
      max-commits:
        description: "Cap on commits considered (0 = no cap), newest kept"
        type: string
        default: ""
      force:
        description: "Rebuild commits that already have a verdict"
        type: boolean
        default: false
      follow-up-of:
        description: "The run this one follows up, set by that run"
        type: string
        default: ""
      follow-up-head:
        description: "The commit that run planned from; a retry tip equal to it is not replanned"
        type: string
        default: ""
  workflow_call:
    inputs:
      branch:
        description: "Branch ref to build (e.g. refs/heads/main-dev)"
        required: true
        type: string
      since:
        required: false
        type: string
        default: ""
      shard-budget-minutes:
        required: false
        type: string
        default: ""
      max-parallel:
        required: false
        type: string
        default: ""
      split-factor:
        required: false
        type: string
        default: ""
      max-commits:
        required: false
        type: string
        default: ""

name: each-rcc

# One planning and building pass per branch at a time.
# `cancel-in-progress: false` on purpose: a queued run must wait for a long build rather than kill it,
# because a killed leg leaves its in-flight commit undecided.
# The follow-up waits in this group too, until the run that dispatched it completes.
concurrency:
  group: each-rcc-${{ inputs.branch || github.ref }}
  cancel-in-progress: false

env:
  EACH_SHARD_BUDGET_MINUTES: ${{ inputs.shard-budget-minutes || '300' }}

jobs:
  plan:
    # Per-commit checks run in the fork that lands the series, not upstream.
    if: github.repository == '<owner>/<repo>'
    runs-on: ubuntu-26.04

    name: "Plan per-commit rcc builds"

    outputs:
      # The fallbacks cover a planning step that did not run at all:
      # `build` is guarded by `shards != '0'`, but its `strategy` must still parse.
      matrix: ${{ steps.plan.outputs.matrix || '{"shard":["none"]}' }}
      shards: ${{ steps.plan.outputs.shards || '0' }}
      max_parallel: ${{ steps.plan.outputs.max_parallel || '1' }}

    permissions:
      contents: read

    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ inputs.branch || github.ref }}
          fetch-depth: 0

      - id: plan
        uses: cynkra/cynkratemplate/.github/actions/each-plan@main
        with:
          since: ${{ inputs.since || vars.EACH_RCC_SINCE }}
          shard-budget-minutes: ${{ env.EACH_SHARD_BUDGET_MINUTES }}
          max-parallel: ${{ inputs.max-parallel || vars.EACH_RCC_MAX_PARALLEL || '20' }}
          max-commits: ${{ inputs.max-commits }}
          split-factor: ${{ inputs.split-factor || vars.EACH_RCC_SPLIT_FACTOR }}
          force: ${{ inputs.force || false }}
          follow-up-of: ${{ inputs.follow-up-of }}
          follow-up-head: ${{ inputs.follow-up-head }}
          # The package's cost model, measured on its own legs.
          setup-minutes: "5"
          full-build-minutes: "40"
          floor-minutes: "6"
          object-seconds: "9.7"

  build:
    needs:
      - plan

    if: needs.plan.outputs.shards != '0'

    runs-on: ubuntu-26.04

    # Below GitHub's 6 h ceiling, and above the leg's own deadline:
    # the leg stops itself and reports what it deferred, rather than being killed mid-commit.
    timeout-minutes: 350

    name: "shard ${{ matrix.shard }} (${{ matrix.label }})"

    permissions:
      # `write` for the store on the `rcc2` branch, and for snapshot branches a gate may publish.
      contents: write
      statuses: write
      actions: read

    strategy:
      fail-fast: false
      max-parallel: ${{ fromJSON(needs.plan.outputs.max_parallel) }}
      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}

    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ inputs.branch || github.ref }}
          fetch-depth: 0

      - uses: cynkra/cynkratemplate/.github/actions/git-identity@main

      - uses: ./.github/workflows/custom/before-install
        if: hashFiles('.github/workflows/custom/before-install/action.yml') != ''

      - uses: cynkra/cynkratemplate/.github/actions/install@main
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          cache-version: each-rcc-1
          needs: build, check, website, roxygen2
          extra-packages: any::rcmdcheck r-lib/roxygen2 any::decor r-lib/pkgdown deps::.

      # Not custom/after-install, which is about one commit; the gates run per commit in rcc-one.sh.
      # Anything else the gates need goes here, such as system packages.

      # Run for its tool installation only (air, clang-format):
      # each-shard.sh resets the workspace before every commit.
      - uses: cynkra/cynkratemplate/.github/actions/style@main

      - uses: cynkra/cynkratemplate/.github/actions/each-shard@main
        with:
          shard: ${{ matrix.shard }}
          token: ${{ secrets.GITHUB_TOKEN }}
          deadline-minutes: ${{ env.EACH_SHARD_BUDGET_MINUTES }}
          summary-tail: ${{ vars.EACH_RCC_SUMMARY_TAIL }}

  # A leg that reaches its deadline defers the commits it did not get to,
  # and nothing else would plan them before the next push.
  # `!cancelled()`, so that a leg that failed or timed out is followed up, while a cancelled run stays retired.
  follow-up:
    needs:
      - plan
      - build

    if: ${{ !cancelled() && needs.plan.result == 'success' && needs.plan.outputs.shards != '0' }}

    runs-on: ubuntu-26.04

    timeout-minutes: 10

    name: "Follow up on undecided commits"

    permissions:
      contents: read
      # Dispatches the follow-up, and lists the runs already waiting on the branch.
      actions: write

    steps:
      # The scripts of the commit this run's workflow was read from, not the branch:
      # a branch that moved or was deleted since must reach the script's "moved" exit rather than fail the checkout.
      - uses: actions/checkout@v6
        with:
          ref: ${{ github.sha }}
          sparse-checkout: scripts
          filter: blob:none

      - uses: cynkra/cynkratemplate/.github/actions/each-follow-up@main
        with:
          inputs: ${{ toJSON(inputs) }}
```

## Testing

- `each-shard/test.sh` runs two legs under a one-minute deadline against stubs of the package's scripts,
  and checks which commits are recorded, published and deferred.
- `each-follow-up/test.sh` checks when a follow-up is dispatched and with what, and the part of `each-plan.sh` it relies on,
  offline, against a synthetic branch and store.
  It reads the store through a package's own scripts:
  `EACH_SCRIPTS=<package>/scripts .github/actions/each-follow-up/test.sh`, and is skipped without one.
