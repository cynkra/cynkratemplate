# Build and install the binary package, see action.yml.

src <- normalizePath(".")
version <- Sys.getenv("VERSION")

desc_path <- file.path(src, "DESCRIPTION")
desc_orig <- readBin(desc_path, "raw", file.size(desc_path))
if (nzchar(version)) {
  lines <- readLines(desc_path, warn = FALSE)
  lines <- sub("^Version:.*$", paste0("Version: ", version), lines)
  writeLines(lines, desc_path)
}

# An empty directory of its own, because `R CMD INSTALL --build`
# writes the binary into the working directory under a name that
# differs by platform: `.tar.gz` with the platform in it on Linux,
# `.tgz` on macOS, `.zip` on Windows. Not the checkout, where the
# binary would end up in the source tarball and in commits.
out_dir <- file.path(Sys.getenv("RUNNER_TEMP"), "build-binary")
unlink(out_dir, recursive = TRUE)
dir.create(out_dir, recursive = TRUE)

# Into the default library, so that later steps find it installed.
status <- tryCatch(
  {
    setwd(out_dir)
    # Quoted: system2() quotes the command, but not the arguments.
    system2(file.path(R.home("bin"), "R"), c("CMD", "INSTALL", "--build", shQuote(src)))
  },
  finally = writeBin(desc_orig, desc_path)
)
if (status != 0) {
  stop("`R CMD INSTALL --build` failed.", call. = FALSE)
}

file <- list.files(out_dir)
if (length(file) != 1) {
  stop(
    "Expected one binary package, found: ", paste(file, collapse = ", "),
    call. = FALSE
  )
}

artifact <- gsub("[^A-Za-z0-9._-]+", "-", paste0("binary-", Sys.getenv("NAME")))
artifact <- sub("-+$", "", artifact)

writeLines(
  c(
    paste0("artifact-name=", artifact),
    paste0("path=", file.path(out_dir, file)),
    paste0("file=", file),
    paste0("r-version=", R.version.string),
    paste0("platform=", R.version$platform)
  ),
  Sys.getenv("GITHUB_OUTPUT")
)

