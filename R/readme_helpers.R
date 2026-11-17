# Everything above the first horizontal rule.
#
# pandoc writes a source `---` rule as a run of dashes on its own line, not as `---`,
# so the marker to match is the rendered form.
# A README with no rule yields the whole document,
# which then collapses into README.md.
#
# Only a rule in prose counts.
# A run of dashes inside a fenced code block is verbatim text, not a horizontal rule
# -- a README that shows the YAML front matter this format is configured from
# contains three of them,
# and matching those truncates the front page in the middle of the snippet.
readme_head <- function(lines) {
  at <- which(grepl("^-{3,}\\s*$", lines) & is.na(fence_lang(lines)))
  if (length(at) == 0) {
    return(lines)
  }
  head <- lines[seq_len(at[[1]] - 1L)]
  # Drop the blank line the rule was separated by,
  # so the file does not end with trailing whitespace.
  while (length(head) > 0 && !nzchar(head[[length(head)]])) {
    head <- head[-length(head)]
  }
  head
}

# Which fenced code block each line of pandoc's markdown output belongs to.
#
# Returns the block's info string
# -- `""` when the opening fence carries none --
# for every line of a fenced block, the delimiters included,
# and `NA` for every line outside one.
# Callers use the `NA` to tell prose from verbatim text,
# and the info string to tell a language-tagged block (source the README is showing)
# from an untagged one.
#
# A fence opens with at least three backticks or tildes at the start of a line
# and closes with at least as many of the same character and nothing else on the line.
# That is what CommonMark says and what pandoc writes;
# an unclosed fence runs to the end of the document, also as CommonMark says.
fence_lang <- function(lines) {
  out <- rep(NA_character_, length(lines))
  char <- ""
  width <- 0L
  lang <- NA_character_

  for (i in seq_along(lines)) {
    fence <- regmatches(
      lines[[i]],
      regexec("^(`{3,}|~{3,})[ \t]*(.*?)[ \t]*$", lines[[i]])
    )[[1]]

    if (width == 0L) {
      if (length(fence) > 0) {
        char <- substr(fence[[2]], 1L, 1L)
        width <- nchar(fence[[2]])
        lang <- fence[[3]]
        out[[i]] <- lang
      }
      next
    }

    out[[i]] <- lang
    closes <- length(fence) > 0 &&
      substr(fence[[2]], 1L, 1L) == char &&
      nchar(fence[[2]]) >= width &&
      !nzchar(fence[[3]])
    if (closes) {
      width <- 0L
      lang <- NA_character_
    }
  }

  out
}

# Rewrite box-drawing horizontals as hyphens, in knitr's output and nowhere else.
#
# The substitution is there
# because those characters line up badly in several pkgdown themes.
# That argument is about the monospace blocks a console session prints,
# so prose and inline code have no business being rewritten
# -- and a chunk's *source* has none either:
# a README that shows how to draw a box
# had the drawing silently taken out of its own code.
#
# Two shapes of output have to be recognised,
# because pandoc writes them differently:
#
# * A chunk with `collapse = TRUE` puts output in the same fenced block as its source,
#   tagged with the chunk's language.
#   There the comment prefix is the only marker,
#   which is why the option hook records it.
# * Anything else becomes a code block with no language,
#   which pandoc's gfm writer emits indented by four spaces rather than fenced.
#
# What this cannot separate, at this stage,
# is knitr's unprefixed output from a verbatim block the README wrote by hand:
# pandoc renders both as the same indented block.
# Both are monospace, so the theme argument applies to both,
# and the residual is a hand-written box drawing in an untagged block.
# Telling those two apart needs the text knitr actually emitted,
# captured from an output hook during the knit and matched here
# -- worth doing if a README ever hits it, not worth the hook wrangling before then.
dash_output <- function(lines, comments = character()) {
  at <- is_knitr_output(lines, comments)
  lines[at] <- gsub("\u2500", "-", lines[at])
  lines
}

is_knitr_output <- function(lines, comments = character()) {
  comments <- comments[!is.na(comments) & nzchar(comments)]
  lang <- fence_lang(lines)

  indented <- is.na(lang) & grepl("^(    |\t)", lines)
  prefixed <- Reduce(
    `|`,
    lapply(comments, function(prefix) startsWith(lines, prefix)),
    init = rep(FALSE, length(lines))
  )

  indented | (!is.na(lang) & nzchar(lang) & prefixed)
}

# `fansi::strip_sgr()` without the dependency:
# the CSI sequences R's own colour output emits are all of the form ESC [ ... m.
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

# `index.md` is not part of the package,
# so `R CMD check --as-cran` reports it as a non-standard top-level file
# unless it is ignored.
# Kept in step with whether the file actually exists,
# so a package that stops needing one does not keep a dangling entry.
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
