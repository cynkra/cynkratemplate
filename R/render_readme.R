#' Render a package README
#'
#' A convenience wrapper around [rmarkdown::render()] for a package's
#' `README.Rmd`. It is only a shorthand: the README declares
#' [readme_document()] as its output format, so plain
#' `rmarkdown::render("README.Rmd")`, [devtools::build_readme()] and the Knit
#' button all produce exactly the same two files.
#'
#' @param path Package root.
#' @param quiet Passed to [rmarkdown::render()].
#' @return The path to `README.md`, invisibly.
#' @export
render_readme <- function(path = ".", quiet = TRUE) {
  # Resolve once, up front: some of these READMEs change the working directory
  # from a chunk, so a relative path would not mean the same thing before and
  # after the render.
  path <- normalizePath(path, mustWork = TRUE)
  rmd <- file.path(path, "README.Rmd")
  if (!file.exists(rmd)) {
    cli::cli_abort("No {.file README.Rmd} in {.path {path}}.")
  }

  # `envir` is pinned to the global environment, which is where chunks run
  # under a plain `rmarkdown::render("README.Rmd")` from the console, and the
  # only place they can run correctly.
  #
  # It has to be pinned to something: `rmarkdown::render()` defaults to
  # `envir = parent.frame()`, which here would be this function's own frame, so
  # knitr would evaluate every README chunk among these locals -- the rprojroot
  # README assigns `path` in a chunk, which would silently rebind the argument
  # mid-function.
  #
  # It must not be pinned to a *child* of the global environment, which is the
  # obvious way to keep a README's assignments out of the caller's workspace.
  # S3 methods defined in a chunk would then not be found. A generic called
  # from inside a package -- `pillar()` calling `pillar_shaft()`, `print.tbl()`
  # calling `tbl_sum()` -- dispatches by searching the namespace's parent
  # chain, which reaches the global environment but not an environment hanging
  # off it. The README would render without error and quietly demonstrate the
  # package's own extension point failing to work.
  owd <- getwd()
  on.exit(setwd(owd), add = TRUE)
  invisible(rmarkdown::render(
    rmd,
    output_file = "README.md",
    output_dir = path,
    envir = globalenv(),
    quiet = quiet
  ))
}

# Everything above the first horizontal rule.
#
# pandoc writes a source `---` rule as a run of dashes on its own line, not as
# `---`, so the marker to match is the rendered form. A README with no rule
# yields the whole document, which then collapses into README.md.
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

# Apply a package-supplied one-sided transform, if the README defined one.
apply_side <- function(env, name, lines) {
  if (is.null(env) || !exists(name, envir = env, inherits = FALSE)) {
    return(lines)
  }
  fn <- get(name, envir = env, inherits = FALSE)
  if (!is.function(fn)) {
    cli::cli_abort("{.code {name}} in {.file README.Rmd} must be a function.")
  }
  out <- fn(lines)
  if (!is.character(out)) {
    cli::cli_abort("{.code {name}()} must return a character vector.")
  }
  out
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
  } else if (!add && has) {
    writeLines(lines[lines != entry], file)
  }
  invisible(NULL)
}
