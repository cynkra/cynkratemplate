# Autolink the inline code in a README's prose, and only in prose.
#
# `downlit::downlit_md_path()` is the obvious tool and is not usable here. It
# rewrites every fenced block into a `<pre class='chroma'>` blob whose
# highlighting lives in CSS classes GitHub does not ship, so the code comes out
# unhighlighted and no longer copy-pasteable as a block; and it reflows the
# prose, which would undo the semantic line breaks these READMEs are written
# with and turn every future edit back into a paragraph-sized diff.
#
# So the markdown is walked instead. Code blocks and line breaks are passed
# through untouched, and only inline spans that `downlit::autolink_url()` can
# resolve to a documented object are rewritten. Anything it cannot resolve --
# prose in backticks, a SQL fragment, a local variable, a file name -- is left
# exactly as it was. The rule is "link what is demonstrably documented, touch
# nothing else", which is what keeps this safe to run over thirty READMEs.
#
# `index.md` is deliberately not autolinked: pkgdown runs downlit over the front
# page itself, so linking here would be redundant work on one side and a source
# of double-linked spans on the other.
#
# downlit is only suggested, so a README renders without links where it is not
# installed. That also makes it the package the rcc-suggests ("without") job
# drops and re-checks: nothing in the CI toolchain (rmarkdown, rcmdcheck,
# testthat) pulls it in, so the dep-suggests-matrix action does not rule it out.
autolink_readme <- function(lines, root) {
  if (!requireNamespace("downlit", quietly = TRUE)) {
    return(lines)
  }
  local_downlit_context(root)
  autolink_lines(lines)
}

# Teach downlit which package it is looking at, so a README may write its own
# `foo()` unqualified and still get a link. Without this only `pkg::foo()` and
# base R resolve, which is the smaller and less useful half.
# The options are restored when `.local_envir` exits.
local_downlit_context <- function(root, .local_envir = parent.frame()) {
  desc_path <- file.path(root, "DESCRIPTION")
  if (!file.exists(desc_path)) {
    return(invisible())
  }
  desc <- read.dcf(desc_path)[1, ]
  pkg <- unname(desc[["Package"]])

  # The reference URL comes from the pkgdown site declared in `URL`, not from a
  # guess: a package whose site is not published would otherwise have every one
  # of its own functions linked to a 404.
  # Its articles are pinned the same way, so `vignette()` in a README links to
  # the site rather than to the package's CRAN page.
  site <- documentation_site(desc[["URL"]] %||% NA_character_)
  if (is.na(site)) {
    return(invisible())
  }

  withr::local_options(
    .local_envir = .local_envir,
    downlit.package = pkg,
    downlit.topic_index = topic_index(root),
    downlit.topic_path = paste0(site, "/reference/"),
    downlit.article_path = paste0(site, "/articles/"),
    downlit.local_packages = local_packages(pkg, site)
  )
}

# downlit discovers another package's documentation URLs by fetching
# `<site>/pkgdown.yml`, and when that fetch fails it falls back to rdrr.io for a
# topic and to the CRAN vignette page for an article, silently. The link a
# README ends up with would then depend on which sites the renderer happens to
# reach, so the same source would render to different bytes for different
# people -- the one thing a checked-in generated file must not do.
#
# `downlit.local_packages` is consulted before any fetch, so the rule used above
# for the package being rendered is applied up front to every installed package
# instead. This also makes the links correct rather than merely stable: rdrr.io
# is a mirror of the manual, and the package's own site is where its readers are.
local_packages <- function(pkg, site) {
  sites <- installed_sites()
  # From the source tree, which documents a new function before any installed
  # copy does.
  sites[[pkg]] <- site
  # The renderer's own setting wins, so a local pkgdown preview keeps pointing
  # at itself.
  utils::modifyList(sites, as.list(getOption("downlit.local_packages")))
}

# Every installed package that declares a documentation site, `pkg = site`.
installed_sites <- function() {
  installed <- tryCatch(
    utils::installed.packages(fields = "URL"),
    error = function(e) NULL
  )
  if (is.null(installed) || nrow(installed) == 0) {
    return(list())
  }
  sites <- vapply(installed[, "URL"], documentation_site, character(1))
  names(sites) <- rownames(installed)
  # A package installed into more than one library is listed once per copy;
  # `.libPaths()` order is precedence order, so the first copy wins.
  sites <- sites[!is.na(sites) & !duplicated(names(sites))]
  as.list(sites)
}

# The first `URL` entry that can be a pkgdown site. A source host and a package
# index are documentation for people, not `/reference/` trees, so a link built
# from either would 404; a package that declares nothing else has no site.
#
# The first entry is taken on the same grounds pkgdown itself does it: a package
# whose `URL` leads with a redirect to its site, as `data.table` does, links
# through that redirect rather than to a second address for the same pages.
documentation_site <- function(url) {
  if (length(url) != 1 || is.na(url)) {
    return(NA_character_)
  }
  urls <- trimws(strsplit(url, ",")[[1]])
  urls <- urls[grepl("^https?://", urls)]
  index <- grepl(
    "(github|gitlab|bitbucket|codeberg)[.]com|(^|[.])r-project[.]org|r-universe[.]dev|rdrr[.]io",
    urls,
    ignore.case = TRUE
  )
  site <- urls[!index][1]
  if (is.na(site) || !nzchar(site)) {
    return(NA_character_)
  }
  sub("/$", "", site)
}

# alias -> Rd page, which is what downlit resolves against. Read from `man/`
# rather than from the installed package: the README is rendered from a source
# tree, and a freshly added function is documented there before it is anywhere
# else.
topic_index <- function(root) {
  files <- list.files(file.path(root, "man"), pattern = "[.]Rd$", full.names = TRUE)
  if (length(files) == 0) {
    return(character())
  }
  idx <- lapply(files, function(f) {
    rd <- tryCatch(tools::parse_Rd(f), error = function(e) NULL)
    if (is.null(rd)) {
      return(NULL)
    }
    tags <- vapply(rd, function(x) attr(x, "Rd_tag") %||% "", character(1))
    aliases <- vapply(
      rd[tags == "\\alias"],
      function(x) trimws(paste(unlist(x), collapse = "")),
      character(1)
    )
    stats::setNames(rep(sub("[.]Rd$", "", basename(f)), length(aliases)), aliases)
  })
  unlist(idx)
}

# Walk the markdown, skipping fenced code blocks.
autolink_lines <- function(lines) {
  fence <- NULL
  out <- character(length(lines))
  for (i in seq_along(lines)) {
    line <- lines[[i]]
    marker <- regmatches(line, regexpr("^\\s{0,3}(`{3,}|~{3,})", line))
    if (length(marker) == 1) {
      ch <- substr(trimws(marker), 1, 1)
      n <- nchar(trimws(marker))
      if (is.null(fence)) {
        fence <- list(ch = ch, n = n)
        out[[i]] <- line
        next
      }
      # A closing fence is the same character, at least as long, and carries
      # nothing else on the line. An info string means a new block, not a close.
      if (ch == fence$ch && n >= fence$n && grepl("^\\s{0,3}[`~]+\\s*$", line)) {
        fence <- NULL
        out[[i]] <- line
        next
      }
    }
    out[[i]] <- if (is.null(fence)) autolink_spans(line) else line
  }
  out
}

# Rewrite the resolvable inline code spans of one prose line.
autolink_spans <- function(line) {
  # ``a span with a backtick`` is as valid as `a span`, so the run length of
  # the opening delimiter has to be matched rather than assumed to be one.
  m <- gregexpr("(?<!`)(`+)(?!`)((?:(?!\\1).)+)\\1(?!`)", line, perl = TRUE)[[1]]
  if (m[[1]] == -1) {
    return(line)
  }
  starts <- as.integer(m)
  lengths <- attr(m, "match.length")

  pieces <- character()
  pos <- 1L
  for (i in seq_along(starts)) {
    start <- starts[[i]]
    end <- start + lengths[[i]] - 1L
    span <- substr(line, start, end)
    code <- gsub("^`+|`+$", "", span)
    url <- tryCatch(downlit::autolink_url(code), error = function(e) NA_character_)

    # A span that is already the text of a link must be left alone: markdown
    # has no nested links, and `[[`x`](a)](b)` renders as literal brackets.
    before <- if (start > 1L) substr(line, start - 1L, start - 1L) else ""
    after <- if (end < nchar(line)) substr(line, end + 1L, end + 2L) else ""
    linked <- !is.na(url) && !identical(before, "[") && !startsWith(after, "](")

    pieces <- c(
      pieces,
      substr(line, pos, start - 1L),
      if (linked) paste0("[", span, "](", url, ")") else span
    )
    pos <- end + 1L
  }
  paste0(paste(pieces, collapse = ""), substr(line, pos, nchar(line)))
}
