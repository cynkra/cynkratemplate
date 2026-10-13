#!/usr/bin/env bash
# File the findings of this run as issues, one per kind of finding.
#
# Each issue carries a hidden key in its body,
#   <!-- ci-finding workflow="rcc" ref="main" kind="style" -->
# which is what makes it the issue for that kind on that branch,
# and a hash of its patches, which is how an unchanged finding is left alone.
# The label is only the filter: an issue counts when it is open,
# carries the label, and has the key.
#
# The input is one directory per artifact, `findings-<source>`,
# as the `report-findings` action uploads it:
# a `results` file of `<kind>\t<result>` lines and a `<kind>.patch` per kind found.
set -euo pipefail

repo="${GITHUB_REPOSITORY}"
ref="${GITHUB_REF_NAME}"
sha="${GITHUB_SHA}"
workflow="${GITHUB_WORKFLOW}"
run_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${GITHUB_RUN_ID}"

# Only the run for the branch's current head speaks for the branch.
head=$(gh api "repos/${repo}/commits/${ref}" --jq .sha)
if [ "${head}" != "${sha}" ]; then
  echo "::notice title=Findings::${ref} has moved on from ${sha} to ${head}, the run for ${head} files its findings."
  exit 0
fi

shopt -s nullglob
sources=("${FINDINGS_DIR}"/findings-*/)
if [ "${#sources[@]}" -eq 0 ]; then
  echo "No findings were reported in this run, nothing to file or close."
  exit 0
fi

# The result of a kind in one source: found beats unknown beats clean beats skipped.
result_of() {
  awk -F'\t' -v k="$2" '
    $1 == k { seen[$2] = 1 }
    END {
      if (seen["found"]) print "found"
      else if (seen["unknown"]) print "unknown"
      else if (seen["clean"]) print "clean"
      else print "skipped"
    }
  ' "$1/results"
}

source_name() {
  local name
  name=$(basename "$1")
  printf '%s' "${name#findings-}"
}

fence_for() {
  local longest
  longest=$(
    { grep -o '`\+' "$1" || true; } |
      awk '{ if (length($0) > n) n = length($0) } END { print n + 0 }'
  )
  if [ "${longest}" -lt 3 ]; then longest=2; fi
  printf '`%.0s' $(seq 1 $((longest + 1)))
}

title_for() {
  case "$1" in
    style) printf 'Formatting differs from `air format` on `%s`' "${ref}" ;;
    roxygen) printf 'Generated documentation is out of date on `%s`' "${ref}" ;;
    snapshots) printf 'Snapshots differ from the test output on `%s`' "${ref}" ;;
    readme) printf '`README.md` is out of date with `README.Rmd` on `%s`' "${ref}" ;;
    *) printf 'CI finding `%s` on `%s`' "$1" "${ref}" ;;
  esac
}

# GitHub renders a single newline in an issue body as a line break,
# so each paragraph is one line.
advice_for() {
  case "$1" in
    style)
      printf '%s\n' 'The sources are not formatted the way `air format .` formats R code, or the way `clang-format` formats C and C++ code where the package has a `.clang-format`. Run the formatter, or apply the patch below as it stands: formatting changes nothing that a test can see.'
      ;;
    roxygen)
      printf '%s\n' 'The committed `man/` pages, `NAMESPACE` or `Collate` field are not what roxygen2 generates from the sources. CI regenerated them before checking, so the checks saw the regenerated files, but the repository still holds the stale ones, and those are what an installation from GitHub gets. Run `devtools::document()`, or apply the patch below. CI leaves the roxygen2 version recorded in `DESCRIPTION` alone, so the patch never touches it.'
      ;;
    snapshots)
      printf '%s\n' 'The tests produce output that differs from the recorded snapshots, so they fail until one of the two changes. Read the diff first. Where the new output is intended, accept it with `testthat::snapshot_accept()` or apply the patch below; where it is not, the code regressed, and the fix belongs in the code.'
      printf '\n%s\n' 'A section from an entry of the version matrix holds a variant for that platform, which can only be regenerated there, so take it from the patch.'
      ;;
    readme)
      printf '%s\n' '`README.md`, and `index.md` where `README.Rmd` writes it, is not what `README.Rmd` renders to. Re-render with `devtools::build_readme()`, or apply the patch below.'
      printf '\n%s\n' 'A README that differs on every render does not render reproducibly: fix that in its setup chunk, or set `Config/cynkra/render-readme: false` in `DESCRIPTION` until it does.'
      ;;
    *)
      printf 'The `%s` step of CI would have changed the files in the patch below.\n' "$1"
      ;;
  esac
}

gh label create "${LABEL}" --repo "${repo}" --force \
  --color "fbca04" \
  --description "Found by CI, to be fixed in a pull request" > /dev/null

open_issues=$(
  gh issue list --repo "${repo}" --label "${LABEL}" --state open \
    --limit 500 --json number,body
)

kinds=$(cat "${FINDINGS_DIR}"/findings-*/results 2> /dev/null | cut -f1 | sort -u)

# Patches beyond this are cut, an issue body is capped at 65536 characters.
budget=50000

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

for kind in ${kinds}; do
  key="ci-finding workflow=\"${workflow}\" ref=\"${ref}\" kind=\"${kind}\""
  number=$(
    jq -r --arg key "${key}" \
      '[.[] | select(.body | contains($key)) | .number] | min // empty' \
      <<< "${open_issues}"
  )

  found_in=()
  clean_in=()
  unknown_in=()
  for src in "${sources[@]}"; do
    [ -f "${src}/results" ] || continue
    case "$(result_of "${src}" "${kind}")" in
      found) found_in+=("${src}") ;;
      clean) clean_in+=("${src}") ;;
      unknown) unknown_in+=("${src}") ;;
    esac
  done

  # Closing takes a clean check and no failed one: a step that failed
  # before it changed anything says nothing about the finding.
  if [ "${#found_in[@]}" -eq 0 ]; then
    if [ "${#clean_in[@]}" -gt 0 ] && [ "${#unknown_in[@]}" -eq 0 ] && [ -n "${number}" ]; then
      echo "Closing #${number}: ${kind} not found on ${ref} any more."
      gh issue close "${number}" --repo "${repo}" --reason completed \
        --comment "Not found any more by [this run](${run_url}) on \`${ref}\` at ${sha}."
    else
      echo "${kind}: nothing found, no open issue to close or nothing checked it."
    fi
    continue
  fi

  hash=$(
    for src in "${found_in[@]}"; do
      source_name "${src}"
      cat "${src}/${kind}.patch"
    done | sha256sum | cut -c1-16
  )

  if [ -n "${number}" ] &&
    jq -e --arg n "${number}" --arg h "ci-finding-hash: ${hash}" \
      '.[] | select((.number | tostring) == $n) | .body | contains($h)' \
      <<< "${open_issues}" > /dev/null; then
    echo "${kind}: #${number} already shows this patch."
    continue
  fi

  cap=$((budget / ${#found_in[@]}))
  body="${work}/${kind}.md"
  {
    printf '<!-- %s -->\n' "${key}"
    printf '<!-- ci-finding-hash: %s -->\n\n' "${hash}"
    printf 'Found by [this run](%s) of `%s` on `%s` at %s.\n\n' "${run_url}" "${workflow}" "${ref}" "${sha}"
    advice_for "${kind}"
    printf '\n'
    printf 'Apply a patch with `git apply` at the root of a checkout of %s or later. ' "${sha}"
    printf 'Fix this in a pull request that closes this issue; '
    printf 'otherwise it closes itself once a run on `%s` no longer finds it.\n\n' "${ref}"
    for src in "${found_in[@]}"; do
      name=$(source_name "${src}")
      patch="${src}/${kind}.patch"
      fence=$(fence_for "${patch}")
      printf '### Patch from `%s`\n\n' "${name}"
      printf '%sdiff\n' "${fence}"
      head -c "${cap}" "${patch}"
      printf '\n%s\n\n' "${fence}"
      if [ "$(wc -c < "${patch}")" -gt "${cap}" ]; then
        printf '_Truncated at %s bytes. The artifact `findings-%s` of the run holds the whole patch, until it expires._\n\n' "${cap}" "${name}"
      fi
    done
  } > "${body}"

  if [ -n "${number}" ]; then
    echo "Updating #${number} with the new ${kind} patch."
    gh issue edit "${number}" --repo "${repo}" --body-file "${body}" > /dev/null
  else
    echo "Opening an issue for ${kind}."
    gh issue create --repo "${repo}" --label "${LABEL}" \
      --title "$(title_for "${kind}")" --body-file "${body}"
  fi
done
