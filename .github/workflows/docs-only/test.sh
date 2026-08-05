#!/usr/bin/env bash

# Self-test for `docs-only.sh`, run as the first step of the action.
# A classifier that wrongly says "documentation only" silently disables all
# checks, so it is worth the couple of seconds this takes.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${dir}/docs-only.sh"
patterns="${dir}/patterns.txt"

failures=0

expect() {
  local want="$1"
  shift

  local got
  got=$(printf '%s\n' "$@" | GITHUB_STEP_SUMMARY="" "${script}" "${patterns}" 2>/dev/null)

  if [ "${got}" = "${want}" ]; then
    echo "ok       ${want} <- $*"
  else
    echo "NOT OK   want ${want}, got ${got} <- $*" >&2
    failures=$((failures + 1))
  fi
}

# Documentation only
expect true "README.md"
expect true "NEWS.md"
expect true "README.md" "NEWS.md" "CONTRIBUTING.md"
expect true ".github/ISSUE_TEMPLATE/bug.yml"

# Tooling that neither ships nor runs
expect true ".gitignore"
expect true ".github/.gitignore"
expect true "cynkratemplate.Rproj"
expect true "renovate.json"

# Config that does have an effect, however harmless it looks
expect false ".gitattributes"
expect false ".Rprofile"
expect false "renv.lock"
expect false "air.toml"
expect false ".Rbuildignore"
# Ships unless the repository excludes it, so it is opt-in per repository
expect false "cran-comments.md"

# R code, tests, metadata
expect false "R/foo.R"
expect false "README.md" "R/foo.R"
expect false "tests/testthat/test-foo.R"
expect false "tests/testthat/_snaps/foo.md"
expect false "DESCRIPTION"
expect false "NAMESPACE"
expect false "LICENSE"
expect false "man/foo.Rd"
expect false "vignettes/foo.Rmd"

# Native code: nothing below is documentation, no matter how it is spelled
expect false "src/foo.c"
expect false "src/foo.cpp"
expect false "src/init.c"
expect false "src/Makevars"
expect false "src/Makevars.win"
expect false "src/README.md"
expect false "inst/include/foo.h"
expect false "configure"
expect false "configure.ac"
expect false "cleanup"
expect false "tools/config.R"

# The website and CI itself
expect false "_pkgdown.yml"
expect false "pkgdown/extra.scss"
expect false "inst/pkgdown/_pkgdown.yml"
expect false ".github/workflows/R-CMD-check.yaml"
expect false ".github/workflows/docs-only/patterns.txt"

# Patterns match the entire path, not a part of it
expect false "docs/README.md"
expect false "README.md.orig"
expect false "old-README.md"

# Nothing at all: we don't know what changed
expect false ""

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed." >&2
  exit 1
fi

echo "All tests passed."
