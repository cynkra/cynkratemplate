test_that("code blocks are left alone", {
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
  lines <- c("Call `base::print()` twice: `base::print()`.")
  once <- autolink_lines(lines)
  expect_identical(autolink_lines(once), once)
})

test_that("a tilde fence is honoured too", {
  lines <- c("~~~", "`base::print()`", "~~~")
  expect_identical(autolink_lines(lines), lines)
})
