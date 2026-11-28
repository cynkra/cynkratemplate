#!/usr/bin/env bash
# Points the release's checklist pull request at a reverse-dependency check run.
#
#   release-comment.sh
#     Reads the run's report from REPORT_DIR (`run.json` and `manifest.json`, as the collector writes them)
#     and looks for the release's checklist pull request:
#     the open pull request whose head is the branch REF of this repository
#     and whose body's first line, without a byte order mark and surrounding whitespace,
#     is `<!-- release-checklist: <package> <version> -->`, for the package and version the run checked.
#     That is the marker krlmlr/r-release-actions finds the checklist pull request by.
#     A head branch of this repository takes write access to push, so no author check is needed for a comment.
#     With exactly one such pull request, github-actions[bot]'s one comment there
#     that starts with `<!-- release-revdep: <package> <version> <workflow> <scope> -->`
#     is created or updated in place, with the run's link, its scope, the counts per result, and the newly broken packages.
#     Without one, or with more than one, it says so in the log and the step summary and writes nothing:
#     the run's summary page and its report artifact are the results either way.
#     Whether the report is also committed is the workflow's `commit` input, not this script's business.
#
# Environment:
#   GH_TOKEN, GH_REPO   the job's own token, with `pull-requests: write`, and the repository, owner/name;
#                       the comment is found among github-actions[bot]'s, which is who that token writes as
#   GH                  the gh command, default `gh`; a test stubs it
#   REPORT_DIR          the downloaded report artifact
#   ARTIFACT            the report artifact's name, as the comment names it
#   WORKFLOW            the workflow's name, part of the comment's marker
#   REF                 the checked ref, `refs/heads/` or not; only a branch can match a pull request's head
#   REPORT_COMMIT       the commit this run pushed its report as, empty where it pushed none
#   REPORT_PARENT       the commit that report commit sits on, after the rebase
#   WHICH, DEPTH, PART, PACKAGES
#                       the dispatch's scope; runs of another scope get a comment of their own
#   GITHUB_SERVER_URL, GITHUB_RUN_ID, GITHUB_STEP_SUMMARY
#
# Exit status: 0 when the comment was written or there is no single pull request to write it to, 1 on a failure.

# shellcheck disable=SC2016  # backticks in single quotes are Markdown, not command substitution
set -euo pipefail

repo=${GH_REPO:?}
gh=${GH:-gh}
bot='github-actions[bot]'
report=${REPORT_DIR:?}
workflow=${WORKFLOW:?}
artifact=${ARTIFACT:-}
ref=${REF:-}
ref=${ref#refs/heads/}
run_id=${GITHUB_RUN_ID:?}
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$run_id"

# The first line of a body, without a byte order mark and surrounding whitespace, as a jq filter,
# the same as krlmlr/r-release-actions' release-report.sh reads the checklist marker with.
first_line_jq='((.body // "") | split("\n")[0] // "") | sub("^[\\s﻿]+"; "") | sub("\\s+$"; "")'

notice() { echo "::notice title=$1::$2"; }
summary() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; }
fail() {
  echo "::error title=$1::$2"
  summary "- Release pull request: $2" ""
  exit 1
}
# Keeps a dispatch input to the characters a scope is written with, so that it cannot end the marker's comment.
clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9/=._, -'; }

if [ ! -f "$report/run.json" ] || [ ! -f "$report/manifest.json" ]; then
  notice "No report" "The run wrote no run.json and manifest.json; the release pull request is not told about it."
  exit 0
fi

pkg=$(jq -r '.package // ""' "$report/run.json")
version=$(jq -r '.dev_version // ""' "$report/run.json")
sha=$(jq -r '.sha // ""' "$report/run.json")
cran_version=$(jq -r '.cran_version // ""' "$report/run.json")
r_version=$(jq -r '.r_version // ""' "$report/run.json")
retry_of=$(jq -r '.retry_of // "0" | tostring' "$report/run.json")
[[ $pkg =~ ^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$ ]] || fail "Report" "run.json names no valid package: '$pkg'."
[[ $version =~ ^[0-9]+([.-][0-9]+)+$ ]] || fail "Report" "run.json names no valid version: '$version'."
[[ $sha =~ ^[0-9a-f]{7,40}$ ]] || sha=''
[[ $retry_of =~ ^[1-9][0-9]*$ ]] || retry_of=''
report_commit=${REPORT_COMMIT:-}
[[ $report_commit =~ ^[0-9a-f]{40}$ ]] || report_commit=''
report_parent=${REPORT_PARENT:-}
[[ $report_parent =~ ^[0-9a-f]{40}$ ]] || report_parent=''

ref_shown=$(clean "$ref")
if [ -z "$ref" ]; then
  notice "No branch" "No ref to look up; the results are on the run's summary page and in its artifact."
  exit 0
fi

# ------------------------------------------------------------- the pull request --

marker="<!-- release-checklist: $pkg $version -->"
owner=${repo%%/*}
ref_uri=$(printf '%s' "$ref" | jq -sRr @uri)
errf=$(mktemp)
# shellcheck disable=SC2064  # expand now
trap "rm -f '$errf'" EXIT
found=$("$gh" api --paginate "repos/$repo/pulls?state=open&per_page=100&head=$owner:$ref_uri" \
  --jq ".[] | [.number, .head.sha, (.head.repo.full_name // \"-\"), ($first_line_jq)] | @tsv" 2>"$errf") ||
  fail "Pull requests" "Listing the open pull requests of $repo failed: $(head -n 1 "$errf")."

prs=()
head_sha=''
while IFS=$'\t' read -r number head head_repo first; do
  [ -n "$number" ] || continue
  if [ "$head_repo" = "$repo" ] && [ "$first" = "$marker" ]; then
    prs+=("$number")
    head_sha=$head
  fi
done <<<"$found"

if [ "${#prs[@]}" -eq 0 ]; then
  notice "No release pull request" \
    "No open pull request from $ref_shown starts its body with $marker; the results are on the run's summary page and in its artifact."
  summary "- Release pull request: none for \`$ref_shown\` starts its body with \`$marker\`." ""
  exit 0
fi
if [ "${#prs[@]}" -gt 1 ]; then
  echo "::warning title=More than one release pull request::Open pull requests ${prs[*]/#/#} from $ref_shown all start with $marker; none is written to."
  summary "- Release pull request: ${prs[*]/#/#} all start with \`$marker\`; none is written to." ""
  exit 0
fi
pr=${prs[0]}

# ----------------------------------------------------------------------- scope --

packages=$(clean "${PACKAGES:-}")
if [ -n "$packages" ]; then
  case "${packages,,}" in
    broken | failed | report)
      scope_key="packages=broken"
      scope_text="the packages the report on the branch lists as broken or failed"
      ;;
    *)
      # Its own comment per list: the list, sorted, as a short hash.
      # shellcheck disable=SC2086  # split the cleaned list into words
      scope_key="packages=$(printf '%s\n' $packages | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u | sha256sum | cut -c1-8)"
      scope_text="selected packages ($packages)"
      ;;
  esac
else
  which=$(clean "${WHICH:-most}")
  depth=$(clean "${DEPTH:-1}")
  scope_key="which=$which depth=$depth"
  scope_text="\`which: $which\`, \`depth: $depth\`"
  part=$(clean "${PART:-}")
  if [ -n "$part" ]; then
    scope_key+=" part=$part"
    scope_text+=", \`part: $part\`"
  fi
fi
own="<!-- release-revdep: $pkg $version $workflow $scope_key -->"

# ------------------------------------------------------------------------ body --

m=$report/manifest.json
total=$(jq 'length' "$m")
count() { jq --arg r "$1" '[.[] | select(.result == $r)] | length' "$m"; }
newly=$(count newly_broken)
not_ok=$(jq '[.[] | select(.result != "ok")] | length' "$m")
carried=$(jq '[.[] | select(.carried == true)] | length' "$m")

if [ "$newly" -gt 0 ]; then
  headline="**$newly of $total packages newly broken.**"
elif [ "$not_ok" -gt 0 ]; then
  headline="No new breakage; $not_ok of $total packages could not be fully checked."
else
  headline="All good: no new problems in $total packages."
fi

label() {
  case "$1" in
    ok) echo "ok" ;;
    newly_broken) echo "newly broken" ;;
    failed) echo "failed to check" ;;
    timeout) echo "timed out, not checked" ;;
    depfail) echo "dependencies not installable" ;;
    depmissing) echo "dependencies unavailable to R CMD check" ;;
    error) echo "shard error" ;;
    deferred) echo "deferred" ;;
    missing) echo "no result from its shard" ;;
    *) printf '`%s`\n' "$(clean "$1")" ;;
  esac
}

body=$(mktemp)
# shellcheck disable=SC2064  # expand now
trap "rm -f '$errf' '$body'" EXIT
{
  echo "$own"
  echo "### Reverse dependencies: $workflow"
  echo
  printf '[Run %s](%s) checked `%s` %s' "$run_id" "$run_url" "$pkg" "$version"
  [ -z "$sha" ] || printf ' at %s' "$sha"
  [ -z "$cran_version" ] || printf ' against CRAN %s' "$cran_version"
  [ -z "$r_version" ] || printf ', under R %s' "$r_version"
  printf ', for %s' "$scope_text"
  [ -z "$retry_of" ] || printf ', retrying [run %s](%s)' "$retry_of" "${run_url%/*}/$retry_of"
  echo "."
  if [ -n "$report_commit" ]; then
    echo
    if [ -n "$sha" ] && [ "$report_parent" != "$sha" ]; then
      echo "This run committed its report to the branch as $report_commit, on top of ${report_parent:-a commit} that this run did not check."
    else
      echo "This run committed its report to the branch as $report_commit."
    fi
  fi
  # A head that is the report commit is covered by the line above, which warns where it sits on an unchecked commit.
  if [ -n "$sha" ] && [ -n "$head_sha" ] && [ "$head_sha" != "$sha" ] && [ "$head_sha" != "$report_commit" ]; then
    echo
    echo "The pull request's head is now $head_sha, which this run did not check."
  fi
  echo
  echo "$headline"
  echo
  for r in ok newly_broken failed timeout depfail depmissing error deferred missing; do
    n=$(count "$r")
    [ "$r" = ok ] || [ "$n" -gt 0 ] || continue
    echo "- $(label "$r"): $n"
  done
  jq -r '[.[].result] | unique | .[]
    | select(IN("ok", "newly_broken", "failed", "timeout", "depfail", "depmissing", "error", "deferred", "missing") | not)' "$m" |
    while IFS= read -r r; do
      echo "- $(label "$r"): $(count "$r")"
    done
  if [ "$carried" -gt 0 ]; then
    echo
    echo "$carried of these results were carried over from an earlier report rather than checked in this run."
  fi
  if [ "$newly" -gt 0 ]; then
    echo
    echo "New problems:"
    echo
    jq -r '[.[] | select(.result == "newly_broken")] | sort_by(.package | ascii_downcase) | .[:50][]
      | [.package, (.version // "?"), (.new_issues // 0 | tostring)] | @tsv' "$m" |
      while IFS=$'\t' read -r p v n; do
        [[ $p =~ ^[A-Za-z][A-Za-z0-9.]*$ ]] || continue
        echo "- [$p](https://cran.r-project.org/package=$p) $(clean "$v"): $(clean "$n") new issue(s)"
      done
    [ "$newly" -le 50 ] || echo "- ... and $((newly - 50)) more"
  fi
  echo
  printf "The run's summary page has the full report"
  [ -z "$artifact" ] || printf ", and its \`%s\` artifact the report files (\`gh run download %s --name %s\`)" "$artifact" "$run_id" "$artifact"
  echo "."
  echo "Later runs of $workflow for the same scope update this comment."
} >"$body"

# --------------------------------------------------------------------- comment --

ids=$("$gh" api --paginate "repos/$repo/issues/$pr/comments?per_page=100" \
  --jq ".[] | select(.user.login == \"$bot\") | [.id, ($first_line_jq)] | @tsv" 2>"$errf") ||
  fail "Comment" "Reading the comments of #$pr failed: $(head -n 1 "$errf"). Check that the job grants \`pull-requests: write\`."
id=''
while IFS=$'\t' read -r cid first; do
  [ "$first" != "$own" ] || id=$cid
done <<<"$ids"

if [ -n "$id" ]; then
  how=Updated
  url=$("$gh" api -X PATCH "repos/$repo/issues/comments/$id" -F "body=@$body" --jq .html_url 2>"$errf")
else
  how=Posted
  url=$("$gh" api -X POST "repos/$repo/issues/$pr/comments" -F "body=@$body" --jq .html_url 2>"$errf")
fi || fail "Comment" "Writing the comment on #$pr failed: $(head -n 1 "$errf"). Check that the job grants \`pull-requests: write\`."

echo "$how the revdep comment on #$pr: $url"
summary "- Release pull request: #$pr, [the revdep comment]($url) ($how)." ""
