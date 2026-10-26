# Apache Traffic Server Dockerized

This is simply a wrapper for ATS, which allows you to easily run it in a Docker
environment.

It is based upon the official Debian image and ships with the default Debian
configuration, but comes with ways to customize it.

## Available tags

We're running two tags in here, which follow internally the same version of ATS
than the one you'll find in Debian stable at the moment of the build.

- `latest` is the latest version of ATS found in Debian stable
- `no-hwloc` is the same as `latest` but without the `hwloc` capabilities,
  which is sadly a requirement for some cloud environments like the
  DigitalOcean app platform

## Security

The images are patched against
[CVE-2026-111497](https://nvd.nist.gov/vuln/detail/CVE-2026-111497), an
out-of-bounds write in the Google Brotli decoder that a remote attacker can
trigger with a crafted `Content-Encoding: br` payload. It affects every Brotli
release from `1.0.3` up to and including `1.2.0`.

Ubuntu noble still ships the vulnerable `libbrotli1` `1.1.0`, and no patched
package has been published for it yet. The Dockerfile therefore builds the fixed
upstream release (pinned by the `BROTLI_VERSION` build argument, currently
`v1.1.1`), installs it into `/usr/local` and deletes the vulnerable copy from
`/usr/lib/x86_64-linux-gnu`, so that every consumer in the image (ATS,
ImageMagick, ...) decodes Brotli with the patched library. The build fails if
the resulting library is older than `1.1.1`.

Two caveats:

- Image scanners that report on the installed packages rather than on the files
  will keep flagging `libbrotli1` until Ubuntu publishes the security update,
  because the Debian package metadata still describes `1.1.0`. The code that is
  actually loaded is the patched `1.1.1`.
- Once Ubuntu ships a fixed `libbrotli1` for noble, this workaround can be
  dropped in favour of the packaged library.

## Environment Interpolation

First of all, any file in `/etc/trafficserver` can be fed with environment
variables. All you need is to prefix its extension with `.tpl` in order to
enable the interpolation.

For example:

- `remap.tpl.config` &rarr; `remap.config`
- `cache#not_in_cache.tpl` &rarr; `cache#not_in_cache`

Then you can use a Django-like `{{ VARIABLE }}` syntax in your files. Here is
an example for `remap.tpl.config`:

```text
map /back/ {{ API_URL }}/back/
map / {{ FRONT_URL }}/
```

## YAML records

It's a matter of personal taste I guess but the `records.config` file is
absolutely unreadable. This is why there is a way to write it as YAML and then
generate the actual file from it.

Here's an example of `records.config.yaml` (which then will be converted to
`records.config`):

```yaml
proxy:
    config:
        admin:
            user_id: trafficserver
        log:
            logging_enabled: 3
        dns:
            search_default_domains: 1
        http:
            server_ports: "9000"
            connect_attempts_timeout: 30
        reverse_proxy:
            enabled: true
        url_remap:
            remap_required: true
            pristine_host_hdr: true
```

> A highlight here: the image ships a `trafficserver` user and makes its runtime
> directories writable by that user. It also makes them group writable for
> `nobody`, the user ATS falls back to when `proxy.config.admin.user_id` is not
> set, so the container starts with or without this record. Setting it to
> `trafficserver` is still the recommended way to run as a dedicated user.

This feature is compatible with the previous one. You could for example have
a `records.config.tpl.yaml` file which would first be transformed into a
`records.config.yaml` and then into a `records.config`.

Finally, if you need to express an `INT` with a suffix, you can use the
following syntax:

```yaml
proxy:
    config:
        some_size: [42, M]
```
