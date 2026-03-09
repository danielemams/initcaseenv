# get-eap-channel.sh

Resolve Galleon channel or feature-pack ENV lines for JBoss EAP container image builds.

Called by `initcaseenv.sh` during image resolution.

## Usage

```bash
get-eap-channel.sh [--list] <eap-version>
```

## Examples

```bash
# EAP 8.x — Galleon channel
get-eap-channel.sh 8.1.4        # Latest patch of EAP 8.1 Update 4
get-eap-channel.sh 8.0.1.1      # EAP 8.0 Update 1, Patch 1 (exact)

# EAP 7.x — feature-pack
get-eap-channel.sh 7.4.21       # EAP 7.4 Update 21

# List available versions
get-eap-channel.sh --list 8.0   # All updates & patches for EAP 8.0
```

## Output

Prints Galleon ENV variable lines for use in a Containerfile:

```
# EAP 8.1 Update 4 (channel eap-8.1)
ENV GALLEON_PROVISION_CHANNELS="eap-8.1"
```

With `--list`, prints available version/channel combinations.

## Dependencies

- bash

## Author

Daniele Mammarella <dmammare@redhat.com>
