# resolve-eap.sh

Product resolver plug-in for JBoss EAP. Called by `initcaseenv.sh` to resolve image and configuration.

## Usage

```bash
resolve-eap.sh <version> [--cached VALUE] [--env-dir DIR]
resolve-eap.sh --detect-info
```

## Behavior

### EAP 8.x

- Resolves Galleon channel via `get-eap-channel.sh`
- Generates `Containerfile-eap-<version>` in `--env-dir` (multi-stage build: builder + runtime)
- Image: `localhost/eap-<version>` (local build required)
- `RESOLVE_CONTAINERFILE=Containerfile-eap-<version>` (non-empty = build required, value is the filename)

### EAP 7.x

- Uses pre-built registry image: `registry.redhat.io/jboss-eap-7/eap7<minor>-openjdk11-openshift-rhel8:latest`
- Resolves feature-pack info via `get-eap-channel.sh` (warning if unavailable)
- No build required — `RESOLVE_CONTAINERFILE=` (empty)

## Options

| Option | Description |
|--------|-------------|
| `--detect-info` | Print detection metadata (DETECT_*) and exit |
| `--cached VALUE` | Use cached channel/feature-pack ENV line (skip resolution) |
| `--env-dir DIR` | Directory where `Containerfile-eap-<version>` is written (EAP 8 only) |

## Detection metadata (--detect-info)

Used by `_detect_environment()` in the agent to auto-detect this product
in case text. See `resolve-rhbk.sh-README.md` for field descriptions.

## Output (stdout)

```
RESOLVE_IMAGE=<image>
RESOLVE_CONTAINER_PREFIX=jbosseap
RESOLVE_COMMAND=
RESOLVE_DEFAULT_ENVS=CONFIG_IS_FINAL=true
RESOLVE_DB_NAME=eap
RESOLVE_DB_USER=eap
RESOLVE_DB_ENVS=<pipe-separated env vars with __DB_HOST__/__DB_NAME__/__DB_USER__ placeholders>
RESOLVE_CONTAINERFILE=Containerfile-eap-<version>|<empty>
RESOLVE_POST_START_CMD=
RESOLVE_CACHE_VALUE=<channel ENV line>
```

## Dependencies

- `get-eap-channel.sh` (same directory)
- bash

## Author

Daniele Mammarella <dmammare@redhat.com>
