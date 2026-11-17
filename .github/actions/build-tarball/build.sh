#!/usr/bin/env bash
# Build, recompress and verify the source tarball, see action.yml.
# Writes `name`, `path`, `sha256` and `commit` to $GITHUB_OUTPUT.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

field() {
  Rscript --no-init-file -e "cat(read.dcf('DESCRIPTION', '$1'))"
}
package=$(field Package)
version=$(field Version)
name="${package}_${version}.tar.gz"

out="${RUNNER_TEMP}/tarball"
work="${RUNNER_TEMP}/tarball-work"
rm -rf "${out}" "${work}"
mkdir -p "${out}" "${work}"

# Built from a copy of the working tree, so that nothing the build does reaches
# the checkout: pkgbuild deletes `inst/doc` and runs `bootstrap.R`, and the steps
# after this one commit or report whatever changed in the checkout.
# The copy holds what the earlier steps of the job left there, as the check of
# the checkout did, but not `.git`.
copy="${RUNNER_TEMP}/tarball-src/${package}"
rm -rf "${RUNNER_TEMP}/tarball-src"
mkdir -p "${copy}"
before_status=$(git status --porcelain --untracked-files=all)
tar -c --exclude=./.git -f - . | tar -x -C "${copy}" -f -

# Run in the copy, with its `.Rprofile`, as `check-r-package` ran the build before.
echo "::group::Build the source tarball"
(cd "${copy}" && Rscript "${script_dir}/build.R" "${work}")
echo "::endgroup::"
rm -rf "${RUNNER_TEMP}/tarball-src"

after_status=$(git status --porcelain --untracked-files=all)
if [ "${before_status}" != "${after_status}" ]; then
  echo "::error title=The build changed the checkout::git status differs before and after the build:"
  diff <(printf '%s\n' "${before_status}") <(printf '%s\n' "${after_status}") || true
  exit 1
fi

if [ ! -f "${work}/${name}" ]; then
  echo "::error title=No source tarball::The build did not write ${name}."
  exit 1
fi

if ! command -v pigz > /dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y pigz
fi

# Zopfli for the runs whose tarball a CRAN submission may take, a push or a
# dispatch; it is slow on a large package, so other runs use plain `-9`.
case "${GITHUB_EVENT_NAME:-}" in
  push | workflow_dispatch) level=-11 ;;
  *) level=-9 ;;
esac

# `-n`: no file name and no time stamp in the gzip header.
gzip -dc "${work}/${name}" > "${work}/original.tar"
pigz "${level}" -n -c "${work}/original.tar" > "${out}/${name}"

gzip -t "${out}/${name}"
if ! gzip -dc "${out}/${name}" | cmp -s - "${work}/original.tar"; then
  echo "::error title=Recompression changed the tarball::${name} does not unpack to the tar stream R CMD build wrote."
  exit 1
fi

before=$(stat -c %s "${work}/${name}")
after=$(stat -c %s "${out}/${name}")
sha256=$(sha256sum "${out}/${name}" | cut -d ' ' -f 1)
rm -rf "${work}"

echo "${name}: ${before} bytes as built, ${after} bytes recompressed with pigz ${level}, SHA-256 ${sha256}"
{
  echo "name=${name}"
  echo "path=${out}/${name}"
  echo "sha256=${sha256}"
  echo "commit=$(git rev-parse HEAD)"
} >> "${GITHUB_OUTPUT}"
{
  echo "## Source tarball"
  echo
  echo "\`${name}\`, built from \`$(git rev-parse --short HEAD)\`, ${after} bytes, SHA-256 \`${sha256}\`."
} >> "${GITHUB_STEP_SUMMARY}"
