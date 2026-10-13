#!/usr/bin/env bash
# Runs file-findings.sh against a fake `gh`: open, unchanged, update, a failed
# smoke test, a stale run, close. Needs bash and jq. `bash test.sh` prints ok.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/findings/changes-patch"
echo '[]' > "${tmp}/issues.json"

# Just enough of gh for file-findings.sh, with the issues in $STATE.
cat > "${tmp}/bin/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
body() { while [ "$1" != "--body-file" ]; do shift; done; echo "$2"; }
case "$1 $2" in
  api*) echo "${HEAD_SHA}" ;;
  "issue list") jq '[.[] | select(.state == "open") | {number, body}]' "${STATE}" ;;
  "issue create") jq --rawfile b "$(body "$@")" '. + [{number: (length + 1), body: $b, state: "open"}]' "${STATE}" > "${STATE}.new" ;;
  "issue edit") jq --argjson n "$3" --rawfile b "$(body "$@")" 'map(if .number == $n then .body = $b else . end)' "${STATE}" > "${STATE}.new" ;;
  "issue close") jq --argjson n "$3" 'map(if .number == $n then .state = "closed" else . end)' "${STATE}" > "${STATE}.new" ;;
esac
if [ -f "${STATE}.new" ]; then mv "${STATE}.new" "${STATE}"; fi
EOF
chmod +x "${tmp}/bin/gh"

run() {
  PATH="${tmp}/bin:${PATH}" STATE="${tmp}/issues.json" HEAD_SHA="${HEAD_SHA:-abc}" \
    GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=main GITHUB_SHA=abc GITHUB_WORKFLOW=rcc \
    GITHUB_RUN_ID=1 GITHUB_SERVER_URL=https://github.com \
    FINDINGS_DIR="${tmp}/findings" LABEL=ci-finding SMOKE_RESULT="${SMOKE:-success}" \
    bash "${here}/file-findings.sh" > /dev/null
}
expect() {
  local got
  got=$(jq -r 'map("\(.number):\(.state)") | join(" ")' "${tmp}/issues.json")
  if [ "${got}" != "$1" ]; then
    echo "$2: expected '$1', got '${got}'"
    exit 1
  fi
}
patch="${tmp}/findings/changes-patch/changes.patch"

printf '+a\n' > "${patch}"
run && expect "1:open" "a patch opens an issue"
run && expect "1:open" "the same patch opens no other"
printf '+b ```\n' > "${patch}"
run && expect "1:open" "a new patch updates the issue"
jq -e '.[0].body | contains("+b ```") and contains("````diff")' "${tmp}/issues.json" > /dev/null
rm "${patch}"
SMOKE=failure run && expect "1:open" "a failed smoke test closes nothing"
HEAD_SHA=def run && expect "1:open" "a stale run writes nothing"
run && expect "1:closed" "no patch closes the issue"
echo ok
