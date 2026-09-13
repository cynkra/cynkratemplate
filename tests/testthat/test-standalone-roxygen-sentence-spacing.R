test_that("the fingerprint still matches the installed roxygen2", {
  skip_if_not_installed("roxygen2")
  ns <- asNamespace("roxygen2")
  expect_true(exists("mdxml_break", envir = ns, inherits = FALSE))
  body_text <- gsub(
    "\\s+", " ",
    paste(deparse(body(get("mdxml_break", envir = ns, inherits = FALSE))), collapse = " ")
  )
  # When this fails, roxygen2 has changed the function the standalone patches.
  # Re-check the fix and update the fingerprint, then push the standalone to
  # every package that imports it.
  expect_equal(body_text, roxy_sentence_spacing_expected())
})

test_that("it does nothing outside a roxygenise() call", {
  expect_false(roxy_sentence_spacing_active(list(quote(library(x)), quote(f()))))
  expect_false(roxy_sentence_spacing())
})

test_that("it detects roxygenise() on the stack, however it was called", {
  expect_true(roxy_sentence_spacing_active(list(quote(roxygenise(".")))))
  expect_true(roxy_sentence_spacing_active(list(quote(roxygen2::roxygenise(".")))))
  expect_true(roxy_sentence_spacing_active(list(quote(roxygen2::roxygenize(".")))))
})

test_that("a package rendered with the patch differs only in sentence spacing", {
  skip_if_not_installed("roxygen2")
  skip_on_cran()

  render <- function(patch) {
    pkg <- withr::local_tempdir()
    dir.create(file.path(pkg, "R"))
    writeLines(
      c(
        "Package: sentencespacing", "Version: 0.0.1", "Title: T",
        "Description: D.",
        'Authors@R: person("A", "B", role = c("aut", "cre"), email = "a@b.com")',
        "License: MIT + file LICENSE", "Encoding: UTF-8",
        "Roxygen: list(markdown = TRUE)"
      ),
      file.path(pkg, "DESCRIPTION")
    )
    writeLines(
      c(
        "#' Title", "#'", "#' Alpha ends here.", "#' Beta starts here.", "#'",
        "#' A clause that wraps", "#' onto a second line.", "#'",
        "#' @param x Par ends here.", "#' ParNext here.", "#' @export",
        "f <- function(x) x"
      ),
      file.path(pkg, "R", "f.R")
    )

    ns <- asNamespace("roxygen2")
    original <- get("mdxml_break", envir = ns, inherits = FALSE)
    if (patch) {
      patched <- function(state) if (isTRUE(state$inlink)) " " else "\n "
      environment(patched) <- environment(original)
      unlockBinding("mdxml_break", ns)
      assign("mdxml_break", patched, envir = ns)
      lockBinding("mdxml_break", ns)
      withr::defer({
        unlockBinding("mdxml_break", ns)
        assign("mdxml_break", original, envir = ns)
        lockBinding("mdxml_break", ns)
      })
    }

    suppressMessages(roxygen2::roxygenise(pkg))
    paste(
      capture.output(tools::Rd2txt(file.path(pkg, "man", "f.Rd"),
        options = list(width = 10000)
      )),
      collapse = "\n"
    )
  }

  plain <- render(FALSE)
  spaced <- render(TRUE)

  expect_false(identical(plain, spaced))
  # The only difference is a sentence gap widening from one space to two.
  normalise <- function(x) gsub("([.?!])[ ]{2,}", "\\1 ", x)
  expect_equal(normalise(spaced), normalise(plain))
  expect_match(spaced, "Alpha ends here\\.  Beta starts here\\.")
  expect_match(spaced, "Par ends here\\.  ParNext here\\.")
  # A break that is not a sentence boundary stays a single space.
  expect_match(spaced, "A clause that wraps onto a second line\\.")
})
