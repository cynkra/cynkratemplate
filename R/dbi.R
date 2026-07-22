# DBI lives in this package's Suggests purely to give the rcc-suggests
# ("without") CI workflow a package to drop and re-check. It is a good fit
# because it is dependency-free (base R only) and is not pulled in transitively
# by the CI toolchain (rmarkdown / rcmdcheck / testthat), so the off_limits
# filter in .github/workflows/dep-suggests-matrix does not exclude it -- unlike
# cli, desc or yaml, which rmarkdown / rcmdcheck drag in. Because DBI is only in
# Suggests, every use of it must be guarded with requireNamespace().

# dbi_example() is intentionally unexported and undocumented: it exists only so
# the package references the optional DBI dependency (conditionally), giving the
# "without" workflow something to drop. Not meant for real use.
dbi_example <- function() {
  if (!requireNamespace("DBI", quietly = TRUE)) {
    return(NULL)
  }

  # Dummy usage: touch a DBI symbol so the dependency is genuinely exercised.
  is.function(DBI::dbGetQuery)
}
