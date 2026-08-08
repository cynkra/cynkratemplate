<!-- NEWS.md is maintained by https://fledge.cynkra.com, contributors should not edit this file -->

# cynkratemplate 0.0.2.9025

## Continuous integration

- Name every step and restore the log entry `setup-pandoc` swallows.


# cynkratemplate 0.0.2.9024

## Continuous integration

- Add sharded `revdep2` workflow.

- Harden `workflow_run` workflows against untrusted pull requests (#106).

- Pin third-party actions to commits and let Renovate keep them pinned (#105).


# cynkratemplate 0.0.2.9023

## Chore

- Auto-update from GitHub Actions.

  Run: https://github.com/cynkra/cynkratemplate/actions/runs/30967492786

## Continuous integration

- Give every workflow and job an explicit `permissions` block (#103).

- Remove unused pr-commands workflow.

- Pass workflow context through the environment, not into script text (#102).

- Add a Windows arm64 (`windows-11-arm`) check on R-release (#99).


# cynkratemplate 0.0.2.9022

## Continuous integration

- Run all smoke-test checks even when one fails (#97).

- Apply matrix `env` vars in the workflow, not in custom actions (#95).

- Link the responsible workflow run in snapshot update PRs (#96).


# cynkratemplate 0.0.2.9021

## Continuous integration

- Lock down `format-suggest` egress (audit → block) (#94).


# cynkratemplate 0.0.2.9020

## Bug fixes

### ci

- Emit empty package matrix when there are no (rev)deps.

## Continuous integration

- Harden `format-suggest` against `pull_request_target` pwn requests (#93).


# cynkratemplate 0.0.2.9019

## Continuous integration

- Move GHA runners to Ubuntu 26.04 and add ragged Linux arm64 matrix (#88).


# cynkratemplate 0.0.2.9018

## Continuous integration

- Centralize R-CMD-check / install / roxygenize improvements from consumers (#87).


# cynkratemplate 0.0.2.9017

## Continuous integration

- Update ccache-action reference.

- Bump action version.


# cynkratemplate 0.0.2.9016

## Continuous integration

- Unify fledge.yaml across cynkratemplate and fledge (#86).


# cynkratemplate 0.0.2.9015

## Chore

- Add ccache to `.gitignore` and `.Rbuildignore`.

## Continuous integration

- Create snapshot update PR against correct branch.

- Add reference to `/apply-patch` workflow in commit message.

- Clarify rationale for not deploying on schedule.


# cynkratemplate 0.0.2.9014

## Chore

- Update `.Rbuildignore`.

## Continuous integration

- Only run fledge on pushes to main.

- Tweak fledge workflow and ccache action.


# cynkratemplate 0.0.2.9013

## Continuous integration

- Prettier.


# cynkratemplate 0.0.2.9012

## Continuous integration

- Tweak fledge and ccache workflows.


# cynkratemplate 0.0.2.9011

## Continuous integration

- Cosmetics.

- Bump action versions.

- Bump version.

- Align with igraph and duckdb.

- Use clang-format-21.

- Harmonize.


# cynkratemplate 0.0.2.9010

## Chore

- Auto-update from GitHub Actions.

  Run: https://github.com/cynkra/cynkratemplate/actions/runs/25267060822


# cynkratemplate 0.0.2.9009

## Chore

- Auto-update from GitHub Actions.

  Run: https://github.com/cynkra/cynkratemplate/actions/runs/22789328875


# cynkratemplate 0.0.2.9008

## Continuous integration

- Fix comment (#84).

- Tweaks (#83).

- Test all R versions on branches that start with cran- (#82).


# cynkratemplate 0.0.2.9007

## Continuous integration

- Install binaries from r-universe for dev workflow (#81).


# cynkratemplate 0.0.2.9006

## Continuous integration

- Fix reviewdog and add commenting workflow (#80).


# cynkratemplate 0.0.2.9005

## Chore

- Auto-update from GitHub Actions.

  Run: https://github.com/cynkra/cynkratemplate/actions/runs/17450844942

## Continuous integration

- Use workflows for fledge (#79).

- Sync (#78).

- Use reviewdog for external PRs (#77).

- Cleanup and fix macOS (#76).

- Format with air, check detritus, better handling of `extra-packages` (#75).


# cynkratemplate 0.0.2.9004

## Continuous integration

- Enhance permissions for workflow (#74).


# cynkratemplate 0.0.2.9003

## Continuous integration

- Permissions, better tests for missing suggests, lints (#73).


# cynkratemplate 0.0.2.9002

## Continuous integration

- Only fail covr builds if token is given (#72).

- Always use `_R_CHECK_FORCE_SUGGESTS_=false` (#71).


# cynkratemplate 0.0.2.9001

## Continuous integration

- Correct installation of xml2 (#69).


# cynkratemplate 0.0.2.9000

## Features

- Update the top navbar according to the new design (#55, #63).

## Continuous integration

- Explain (#68).

- Add xml2 for covr, print testthat results (#67).

- Change workflow as this is not meant for CRAN @krlmlr.

- Fix (#66).

- Sync (#65).

## Documentation

- Increment version number.


# cynkratemplate 0.0.1.9008

## Chore

- Auto-update from GitHub Actions.

  Run: https://github.com/cynkra/cynkratemplate/actions/runs/14607314672


# cynkratemplate 0.0.1.9007

## Bug fixes

- List renovate.json in .Rbuildignore.

## Chore

- Fix RCC.

- Auto-update from GitHub Actions.

  Run: https://github.com/cynkra/cynkratemplate/actions/runs/14280339496

### deps

- Update nick-fields/retry action to v3 (#50).

### deps

- Update peter-evans/create-pull-request action to v6 (#51).

### deps

- Update dessant/lock-threads action to v5 (#47).

### deps

- Update actions/cache action to v4 (#48).

## Continuous integration

- Sync (#59).

- cynkratemplate to be continuously deployed.

## Documentation

- Add cynkra's ROR (#56).

- Set BS version explicitly for now.

  https://github.com/cynkra/cynkratemplate/issues/53


# cynkratemplate 0.0.1.9006

- Internal changes only.


# cynkratemplate 0.0.1.9005

- Merge pull request #42 from cynkra/maelle-patch-2.


# cynkratemplate 0.0.1.9004

- Internal changes only.


# cynkratemplate 0.0.1.9003

- Internal changes only.


# cynkratemplate 0.0.1.9002

- Internal changes only.


# cynkratemplate 0.0.1.9001

## Features

- Use_cynkra_pkgdown() (#6, #28, #29).

## Uncategorized

- Harmonize yaml formatting.

- Revert changes to matrix section.

- Merge pull request #25 from cynkra/docs-logo-nav.

Improve logo for navbar & footer

- Merge pull request #18 from maelle/bs5.



- Merge branch 'main' of github.com:cynkra/cynkratemplate.



# cynkratemplate 0.0.1.9000

* Added a `NEWS.md` file to track changes to the package.
