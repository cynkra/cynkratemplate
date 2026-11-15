#!/usr/bin/env bash
# Build, recompress and verify the source tarball, see action.yml.
# Writes `name`, `path` and `sha256` to $GITHUB_OUTPUT.

set -euo pipefail

src=$(pwd)
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

# Outside the checkout, so that its `.Rprofile` does not run and nothing lands in the working tree.
echo "::group::R CMD build"
(cd "${work}" && R CMD build --no-manual "${src}")
echo "::endgroup::"

if [ ! -f "${work}/${name}" ]; then
  echo "::error title=No source tarball::R CMD build did not write ${name}."
  exit 1
fi

if ! command -v pigz > /dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y pigz
fi

# `-n`: no file name and no time stamp in the gzip header.
gzip -dc "${work}/${name}" > "${work}/original.tar"
pigz -11 -n -c "${work}/original.tar" > "${out}/${name}"

gzip -t "${out}/${name}"
if ! gzip -dc "${out}/${name}" | cmp -s - "${work}/original.tar"; then
  echo "::error title=Recompression changed the tarball::${name} does not unpack to the tar stream R CMD build wrote."
  exit 1
fi

before=$(stat -c %s "${work}/${name}")
after=$(stat -c %s "${out}/${name}")
sha256=$(sha256sum "${out}/${name}" | cut -d ' ' -f 1)
rm -rf "${work}"

echo "${name}: ${before} bytes from R CMD build, ${after} bytes recompressed, SHA-256 ${sha256}"
{
  echo "name=${name}"
  echo "path=${out}/${name}"
  echo "sha256=${sha256}"
} >> "${GITHUB_OUTPUT}"
{
  echo "## Source tarball"
  echo
  echo "\`${name}\`, built from \`$(git rev-parse --short HEAD)\`, ${after} bytes, SHA-256 \`${sha256}\`."
} >> "${GITHUB_STEP_SUMMARY}"
