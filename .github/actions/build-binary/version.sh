#!/usr/bin/env bash
# Determine the version of the binary package, see action.yml.
# Writes `version` to $GITHUB_OUTPUT only when it differs from DESCRIPTION.

set -euo pipefail

version=$(sed -n 's/^Version:[[:space:]]*//p' DESCRIPTION | tr -d '[:space:]')
echo "Version in DESCRIPTION: ${version}"

if [ -f NEWS.md ] && grep -qF "NEWS.md is maintained by https://fledge.cynkra.com" NEWS.md; then
  echo "NEWS.md is maintained by fledge, which bumps the version with every commit."
  exit 0
fi

# Only a development version: a release, or a release candidate on a
# `cran-*` branch, keeps the version it declares.
dev=$(printf '%s' "${version}" | sed -nE 's/^[0-9]+[.-][0-9]+[.-][0-9]+[.-]([0-9]+)$/\1/p')
if [ -z "${dev}" ] || [ "${dev}" -lt 9000 ]; then
  echo "Not a development version, keeping it."
  exit 0
fi

# The checkout is shallow and has no tags.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  git fetch --quiet --unshallow --tags origin
else
  git fetch --quiet --tags origin
fi

# The last release is the highest release tag this commit contains:
# `v1.2.3` or `1.2.3`, never a development tag such as `v1.2.3.9001`.
tag=$(git tag --merged HEAD | grep -E '^v?[0-9]+[.-][0-9]+([.-][0-9]+)?$' | sort -V | tail -n 1 || true)
if [ -n "${tag}" ]; then
  commits=$(git rev-list --count --first-parent "${tag}..HEAD")
  echo "${commits} first-parent commits since ${tag}."
else
  commits=$(git rev-list --count --first-parent HEAD)
  echo "No release yet, ${commits} first-parent commits in all."
fi

version=$(printf '%s' "${version}" | sed -E "s/[0-9]+\$/$((9000 + commits))/")
echo "Version of the binary package: ${version}"
echo "version=${version}" >> "${GITHUB_OUTPUT}"

