# cynkratemplate

[![Lifecycle: maturing](https://img.shields.io/badge/lifecycle-maturing-blue.svg)](https://www.tidyverse.org/lifecycle/#maturing)

This is a private template for use by cynkra packages.
Please don't use it for your own package.

## Usage

Install cynkratemplate.

```r
devtools::install_github("cynkra/cynkratemplate")
```

Run 

```r
cynkratemplate::use_cynkra_pkgdown()
```

Please ask the person in charge (see website page of the general manual in clickup) for a plausible subdomain via email or another mean of communication of their choice.

## Fonts

Our private "Frutiger" fonts are hosted on AWS in the "cynkraweb" S3 bucket.
Some browsers (e.g. Firefox) block the font access if the "CORS" headers are not set correctly.

To allow access, the domain needs to be whitelisted within the CORS configuration block of the S3 bucket.
In addition, he ACL settings of the bucket must be set to "public read" so the files can actually be accessed in the first place.

## Local preview

To see the Frutiger fonts within local previews, you need to allow CORS for localhost files.
This setting is usually off in most browsers and will hence block resources from a different origin.
As the fonts are served via AWS S3, the origin differs from localhost.

For Chromium-based browsers, the "CORS Unblock" extension does the job.
There should be similar extensions for Firefox and other browsers.
Safari is less strict with CORS and should serve the Frutiger font by default.
