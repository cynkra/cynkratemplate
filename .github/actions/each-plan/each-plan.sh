#!/bin/bash
# Plan the sharded per-commit `rcc` build for the checked-out branch.
#
# Selects the undecided commits -- on a series branch those in
# `<S>-green..HEAD` with no verdict on the `rcc2` branch, elsewhere the
# first-parent history on or after $SINCE without one -- and
# partitions them into contiguous, cost-balanced shards (see
# `each-partition.py` beside this file, which also decides how many shards are
# worth paying for).
# One shard becomes one matrix leg in the package's `each.yaml`, and one
# leg builds its whole slice sequentially in a single job (see
# the `each-shard` action). Shards are numbered along the history -- shard 1 is
# the oldest slice, shard N the branch tip -- and emitted in that same order,
# so the leg holding the oldest slice is the one queued first.
#
# Why shards instead of one dispatch per commit:
#   * a leg pays the R/dependency setup once for all its commits, not once
#     per commit;
#   * consecutive commits in a leg share the runner's local ccache, where a
#     typical vendor commit is almost all hits;
#   * the whole batch is one workflow run: one thing to cancel, one set of logs.
#
# "Undecided" is read from the **verdict store**, not from commit statuses: a
# commit has been decided when the `rcc2` branch carries a record for it, and the
# whole scan is one tree-only fetch (the package's `rcc-decided.sh`). Statuses are a
# display surface on the commit list and decide nothing here -- which is what
# removes the reconciliation between two stores that used to answer this same
# question differently: no GraphQL scan, no `pending` state to age out, and
# nothing that has to be true about the status API for a plan to be correct.
#
# Served by the `each-plan` action of cynkra/cynkratemplate. It runs in the
# package's checkout and reads two things from the package (README.md of the
# `each-shard` action has the whole contract):
#   * `series-lib.sh`, sourced, for `series_seed_of` (the seed of an rc strand)
#     and `series_cost_estimator` (the command that weighs a commit);
#   * `rcc-decided.sh`, which lists the commits the verdict store has decided.
#
# Usage:
#   GH_TOKEN=<token> .github/actions/each-plan/each-plan.sh
#
# Local testing example (prints the plan, writes no outputs), in the package:
#   git checkout main-dev
#   GH_TOKEN=$(gh auth token) OUT=/tmp/plan.json <template>/.github/actions/each-plan/each-plan.sh
#
# Environment variables:
#   GH_TOKEN            - token with contents:read (required)
#   EACH_SCRIPTS        - the package's directory holding series-lib.sh and
#                         rcc-decided.sh, absolute or relative to the checkout
#                         (default: scripts)
#   SINCE               - earliest commit date to consider (required; the
#                         package's own choice, such as when it began
#                         recording verdicts)
#   OUT                 - plan file to write (default: plan.json)
#   FORCE               - if non-empty, ignore existing verdicts and replan all
#                         (a `retry-<S>-dev` branch replans its tip that way
#                         without this, which is the whole point of it)
#   FOLLOW_UP_OF        - the run that dispatched this one to finish what it
#                         left undecided (each-follow-up.sh); logged
#   FOLLOW_UP_HEAD      - the commit that run planned from, sent only once
#                         that run has judged its `retry-<S>-dev` tip again; a
#                         tip equal to it is not replanned a second time
#   SHARD_BUDGET_MINUTES- build-time target per leg, excluding job setup
#                         (default: 300; the GitHub job limit is 360, and
#                         each-shard.sh stops at its own deadline rather
#                         than being killed)
#   MAX_SHARDS          - matrix legs to emit (default: 250; GitHub generates at
#                         most 256 jobs per matrix)
#   MAX_PARALLEL        - legs to run concurrently (default: 20, the same as
#                         each-partition.py)
#   MAX_COMMITS         - hard cap on commits considered (default: 0 = no cap)
#   SPLIT_FACTOR        - runner-minutes the plan may cost, as a multiple of the
#                         fewest-legs plan, to shorten wall clock
#                         (default: 1.5; 1.0 disables rebalancing)
#   SETUP_MINUTES       - per-leg checkout, R and dependency install (required)
#   FULL_BUILD_MINUTES  - a build on an empty ccache, every object compiled
#                         (required)
#   FLOOR_MINUTES       - per-commit floor: link, install, R CMD check, gates
#                         (required)
#   OBJECT_SECONDS      - marginal cost of recompiling one object, of those the
#                         package's estimator counts (required)
#
# The four constants are the package's to measure, and its `each.yaml` passes
# them; there are no defaults, since one package's fit means nothing for
# another. Every leg records duration_seconds per commit, in the record it
# publishes and in its `each-logs-*` artifact, so the fit can be made, and
# redone, from real legs at any time.

set -euo pipefail

# Required, and checked before anything is read: a default here would be one
# package's numbers planning another's commits.
missing=""
for var in SINCE SETUP_MINUTES FULL_BUILD_MINUTES FLOOR_MINUTES OBJECT_SECONDS; do
  [ -n "${!var:-}" ] || missing="${missing} ${var}"
done
if [ -n "${missing}" ]; then
  echo "::error::each-plan needs${missing}: the package's own scan start and cost model (README.md of the each-shard action)" >&2
  exit 1
fi
OUT="${OUT:-plan.json}"
FORCE="${FORCE:-}"
FOLLOW_UP_OF="${FOLLOW_UP_OF:-}"
FOLLOW_UP_HEAD="${FOLLOW_UP_HEAD:-}"
SHARD_BUDGET_MINUTES="${SHARD_BUDGET_MINUTES:-300}"
MAX_SHARDS="${MAX_SHARDS:-250}"
MAX_PARALLEL="${MAX_PARALLEL:-20}"
MAX_COMMITS="${MAX_COMMITS:-0}"
SPLIT_FACTOR="${SPLIT_FACTOR:-1.5}"

here="$(cd "$(dirname "$0")" && pwd)"
EACH_SCRIPTS="${EACH_SCRIPTS:-scripts}"
case "${EACH_SCRIPTS}" in
  /*) scripts="${EACH_SCRIPTS}" ;;
  *) scripts="$(pwd)/${EACH_SCRIPTS}" ;;
esac
# shellcheck source=/dev/null
. "${scripts}/series-lib.sh"
# The two names the planner takes from it, checked here rather than where they
# are first used, so a package that lacks one fails before anything is read.
# shellcheck disable=SC2154  # assigned by series-lib.sh
if ! declare -F series_seed_of > /dev/null \
    || ! declare -p series_cost_estimator > /dev/null 2>&1; then
  echo "::error::${scripts}/series-lib.sh must define series_seed_of and series_cost_estimator" >&2
  exit 1
fi
# shellcheck disable=SC2154  # assigned by series-lib.sh, checked above
cost_estimator=("${series_cost_estimator[@]}")
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

branch="$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)"
echo "Branch: ${branch}"
if [ -n "${FOLLOW_UP_OF}" ]; then
  echo "Follow-up of run ${FOLLOW_UP_OF}${FOLLOW_UP_HEAD:+, which planned from ${FOLLOW_UP_HEAD}}"
fi
echo "Considering commits on or after ${SINCE}"

# ---------------------------------------------------------------- enumerate --
# Bound the scan to the series' world when there is one:
# everything at or before `<S>-green` is trusted
# and never rebuilt, and if green exists but is not an ancestor of HEAD the
# branch is mid-surgery or on another lineage, so nothing is planned rather than
# flooding the queue with an unbounded scan -- and the job fails, because that
# state is somebody's half-finished ref move, not a branch the loop produced.

# Reached from more than one early exit: a branch whose range cannot be bounded
# plans nothing at all rather than a little of everything.
plan_nothing() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo 'matrix={"shard":["none"]}'
      echo "shards=0"
      echo "commits=0"
      echo "deferred=0"
      echo "max_parallel=1"
    } >> "${GITHUB_OUTPUT}"
  fi
}

RANGE=("HEAD")
retry=""
case "${branch}" in
  *-dev)
    series="${branch%-dev}"
    # `retry-<S>-dev` asks for one commit of series `<S>` to be judged again on
    # its own SHA -- the alternative is amending it, which re-mints every
    # descendant and throws away the runs that decided them. See
    # the package's series tooling.
    #
    # It is the series' own branch name with a prefix, so stripping the prefix
    # anchors the scan on `<S>-green`, the ref that already marks how far the
    # series is trusted. The retry branch needs no ref of its own for that: the
    # bound it needs is the bound the series already publishes. Only the tip is
    # forced, below -- the commit the branch was pushed at is the one being
    # asked about, and everything under it keeps the ordinary rule, so a run
    # lost further down the range is picked up in the same pass.
    case "${series}" in
      retry-*) series="${series#retry-}"; retry=1 ;;
    esac
    # An rc strand has no green: it is derived from its source series commit for
    # commit, so its world is everything above
    # its own seed, and without that bound the scan would reach into `main`.
    if [ -z "${retry}" ] && [ "${series%-rc}" != "${series}" ]; then
      rc_seed="$(series_seed_of HEAD)"
      if [ -z "${rc_seed}" ]; then
        echo "RC branch ${branch} has no seed -- planning nothing"
        plan_nothing
        exit 0
      fi
      RANGE=("${rc_seed}..HEAD")
      echo "RC branch: scanning ${rc_seed:0:10}..HEAD"
    elif git fetch -q origin \
        "+refs/heads/${series}-green:refs/remotes/origin/${series}-green" 2>/dev/null; then
      if git merge-base --is-ancestor "refs/remotes/origin/${series}-green" HEAD; then
        RANGE=("refs/remotes/origin/${series}-green..HEAD")
        echo "Series branch: scanning origin/${series}-green..HEAD"
      else
        # Loud, unlike the other early exit below: green existing but off this
        # lineage is never a state the branch reaches on its own. Somebody moved
        # a ref -- a rewind that did not take green back with it, a force-push
        # onto another lineage -- and every commit pushed until they notice goes
        # unbuilt. Silence here reads as a green run that built nothing.
        green_sha="$(git rev-parse --short "refs/remotes/origin/${series}-green")"
        head_sha="$(git rev-parse --short HEAD)"
        echo "::error title=${series}-green is not an ancestor of ${branch}::" \
          "origin/${series}-green (${green_sha}) is not an ancestor of ${branch}" \
          "(${head_sha}), so no commit can be selected. Move ${series}-green to a" \
          "commit ${branch} descends from, then push ${branch} again."
        {
          echo "## Nothing planned"
          echo
          echo "\`origin/${series}-green\` (\`${green_sha}\`) is not an ancestor of"
          echo "\`${branch}\` (\`${head_sha}\`)."
          echo
          echo "Everything at or before green is trusted and never rebuilt, so the"
          echo "scan is bounded by it; off this lineage there is no range to scan."
          echo "Move \`${series}-green\` to a commit \`${branch}\` descends from,"
          echo "then push \`${branch}\` again."
        } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
        plan_nothing
        exit 1
      fi
    elif [ -n "${retry}" ]; then
      # Without the anchor the scan would fall back to first-parent history
      # since SINCE, reach past the series' seed into `main`, and queue a build
      # for every commit there that has no verdict. A retry branch
      # naming a series that has no green is not a request anyone can serve.
      #
      # Quiet, unlike the exit above: a series with no green yet is a state a
      # new series is legitimately in, and failing here would redden a push that
      # is not wrong, only early.
      echo "Retry branch names series ${series}, which has no green -- planning nothing"
      plan_nothing
      exit 0
    fi ;;
esac

# Oldest first. `awk 'NF'` re-emits every
# SHA newline-terminated, so the tip -- left unterminated by --pretty=format:
# under --reverse -- is not dropped, and empty input yields nothing.
git log --first-parent --reverse --pretty=format:"%H" --after="${SINCE}" "${RANGE[@]}" -- \
  | awk 'NF' > "${workdir}/all"

if [ "${MAX_COMMITS}" -gt 0 ]; then
  # Keep the newest MAX_COMMITS; the older ones are picked up by later runs.
  tail -n "${MAX_COMMITS}" "${workdir}/all" > "${workdir}/all.capped"
  mv "${workdir}/all.capped" "${workdir}/all"
fi

total="$(wc -l < "${workdir}/all" | tr -d ' ')"
echo "Commits in range: ${total}"

# ------------------------------------------------------------ read verdicts --
# Every commit the `rcc2` branch holds a record for, in one tree-only fetch. A
# reachable store that says nothing about a commit is the answer "undecided";
# a store that cannot be reached is not an answer at all, and
# rcc-decided.sh exits non-zero for it rather than reporting an empty
# one, which under `set -e` stops the plan instead of replanning the world.
if [ -n "${EACH_DECIDED_FILE:-}" ]; then
  # Offline hook for testing the planner without a remote: one SHA per line.
  echo "Reading decided commits from ${EACH_DECIDED_FILE}"
  cp "${EACH_DECIDED_FILE}" "${workdir}/decided"
elif [ "${total}" -eq 0 ]; then
  : > "${workdir}/decided"
else
  "${scripts}/rcc-decided.sh" > "${workdir}/decided"
fi
echo "Verdicts on the rcc2 branch: $(wc -l < "${workdir}/decided" | tr -d ' ')"

# ---------------------------------------------------------------- select ----
# Keep a commit when the store has no record for it. A record is a decision and
# is left alone -- which is what keeps a rebase-and-force-push the way to
# re-trigger a commit, the SHA being what the record is keyed by.
#
# The tip of a `retry-<S>-dev` branch is the one exception: it is a decision the
# push exists to overturn. Only the tip, and only on that branch -- the rest of
# the range is the series' own history and keeps the ordinary rule.
#
# Driven by the enumeration, not by the record list, so a commit the store does
# not mention is replanned rather than silently dropped. Order stays
# oldest-first, which is what the partitioner and the shard driver rely on.
#
# A follow-up leaves the tip to the ordinary rule when FOLLOW_UP_HEAD is the tip:
# the run before judged that very commit again already, and the follow-up
# (each-follow-up.sh) sends the head only then. A tip that moved since,
# or one the run before deferred, is forced as on any push.
retry_tip=""
if [ -n "${retry}" ] && [ "${FOLLOW_UP_HEAD}" != "$(git rev-parse HEAD)" ]; then
  retry_tip="$(git rev-parse HEAD)"
fi
awk -v force="${FORCE}" -v retry_tip="${retry_tip}" '
  # The FILENAME guard matters: with an empty record list, FNR == NR is still
  # true for the first record of the second file.
  FNR == NR && FILENAME == ARGV[1] { decided[$1] = 1; next }
  {
    sha = $1
    if (force != "") { print sha, "replan-forced"; next }
    if (retry_tip != "" && sha == retry_tip) { print sha, "replan-retry"; next }
    if (!(sha in decided)) { print sha, "no-record"; next }
    print sha, "skip:decided"
  }
' "${workdir}/decided" "${workdir}/all" > "${workdir}/decisions"

awk '$2 !~ /^skip:/ { print $1 }' "${workdir}/decisions" > "${workdir}/todo"

# The commits that are in the plan *despite* already carrying a verdict -- a
# forced replan, or the tip of a retry branch. each-shard.sh skips a
# decided commit so that re-running a leg that died costs only what was lost,
# and this is the list that tells it which decisions are the point of the run
# rather than work already done. Carried in the plan rather than agreed on
# through the workflow, so the two cannot drift apart.
replanned="$(awk '$2 == "replan-forced" || $2 == "replan-retry" { print $1 }' \
  "${workdir}/decisions" | jq -Rsc 'split("\n") | map(select(length > 0))')"

todo="$(wc -l < "${workdir}/todo" | tr -d ' ')"
skipped=$(( total - todo ))
echo "Already decided: ${skipped}"
echo "To build: ${todo}"

# ------------------------------------------------------------------ weigh ----
# Cost per commit = fixed floor (link + install + R CMD check) plus the objects
# the commit invalidates, as counted by the estimator the package's
# series-lib.sh names in `series_cost_estimator`: a command with a `map` and a
# `batch` form, which may read the include graph or answer a constant weight.
# The changed paths are collected and passed on either way.
if [ "${todo}" -gt 0 ]; then
  echo "Building the cost map..."
  "${cost_estimator[@]}" map . > "${workdir}/cost-map.json"

  while IFS= read -r sha; do
    files="$(git diff --name-only "${sha}^" "${sha}" -- 2>/dev/null | tr '\n' ' ' || true)"
    printf '%s %s\n' "${sha}" "${files}"
  done < "${workdir}/todo" > "${workdir}/changed"

  "${cost_estimator[@]}" batch "${workdir}/cost-map.json" \
    < "${workdir}/changed" > "${workdir}/objects"
else
  : > "${workdir}/objects"
fi

# --------------------------------------------------------------- partition ---
# Greedy contiguous fill for the fewest legs under the deadline, then a rerun of
# that fill at shorter deadlines, keeping whichever plan finishes soonest at
# MAX_PARALLEL legs at a time and costs at most SPLIT_FACTOR times the runner
# minutes of the fewest-legs plan. See each-partition.py.
python3 "${here}/each-partition.py" \
  --budget "${SHARD_BUDGET_MINUTES}" \
  --setup "${SETUP_MINUTES}" \
  --full "${FULL_BUILD_MINUTES}" \
  --floor "${FLOOR_MINUTES}" \
  --object-seconds "${OBJECT_SECONDS}" \
  --max-shards "${MAX_SHARDS}" \
  --max-parallel "${MAX_PARALLEL}" \
  --split-factor "${SPLIT_FACTOR}" \
  < "${workdir}/objects" > "${workdir}/partition.json"

jq '.shards' "${workdir}/partition.json" > "${workdir}/shards.json"
shards="$(jq 'length' "${workdir}/shards.json")"
dropped="$(jq '.deferred' "${workdir}/partition.json")"

jq -r '"Fewest legs: \(.split.before.shards) shard(s), "
       + "~\(.split.before.makespan_minutes) min wall, "
       + "~\(.split.before.runner_minutes) min runner time",
       "Rebalanced at factor \(.split.factor) (\(.split.splits) extra leg(s)): "
       + "\(.split.after.shards) shard(s), "
       + "~\(.split.after.makespan_minutes) min wall, "
       + "~\(.split.after.runner_minutes) min runner time"' \
  "${workdir}/partition.json"

if [ "${dropped}" -gt 0 ]; then
  echo "Capped to ${MAX_SHARDS} shards; ${dropped} older commit(s) deferred to the next run"
fi

# Number and order now say the same thing:
#
#   * the *number* runs with history -- shard 1 holds the oldest commits of the
#     plan and shard N the branch tip, so a shard number reads the way the
#     commits do, and adjacent numbers are adjacent slices;
#   * the *order* of the array is oldest first, because that is the order
#     GitHub starts the legs in, and under MAX_PARALLEL throttling the oldest
#     undecided slice has to be decided first -- `<S>-green` only ever advances
#     over a contiguous run of green commits, so a decided tip above an
#     undecided gap moves nothing.
#
# So the matrix starts shard 1 and finishes with shard N.
jq -r 'to_entries | map(.value + {index: (.key + 1)})' \
  "${workdir}/shards.json" > "${workdir}/shards.final.json"

parallel="${MAX_PARALLEL}"
if [ "${parallel}" -gt "${shards}" ] && [ "${shards}" -gt 0 ]; then
  parallel="${shards}"
fi

# The planned commits the store had no record for when the plan was made, which
# leaves out the ones replanned despite a verdict. It is what the run set out to
# decide, and each-follow-up.sh measures the run's progress against it
# from the same store, together with `head`, the commit the plan was made from.
jq -r '.[].commits[].sha' "${workdir}/shards.final.json" > "${workdir}/planned"
without_verdict="$(grep -cvxF -f "${workdir}/decided" "${workdir}/planned" || true)"

# What the follow-up needs besides that count: the commits deferred past
# MAX_SHARDS, the oldest of the to-do list, so that it can ask the store about
# them rather than trust a count made at plan time; and the retry tip, when it
# is in the plan despite its verdict, so that it can tell whether this run judged
# it again. The `grep` reads an empty plan as "no patterns" and keeps every line,
# which is right: with no shard, every commit to build was deferred.
grep -vxF -f "${workdir}/planned" "${workdir}/todo" \
  | jq -Rsc 'split("\n") | map(select(length > 0))' > "${workdir}/deferred.json" || true
planned_retry_tip=""
if [ -n "${retry_tip}" ] && grep -qxF "${retry_tip}" "${workdir}/decided" \
    && grep -qxF "${retry_tip}" "${workdir}/planned"; then
  planned_retry_tip="${retry_tip}"
fi

jq -n \
  --arg branch "${branch}" \
  --arg head "$(git rev-parse HEAD)" \
  --arg since "${SINCE}" \
  --argjson replanned "${replanned}" \
  --argjson total "${total}" \
  --argjson skipped "${skipped}" \
  --argjson dropped "${dropped}" \
  --argjson without_verdict "${without_verdict}" \
  --slurpfile deferred_shas "${workdir}/deferred.json" \
  --arg retry_tip "${planned_retry_tip}" \
  --argjson budget "${SHARD_BUDGET_MINUTES}" \
  --argjson setup "${SETUP_MINUTES}" \
  --argjson full "${FULL_BUILD_MINUTES}" \
  --argjson floor "${FLOOR_MINUTES}" \
  --argjson objsec "${OBJECT_SECONDS}" \
  --slurpfile split "${workdir}/partition.json" \
  --slurpfile shards "${workdir}/shards.final.json" \
  '{
     branch: $branch,
     head: $head,
     since: $since,
     commits_in_range: $total,
     commits_already_decided: $skipped,
     commits_deferred: $dropped,
     deferred_shas: $deferred_shas[0],
     replanned_despite_verdict: $replanned,
     retry_tip: $retry_tip,
     planned_without_verdict: $without_verdict,
     cost_model: {
       setup_minutes: $setup,
       full_build_minutes: $full,
       per_commit_floor_minutes: $floor,
       per_object_seconds: $objsec,
       shard_budget_minutes: $budget
     },
     split: $split[0].split,
     shards: $shards[0]
   }' > "${OUT}"

# An `include`-only matrix with an empty array is not a valid matrix, and the
# job's `if:` guard is not something to bet the run on -- emit a parseable
# placeholder instead. The guard is what keeps it from ever being built.
if [ "${shards}" -eq 0 ]; then
  matrix='{"shard":["none"]}'
else
  matrix="$(jq -c '{
    include: [ .shards[]
      | { shard: .index,
          label: ((.commits | length | tostring) + " commits, ~" + (.estimate_minutes | floor | tostring) + " min") } ]
  }' "${OUT}")"
fi

planned="$(jq '[.shards[].commits | length] | add // 0' "${OUT}")"

echo "Plan written to ${OUT}: ${shards} shard(s), ${planned} commit(s), max-parallel ${parallel}"
# Listed by number, which is oldest slice first, and that is also the order the
# legs are queued in.
jq -r '.shards | sort_by(.index)[]
       | "  shard \(.index): \(.commits | length) commits, ~\(.estimate_minutes) min"' "${OUT}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "matrix=${matrix}"
    echo "shards=${shards}"
    echo "commits=${planned}"
    echo "deferred=${dropped}"
    echo "max_parallel=${parallel}"
  } >> "${GITHUB_OUTPUT}"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## each-rcc plan"
    echo
    echo "| | |"
    echo "| --- | --- |"
    echo "| Branch | \`${branch}\` |"
    echo "| Commits since \`${SINCE}\` | ${total} |"
    echo "| Already decided | ${skipped} |"
    echo "| Planned | ${planned} |"
    echo "| Deferred (matrix cap) | ${dropped} |"
    echo "| Shards | ${shards} (max-parallel ${parallel}) |"
    echo
    if [ "${shards}" -gt 0 ]; then
      jq -r '.split |
        "| Plan | Shards | Wall clock | Runner time |",
        "| --- | --- | --- | --- |",
        "| Fewest legs | \(.before.shards) | ~\(.before.makespan_minutes) min | ~\(.before.runner_minutes) min |",
        "| Rebalanced, factor \(.factor) (+\(.splits) legs) | \(.after.shards) | ~\(.after.makespan_minutes) min | ~\(.after.runner_minutes) min |"' \
        "${OUT}"
      echo
      echo "| Shard | Commits | Estimate | Invalidated objects (max) |"
      echo "| --- | --- | --- | --- |"
      jq -r '.shards | sort_by(.index)[]
             | "| \(.index) | \(.commits | length) | ~\(.estimate_minutes) min | \([.commits[].objects] | max) |"' "${OUT}"
      echo
      echo "Shard 1 is the oldest slice; the legs are queued oldest first, so shard 1 starts first."
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi
