#!/usr/bin/env bash
# Summarize what `record-finding` left in `$RUNNER_TEMP/findings`.
set -euo pipefail

dir="${RUNNER_TEMP}/findings"
results="${dir}/results"

if [ ! -s "${results}" ]; then
  echo "No findings were recorded in this job."
  echo "found=" >> "${GITHUB_OUTPUT}"
  exit 0
fi

# A kind recorded more than once is found if any of its records found it.
kinds=$(cut -f1 "${results}" | awk '!seen[$0]++')
found=$(awk -F'\t' '$2 == "found" && !seen[$1]++ { print $1 }' "${results}")

rm -f "${dir}/changes.patch"
for kind in ${found}; do
  cat "${dir}/${kind}.patch" >> "${dir}/changes.patch"
done

found_csv=$(printf '%s\n' "${found}" | paste -sd, -)
echo "found=${found_csv}" >> "${GITHUB_OUTPUT}"

# A step summary is capped at 1 MiB, a snapshot patch with images is not.
max_bytes=100000

fence_for() {
  local longest
  longest=$(
    { grep -o '`\+' "$1" || true; } |
      awk '{ if (length($0) > n) n = length($0) } END { print n + 0 }'
  )
  if [ "${longest}" -lt 3 ]; then longest=2; fi
  printf '`%.0s' $(seq 1 $((longest + 1)))
}

{
  printf '## Findings: %s\n\n' "${NAME}"
  if [ -z "${found}" ]; then
    printf 'Nothing to fix.\n\n'
  else
    printf 'CI changes nothing in the repository.\n'
    printf 'The patches below are what it would have committed;\n'
    printf 'on the default branch they are filed as issues labelled `ci-finding`.\n\n'
  fi
  for kind in ${kinds}; do
    result=$(awk -F'\t' -v k="${kind}" '$1 == k { r = (r == "found" ? r : $2) } END { print r }' "${results}")
    printf -- '- `%s`: %s\n' "${kind}" "${result}"
  done
  printf '\n'
  for kind in ${found}; do
    patch="${dir}/${kind}.patch"
    fence=$(fence_for "${patch}")
    printf '<details>\n<summary><code>%s</code>: %s</summary>\n\n' "${kind}" "$(git apply --stat "${patch}" 2>/dev/null | tail -n 1 || true)"
    printf '%sdiff\n' "${fence}"
    head -c "${max_bytes}" "${patch}"
    printf '\n%s\n\n' "${fence}"
    if [ "$(wc -c < "${patch}")" -gt "${max_bytes}" ]; then
      printf '_Truncated at %s bytes, the artifact `findings-%s` holds the whole patch._\n\n' "${max_bytes}" "${NAME}"
    fi
    printf '</details>\n\n'
  done
} >> "${GITHUB_STEP_SUMMARY}"

if [ -n "${found}" ]; then
  echo "::warning title=Findings::CI would have changed: ${found_csv}. The job summary has the patches."
fi
