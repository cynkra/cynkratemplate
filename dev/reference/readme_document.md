# An R Markdown output format for package READMEs

A `github_document` that also writes the pkgdown front page, `index.md`,
from the same render. Use it from `README.Rmd`:

## Usage

``` r
readme_document(...)
```

## Arguments

- ...:

  Passed to
  [`rmarkdown::github_document()`](https://pkgs.rstudio.com/rmarkdown/reference/github_document.html).

## Value

An
[`rmarkdown::output_format()`](https://pkgs.rstudio.com/rmarkdown/reference/output_format.html).

## Details

    output: cynkratemplate::readme_document

Rendering then works the ordinary way –
`rmarkdown::render("README.Rmd")`, `devtools::build_readme()`, or the
Knit button – with no wrapper to remember.

## Why two files

The README and the front page differ in exactly two ways:

- **Colour.** pkgdown turns ANSI SGR escapes into HTML; GitHub shows the
  raw bytes. So `index.md` keeps the escapes and `README.md` has them
  stripped.

- **The tail.** Everything from the first horizontal rule onwards – the
  code of conduct, licence and funding boilerplate – belongs on GitHub,
  while pkgdown puts that material in its sidebar.

`index.md` is written only when it would differ from `README.md`. A
README with no horizontal rule that emits no colour produces two
identical files, so the file is dropped and pkgdown falls through to
`README.md` on its own lookup order. `.Rbuildignore` is kept in step
either way.

Only a generated `index.md` is dropped. Every one this format writes
opens with a marker comment, the way roxygen2 stamps the files it
generates, and a file without that marker is left where it is with a
warning. A hand-written front page is not this format's to remove.

## Package-specific touch-ups

A README may define `readme_only()` or `index_only()` in a chunk, each
taking and returning a character vector. Each is applied to just that
one output. This is how an asymmetry survives a single render: the usual
case is rewriting `vignette("x")` into an absolute article link, which
GitHub needs and pkgdown must not have, since downlit already auto-links
it there.

## Autolinking

Inline code in the README's prose is linked to its documentation:
`readme_document()` becomes a link to the package's own pkgdown
reference,
[`tibble::tibble()`](https://tibble.tidyverse.org/reference/tibble.html)
to tibble's, [`print()`](https://rdrr.io/r/base/print.html) to the base
R help. The reference URL is taken from the pkgdown site declared in
`URL`, so a package without a published site is left unlinked rather
than pointed at a page that does not exist.

Only prose is linked. Fenced code blocks are passed through untouched:
[`downlit::downlit_md_path()`](https://downlit.r-lib.org/reference/downlit_md_path.html)
would rewrite them into HTML whose highlighting GitHub does not render,
and would reflow the prose besides, undoing the line breaks these
sources are written with. A span that resolves to no documented object –
`TRUE`, a local variable, a SQL fragment – is left exactly as it was.

`index.md` is not linked here: pkgdown runs downlit over the front page
itself.

## Encoding

Rendering requires a UTF-8 locale. The pandoc output this format reads
back is UTF-8 whatever the session is, so a non-UTF-8 locale would have
it re-encoded on the way in and quietly corrupt every non-ASCII
character. Rather than guess, the format checks
[`l10n_info()`](https://rdrr.io/r/base/l10n_info.html) before knitting
and stops.
