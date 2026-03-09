# get-rhbk-image.sh

Resolve container image reference for Red Hat build of Keycloak (RHBK) by product version.

Called by `initcaseenv.sh` during image resolution.

## Usage

```bash
get-rhbk-image.sh [--list] [<rhbk-version>]
```

## Examples

```bash
# Find exact image for a product version
get-rhbk-image.sh 26.4.5        # RHBK 26.4.5

# Find latest build for a stream
get-rhbk-image.sh 26.4          # Latest RHBK 26.4.x

# List available streams/builds
get-rhbk-image.sh --list        # All streams
get-rhbk-image.sh --list 26.4   # Builds with product versions for 26.4
```

## How it works

Image tag build numbers (e.g. `26.4-4`) do not directly correspond to product micro versions (e.g. `26.4.5`). The script:

1. Lists available tags via `skopeo list-tags`
2. Runs `podman run --version` on candidate images to find the correct product version mapping

## Output

```
# RHBK 26.4 build 4 (built 2026-02-15)
registry.redhat.io/rhbk/keycloak-rhel9:26.4-4
```

## Dependencies

- `skopeo` (for listing tags)
- `podman` (for running version check)
- Registry login: `podman login registry.redhat.io`

## Author

Daniele Mammarella <dmammare@redhat.com>
