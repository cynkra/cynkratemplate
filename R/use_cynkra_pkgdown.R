#' Set up cynkratemplate usage
#'
#' This function
#' * registers cynkratemplate usage in the pkgdown config;
#' * explains what the next steps are.
#'
#' The cynkra favicon is shipped with the template itself
#' and copied to the root of every site that uses it,
#' so the package does not need its own `pkgdown/favicon/` folder.
#' If one exists, pkgdown uses it instead of the cynkra favicon.
#'
#' @param pkg Path to package
#'
#' @return None
#' @export
#'
use_cynkra_pkgdown <- function(pkg = getwd()) {
  cat(paste(cli::symbol$info, sprintf("Working in %s\n", pkg)))

  current_needs <- desc::desc_get("Config/Needs/website")
  needs <- if (!is.na(current_needs)) {
    toString(c(as.character(current_needs), "cynkra/cynkratemplate"))
  } else {
    "cynkra/cynkratemplate"
  }
  desc::desc_set("Config/Needs/website" = needs)
  cat(paste(cli::symbol$tick, "Registered GHA dependency on cynkratemplate.\n"))

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
    config$template$includes$before_title <- NULL
    if (!is.null(config$template$bootstrap)) {
      config$template$bootstrap <- 5
    }
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
