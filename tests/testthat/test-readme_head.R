test_that("the head stops at the first horizontal rule", {
  lines <- c("# Title", "", "Body.", "", strrep("-", 72), "", "## Code of Conduct")

  expect_equal(readme_head(lines), c("# Title", "", "Body."))
})

test_that("a README without a horizontal rule is kept whole", {
  lines <- c("# Title", "", "Body.")

  expect_equal(readme_head(lines), lines)
})

test_that("a rule inside a fenced code block is not a rule", {
  # The snippet every README configured for this format may show:
  # pandoc writes the YAML front matter as a fenced block
  # whose first and last lines are the three dashes the old scan matched.
  lines <- c(
    "# Title",
    "",
    "``` yaml",
    "---",
    "output: cynkratemplate::readme_document",
    "---",
    "```",
    "",
    "Body.",
    "",
    strrep("-", 72),
    "",
    "## Code of Conduct"
  )

  expect_equal(readme_head(lines), lines[seq_len(9)])
})

test_that("fences of every shape are tracked", {
  # A tilde fence, a fence longer than three characters,
  # and a fence whose content contains a shorter run of the same character.
  lines <- c(
    "~~~",
    "---",
    "~~~",
    "````",
    "```",
    "---",
    "````",
    "",
    "---",
    "",
    "tail"
  )

  expect_equal(readme_head(lines), lines[seq_len(7)])
})

test_that("an unclosed fence swallows the rest of the document", {
  lines <- c("intro", "", "``` r", "---", "still code")

  expect_equal(readme_head(lines), lines)
})

test_that("fence_lang() reports the info string", {
  lines <- c("prose", "``` r", "code", "```", "prose", "```", "plain", "```")

  expect_equal(
    fence_lang(lines),
    c(NA, "r", "r", "r", NA, "", "", "")
  )
})

test_that("a rendered README keeps a front-matter snippet whole", {
  skip_if_not_installed("withr")

  out <- render_fixture(c(
    "# fixture",
    "",
    "Configure `README.Rmd` like this:",
    "",
    "```yaml",
    "---",
    "output: cynkratemplate::readme_document",
    "---",
    "```",
    "",
    "Then render.",
    "",
    "---",
    "",
    "## Code of Conduct",
    "",
    "Boilerplate that belongs on GitHub only."
  ))

  # The snippet survives, the boilerplate after the rule does not.
  expect_true(any(grepl("output: cynkratemplate::readme_document", out$index)))
  expect_true(any(grepl("Then render", out$index)))
  expect_false(any(grepl("Code of Conduct", out$index)))
  expect_true(any(grepl("Code of Conduct", out$readme)))
})
