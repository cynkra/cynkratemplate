box <- "\u2500"

test_that("collapsed output is rewritten and its source is not", {
  lines <- c(
    "``` r",
    paste0("rule <- \"", box, box, "\""),
    paste0("#> ", box, box),
    "```"
  )

  expect_equal(
    dash_output(lines, "#>"),
    c("``` r", paste0("rule <- \"", box, box, "\""), "#> --", "```")
  )
})

test_that("prose and inline code are left alone", {
  lines <- c(
    paste0("A rule looks like ", box, box, "."),
    paste0("Draw it with `", box, "`.")
  )

  expect_equal(dash_output(lines, "#>"), lines)
})

test_that("an indented block is output and is rewritten", {
  # Output that is not collapsed into its source block carries no language,
  # and pandoc's gfm writer indents those rather than fencing them.
  lines <- c("Prose.", "", paste0("    Backtrace: ", box), "")

  expect_equal(dash_output(lines, "#>"), c("Prose.", "", "    Backtrace: -", ""))
})

test_that("a block tagged with a language is source, whatever the language", {
  lines <- c("``` yaml", paste0("rule: ", box), "```")

  expect_equal(dash_output(lines, "#>"), lines)
})

test_that("no recorded prefix leaves fenced blocks untouched", {
  lines <- c("``` r", paste0("#> ", box), "```")

  expect_equal(dash_output(lines, character()), lines)
})

test_that("an unusable recorded prefix is ignored", {
  lines <- c("``` r", paste0("#> ", box), "```")

  expect_equal(dash_output(lines, c(NA, "")), lines)
})

test_that("a rendered README keeps the character in its own code", {
  skip_if_not_installed("withr")

  out <- render_fixture(c(
    "# fixture",
    "",
    paste0("Inline: `a ", box, " b`. Prose: a ", box, " b."),
    "",
    "```{r collapse = TRUE, comment = \"#>\"}",
    paste0("rule <- \"", box, box, "\""),
    "cat(rule, \"\\n\")",
    "```"
  ))

  index <- out$index
  skip_if(is.null(index), "README and index are identical here")

  expect_true(any(grepl(paste0("Inline: `a ", box, " b`"), index, fixed = TRUE)))
  expect_true(any(grepl(paste0("rule <- \"", box, box, "\""), index, fixed = TRUE)))
  expect_true(any(grepl("^#> --", index)))
})
