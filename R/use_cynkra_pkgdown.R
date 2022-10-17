#' Set up cynkratemplate usage
#'
#' This function
#' * copies the favicon folder to the package;
#' * registers cynkratemplate usage in the pkgdown config;
#' * explains what the next steps are.
#'
#' @param pkg Path to package
#'
#' @return None
#' @export
#'
use_cynkra_pkgdown <- function(pkg = getwd()) {
  cat(paste(cli::symbol$info, sprintf("Working in %s\n", pkg)))

  if (!dir.exists(file.path(pkg, "pkgdown", "favicon"))) {
    dir.create(file.path(pkg, "pkgdown", "favicon"), recursive = TRUE)
    copied <- file.copy(
      system.file("favicon", package = "cynkratemplate"),
      file.path(pkg, "pkgdown", "favicon"),
      recursive = TRUE
    )
    if (!copied) {
      stop("Failed to copy favicon folder.")
    }
    cat(paste(cli::symbol$tick, "Copied favicon files to local package.\n"))
  }

  config_path <- find_pkgdown_config(pkg)
  if (is.null(config_path)) {
    meta <- list(
      template = list(package = "cynkratemplate")
    )
    yaml::write_yaml(meta, file.path(pkg, "_pkgdown.yml"))
  } else {
    config <- yaml::read_yaml(config_path)
    config$template$package <- "cynkratemplate"
    config$template$params$bootswatch <- NULL
    yaml::write_yaml(config, file.path(pkg, config_path))
  }
  cat(paste(cli::symbol$tick, "Registered cynkratemplate in pkgdown config.\n"))
  cat(paste(cli::symbol$bullet, "Check the config edits are all harmless.\n"))

  cat(paste(cli::symbol$bullet, "Contact cynkra plausible owner to set up subdomain (see website page of the general manual in clickup).\n"))
}

find_pkgdown_config <- function(pkg) {
  possible_paths <- c(
    "_pkgdown.yml", "_pkgdown.yaml",
    "pkgdown/_pkgdown.yml", "pkgdown/_pkgdown.yaml",
    "inst/_pkgdown.yml", "inst/_pkgdown.yaml"
  )
  for (path in possible_paths) {
    if (file.exists(file.path(pkg, path))) {
      return(path)
    }
  }
  NULL
}
