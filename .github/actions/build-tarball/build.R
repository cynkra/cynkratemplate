# Build the source tarball as the `check` action's `R CMD check` of the checkout
# did: `rcmdcheck()` with `check-r-package`'s `build_args = "--no-manual"`
# calls pkgbuild with `manual = TRUE`, which adds `--no-resave-data` and
# honours `Config/build/*` in DESCRIPTION. See build.sh.
out <- commandArgs(trailingOnly = TRUE)[[1]]
pkgbuild::build(".", dest_path = out, args = "--no-manual", manual = TRUE)
