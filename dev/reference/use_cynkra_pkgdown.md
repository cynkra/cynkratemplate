# Set up cynkratemplate usage

This function

- registers cynkratemplate usage in the pkgdown config;

- explains what the next steps are.

## Usage

``` r
use_cynkra_pkgdown(pkg = getwd())
```

## Arguments

- pkg:

  Path to package

## Value

None

## Details

The cynkra favicon is shipped with the template itself and copied to the
root of every site that uses it, so the package does not need its own
`pkgdown/favicon/` folder. If one exists, pkgdown uses it instead of the
cynkra favicon.
