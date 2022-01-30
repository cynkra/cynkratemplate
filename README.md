# cynkratemplate

[![Lifecycle: maturing](https://img.shields.io/badge/lifecycle-maturing-blue.svg)](https://www.tidyverse.org/lifecycle/#maturing)

This is a private template for use by cynkra packages.
Please don't use it for your own package.

## Fonts

Our private "Frutiger" fonts are hosted on Exoscale in the "cynkraweb" S3 bucket.
Some browsers (e.g. Firefox) block the font access if the "CORS" headers are not set correctly.

To allow access, the following XML configuration file needs to be applied recursively to all elements in the S3 bucket.
To do so, click on "Edit" in the Exoscale S3 bucket and paste the snippet into the "CORS" field

```xml
<?xml version="1.0" ?>
<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <CORSRule>
    <AllowedOrigin>*</AllowedOrigin>
    <AllowedMethod>*</AllowedMethod>
    <AllowedHeader>Content-*</AllowedHeader>
  </CORSRule>
</CORSConfiguration>
```

This allows access for any domain.
To restrict access, replace `*` by `https://cynkra.com`.
However note that this only applies to this exact domain and does not include subdomains like `xyz.cynkra.com`.

Also ensure that the ACL settings are set to "public read" so the files can actually be accessed in the first place.

## Local preview

To see the Frutiger fonts within local previews, you need to allow CORS for localhost files.
This setting is usually off in most browsers and will hence block resources from a different origin.
As the fonts are served via AWS S3, the origin differs from localhost.

For Chromium-based browsers, the "CORS Unblock" extension does the job.
