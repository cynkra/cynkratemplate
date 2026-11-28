# Determine active versions of R to test against

# The packages this script calls into.
# A caller that has not been updated to install them still gets a working action:
# the missing ones are installed here, with a warning in the run's summary.
needed <- c("curl", "xml2", "jsonlite", "desc")
missing <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  cat(
    "::warning::The versions-matrix action is installing the R packages ",
    paste(missing, collapse = ", "),
    ". Add ",
    paste0("any::", missing, collapse = " "),
    " to the packages that the setup step before it installs.\n",
    sep = ""
  )
  # The warnings raised while installing, such as "package 'x' is not available",
  # which say why a package is still missing afterwards.
  # They are collected, not muffled, so they still show when the installation succeeds.
  install_warnings <- character()
  tryCatch(
    withCallingHandlers(
      if (requireNamespace("pak", quietly = TRUE)) {
        pak::pak(paste0("any::", missing))
      } else {
        install.packages(missing)
      },
      warning = function(w) {
        install_warnings <<- c(install_warnings, conditionMessage(w))
      }
    ),
    error = function(e) {
      stop(
        "Could not install the R packages ", paste(missing, collapse = ", "),
        " that the versions-matrix action needs: ", conditionMessage(e)
      )
    }
  )
  still_missing <- missing[!vapply(missing, requireNamespace, logical(1), quietly = TRUE)]
  if (length(still_missing) > 0) {
    stop(
      "Could not install the R packages ", paste(still_missing, collapse = ", "),
      " that the versions-matrix action needs.",
      if (length(install_warnings) > 0) {
        paste0(" The installation warned: ", paste(install_warnings, collapse = "; "))
      }
    )
  }
}

# Runs `f()` up to four times, waiting 5, 10 and 20 seconds between attempts.
# svn.r-project.org drops connections from GitHub runners now and then,
# and a transient failure should not fail the whole check.
with_retries <- function(f, what, waits = c(5, 10, 20)) {
  for (attempt in seq_len(length(waits) + 1)) {
    result <- tryCatch(f(), error = identity)
    if (!inherits(result, "error")) {
      return(result)
    }
    message(
      "Attempt ", attempt, " to read ", what, " failed: ",
      conditionMessage(result)
    )
    if (attempt <= length(waits)) {
      message("Retrying in ", waits[[attempt]], " seconds.")
      Sys.sleep(waits[[attempt]])
    }
  }
  NULL
}

# The body of `url` as raw bytes, so that every attempt is bounded:
# 15 seconds to connect, 60 for the whole transfer.
# An HTTP error status is an error too, so that it is retried.
fetch <- function(url) {
  handle <- curl::new_handle(
    connecttimeout = 15,
    timeout = 60,
    failonerror = TRUE
  )
  curl::curl_fetch_memory(url, handle = handle)$content
}

# Minor versions ("4.5") of every R release, from the release tags in svn.
versions_from_svn <- function() {
  tags <- xml2::read_html(fetch("https://svn.r-project.org/R/tags/"))

  bullets <-
    tags |>
    xml2::xml_find_all("//li") |>
    xml2::xml_text()

  version_bullets <- grep("^R-([0-9]+-[0-9]+-[0-9]+)/$", bullets, value = TRUE)
  versions <- unique(gsub("^R-([0-9]+)-([0-9]+)-[0-9]+/$", "\\1.\\2", version_bullets))
  if (length(versions) == 0) {
    stop("Found no R release tags on svn.r-project.org.")
  }
  versions
}

# The same minor versions from the r-hub rversions API,
# which lists every release with its three-component version as "semver".
# It also lists the releases before 1.0, which svn has no tags for
# and which never reach the five newest.
versions_from_rversions <- function() {
  json <- rawToChar(fetch("https://api.r-hub.io/rversions/r-versions"))
  releases <- jsonlite::fromJSON(json)
  semver <- grep("^[0-9]+[.][0-9]+[.][0-9]+$", releases$semver, value = TRUE)
  versions <- unique(gsub("^([0-9]+)[.]([0-9]+)[.][0-9]+$", "\\1.\\2", semver))
  if (length(versions) == 0) {
    stop("Found no R releases in the api.r-hub.io response.")
  }
  versions
}

versions <- with_retries(versions_from_svn, "the R release tags from svn.r-project.org")
if (is.null(versions)) {
  message("svn.r-project.org gave no R releases, falling back to the r-hub rversions API.")
  versions <- with_retries(versions_from_rversions, "the R releases from api.r-hub.io")
  if (is.null(versions)) {
    stop("Could not read the R releases from svn.r-project.org or api.r-hub.io.")
  }
  # A workflow command on stdout, so that the run's summary shows the fallback.
  cat("::warning::Used the R releases from api.r-hub.io, because svn.r-project.org gave none.\n")
}

r_release <- head(sort(as.package_version(versions), decreasing = TRUE), 5)

deps <- desc::desc_get_deps()
r_crit <- deps$version[deps$package == "R"]
if (length(r_crit) == 1) {
  min_r <- as.package_version(gsub("^>= ([0-9]+[.][0-9]+)(?:.*)$", "\\1", r_crit))
  r_release <- r_release[r_release >= min_r]
}

r_versions <- c("devel", as.character(r_release))

macos <- data.frame(os = "macos-latest", r = r_versions[2:3])
windows <- data.frame(os = "windows-latest", r = r_versions[1:3])

# Linux amd64 (ubuntu-26.04) carries the full historical sweep: R-devel plus
# every supported release down to the oldest. amd64 has the most mature
# toolchain and the broadest CRAN binary coverage on Posit Package Manager, so
# it is where the deep back-compatibility testing lives.
linux_devel <- data.frame(os = "ubuntu-26.04", r = r_versions[1], `http-user-agent` = "release", check.names = FALSE)
linux <- data.frame(os = "ubuntu-26.04", r = r_versions[-1])

# Linux arm64 (ubuntu-26.04-arm) is intentionally ragged: only the two newest R
# versions, R-devel and R-release. These are the versions actually deployed to
# arm64 today (Apple Silicon, AWS Graviton, ...) and the ones with dependable
# arm64 R builds; re-running the full historical range on a second architecture
# would add cost without adding meaningful coverage. R-release (and R-devel)
# overlap with amd64, so at least one R version is exercised on both arches.
# PPM note: r-lib/actions/setup-r historically disabled Posit Package Manager on
# aarch64 Linux (r-lib/actions NEWS v2.11.2, 2025-02-19) because PPM shipped no
# arm64 binaries and would have served x86_64 ones. setup-r v2.12.0 (2026-04-29)
# re-enabled it, and PPM has published resolute (26.04) aarch64 CRAN binaries
# since PPM 2026.05.0, so arm64 jobs on @v2 now install binaries, not source.
linux_arm64 <- data.frame(os = "ubuntu-26.04-arm", r = r_versions[1:2])

# Windows arm64 (windows-11-arm) is ragged for the same reason as Linux arm64,
# only more so: a single entry, R-release. Windows on Arm is the youngest of the
# three arm64 targets, and R for Windows/aarch64 is a separate distribution from
# the x86_64 one rather than a second build of it, so the point here is to catch
# "does this package build and check at all on Windows/aarch64", not to sweep R
# versions. R-release overlaps with the windows-latest (amd64) entries, which
# keeps the two Windows architectures comparable on at least one R version.
# Tooling note: r-lib/actions/setup-r resolves the aarch64 Windows installer
# through the r-hub rversions API and installs the matching aarch64 Rtools45
# (r-lib/actions NEWS v2.11.4, 2025-10-08). Posit Package Manager publishes no
# aarch64 Windows binaries, and setup-r's `use-public-rspm: true` enables PPM on
# x86_64 Windows only, so dependencies are compiled from source on this runner
# and it is the slowest entry in the matrix.
#
# Strictness note: this is the one entry that checks with `error_on = "error"`
# instead of the default `"note"`, requested through the generic "env" field.
# The aarch64 Rtools45 is documented as experimental, and its Fortran driver
# makes `R CMD check` report a WARNING for every package that ships Fortran
# sources: `flang` there is LLVM's `flang-new` invoked as
# `aarch64-w64-mingw32-flang`, which loads the llvm-mingw configuration files
# for that triple, and those add link-time flags (`-lc++`, `-rtlib=compiler-rt`,
# `-pthread`) to every invocation, including the compile-only ones. The driver
# then warns that each of them is unused, and `[-Wunused-command-line-argument]`
# is one of the patterns `R CMD check` collects as a "significant warning" from
# the installation log. Nothing in the package can suppress those: flang 19
# rejects `-Qunused-arguments` ("unknown argument") and
# `-Wno-unused-command-line-argument` ("Only `-Werror` is supported currently"),
# and `--no-default-config` would drop the `-target` line that the same
# configuration files supply. Errors -- a build that fails, a test that fails,
# an example that fails -- still fail this entry, which is what it is here to
# catch. Drop the "env" field once the toolchain stops emitting the warnings.
windows_arm64 <- data.frame(
  os = "windows-11-arm",
  r = r_versions[2],
  env = 'RCMDCHECK_ERROR_ON="error"'
)

include_list <- list(
  macos,
  windows,
  linux_devel,
  linux,
  linux_arm64,
  windows_arm64
)

if (file.exists(".github/versions-matrix.R")) {
  custom <- source(".github/versions-matrix.R")$value
  if (is.data.frame(custom)) {
    custom <- list(custom)
  }
  include_list <- c(include_list, custom)
}

print(include_list)

filter <- read.dcf("DESCRIPTION")[1, ]["Config/gha/filter"]
if (!is.na(filter)) {
  filter_expr <- parse(text = filter)[[1]]
  subset_fun_expr <- bquote(function(x) subset(x, .(filter_expr)))
  subset_fun <- eval(subset_fun_expr)
  include_list <- lapply(include_list, subset_fun)
  print(include_list)
}

to_json <- function(x) {
  if (nrow(x) == 0) return(character())
  # Minimal JSON string escaping: backslash, double quote, newline.
  # Newlines matter for the "env" field,
  # which carries one KEY=VALUE per line.
  escape <- function(v) {
    v <- gsub("\\", "\\\\", v, fixed = TRUE)
    v <- gsub('"', '\\"', v, fixed = TRUE)
    v <- gsub("\n", "\\n", v, fixed = TRUE)
    v
  }
  parallel <- vector("list", length(x))
  for (i in seq_along(x)) {
    parallel[[i]] <- paste0('"', escape(names(x)[[i]]), '":"', escape(x[[i]]), '"')
  }
  paste0("{", do.call(paste, c(parallel, sep = ",")), "}")
}

configs <- unlist(lapply(include_list, to_json))
json <- paste0('{"include":[', paste(configs, collapse = ","), "]}")

if (Sys.getenv("GITHUB_OUTPUT") != "") {
  writeLines(paste0("matrix=", json), Sys.getenv("GITHUB_OUTPUT"))
}
writeLines(json)
