# initcaseenv

Manage containerized product environments for support case analysis on Podman.

Uses a plug-in resolver architecture: each product type has a `lib/resolve-<type>.sh` script. To add a new product, create a new resolver — no changes to `initcaseenv.sh` needed.

Supports JBoss EAP (7.x, 8.x), RHBK (Keycloak), and AMQ Broker.

## Quick start

```bash
# Start a containerized EAP 8.1.4 instance for case 04393780
initcaseenv.sh 04393780 start -t eap -v 8.1.4

# Start RHBK 26.4.5 with PostgreSQL
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d

# Setup only (no containers)
initcaseenv.sh 04393780 setup -t eap -v 8.1.4

# Lifecycle
initcaseenv.sh 04393780 stop
initcaseenv.sh 04393780 restart
initcaseenv.sh 04393780 rm --all
```

## Project structure

```
initcaseenv.sh                     # Main script (plug-in architecture)
lib/
  resolve-eap.sh                   # Product resolver for JBoss EAP (7.x + 8.x)
  resolve-rhbk.sh                  # Product resolver for RHBK
  get-eap-channel.sh               # Resolve EAP Galleon channel (standalone)
  get-rhbk-image.sh                # Resolve RHBK container image (standalone)
```

Each code file has a `<filename>-README.md` in the same directory.
See [initcaseenv.sh-README.md](initcaseenv.sh-README.md) for full usage, options, and configuration.

## Prerequisites

- `podman`
- `skopeo` (for RHBK)
- `podman-compose` (if using `-d` for database)
- `podman login registry.redhat.io`
