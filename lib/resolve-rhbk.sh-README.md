# resolve-rhbk.sh

Product resolver plug-in for Red Hat build of Keycloak (RHBK). Called by `initcaseenv.sh` to resolve image and configuration.

## Usage

```bash
resolve-rhbk.sh <version> [--cached VALUE] [--env-dir DIR]
resolve-rhbk.sh --detect-info
```

## Behavior

- Resolves the container image for the given RHBK version via `get-rhbk-image.sh` (uses skopeo + podman)
- No build required — uses pre-built registry images (`RESOLVE_CONTAINERFILE=` empty)
- `--env-dir` is accepted but not used (no Containerfile needed)

## Options

| Option | Description |
|--------|-------------|
| `--detect-info` | Print detection metadata (DETECT_*) and exit |
| `--cached VALUE` | Use cached image URL (skip resolution) |
| `--env-dir DIR` | Accepted for interface compatibility (ignored) |

## Detection metadata (`--detect-info`)

Static "identity card" of the product. Used by the agent to auto-detect
this product in case text, and by `initcaseenv.sh` for health checks.
Called without a version. Output:

```
DETECT_GREP_PATTERN=<extended regex for product mention detection>
DETECT_VERSION_PATTERN=<extended regex for version extraction>
DETECT_DB_MODE=always|detect|never
DETECT_DEFAULT_PORTS=<comma-separated host:container, primary position>
DETECT_READY_LOG=<grep pattern in container logs meaning "app started">
DETECT_HEALTH_CHECKS=<proto:port:path endpoints for curl checks, empty=disabled>
```

## Resolution output (`<version>`)

Called with a version (e.g. `resolve-rhbk.sh 26.4.7`). Returns everything
needed to build and run the container. `initcaseenv.sh` captures and `eval`s
this output. Output:

```
RESOLVE_IMAGE=<image>
RESOLVE_CONTAINER_PREFIX=rhbk
RESOLVE_COMMAND=start-dev
RESOLVE_DEFAULT_ENVS=KC_BOOTSTRAP_ADMIN_USERNAME=admin|KC_BOOTSTRAP_ADMIN_PASSWORD=admin|...
RESOLVE_DB_NAME=keycloak
RESOLVE_DB_USER=keycloak
RESOLVE_DB_ENVS=<pipe-separated env vars with __DB_HOST__/__DB_NAME__/__DB_USER__ placeholders>
RESOLVE_CONTAINERFILE=
RESOLVE_POST_START_CMD=<command to run inside container after startup, e.g. kcadm.sh>
RESOLVE_CACHE_VALUE=<image URL>
```

## Dependencies

- `get-rhbk-image.sh` (same directory)
- bash

## Author

Daniele Mammarella <dmammare@redhat.com>
