#!/usr/bin/env bash
# Delete a branch only where a closed pull request in the same repository has that branch as its head,
# and the branch's tip is still the pull request's head, which GitHub keeps as `refs/pull/<n>/head`.
# A cloud session's git proxy refuses branch deletions, and "Automatically delete head branches" covers merged pull requests only.
#
# What it refuses, each with exit 1 and the reason in the step summary, before anything is pushed:
#   - the default branch, a protected branch, and, in any letter case, the long-lived names
#     `main`, `master`, `main-*`, `master-*`, `cran`, `cran-*`, `release*`, `docs*`, `gh-pages`, `upstream-main`, `archive/*`, `v[0-9]*`;
#   - a branch that does not exist, or a pull request with no head ref;
#   - a pull request that is not closed, whose head is another branch or a fork, or whose state cannot be read;
#   - a branch whose tip is not the pull request's head, that is, one that moved after the pull request closed;
#   - a branch that an open pull request has as its head or its base, or where either cannot be ruled out.
# The deletion is leased on the tip read, so a branch that moves after the checks is kept as well.
# The lease covers the tip only: a pull request reopened or opened between the reads and the push is closed by the deletion,
# its commits staying under its `refs/pull/<n>/head`.
#
# Usage: delete-branch.sh <branch> <pr>
#   <branch>  the branch's name without `refs/heads/`
#   <pr>      the pull request's number
# Anything else is a usage error, exit 2, before anything is read.
#
# Environment variables:
#   GH_TOKEN  token with contents:read and pull-requests:read on REPO, for `gh`
#   REPO      the repository, `owner/repo` (default: $GITHUB_REPOSITORY)
#   REMOTE    the git remote of REPO that takes the deletion (default: origin)

set -euo pipefail

REMOTE="${REMOTE:-origin}"

report() {
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n\n' "$*" >>"${GITHUB_STEP_SUMMARY}"
  fi
}
refuse() {
  report "delete-branch: refused, ${branch} is kept: $*"
  exit 1
}
usage() {
  echo "delete-branch: $*" >&2
  echo "usage: delete-branch.sh <branch> <pr>" >&2
  exit 2
}

[ $# -eq 2 ] || usage "expected two arguments, got $#"
branch=$1
pr=$2
# The inputs come from a dispatch, so they are checked before they reach a command.
case "${branch}" in
  -* | '') usage "the branch name must not be empty or start with '-'" ;;
esac
git check-ref-format "refs/heads/${branch}" || usage "'${branch}' is not a valid branch name"
[[ "${pr}" =~ ^[1-9][0-9]{0,8}$ ]] || usage "the pull request must be a positive whole number, not '${pr}'"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY is required}}"

case "${branch,,}" in
  main | master | main-* | master-* | cran | cran-* | release* | docs* | gh-pages | upstream-main | archive/* | v[0-9]*)
    refuse "its name is reserved for a long-lived branch"
    ;;
esac

# Only exact names count, since `git ls-remote` matches a pattern against the end of a ref name.
default=$(git ls-remote --symref "${REMOTE}" HEAD | sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p')
[ -n "${default}" ] || refuse "the default branch of ${REPO} could not be read"
[ "${branch}" != "${default}" ] || refuse "it is the default branch"
tips=$(git ls-remote "${REMOTE}" "refs/heads/${branch}" "refs/pull/${pr}/head")
tip=$(awk -v r="refs/heads/${branch}" '$2 == r { print $1 }' <<<"${tips}")
head=$(awk -v r="refs/pull/${pr}/head" '$2 == r { print $1 }' <<<"${tips}")
[ -n "${tip}" ] || refuse "no such branch in ${REPO}"
[ -n "${head}" ] || refuse "pull request #${pr} has no head in ${REPO}"
[ "${tip}" = "${head}" ] || refuse "its tip ${tip} is not the head of pull request #${pr}, ${head}"

pull=$(gh api "repos/${REPO}/pulls/${pr}" --jq '[.state, .head.ref, (.head.repo.full_name // "")] | @tsv') || pull=''
IFS=$'\t' read -r state head_ref head_repo <<<"${pull}" || true
case "${state:-}" in
  closed) ;;
  '') refuse "the state of pull request #${pr} could not be read" ;;
  *) refuse "pull request #${pr} is ${state}; deleting its head branch would close it" ;;
esac
if [ "${head_ref:-}" != "${branch}" ] || [ "${head_repo:-}" != "${REPO}" ]; then
  refuse "pull request #${pr} has ${head_repo:-an unknown repository}:${head_ref:-} as its head"
fi

uri=$(jq -rn --arg b "${branch}" '$b | @uri')
for side in head base; do
  if [ "${side}" = head ]; then query="head=${REPO%%/*}:${uri}"; else query="base=${uri}"; fi
  open=$(gh api "repos/${REPO}/pulls?state=open&${query}" --jq length) || open=''
  case "${open}" in
    0) ;;
    '' | *[!0-9]*) refuse "whether an open pull request has it as its ${side} could not be read" ;;
    *) refuse "an open pull request has it as its ${side}" ;;
  esac
done

protected=$(gh api "repos/${REPO}/branches/${uri}" --jq .protected) || protected=''
case "${protected}" in
  false) ;;
  true) refuse "it is protected" ;;
  *) refuse "whether it is protected could not be read" ;;
esac

if ! git push --force-with-lease="refs/heads/${branch}:${tip}" "${REMOTE}" ":refs/heads/${branch}"; then
  refuse "push rejected (lease, protection or ruleset); see the log above"
fi
report "delete-branch: deleted ${branch} at ${tip}, the head of closed pull request #${pr} in ${REPO}"
