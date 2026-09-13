#' Render `README.md` and the pkgdown `index.md` from `README.Rmd`
#'
#' Renders `README.Rmd` once and derives both outputs from that single pandoc
#' pass, so the two cannot drift apart in formatting.
#' The package README and the pkgdown front page differ in exactly two ways,
#' and both are applied here rather than left to each package:
#'
#' * **Colour.** pkgdown renders ANSI SGR escapes as HTML; GitHub cannot, and
#'   shows the raw bytes. So `index.md` keeps the escapes and `README.md` has
#'   them stripped.
#' * **The tail.** Everything from the first horizontal rule onwards -- the
#'   code of conduct, licence and funding boilerplate -- belongs on GitHub but
#'   not on the front page, where pkgdown puts that material in the sidebar.
#'
#' `index.md` is written only when it would differ from `README.md`.
#' When a README has no horizontal rule and produces no colour the two are
#' identical, so the file is dropped and pkgdown falls through to `README.md`
#' by its own lookup order.
#'
#' @param path Package root.
#' @param quiet Passed to [rmarkdown::render()].
#' @return The paths written, invisibly.
#' @export
render_readme <- function(path = ".", quiet = TRUE) {
  # Resolve once, up front, and use absolute paths from here on. Several of
  # these READMEs call `setwd()` from a chunk to demonstrate project-root
  # behaviour, and knitr restores the working directory on its own schedule --
  # so anything written through a relative path can land in a temporary
  # directory instead of the package, silently.
  path <- normalizePath(path, mustWork = TRUE)
  rmd <- file.path(path, "README.Rmd")
  if (!file.exists(rmd)) {
    cli::cli_abort("No {.file README.Rmd} in {.path {path}}.")
  }

  # One render, one pandoc pass. The YAML in README.Rmd supplies
  # `md_extensions: "-smart"` and `--wrap=preserve`, which keep the pass close
  # to an identity transform: no smart quotes, no reflowing. That is what makes
  # the output diff sentence-level instead of paragraph-level.
  # `output_dir` is pinned explicitly. Without it rmarkdown resolves the output
  # against the working directory as it stands when the render returns, and a
  # README that calls `setwd()` from a chunk -- rprojroot and here both do, to
  # demonstrate project-root detection -- leaves that pointing into a knitr
  # temporary directory. The render then succeeds while writing everything
  # somewhere that is silently discarded.
  owd <- getwd()
  on.exit(setwd(owd), add = TRUE)
  rendered <- rmarkdown::render(
    rmd,
    output_file = "README.md",
    output_dir = path,
    quiet = quiet
  )
  full <- readLines(rendered, warn = FALSE)

  readme <- strip_sgr(full)
  index <- readme_head(full)
  # Box-drawing characters render as boxes on the front page but line up badly
  # in several pkgdown themes; the README keeps them.
  index <- gsub("─", "-", index)

  writeLines(readme, file.path(path, "README.md"))

  index_path <- file.path(path, "index.md")
  if (identical(index, readme)) {
    # Nothing to distinguish the two: let pkgdown read README.md instead.
    if (file.exists(index_path)) {
      file.remove(index_path)
      cli::cli_alert_info("Removed {.file index.md}: identical to {.file README.md}.")
    }
    unignore_index(path)
    return(invisible(file.path(path, "README.md")))
  }

  writeLines(index, index_path)
  ignore_index(path)
  invisible(c(file.path(path, "README.md"), index_path))
}

# Everything above the first horizontal rule.
#
# pandoc writes a source `---` rule as a run of dashes on its own line, not as
# `---`, so the marker to match is the rendered form. A README with no rule
# yields the whole document, which then collapses into README.md above.
readme_head <- function(lines) {
  at <- grep("^-{3,}\\s*$", lines)
  if (length(at) == 0) {
    return(lines)
  }
  head <- lines[seq_len(at[[1]] - 1L)]
  # Drop the blank line the rule was separated by, so the file does not end
  # with trailing whitespace.
  while (length(head) > 0 && !nzchar(head[[length(head)]])) {
    head <- head[-length(head)]
  }
  head
}

# `fansi::strip_sgr()` without the dependency: the CSI sequences R's own
# colour output emits are all of the form ESC [ ... m.
strip_sgr <- function(x) {
  gsub("\033\\[[0-9;]*m", "", x)
}

ignore_index <- function(path) {
  edit_buildignore(path, add = TRUE)
}

unignore_index <- function(path) {
  edit_buildignore(path, add = FALSE)
}

# `index.md` is not part of the package, so `R CMD check --as-cran` reports it
# as a non-standard top-level file unless it is ignored. Kept in step with
# whether the file actually exists, so a package that stops needing one does
# not keep a dangling entry.
edit_buildignore <- function(path, add) {
  file <- file.path(path, ".Rbuildignore")
  entry <- "^index\\.md$"
  lines <- if (file.exists(file)) readLines(file, warn = FALSE) else character()
  has <- entry %in% lines

  if (add && !has) {
    writeLines(c(lines, entry), file)
    cli::cli_alert_info("Added {.code {entry}} to {.file .Rbuildignore}.")
  } else if (!add && has) {
    writeLines(lines[lines != entry], file)
    cli::cli_alert_info("Removed {.code {entry}} from {.file .Rbuildignore}.")
  }
  invisible(NULL)
}
