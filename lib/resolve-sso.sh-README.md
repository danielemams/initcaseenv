# resolve-sso.sh

Product resolver plug-in for Red Hat Single Sign-On (RHSSO / Keycloak 7.x). Called by `initcaseenv.sh` to resolve image and configuration.

## Usage

```bash
resolve-sso.sh <version> [--cached VALUE] [--env-dir DIR]
resolve-sso.sh --detect-info
```

## Behavior

- Resolves the container image for the given RHSSO version from `registry.redhat.io/rh-sso-7/`
- Version format: `7.6` → image tag `sso76-openshift-rhel8:7.6`; `7.6.73` → tag `7.6-73`
- Uses skopeo to verify image availability when possible
- No build required — uses pre-built registry images (`RESOLVE_CONTAINERFILE=` empty)
- `--env-dir` is accepted but not used (no Containerfile needed)

## Options

| Option | Description |
|--------|-------------|
| `--detect-info` | Print detection metadata (DETECT_*) and exit |
| `--cached VALUE` | Use cached image URL (skip resolution) |
| `--env-dir DIR` | Accepted for interface compatibility (ignored) |

## Detection metadata (--detect-info)

Used by `_detect_environment()` in the agent to auto-detect this product
in case text. Output:

```
DETECT_GREP_PATTERN=<extended regex for product mention detection>
DETECT_VERSION_PATTERN=<extended regex for version extraction>
DETECT_DB_MODE=always
DETECT_DEFAULT_PORTS=8080:8080,8443:8443
DETECT_HEALTH_CHECKS=http:8080:/auth,https:8443:/auth,http:8080:/auth/admin/master/console/
```

## Output (stdout)

```
RESOLVE_IMAGE=<image>
RESOLVE_CONTAINER_PREFIX=sso
RESOLVE_COMMAND=
RESOLVE_DEFAULT_ENVS=SSO_ADMIN_USERNAME=admin|SSO_ADMIN_PASSWORD=admin
RESOLVE_DB_NAME=sso
RESOLVE_DB_USER=sso
RESOLVE_DB_ENVS=<pipe-separated env vars with __DB_HOST__/__DB_NAME__/__DB_USER__ placeholders>
RESOLVE_CONTAINERFILE=
RESOLVE_POST_START_CMD=<command to run inside container after startup, e.g. kcadm.sh>
RESOLVE_CACHE_VALUE=<image URL>
```

## Dependencies

- skopeo (optional, for image verification)
- bash

## Author

Daniele Mammarella <dmammare@redhat.com>
