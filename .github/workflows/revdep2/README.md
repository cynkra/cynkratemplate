# `revdep2` — sharded reverse-dependency checking

`.github/workflows/revdep2.yaml` checks every CRAN reverse dependency of the
package twice — once against the CRAN version, once against the checked-out
dev version — and reports the difference,
the way [revdepcheck](https://github.com/r-lib/revdepcheck) does,
but spread over as many GitHub Actions jobs as the batch needs.
The trade is deliberate:
runner minutes are spent (duplicate setup, duplicate dependency installs)
to buy wall clock,
where the older `revdep.yaml` spends one job per package
and `revdepcheck::revdep_check()` spends one machine for everything.

## Topology

```
plan     (1 job, ~2 min)
  ├─ enumerate revdeps, or take the retry/explicit list
  ├─ weigh each by CRAN's own check time for it
  ├─ resolve the baseline donor run, decide per package what is reusable
  └─ partition into shards → plan.json (artifact) + matrix (job output)

build    (1 job)
  ├─ R CMD build + R CMD INSTALL --build   → revdep2-pkg artifact
  └─ install + load *every* dependency any revdep needs
       → depfail.json, warm pak cache (saved under the plan hash)

test     (one job per shard, max-parallel throttled, fail-fast: false)
  ├─ install the shard's dependency union (pak, sysreqs on, warm cache)
  ├─ phase old: reuse baselines, check the rest against the CRAN version
  ├─ install the prebuilt dev binary
  ├─ phase new: check everything again, compare per package
  └─ results + manifest.ndjson → revdep2-results-<shard>-<attempt>

collect  (1 job, if: always() past plan/build)
  ├─ merge all shard attempts (+ carried results of a retried run)
  ├─ reports via revdepcheck: README.md, problems.md, failures.md, cran.md
  ├─ manifest.json, job summary, red/green verdict per fail-on
  └─ revdep2-report + revdep2-baseline artifacts
```

A failing check never fails a shard,
and a failing shard never aborts the run:
`fail-fast: false` isolates shard-level accidents,
the shard driver records per-package failure as data,
and the collector runs on `always()` past a successful plan and build.
The one red job a broken revdep can produce is `collect`,
under the `fail-on` input's rule.

## Weighing and partitioning

CRAN publishes per-package check times for each flavor;
`tools::CRAN_check_results()` carries them as `T_total`.
The planner takes the `r-release-linux-x86_64` flavor as the proxy
for what a check costs here:
one check ≈ `T_total`, a package without a reusable baseline pays two,
plus a small fixed overhead.
Packages CRAN has no timing for get the cohort median.

The shard count is demand-driven:
the smallest `K` whose average check load fits `shard-budget-minutes`
(default 45), capped by the 250-leg matrix limit.
A smaller budget buys wall clock with more shards;
the per-shard setup (~6 min: R, pandoc, TinyTeX, dependency install)
is the price of each extra shard.

Assignment is greedy, in two phases:

1. **Round-robin the heavyweights.**
   The `K` heaviest packages are dealt one per shard,
   so no two giants end up queued behind each other.
2. **Marginal-cost placement for the rest.**
   Every remaining package, heaviest first,
   goes to the shard where
   `load + weight + install_seconds × |dependencies the shard does not yet have|`
   is smallest.
   The install penalty (default 2.5 s per package, from a warm binary cache)
   is what pulls packages with overlapping dependency trees together,
   so a shard's install phase is amortised over packages that share it.

### Why greedy, not an exact optimisation

The exact problem is makespan minimisation with sequence-dependent setup
costs — bin packing crossed with a coverage objective —
which is NP-hard in both halves,
and the classic greedy (LPT: longest processing time first)
is already within 4/3 − 1/(3K) of the optimal makespan.
The inputs do not deserve better:
CRAN timings come from a different machine under different load,
install costs are a scalar guess,
and the actual runtime moves with cache hits and CRAN's own state.
An ILP or local-search pass could shave minutes off the plan on paper
and would still be wrong by more than that in practice —
and it would need a solver in a job whose entire budget is two minutes.
The greedy pass is O(n · K) with a bitmap per shard,
runs in well under a second for thousands of revdeps,
and its plans are inspectable
(the plan job's summary prints per-shard estimates and contents).

`each.yaml` in duckdb-r solves the mirror-image problem
(contiguous slices of a commit history, reuse via ccache adjacency);
its two-pass rebalancing exists because contiguity pins its cuts.
Here nothing is contiguous — any package can sit anywhere —
so the whole plan family collapses into the one greedy pass
and the only dial left is the budget.

## The CRAN baseline, and when it is reused

The old-version check of a revdep does not involve the dev code at all:
it is the CRAN version of this package, the revdep, and their dependencies.
Its result therefore outlives the run that produced it,
and re-checking it every run would double the bill for no information.

The collector publishes every old-version result as `revdep2-baseline`
(`baseline.json` plus one `old.rds` per package),
and the planner reuses an entry only when *everything that shaped it*
is unchanged:

| Criterion | Compared |
| --- | --- |
| revdep version | baseline vs `available.packages()` now |
| our CRAN version | baseline vs CRAN now |
| R series | baseline vs the runner's `major.minor` |
| dependency versions | md5 over the sorted `package version` lines of the revdep's whole install closure, from CRAN metadata |
| age | `checked_at` within `baseline-max-age-days` (default 30) |

The dependency fingerprint is the load-bearing one:
a tidyverse point release changes the environment an old check ran in,
and versions-of-us-and-them alone would happily reuse a result
that release just invalidated.
The age cap backstops what CRAN metadata cannot see —
the runner image, system libraries, network state.
Reuse does not refresh `checked_at`:
a result ages from the day it actually ran.
`refresh-baseline: true` ignores all of it for one run.

Baselines are looked up newest-run-first across the workflow's history
(any branch — the dev code plays no part in an old check),
and a retried run's own report doubles as its donor.
A missing, expired, or partially unusable baseline is never an error;
the affected packages are simply checked fresh.

## Results, artifacts, tooling

Every artifact this workflow writes:

| Artifact | Content | Lifetime |
| --- | --- | --- |
| `revdep2-plan` | `plan.json` | 30 days |
| `revdep2-pkg` | source tarball, platform binary, `meta.json`, `depfail.json` | 30 days |
| `revdep2-results-<shard>-<attempt>` | `manifest.ndjson`, `pkgs/<p>/{old,new}.rds`, kept check output | 30 days |
| `revdep2-report` | `README.md`, `problems.md`, `failures.md`, `cran.md`, `manifest.json`, all `pkgs/` | 90 days |
| `revdep2-baseline` | `baseline.json`, `old-rds/<p>.rds` | 90 days |

The reports are revdepcheck's own,
generated through its `results` injection point
(`cloud_report_summary()` and friends),
so `README.md` reads exactly like a local `revdep_check()`'s.

To fetch a run's results:

```sh
.github/workflows/revdep2/fetch.sh            # newest completed run
.github/workflows/revdep2/fetch.sh <run-id>   # a specific one
```

To re-check only what a run could not declare ok —
after fixing the code, after a flaky failure, after a deadline deferral:

```sh
gh workflow run revdep2.yaml -f retry-run=<run-id>
```

The retry's collector carries the donor run's untouched results over,
so its report is complete again, not a fragment.

## Failure modes

| Situation | Outcome |
| --- | --- |
| A revdep breaks under the dev version | `newly_broken` in manifest and report; run red only per `fail-on` |
| A revdep fails under both versions | `ok` (no *new* problems), visible in the report's tables |
| A check times out | rcmdcheck kills it at `REVDEP2_CHECK_TIMEOUT_MINUTES`; compared as `t-`, reported `failed` |
| A revdep's strong dependencies cannot install | `depfail`, check not attempted, named in the shard summary |
| A dependency fails the build-job preflight | reported in the build summary and `depfail.json`; shards still try their own subset |
| A shard hits its deadline | remaining packages `deferred`; finished old-halves still uploaded and baseline-fed |
| A shard job dies hard | its packages have no manifest entries; the collector reports what exists; `retry-run` re-plans the rest |
| A shard is re-run | new artifact per attempt; the collector lets the later attempt win per package |
| The baseline artifact is gone | planner reuses nothing, everything checked fresh |
| CRAN bumps a dependency mid-run | shards install what resolves at their start; the recorded fingerprint is the plan's — next run re-fingerprints |
| The package is not on CRAN | plan emits zero shards, run ends green |
| `collect` finds new problems | uploads everything first, then exits per `fail-on` |

## Knobs

| Knob | Input | Variable | Default |
| --- | --- | --- | --- |
| Packages to check | `packages` | — | all revdeps |
| Revdep set | `which` | — | `strong` |
| Retry a run | `retry-run` | — | — |
| Check-time target per shard | `shard-budget-minutes` | `REVDEP2_SHARD_BUDGET_MINUTES` | 45 |
| Concurrent shards | `max-parallel` | `REVDEP2_MAX_PARALLEL` | 20 |
| Ignore reusable baselines | `refresh-baseline` | — | false |
| Oldest reusable baseline | `baseline-max-age-days` | `REVDEP2_BASELINE_MAX_AGE_DAYS` | 30 days |
| Per-check timeout | — | `REVDEP2_CHECK_TIMEOUT_MINUTES` | 30 |
| Shard graceful deadline | — | `REVDEP2_DEADLINE_MINUTES` | 300 |
| Red-run rule | `fail-on` | — | `newly-broken` |

## Prior art

Surveyed before building this; what each contributed:

* [r-lib/revdepcheck](https://github.com/r-lib/revdepcheck) —
  the comparison model (old vs new `rcmdcheck`, `compare_checks()`),
  the report format, and the `results` injection point the collector uses.
  Its `cloud_check()` (one AWS Batch job per package, fetch, compare locally)
  is the closest architectural relative.
* [r-devel/recheck](https://github.com/r-devel/recheck) —
  CRAN-parity system libraries, binary-first dependency installs,
  and the honest framing that revdep results are diagnostics,
  too volatile for a pass/fail gate (hence `fail-on`).
* [yihui/crandalf](https://github.com/yihui/crandalf) —
  batching revdeps across CI jobs,
  and re-checking only previously failed packages (`retry-run` here).
* [HenrikBengtsson/revdepcheck.extras](https://github.com/HenrikBengtsson/revdepcheck.extras) —
  pre-installing the dependency universe before the checks start
  (the build job's preflight).
* duckdb-r's `each.yaml` —
  the plan/matrix/fan-in shape, cost-balanced shards under a budget,
  graceful deadlines with deferral, per-attempt artifacts,
  and empty-matrix/fallback-output hygiene.

No published workflow was found that balances revdep shards
by CRAN check timings or by dependency overlap;
that part is new here.

## Not yet validated

1. The cost model's constants
   (45 min budget, 6 min setup, 2.5 s per dependency install, 0.5 min
   per-package overhead) are estimates, not fits.
   Shard manifests record actual durations, so they can be fitted
   from real runs the way duckdb-r recalibrated `each`.
2. Bioconductor revdeps are out of scope:
   enumeration, versions and fingerprints all come from CRAN metadata.
3. The report generation leans on unexported revdepcheck internals
   (`try_compare_checks()`, `rcmdcheck_error()`) via `:::`,
   with a manifest-only fallback when they drift.
4. Baselines live in artifacts, whose retention caps reuse at 90 days
   and whose availability is per-repository;
   an orphan branch (the `rcc` model) would be durable and fetchable
   but grows the repository.
