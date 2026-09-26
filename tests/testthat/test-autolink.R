test_that("code blocks are left alone", {
  skip_if_not_installed("downlit")
  lines <- c(
    "Use `base::print()` here.",
    "```r",
    "base::print(1)",
    "```",
    "And `base::print()` again."
  )
  out <- autolink_lines(lines)

  # The fence and everything inside it come through byte-identical.
  expect_identical(out[2:4], lines[2:4])
  # The prose on both sides of the block is linked.
  expect_match(out[[1]], "^Use \\[`base::print\\(\\)`\\]\\(http")
  expect_match(out[[5]], "^And \\[`base::print\\(\\)`\\]\\(http")
})

test_that("spans that resolve to nothing are untouched", {
  lines <- "Set `TRUE`, read `some_local_var`, run `SELECT 1`, see `notafunction()`."
  expect_identical(autolink_lines(lines), lines)
})

test_that("an existing link is not nested", {
  skip_if_not_installed("downlit")
  lines <- "See [`base::print()`](https://example.org) for details."
  expect_identical(autolink_lines(lines), lines)
})

test_that("line breaks survive, so semantic line breaks do", {
  lines <- c("One sentence with `base::print()`.", "Another on its own line.")
  out <- autolink_lines(lines)
  expect_length(out, 2L)
  expect_identical(out[[2]], lines[[2]])
})

test_that("autolinking is idempotent", {
  skip_if_not_installed("downlit")
  lines <- c("Call `base::print()` twice: `base::print()`.")
  once <- autolink_lines(lines)
  expect_identical(autolink_lines(once), once)
})

test_that("a tilde fence is honoured too", {
  lines <- c("~~~", "`base::print()`", "~~~")
  expect_identical(autolink_lines(lines), lines)
})

test_that("the documentation site is the first `URL` that can be a pkgdown site", {
  expect_identical(
    documentation_site("https://dm.cynkra.com, https://github.com/cynkra/dm"),
    "https://dm.cynkra.com"
  )
  # A trailing slash would double up in `<site>//reference/`.
  expect_identical(
    documentation_site("https://pillar.r-lib.org/, https://github.com/r-lib/pillar"),
    "https://pillar.r-lib.org"
  )
  # A source host or a package index is not a `/reference/` tree.
  expect_identical(documentation_site("https://github.com/r-lib/gargle"), NA_character_)
  expect_identical(documentation_site("https://CRAN.R-project.org/package=foo"), NA_character_)
  expect_identical(documentation_site("https://foo.r-universe.dev"), NA_character_)
  # A site hosted on GitHub Pages is a site, unlike the repository next to it.
  expect_identical(
    documentation_site("https://Rdatatable.github.io/data.table, https://github.com/Rdatatable/data.table"),
    "https://Rdatatable.github.io/data.table"
  )
  expect_identical(documentation_site(NA_character_), NA_character_)
})

test_that("the package being rendered is taken from its source tree", {
  out <- local_packages("dm", "https://dm.cynkra.com")
  expect_identical(out[["dm"]], "https://dm.cynkra.com")
})

test_that("the renderer's own `downlit.local_packages` wins", {
  # A local pkgdown preview sets this to point at itself, and must keep doing so.
  withr::local_options(downlit.local_packages = list(testthat = "file:///tmp/site"))
  out <- local_packages("dm", "https://dm.cynkra.com")
  expect_identical(out[["testthat"]], "file:///tmp/site")
  expect_identical(out[["dm"]], "https://dm.cynkra.com")
})

test_that("the downlit context lasts until the caller exits", {
  withr::local_options(downlit.package = NULL, downlit.local_packages = list(testthat = "file:///tmp/site"))
  root <- withr::local_tempdir()
  writeLines(c("Package: fixture", "URL: https://fixture.example.org"), file.path(root, "DESCRIPTION"))

  inside <- local({
    local_downlit_context(root)
    list(pkg = getOption("downlit.package"), local = getOption("downlit.local_packages"))
  })

  expect_identical(inside$pkg, "fixture")
  expect_identical(inside$local[["fixture"]], "https://fixture.example.org")
  expect_identical(inside$local[["testthat"]], "file:///tmp/site")
  expect_null(getOption("downlit.package"))
  expect_identical(getOption("downlit.local_packages"), list(testthat = "file:///tmp/site"))
})

test_that("a seeded site is used instead of the rdrr.io fallback", {
  # This is the guarantee the seeding rests on: downlit consults
  # `downlit.local_packages` before it tries to fetch `<site>/pkgdown.yml`, so
  # the link is the same whether or not the renderer can reach that site.
  skip_if_not_installed("downlit")
  withr::local_options(downlit.local_packages = list(testthat = "https://testthat.r-lib.org"))
  expect_identical(
    downlit::autolink_url("testthat::test_that()"),
    "https://testthat.r-lib.org/reference/test_that.html"
  )
})
