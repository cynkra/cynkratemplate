# Render a README.Rmd with this package's output format in a throwaway package
# root, and hand back the two files it produced.
#
# The tests that use this exercise the whole pipeline -- knitr, pandoc, and the
# post-processor that reads pandoc's output back -- because that is the only
# way to see what the post-processor actually sees. Reasoning about the `.Rmd`
# source instead is how the horizontal-rule scan came to match a fence.
render_fixture <- function(body, env = parent.frame()) {
  skip_if_not_installed("rmarkdown")
  skip_if_not(rmarkdown::pandoc_available("1.12.3"))

  root <- withr::local_tempdir(.local_envir = env)
  rmd <- file.path(root, "README.Rmd")
  writeLines(
    c("---", "output: cynkratemplate::readme_document", "---", "", body),
    rmd
  )

  rmarkdown::render(
    rmd,
    output_file = "README.md",
    output_dir = root,
    envir = new.env(parent = globalenv()),
    quiet = TRUE
  )

  read <- function(name) {
    path <- file.path(root, name)
    if (!file.exists(path)) NULL else readLines(path, warn = FALSE)
  }
  list(root = root, readme = read("README.md"), index = read("index.md"))
}
