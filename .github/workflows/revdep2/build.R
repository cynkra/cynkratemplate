# Build the package under test once, and prove the dependency world installs.
#
# Two deliverables, both consumed by every shard:
#
#   1. A source tarball and a platform binary of the checked-out (dev) package,
#      so no shard pays the compilation twice. Shards install the binary; the
#      tarball is kept alongside for reference and local reproduction.
#   2. A warmed pak package cache: this job installs the union of every
#      dependency any revdep needs into a scratch library -- which downloads
#      every binary exactly once into the cache that the workflow then saves
#      for the shards -- and then load-tests each installed package. Broken or
#      uninstallable dependencies surface here, before any shard has spent a
#      minute on checks, and are reported in depfail.json and the job summary.
#
# A dependency failure is a report, not a stop: shards attempt their own subset
# regardless (their PPM snapshot may succeed where this one failed), and a
# revdep whose dependencies genuinely cannot be installed fails its own check
# with an install log, which is the result a report can work with.
#
# Environment variables:
#   PLAN     - plan.json from plan.R (default: plan.json)
#   OUT_DIR  - where the tarball, binary, metadata and depfail report land
#              (default: pkg)

source(file.path(dirname(sub("--file=", "", grep("^--file=", commandArgs(), value = TRUE))), "util.R"))

plan_path <- env_chr("PLAN", "plan.json")
out_dir <- env_chr("OUT_DIR", "pkg")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

plan <- read_json(plan_path)
package <- plan$package
install_union <- unlist(plan$install_union, use.names = FALSE)

# ------------------------------------------------------------------- build ---

inform("Building ", package, " ", plan$dev_version)
status <- system2("R", c("CMD", "build", "--no-manual", "."))
if (status != 0) {
  stop("R CMD build failed", call. = FALSE)
}
tarball <- sort(
  list.files(pattern = sprintf("^%s_.*[.]tar[.]gz$", package)),
  decreasing = TRUE
)[[1]]

inform("Building the binary from ", tarball)
binary_dir <- file.path(out_dir, "bin")
dir.create(binary_dir, recursive = TRUE, showWarnings = FALSE)
build_lib <- tempfile("lib-")
dir.create(build_lib)
status <- system2(
  "R",
  c("CMD", "INSTALL", "--build", "-l", build_lib, tarball)
)
if (status != 0) {
  stop("R CMD INSTALL --build failed", call. = FALSE)
}
binary <- sort(
  list.files(pattern = sprintf("^%s_.*_R_.*[.]tar[.]gz$", package)),
  decreasing = TRUE
)[[1]]
file.rename(binary, file.path(binary_dir, binary))
file.copy(tarball, file.path(out_dir, tarball))

write_json(
  list(
    package = package,
    dev_version = plan$dev_version,
    cran_version = plan$cran_version,
    sha = plan$sha,
    r_version = plan$r_version,
    platform = R.version$platform,
    tarball = tarball,
    binary = file.path("bin", binary),
    built_at = now_utc()
  ),
  file.path(out_dir, "meta.json")
)
inform("Binary: ", binary)

# --------------------------------------------------------------- preflight ---

lib <- file.path(env_chr("RUNNER_TEMP", tempdir()), "revdep2-preflight-lib")
dir.create(lib, recursive = TRUE, showWarnings = FALSE)
failures <- list()

inform("Preflight: installing ", length(install_union), " packages")
installed_ok <- tryCatch(
  {
    pak::pkg_install(install_union, lib = lib, ask = FALSE)
    TRUE
  },
  error = function(e) {
    inform("Bulk install failed: ", conditionMessage(e))
    FALSE
  }
)
if (!installed_ok) {
  # One bad package must not hide the state of the other thousand: retry each
  # missing package on its own and record exactly which ones will not install.
  for (p in install_union) {
    if (dir.exists(file.path(lib, p))) {
      next
    }
    result <- tryCatch(
      {
        pak::pkg_install(p, lib = lib, ask = FALSE)
        NULL
      },
      error = function(e) conditionMessage(e)
    )
    if (!is.null(result)) {
      failures[[length(failures) + 1]] <- list(
        package = p,
        phase = "install",
        message = result
      )
    }
  }
}

# Load every installed dependency, in chunks small enough to stay clear of the
# DLL limit; a failing chunk is retried one package at a time so a single bad
# namespace names itself.
installed <- intersect(install_union, rownames(utils::installed.packages(lib)))
inform("Preflight: loading ", length(installed), " packages")
load_batch <- function(pkgs) {
  script <- tempfile(fileext = ".R")
  writeLines(
    c(
      sprintf(".libPaths(c(%s, .libPaths()))", deparse(lib)),
      "for (p in commandArgs(trailingOnly = TRUE)) {",
      "  loadNamespace(p)",
      "  writeLines(paste0('LOADED ', p))",
      "}"
    ),
    script
  )
  out <- suppressWarnings(system2(
    "Rscript",
    c("--vanilla", script, pkgs),
    stdout = TRUE,
    stderr = TRUE
  ))
  loaded <- sub("^LOADED ", "", grep("^LOADED ", out, value = TRUE))
  list(failed = setdiff(pkgs, loaded), log = out)
}
chunks <- split(installed, ceiling(seq_along(installed) / 40))
for (chunk in chunks) {
  first <- load_batch(chunk)
  if (length(first$failed) == 0) {
    next
  }
  for (p in first$failed) {
    single <- load_batch(p)
    if (length(single$failed) > 0) {
      failures[[length(failures) + 1]] <- list(
        package = p,
        phase = "load",
        message = paste(utils::tail(sanitize_log(single$log), 20), collapse = "\n")
      )
    }
  }
}

write_json(failures, file.path(out_dir, "depfail.json"))

# ------------------------------------------------------------------ summary --

append_summary(c(
  "## revdep2 build",
  "",
  sprintf(
    "Built `%s` %s (binary `%s`), preflighted %d dependencies: %d could not be installed or loaded.",
    package, plan$dev_version, binary, length(install_union), length(failures)
  ),
  ""
))
if (length(failures) > 0) {
  df <- data.frame(
    Package = vapply(failures, function(f) f$package, character(1)),
    Phase = vapply(failures, function(f) f$phase, character(1))
  )
  append_summary(md_table(df))
  for (f in failures) {
    append_summary(md_details(
      sprintf("<code>%s</code> &mdash; %s failure", f$package, f$phase),
      strsplit(f$message, "\n")[[1]]
    ))
  }
  inform(length(failures), " dependencies failed preflight; see depfail.json")
}
