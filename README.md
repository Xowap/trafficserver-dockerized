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

> A highlight here: it's expected that you're going to have
> `proxy.config.admin.user_id` set to `trafficserver`, so if you don't you
> probably will run into trouble.

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
