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
    <AllowedOrigin>https://cynkra.com</AllowedOrigin>
    <AllowedMethod>*</AllowedMethod>
    <AllowedHeader>Content-*</AllowedHeader>
  </CORSRule>
</CORSConfiguration>
```

This allows access only for the cynkra.com domain.
To open up for everyone, replace `https://cynkra.com` by `*`.

Also ensure that the ACL settings are set to "public read" so the files can actually be accessed in the first place.
