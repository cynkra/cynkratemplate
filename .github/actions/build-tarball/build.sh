#!/usr/bin/env bash
# Build the source tarball, and recompress and verify it if RECOMPRESS is true, see action.yml.
# Writes `name`, `path`, `sha256`, `commit`, `recompressed` and `metadata` to $GITHUB_OUTPUT.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

commit=$(git rev-parse --verify "${REF:-HEAD}^{commit}")

case "${RECOMPRESS:-false}" in
  true | false) ;;
  *)
    echo "::error title=Invalid input::recompress must be true or false, not ${RECOMPRESS}."
    exit 1
    ;;
esac

field() {
  git show "${commit}:DESCRIPTION" | Rscript --no-init-file -e "cat(read.dcf(file('stdin'), '$1'))"
}
package=$(field Package)
version=$(field Version)
name="${package}_${version}.tar.gz"

out="${RUNNER_TEMP}/tarball"
work="${RUNNER_TEMP}/tarball-work"
rm -rf "${out}" "${work}"
mkdir -p "${out}" "${work}"

# Built from a copy of the commit's files, so that nothing the build does
# reaches the checkout (pkgbuild deletes `inst/doc` and runs `bootstrap.R`),
# and nothing the checkout holds besides that commit reaches the tarball:
# no uncommitted, untracked or ignored files, and no `.git`.
# Written through a temporary index, so that neither the checkout's index nor
# `export-ignore` attributes come into play.
copy="${RUNNER_TEMP}/tarball-src/${package}"
rm -rf "${RUNNER_TEMP}/tarball-src"
mkdir -p "${copy}"
before_status=$(git status --porcelain --untracked-files=all)
index="${RUNNER_TEMP}/tarball-index"
GIT_INDEX_FILE="${index}" git read-tree "${commit}"
GIT_INDEX_FILE="${index}" git --work-tree="${copy}" checkout-index -a -f
rm -f "${index}"

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

# Recompressed only when asked for, for the tarball a CRAN submission takes:
# zopfli (`pigz -11`) is slow on a large package, and no other run needs it.
# `-n`: no file name and no time stamp in the gzip header.
# Otherwise the tarball is exactly the file `pkgbuild::build()` wrote.
before=$(stat -c %s "${work}/${name}")
if [ "${RECOMPRESS:-false}" = "true" ]; then
  if ! command -v pigz > /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y pigz
  fi
  compression="pigz -11 -n"
  gzip -dc "${work}/${name}" > "${work}/original.tar"
  pigz -11 -n -c "${work}/original.tar" > "${out}/${name}"

  gzip -t "${out}/${name}"
  if ! gzip -dc "${out}/${name}" | cmp -s - "${work}/original.tar"; then
    echo "::error title=Recompression changed the tarball::${name} does not unpack to the tar stream R CMD build wrote."
    exit 1
  fi
  recompressed=true
else
  compression="R CMD build"
  mv "${work}/${name}" "${out}/${name}"
  recompressed=false
fi

after=$(stat -c %s "${out}/${name}")
sha256=$(sha256sum "${out}/${name}" | cut -d ' ' -f 1)
rm -rf "${work}"

# The sidecar `<name>.json`, uploaded as its own artifact next to the
# tarball's, so that the consumer can check what it downloaded.
# All values are plain: package names, versions and hex digests need no escaping.
meta="${RUNNER_TEMP}/tarball-meta"
rm -rf "${meta}"
mkdir -p "${meta}"
printf '{"name":"%s","sha256":"%s","commit":"%s","recompressed":%s,"compression":"%s"}\n' \
  "${name}" "${sha256}" "${commit}" "${recompressed}" "${compression}" > "${meta}/${name}.json"

if [ "${recompressed}" = "true" ]; then
  echo "${name}: ${before} bytes as built, ${after} bytes recompressed with ${compression} and verified, SHA-256 ${sha256}"
else
  echo "${name}: ${after} bytes as built, not recompressed, SHA-256 ${sha256}"
fi
{
  echo "name=${name}"
  echo "path=${out}/${name}"
  echo "sha256=${sha256}"
  echo "commit=${commit}"
  echo "recompressed=${recompressed}"
  echo "metadata=${meta}/${name}.json"
} >> "${GITHUB_OUTPUT}"
{
  echo "## Source tarball"
  echo
  if [ "${recompressed}" = "true" ]; then
    echo "\`${name}\`, built from \`${commit:0:7}\`, ${after} bytes, SHA-256 \`${sha256}\`, recompressed with \`${compression}\` and verified."
  else
    echo "\`${name}\`, built from \`${commit:0:7}\`, ${after} bytes, SHA-256 \`${sha256}\`, as \`R CMD build\` wrote it, not recompressed."
  fi
} >> "${GITHUB_STEP_SUMMARY}"
