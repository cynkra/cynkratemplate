# ---
# repo: cynkra/cynkratemplate
# file: standalone-roxygen-sentence-spacing.R
# last-updated: 2026-09-13
# license: https://unlicense.org
# imports:
# ---
#
# Restores the sentence spacing that roxygen2's markdown pass drops.
#
# ## The problem
#
# Under `Roxygen: list(markdown = TRUE)`, roxygen2 converts a block to Rd via
# commonmark. `md_to_mdxml()` calls `commonmark::markdown_xml(hardbreaks = TRUE)`,
# and `mdxml_node_to_rd()` turns every `softbreak` and `linebreak` node into
# `mdxml_break()`, which returns a bare `"\n"`.
#
# commonmark has already discarded the source line's leading whitespace by then,
# so the Rd carries a line break with nothing after it. `Rd2txt()` renders that
# as ONE space. Two spaces only survive when the sentences share a source line.
#
# The visible consequence: a package that writes one sentence per line -- the
# house convention -- gets single-spaced sentences in `?topic`, while one that
# wraps to 80 columns with two spaces after the period keeps them. The rendered
# help depends on where the author happened to break lines.
#
# It also makes the two conventions mutually exclusive. Splitting a sentence
# pair that is separated by two spaces silently drops one of them, which is why
# several packages in this fleet carry single roxygen lines of 300, 460, even
# 600 columns: joining was the only way to keep the gap.
#
# ## The fix
#
# Make `mdxml_break()` emit `"\n "` instead of `"\n"`. `Rd2txt()` renders a line
# break followed by indentation as two spaces after `.`, `?` and `!`, and as one
# space everywhere else -- so sentence gaps come out double-spaced and
# mid-sentence breaks are unaffected. Nothing in the source files changes.
#
# Measured on kimisc: 14 of 22 topics change, 0 of them by anything other than
# sentence spacing, and the count of sentence gaps goes from 7 to 32. Rd2HTML
# and Rd2latex output differs only in whitespace that HTML and TeX collapse, so
# the pkgdown site and the PDF manual are unaffected.
#
# ## Wiring it up
#
# The patch has to be installed before roxygen2 parses the blocks. `roxygenise()`
# calls `load_code()` -- `pkgload::load_all()` by default -- before
# `parse_package()`, so a package's own `.onLoad()` runs early enough.
#
# If the package imports rlang, register it with `on_load()` and make sure
# `.onLoad()` calls `run_on_load()`:
#
# ```r
# rlang::on_load(roxy_sentence_spacing())
#
# .onLoad <- function(libname, pkgname) {
#   rlang::run_on_load()
# }
# ```
#
# Otherwise call it directly from `.onLoad()`, with a comment saying why:
#
# ```r
# .onLoad <- function(libname, pkgname) {
#   # Restore sentence spacing in the rendered help. This is a no-op unless
#   # roxygen2 is mid-roxygenise; see R/import-standalone-roxygen-sentence-spacing.R.
#   roxy_sentence_spacing()
# }
# ```
#
# ## Safety
#
# It does nothing outside a `roxygenise()` call, so `library(pkg)` never reaches
# the patching code even in a session that has roxygen2 loaded.
#
# It refuses to guess. If `mdxml_break()` is missing, or its body is not the one
# this file was written against, it throws -- loudly, at documentation time,
# where a person can fix it. It does not silently regenerate `man/` without the
# spacing, because that failure would be invisible until someone read the diff.
#
# ## Changelog
#
# 2026-09-13:
# * Initial version, written against roxygen2 8.1.0.9000.
#
# nocov start

# The body of `roxygen2:::mdxml_break()` this file was written against. Used as
# a fingerprint rather than a version comparison: the version number moves for
# unrelated reasons, the body moves only when the thing we depend on changes.
roxy_sentence_spacing_expected <- function() {
  "{ if (isTRUE(state$inlink)) \" \" else \"\\n\" }"
}

# TRUE while a `roxygenise()` call is on the stack. Deliberately narrow: the
# patch must not be reachable from an ordinary `library()`, even for a user who
# has roxygen2 loaded.
roxy_sentence_spacing_active <- function(calls = sys.calls()) {
  for (call in calls) {
    fun <- call[[1]]
    name <- if (is.name(fun)) {
      as.character(fun)
    } else if (is.call(fun) && identical(as.character(fun[[1]]), "::")) {
      as.character(fun[[3]])
    } else {
      ""
    }
    if (name %in% c("roxygenise", "roxygenize")) {
      return(TRUE)
    }
  }
  FALSE
}

roxy_sentence_spacing <- function() {
  if (!roxy_sentence_spacing_active()) {
    return(invisible(FALSE))
  }
  if (!isNamespaceLoaded("roxygen2")) {
    return(invisible(FALSE))
  }

  ns <- asNamespace("roxygen2")
  if (!exists("mdxml_break", envir = ns, inherits = FALSE)) {
    stop(
      "roxygen2 has no `mdxml_break()`, so sentence spacing cannot be restored.\n",
      "Update R/import-standalone-roxygen-sentence-spacing.R from cynkra/cynkratemplate.",
      call. = FALSE
    )
  }

  original <- get("mdxml_break", envir = ns, inherits = FALSE)
  if (isTRUE(attr(original, "roxy_sentence_spacing"))) {
    return(invisible(FALSE))
  }

  body_text <- gsub("\\s+", " ", paste(deparse(body(original)), collapse = " "))
  if (!identical(body_text, roxy_sentence_spacing_expected())) {
    stop(
      "`roxygen2:::mdxml_break()` is not the function this package patches.\n",
      "  expected: ", roxy_sentence_spacing_expected(), "\n",
      "  found:    ", body_text, "\n",
      "Re-check the fix against the new roxygen2 and update ",
      "R/import-standalone-roxygen-sentence-spacing.R from cynkra/cynkratemplate.",
      call. = FALSE
    )
  }

  # `" "` inside a link is roxygen2's own behaviour and must stay: an Rd link
  # cannot carry a line break.
  patched <- function(state) if (isTRUE(state$inlink)) " " else "\n "
  environment(patched) <- environment(original)
  attr(patched, "roxy_sentence_spacing") <- TRUE

  unlockBinding("mdxml_break", ns)
  on.exit(lockBinding("mdxml_break", ns), add = TRUE)
  assign("mdxml_break", patched, envir = ns)

  invisible(TRUE)
}

# nocov end
