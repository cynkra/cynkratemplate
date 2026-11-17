#!/usr/bin/env bash
# Keep one issue per workflow and branch that holds what CI would change,
# from the `changes-patch*` artifacts that `report-findings` uploaded in this run.
# The issue is found by a hidden key in its body, and left alone while its patch is unchanged.
set -euo pipefail

repo="${GITHUB_REPOSITORY}"
ref="${GITHUB_REF_NAME}"
run_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${GITHUB_RUN_ID}"
key="<!-- ci-findings workflow=\"${GITHUB_WORKFLOW}\" ref=\"${ref}\" -->"

# Only the run for the branch's current head speaks for the branch.
if [ "$(gh api "repos/${repo}/commits/${ref}" --jq .sha)" != "${GITHUB_SHA}" ]; then
  echo "${ref} has moved on from ${GITHUB_SHA}, a newer run files its findings."
  exit 0
fi

gh label create "${LABEL}" --repo "${repo}" --force --color fbca04 \
  --description "Found by CI, to be fixed in a pull request" > /dev/null

issues=$(gh issue list --repo "${repo}" --label "${LABEL}" --state open --limit 500 --json number,body)
number=$(jq -r --arg key "${key}" '[.[] | select(.body | contains($key)) | .number] | min // empty' <<< "${issues}")

shopt -s nullglob
patches=("${FINDINGS_DIR}"/changes-patch*/changes.patch)

if [ "${#patches[@]}" -eq 0 ]; then
  # A smoke test that failed before or while reporting has not shown that the findings are gone.
  # ponytail: a matrix entry that died before its snapshot update can still close the issue, which the next run reopens.
  if [ -n "${number}" ] && [ "${SMOKE_RESULT}" = "success" ]; then
    gh issue close "${number}" --repo "${repo}" --reason completed \
      --comment "Nothing found any more by [this run](${run_url}) at ${GITHUB_SHA}."
  fi
  exit 0
fi

hash=$(cat "${patches[@]}" | sha256sum | cut -c1-16)
if [ -n "${number}" ] && jq -e --arg n "${number}" --arg h "hash=${hash}" \
  '.[] | select((.number | tostring) == $n) | .body | contains($h)' <<< "${issues}" > /dev/null; then
  echo "#${number} already holds this patch."
  exit 0
fi

# An issue body is capped at 65536 characters.
cap=$((50000 / ${#patches[@]}))
body=$(mktemp)
{
  printf '%s\n<!-- hash=%s -->\n\n' "${key}" "${hash}"
  printf 'Found by [this run](%s) at %s. ' "${run_url}" "${GITHUB_SHA}"
  printf 'CI does not push to `%s`; these are the changes it would have made.\n\n' "${ref}"
  printf -- '- Formatting: `air format .`\n'
  printf -- '- Documentation: `devtools::document()`\n'
  printf -- '- README: `devtools::build_readme()`\n'
  printf -- '- Snapshots: read the diff first. Accept intended changes with `testthat::snapshot_accept()`; anything else is a regression to fix in the code. A section from a matrix entry is a platform variant, take it from the patch.\n\n'
  printf 'Or apply a patch with `git apply`. '
  printf 'This issue closes itself once a run on `%s` finds nothing.\n\n' "${ref}"
  for patch in "${patches[@]}"; do
    name=$(basename "$(dirname "${patch}")")
    name=${name#changes-patch}
    name=${name#-}
    # Longer than any run of backticks in the patch, so that it cannot end the block.
    longest=$({ grep -o '`\+' "${patch}" || true; } | awk '{ n = length($0) > n ? length($0) : n } END { print n + 0 }')
    fence=$(printf '`%.0s' $(seq 1 $((longest < 3 ? 3 : longest + 1))))
    printf '### Patch from `%s`\n\n%sdiff\n' "${name:-smoke}" "${fence}"
    printf '%s\n' "$(head -c "${cap}" "${patch}")"
    printf '%s\n\n' "${fence}"
    if [ "$(wc -c < "${patch}")" -gt "${cap}" ]; then
      printf '_Truncated, the artifact of the run holds the whole patch._\n\n'
    fi
  done
} > "${body}"

if [ -n "${number}" ]; then
  gh issue edit "${number}" --repo "${repo}" --body-file "${body}" > /dev/null
  echo "Updated #${number}."
else
  gh issue create --repo "${repo}" --label "${LABEL}" --body-file "${body}" \
    --title "CI would change files on \`${ref}\`"
fi
