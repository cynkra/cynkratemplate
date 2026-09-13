#' An R Markdown output format for package READMEs
#'
#' A `github_document` that also writes the pkgdown front page, `index.md`,
#' from the same render.
#' Use it from `README.Rmd`:
#'
#' ```yaml
#' output: cynkratemplate::readme_document
#' ```
#'
#' Rendering then works the ordinary way -- `rmarkdown::render("README.Rmd")`,
#' `devtools::build_readme()`, or the Knit button -- with no wrapper to
#' remember. [render_readme()] is a convenience for the same thing.
#'
#' # Why two files
#'
#' The README and the front page differ in exactly two ways:
#'
#' * **Colour.** pkgdown turns ANSI SGR escapes into HTML; GitHub shows the
#'   raw bytes. So `index.md` keeps the escapes and `README.md` has them
#'   stripped.
#' * **The tail.** Everything from the first horizontal rule onwards -- the
#'   code of conduct, licence and funding boilerplate -- belongs on GitHub,
#'   while pkgdown puts that material in its sidebar.
#'
#' `index.md` is written only when it would differ from `README.md`. A README
#' with no horizontal rule that emits no colour produces two identical files,
#' so the file is dropped and pkgdown falls through to `README.md` on its own
#' lookup order. `.Rbuildignore` is kept in step either way.
#'
#' # Package-specific touch-ups
#'
#' A README may define `readme_only()` or `index_only()` in a chunk, each
#' taking and returning a character vector. Each is applied to just that one
#' output. This is how an asymmetry survives a single render: the usual case
#' is rewriting `vignette("x")` into an absolute article link, which GitHub
#' needs and pkgdown must not have, since downlit already auto-links it there.
#'
#' @param ... Passed to [rmarkdown::github_document()].
#' @return An [rmarkdown::output_format()].
#' @export
readme_document <- function(...) {
  # `-smart` and `--wrap=preserve` keep the pandoc pass close to an identity
  # transform: no smart quotes, no reflowing to 72 columns. That keeps the
  # rendered file close to its source and makes diffs sentence-level, which is
  # what the house line-break convention is for.
  # Merged rather than passed alongside `...`. `devtools::build_readme()` sets
  # `html_preview = FALSE` itself and rmarkdown folds that into the format
  # call, so naming it here as well made every argument it supplies collide:
  # "formal argument "html_preview" matched by multiple actual arguments".
  # These are defaults a caller may override, which is what they always read
  # as anyway.
  defaults <- list(
    html_preview = FALSE,
    md_extensions = "-smart",
    pandoc_args = "--wrap=preserve"
  )
  base <- do.call(
    rmarkdown::github_document,
    utils::modifyList(defaults, list(...))
  )

  # The package root, captured while we can still see the original input.
  # By post-processing time the paths in play may be intermediates.
  #
  # `max.print` is pinned here too. A README that prints a query result or a
  # data frame otherwise renders differently depending on the value in the
  # rendering session -- a maintainer with it set gets a truncated table, a
  # runner without it gets the whole thing. That is how DBI's and RSQLite's
  # front pages came to open with two complete `mtcars` dumps, thirty-odd
  # lines each, in a commit that claimed to change only pandoc settings.
  #
  # Set in `pre_knit`, so the README's own setup chunk runs afterwards and
  # still wins if it wants something else. Restored in the post-processor.
  root <- NULL
  old_max_print <- NULL
  inner_pre <- base$pre_knit
  base$pre_knit <- function(input, ...) {
    root <<- dirname(normalizePath(input, mustWork = TRUE))
    old_max_print <<- options(max.print = 100)
    if (is.function(inner_pre)) inner_pre(input, ...)
  }

  # The environment the chunks were evaluated in, captured while knitr is still
  # running. It cannot be recovered later: `knitr::knit_global()` reverts to the
  # global environment once the knit finishes, so reading it from the
  # post-processor silently yields an environment where `readme_only()` and
  # `index_only()` do not exist, and the transform is skipped without a word.
  #
  # Captured through an option hook rather than a `document` or `chunk` hook.
  # Those are single-slot: several READMEs in this fleet set a `document` hook
  # of their own from the setup chunk, which would replace ours. An option hook
  # keyed on an option nothing else uses cannot collide, and unlike a chunk hook
  # it has no say in how output is rendered.
  knit_env <- NULL
  capture <- list(function(options) {
    knit_env <<- knitr::knit_global()
    options
  })
  names(capture) <- CAPTURE_OPTION
  defaults <- list(TRUE)
  names(defaults) <- CAPTURE_OPTION

  base$knitr$opts_chunk <- c(base$knitr$opts_chunk, defaults)
  base$knitr$opts_hooks <- c(base$knitr$opts_hooks, capture)

  # A post-processor runs *after* pandoc, which is the only correct place for
  # this. The knitr `document` hook these packages used instead runs before
  # pandoc, so its `index.md` was the pre-pandoc text while `README.md` was the
  # post-pandoc one -- and the two then differed by reflowing and smart quotes
  # on top of anything real.
  inner_post <- base$post_processor
  base$post_processor <- function(metadata, input_file, output_file, clean, verbose) {
    if (is.function(inner_post)) {
      output_file <- inner_post(metadata, input_file, output_file, clean, verbose)
    }
    if (!is.null(old_max_print)) options(old_max_print)
    split_readme(root %||% dirname(normalizePath(input_file)), output_file, knit_env)
    output_file
  }

  base
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# The chunk option whose only purpose is to give the option hook above
# something to fire on. Named for this package so nothing else can set it.
CAPTURE_OPTION <- "cynkratemplate.capture"

# Write `index.md` beside the README and strip colour from `README.md`.
split_readme <- function(root, output_file, knit_env = NULL) {
  full <- readLines(output_file, warn = FALSE)

  readme <- strip_sgr(full)
  index <- readme_head(full)
  # Box-drawing characters line up badly in several pkgdown themes; the README
  # keeps them.
  index <- gsub("─", "-", index)

  # The environment the chunks ran in, handed over from the capture hook. A
  # README that defines `readme_only()` or `index_only()` is visible there.
  env <- knit_env
  readme <- apply_side(env, "readme_only", readme)
  index <- apply_side(env, "index_only", index)

  writeLines(readme, output_file)

  index_path <- file.path(root, "index.md")
  if (identical(index, readme)) {
    if (file.exists(index_path)) {
      file.remove(index_path)
    }
    edit_buildignore(root, add = FALSE)
    return(invisible(NULL))
  }

  writeLines(index, index_path)
  edit_buildignore(root, add = TRUE)
  invisible(NULL)
}
