#!/usr/bin/env bash

# Self-test for `delete-branch.sh`, run as the first step of the action.
# A guard that wrongly lets a deletion through loses a branch, so it is worth the second this takes.
# It runs the script against a local bare repository, with a stand-in for `gh` on the PATH.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${dir}/delete-branch.sh"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# The stand-in answers the two calls the script makes from FAKE_PULL and FAKE_PROTECTED; an empty answer fails.
mkdir "${tmp}/bin"
cat >"${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  */pulls/*) out=${FAKE_PULL} ;;
  */branches/*) out=${FAKE_PROTECTED} ;;
esac
[ -n "${out}" ] || exit 1
printf '%s\n' "${out}"
EOF
chmod +x "${tmp}/bin/gh"
export PATH="${tmp}/bin:${PATH}"
export REMOTE="${tmp}/remote.git" REPO=o/r GITHUB_STEP_SUMMARY=""

git init -q --bare -b main "${REMOTE}"
git init -q -b main "${tmp}/work"
work() { git -C "${tmp}/work" "$@"; }
work commit -q --allow-empty -m one
one=$(work rev-parse HEAD)
work commit -q --allow-empty -m two
two=$(work rev-parse HEAD)

# Sets up the remote: `<branch>` at `<tip>`, and pull request 1's head at `<head>`.
setup() { # <branch> <tip> <head>
  rm -rf "${REMOTE}"
  git init -q --bare -b main "${REMOTE}"
  work push -q "${REMOTE}" "${one}:refs/heads/main" "$3:refs/pull/1/head"
  if [ "$1" != main ] && git check-ref-format "refs/heads/$1"; then
    work push -q "${REMOTE}" "$2:refs/heads/$1"
  fi
}

failures=0

expect() { # <want status> <branch> <tip> <head> <pull> <protected> [<pr>]
  local want=$1 branch=$2 tip=$3 head=$4 pull=$5 protected=$6 pr=${7-1}
  setup "${branch}" "${tip}" "${head}"
  local got=0
  FAKE_PULL=${pull} FAKE_PROTECTED=${protected} "${script}" "${branch}" "${pr}" >/dev/null 2>&1 || got=$?
  # A usage error reads nothing, so only a refusal has to leave the branch in place.
  local kept=yes want_kept=yes
  git --git-dir="${REMOTE}" rev-parse -q --verify "refs/heads/${branch}" >/dev/null 2>&1 || kept=no
  case "${want}" in
    0) want_kept=no ;;
    2) want_kept=${kept} ;;
  esac
  local label="${branch} tip=${tip:0:7} head=${head:0:7} pull='${pull}' protected='${protected}' pr=${pr}"
  if [ "${got}" = "${want}" ] && [ "${kept}" = "${want_kept}" ]; then
    echo "ok       exit ${got}, kept ${kept} <- ${label}"
  else
    echo "NOT OK   want exit ${want}, got ${got}, kept ${kept} <- ${label}" >&2
    failures=$((failures + 1))
  fi
}

closed=$'closed\tfeature\to/r'

# Deleted: a closed pull request's head, unmoved
expect 0 feature "${two}" "${two}" "${closed}" false
expect 0 claude/x "${two}" "${two}" $'closed\tclaude/x\to/r' false

# Moved after the pull request closed, or never its head
expect 1 feature "${two}" "${one}" "${closed}" false

# Open, or a state that cannot be read
expect 1 feature "${two}" "${two}" $'open\tfeature\to/r' false
expect 1 feature "${two}" "${two}" "" false

# The pull request's head is another branch, or a fork's
expect 1 feature "${two}" "${two}" $'closed\tother\to/r' false
expect 1 feature "${two}" "${two}" $'closed\tfeature\tfork/r' false
expect 1 feature "${two}" "${two}" $'closed\tfeature\t' false

# Protected, or protection that cannot be read
expect 1 feature "${two}" "${two}" "${closed}" true
expect 1 feature "${two}" "${two}" "${closed}" ""

# Reserved names, whatever the pull request says
for b in main docs docs-dev cran-0.1.0 release release-1.0 upstream-main gh-pages archive/old; do
  expect 1 "${b}" "${one}" "${one}" "closed"$'\t'"${b}"$'\t'"o/r" false
done

# A pull request with no head ref
expect 1 feature "${two}" "${two}" "${closed}" false 2

# Usage errors
expect 2 -x "${two}" "${two}" "${closed}" false
expect 2 "a..b" "${two}" "${two}" "${closed}" false
expect 2 feature "${two}" "${two}" "${closed}" false 0
expect 2 feature "${two}" "${two}" "${closed}" false "1; true"

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed." >&2
  exit 1
fi

echo "All tests passed."
