#!/usr/bin/env bash
# Record what the previous step changed, as `<kind>.patch` in `$RUNNER_TEMP/findings`,
# and its result as a `<kind>\t<result>` line in `results` there,
# where the result is `found`, `clean`, `unknown` or `skipped`.
#
# The measure is the tree, not the working directory:
# `git add -A` stages new files too, and leaves out what `.gitignore` leaves out,
# so a finding is what a commit of the working tree would have contained.
# The staged tree after each record is the baseline of the next one.
set -euo pipefail

dir="${RUNNER_TEMP}/findings"
mkdir -p "${dir}"

if ! printf '%s' "${KIND}" | grep -qE '^[a-z][a-z0-9-]*$'; then
  echo "::error title=record-finding::The kind must be one lowercase word, not '${KIND}'"
  exit 1
fi

git add -A
tree=$(git write-tree)

if [ "${KIND}" = "baseline" ]; then
  printf '%s\n' "${tree}" > "${dir}/base"
  echo "Recording the findings from tree ${tree}."
  exit 0
fi

if [ ! -s "${dir}/base" ]; then
  echo "::error title=record-finding::Call this action with 'kind: baseline' before the first step it records."
  exit 1
fi
base=$(cat "${dir}/base")

result=unknown
patch=$(mktemp)
git diff --binary "${base}" "${tree}" > "${patch}"

if [ -s "${patch}" ]; then
  result=found
  echo "The ${KIND} step changed:"
  git --no-pager diff --stat "${base}" "${tree}"
  cat "${patch}" >> "${dir}/${KIND}.patch"

  if [ "${ADAPT}" = "true" ]; then
    # Later findings are measured against the adapted tree.
    printf '%s\n' "${tree}" > "${dir}/base"
    echo "Keeping the change in the working tree for the steps that follow."
  else
    # The two-tree form of read-tree is a checkout from one tree to the other:
    # it restores what the step changed or deleted, and removes what it added.
    git read-tree -m -u "${tree}" "${base}"
    echo "Reverted the change, the steps that follow see the commit as pushed."
  fi
else
  case "${OUTCOME}" in
    success) result=clean ;;
    skipped | cancelled) result=skipped ;;
  esac
  echo "The ${KIND} step changed nothing (outcome: ${OUTCOME})."
fi
rm -f "${patch}"

printf '%s\t%s\n' "${KIND}" "${result}" >> "${dir}/results"

if [ "${result}" = "found" ]; then
  echo "found=true" >> "${GITHUB_OUTPUT}"
else
  echo "found=false" >> "${GITHUB_OUTPUT}"
fi
