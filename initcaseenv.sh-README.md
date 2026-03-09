# initcaseenv.sh

Initialize and manage containerized case environments for enterprise products on Podman.

Uses a plug-in resolver architecture: each product type has a `lib/resolve-<type>.sh` script. To add a new product, create a new resolver — no changes to `initcaseenv.sh` needed.

## Supported products

- **RHBK** (Red Hat build of Keycloak) — resolves container image via skopeo+podman
- **RHSSO** (Red Hat Single Sign-On / Keycloak 7.x) — pre-built images from `registry.redhat.io`
- **JBoss EAP 8.x** — resolves Galleon channel, builds custom image from Containerfile
- **JBoss EAP 7.x** — uses pre-built images from `registry.redhat.io`
- **AMQ Broker** (Red Hat AMQ / ActiveMQ Artemis) — pre-built images from `registry.redhat.io`

## Requirements

- `podman`
- `podman-compose`
- `skopeo` (for RHBK image resolution)
- `python3` (for compose file manipulation and multi-service JSON parsing)
- Registry login: `podman login registry.redhat.io`

## Architecture

### Always-compose

Every case uses `podman-compose` — there is no `podman run` path. The `docker-compose.yml` file is the **single source of truth** for the case environment. There is no `.caseenv.conf`.

### Incremental service management

Services are added incrementally to the compose file. Each invocation with `-t -v` or `-m` **adds** new services to the existing compose — it never replaces it.

**`-t TYPE -v VERSION [-d] [-e K=V] [-p H:C] [-c CMD] [--post-start CMD] [--db-name NAME] [--db-user USER]`** — add a single service:

```bash
# First service: creates compose file with EAP
initcaseenv.sh 04393780 start -t eap -v 8.1.4

# Second service: adds RHBK to the same compose (ports auto-incremented)
initcaseenv.sh 04393780 start -t rhbk -v 26.4.7 -d

# Third service: same type, different version — coexists
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d

# Override container command and post-start
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d -c "start-dev --http-port=9090" --post-start "kcadm.sh update realms/master -s sslRequired=NONE"

# Override database name and user
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d --db-name mykeycloak --db-user myuser
```

**`-m FILE`** — add multiple services from a JSON file:

```bash
initcaseenv.sh 04393780 start -m multi-env.json
```

Both `-t -v` and `-m` call the same `_add_service()` function. Services already present (same type + same version) are skipped.

### Container naming convention

Container names are deterministic: `<resolver_prefix>-<version_nodots>-<CASEID>`

Examples:
- `rhbk-2647-04393780` (RHBK 26.4.7, case 04393780)
- `jbosseap-814-04393780` (EAP 8.1.4, case 04393780)
- `rhbk-2645-04393780` (RHBK 26.4.5, same case — coexists with 26.4.7)

The `<resolver_prefix>` comes from `RESOLVE_CONTAINER_PREFIX` in the resolver output.

### Multiple versions of the same product

You can run multiple versions of the same product in the same case. Each version gets its own container name, ports (auto-incremented), and optionally its own database:

```bash
initcaseenv.sh 04393780 start -t rhbk -v 26.4.7 -d   # ports 8080, 8443
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d   # ports 8081, 8444 (auto-incremented)
```

## Usage

### Adding services

```bash
initcaseenv.sh <CASEID> setup  [-t TYPE] [-v VERSION] [-d] [-e K=V] [-p H:C] [-c CMD] [--post-start CMD] [--db-name NAME] [--db-user USER]
initcaseenv.sh <CASEID> start  [-t TYPE] [-v VERSION] [-d] [-e K=V] [-p H:C] [-c CMD] [--post-start CMD] [--db-name NAME] [--db-user USER]
initcaseenv.sh <CASEID> setup  -m FILE
initcaseenv.sh <CASEID> start  -m FILE
```

| Flag | Description |
|------|-------------|
| `-t TYPE` | Product type (auto-detected from available `resolve-*.sh` scripts) |
| `-v VERSION` | Product version (e.g. `26.4.5` for RHBK, `8.1.4` for EAP) |
| `-d` | Add a PostgreSQL database |
| `-e KEY=VAL` | Environment variable for the container (repeatable) |
| `-p HOST:CTR` | Port mapping (repeatable, replaces auto-detected defaults) |
| `-c CMD` | Override container command (replaces resolver's `RESOLVE_COMMAND`) |
| `--post-start CMD` | Override post-start command (replaces resolver's `RESOLVE_POST_START_CMD`) |
| `--db-name NAME` | Override database name (replaces resolver's `RESOLVE_DB_NAME`) |
| `--db-user USER` | Override database user (replaces resolver's `RESOLVE_DB_USER`) |
| `-m FILE` | JSON file defining multiple services (mutually exclusive with `-t/-v/-d/-e/-p/-c/--post-start/--db-name/--db-user`) |

`setup` only adds to the compose file. `start` adds to compose (if `-t`/`-m` given) and then starts all containers.

### Removing services

```bash
initcaseenv.sh <CASEID> rm CONTAINER [CONTAINER ...]   # Remove specific containers
initcaseenv.sh <CASEID> rm --all                        # Remove everything (compose + containers + howto)
initcaseenv.sh <CASEID> rm                              # Stop all containers (keep compose)
```

### Lifecycle commands

```bash
initcaseenv.sh <CASEID> exec    CONTAINER CMD [ARG ...]
initcaseenv.sh <CASEID> stop    [CONTAINER ...]
initcaseenv.sh <CASEID> restart [CONTAINER ...]
initcaseenv.sh <CASEID> status  [CONTAINER ...]
initcaseenv.sh <CASEID> logs    [CONTAINER ...]
```

`exec` runs a command inside a container (validates container name against compose first). All other lifecycle commands accept optional container names. No names = all containers (default). One or more names = only those containers.

### Context-aware argument parsing

Flags are parsed based on the ACTION, not globally:

- `setup`/`start` accept: `-t`, `-v`, `-d`, `-e`, `-p`, `-m`, `-i`, `-c`, `--post-start`, `--db-name`, `--db-user`
- `exec` accepts: container name + command (all remaining args)
- `rm` accepts: container names, `--all`
- `stop`/`restart`/`status`/`logs` accept: container names (no flags)

### JSON format (`-m`)

```json
{
  "services": [
    {
      "type": "rhbk", "version": "26.4.5", "db": true,
      "ports": ["8080:8080"], "envs": ["KEY=VAL"],
      "command": "start-dev --http-port=9090",
      "post_start": "kcadm.sh update realms/master -s sslRequired=NONE",
      "db_name": "mykeycloak",
      "db_user": "myuser"
    },
    {
      "type": "eap", "version": "8.1.4",
      "ports": ["9080:8080"], "envs": ["KEY=VAL"]
    }
  ]
}
```

The `command`, `post_start`, `db_name`, and `db_user` fields are optional. When specified, they override the resolver defaults for that service.

### Environment merge

Custom environment variables passed via `-e KEY=VAL` are **merged** with resolver defaults (`RESOLVE_DEFAULT_ENVS`). If the same key appears in both, the custom value wins — it overrides the resolver default rather than adding a duplicate. For example, if the resolver sets `KC_HTTP_ENABLED=true` and you pass `-e KC_HTTP_ENABLED=false`, the container gets `KC_HTTP_ENABLED=false`.

## Behavior

### Service add logic (`_add_service`)

When adding a service, the flow checks whether the container already exists:

| Container state (podman) | Compose entry exists? | Action |
|--------------------------|----------------------|--------|
| Running | Yes | "already running, reusing." — no changes |
| Stopped/exited | Yes | "exists but stopped, will be restarted." — compose up restarts it |
| Not found | Yes | "container not found, will be recreated." — compose up recreates it |
| Not found | No | Full resolution: resolve image, build if needed, add to compose |

**Config conflict warning**: if a service already exists and the user passes `-d`, `-e`, or `-p` flags that differ from the existing configuration, a NOTE is printed:

```
Service rhbk 26.4.7 already running (rhbk-2647-04393780), reusing.
  NOTE: -d -p flags ignored — existing container retains its original configuration.
  To apply new configuration: rm rhbk-2647-04393780, then re-add.
```

This preserves the existing container (which may have been customized at runtime — files added, config changed inside). To apply new configuration, explicitly remove and re-add.

### Port allocation

- Default ports are auto-detected from the image's exposed ports (1:1 mapping)
- Use `-p` to override defaults (auto-increment still applies)
- **Auto-increment**: if a host port is already used by a running podman container OR already allocated in the compose file, the host port is incremented by +1 until a free one is found
- This works across CASEIDs, enabling parallel multi-case work
- Ports are fixed at container creation and don't change on subsequent starts

### Start-up flow

```
_prepare_services()     Add new services to compose (if -t/-v or -m given)
  |
do_start()              podman-compose up -d (skip running, restart stopped, create missing)
  |
do_health_check()       Per-container: wait for DETECT_READY_LOG, then curl DETECT_HEALTH_CHECKS
  |                     Skipped for containers that were already running before this start
do_post_start()         Per-container: podman exec post-start command
  |                     Skipped for containers that were already running before this start
do_health_check()       Re-check after post-start (if post-start ran)
```

### Health checks (per-product, in `lib/resolve-<type>.sh`)

There are 3 levels of readiness verification, all configured in the resolver:

**1. `DETECT_READY_LOG` (always active)** — in `--detect-info` block.
Grep pattern matched against container logs. Uses `podman logs --since <timestamp>` where the timestamp is captured right before `podman-compose up`. This ensures only logs from the current start are matched — old logs from previously stopped or restarted containers are ignored. Waits up to 120s for this line to appear before proceeding.
Every product should define this (e.g. `WFLYSRV0025.*started in` for JBoss, `Listening on: http://` for Quarkus).

**2. `DETECT_HEALTH_CHECKS` (opt-in, disabled by default)** — in `--detect-info` block.
HTTP/HTTPS endpoint checks via curl. Only runs if non-empty. Uses per-container port mapping via `podman port` (not global compose ports), so each container's health check hits the correct host port even when multiple services expose the same container port.

Syntax:
```
DETECT_HEALTH_CHECKS=proto:container_port:path[,proto:container_port:path,...]
```

**3. Post-start command (opt-in)** — from resolver output (`RESOLVE_POST_START_CMD`) or `--post-start` flag override.
Arbitrary command executed inside the container via `podman exec` after the app is ready.

When `--post-start` is specified via CLI or JSON, it is stored as a compose label `initcaseenv.post_start` on the container service. At runtime, `do_post_start()` reads the label via `podman inspect` and executes it. If no label is set, it falls back to the resolver's `RESOLVE_POST_START_CMD`.

All health check and post-start messages include both the product type and version for clarity (e.g. "rhbk 26.4.7: UP & RUNNING").

### Skip already-running containers

Health checks and post-start commands are **skipped** for containers that were already running before `podman-compose up -d`. This avoids redundant checks when adding a new service to a case that already has running containers.

### Run history

Every successful start appends a timestamped entry to `buildenv-<CASEID>-howto.txt` with full configuration details per run:

- **Invocation args**: the full command-line arguments used
- **Compose command**: the exact `podman-compose` command executed
- **Per-container details**: image, command, ports (host:container mappings), environment variables, and container state (newly started vs. already running)

This provides a complete audit trail of all configuration across runs.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CASES_DIR` | `~/cases` | Base directory for case folders |
| `CASE_DIR` | (env override) | Override case folder path |
| `INITCASEENV_SUBDIR` | `initcaseenv-data` | Subfolder for generated files |

## Generated files

```
$CASES_DIR/<CASEID>/initcaseenv-data/
├── docker-compose.yml                  # Single source of truth for all services
├── buildenv-<CASEID>-howto.txt         # Reference commands, service list, run history
└── Containerfile-<type>-<version>      # If build required (e.g. Containerfile-eap-8.1.4)
```

Containerfile naming convention: `Containerfile-<type>-<version>` (e.g. `Containerfile-eap-8.1.4`). Only generated when the resolver indicates a build is required (see `RESOLVE_CONTAINERFILE`).

## Resolver architecture

Each product resolver (`lib/resolve-<type>.sh`) exposes **two APIs** via stdout:

### 1. `resolve-<type>.sh --detect-info` — Detection metadata (static)

Called **without a version**. Returns `DETECT_*` variables — a static "identity card" of the product:

- **Who am I**: `DETECT_GREP_PATTERN` — regex to recognize this product in case text (e.g. `\bKeycloak\b|\bRHBK\b`)
- **What version**: `DETECT_VERSION_PATTERN` — regex to extract version from case text (e.g. `(Keycloak|RHBK) [0-9]+\.[0-9]+`)
- **Do I need a DB**: `DETECT_DB_MODE` — `always` (RHBK, SSO), `detect` (EAP: only if case mentions datasource), `never` (AMQ)
- **My ports**: `DETECT_DEFAULT_PORTS` — default port mappings (host ports auto-increment if already in use)
- **When am I ready**: `DETECT_READY_LOG` — grep pattern in container logs (e.g. `Listening on: http://`)
- **Extra health checks**: `DETECT_HEALTH_CHECKS` — HTTP/HTTPS curl checks (opt-in, empty by default)

The **agent** uses this to auto-detect product type and version from case text. `initcaseenv.sh` uses `DETECT_READY_LOG` and `DETECT_HEALTH_CHECKS` for post-start health verification.

### 2. `resolve-<type>.sh <version>` — Resolution output (version-dependent)

Called **with a version** (e.g. `resolve-rhbk.sh 26.4.7`). Returns `RESOLVE_*` variables — everything needed to build and run the container:

| Variable | Description |
|----------|-------------|
| `RESOLVE_IMAGE` | Container image to pull/build |
| `RESOLVE_CONTAINER_PREFIX` | Naming prefix (e.g. `rhbk`, `jbosseap`) |
| `RESOLVE_COMMAND` | Container entrypoint command (e.g. `start-dev`) |
| `RESOLVE_DEFAULT_ENVS` | Default environment variables (pipe-separated) |
| `RESOLVE_DB_NAME` | Database name for PostgreSQL container |
| `RESOLVE_DB_USER` | Database user for PostgreSQL container |
| `RESOLVE_DB_ENVS` | Database-related environment variables for the app container |
| `RESOLVE_CONTAINERFILE` | Containerfile name if image needs local build (e.g. `Containerfile-eap-8.1.4`), empty if pre-built image. Non-empty = build required + the filename; empty = no build required |
| `RESOLVE_POST_START_CMD` | Command to run inside the container after startup via `podman exec` (e.g. `kcadm.sh update realms/master -s sslRequired=NONE`) |
| `RESOLVE_CACHE_VALUE` | Value to cache for subsequent runs |

`initcaseenv.sh` captures this output via `eval` and uses it to configure podman.

### Who uses what

The `--detect-info` output is consumed by **two different callers**, each reading different fields:

**Agent** (pre-start, auto-detection from case text):
- `DETECT_GREP_PATTERN` — grep case text to find which product is mentioned
- `DETECT_VERSION_PATTERN` — extract version number from case text
- `DETECT_DB_MODE` — decide whether to add a database container
- `DETECT_DEFAULT_PORTS` — assign port mappings (auto-increment if occupied)

**initcaseenv.sh** (post-start, health verification):
- `DETECT_READY_LOG` — grep container logs, wait up to 120s for this line
- `DETECT_HEALTH_CHECKS` — curl HTTP/HTTPS endpoints (only if non-empty)

The resolution output (`RESOLVE_*`) is used only by **initcaseenv.sh**:
- `RESOLVE_IMAGE`, `RESOLVE_COMMAND`, `RESOLVE_DEFAULT_ENVS` → build compose service definition
- `RESOLVE_CONTAINERFILE` → if non-empty, build image locally from the named Containerfile
- `RESOLVE_POST_START_CMD` → run inside the container via `podman exec` after health checks pass
- `RESOLVE_DB_NAME`, `RESOLVE_DB_USER`, `RESOLVE_DB_ENVS` → configure PostgreSQL sidecar

### Flow

```
# 1. Agent: auto-detect product from case text (pre-start)
for resolver in lib/resolve-*.sh; do
  detect_info=$($resolver --detect-info)
  # grep case text with DETECT_GREP_PATTERN → match? → this is our product
  # extract version with DETECT_VERSION_PATTERN → e.g. "26.4.7"
  # check DETECT_DB_MODE → add DB? yes/no
  # pick DETECT_DEFAULT_PORTS (auto-increment if port occupied)
done

# 2. initcaseenv.sh: resolve and add to compose
resolve_output=$(lib/resolve-rhbk.sh 26.4.7)
eval "$resolve_output"
# → generate/update docker-compose.yml with new service block

# 3. initcaseenv.sh: start all services
podman-compose -p case-04393780 up -d

# 4. initcaseenv.sh: health checks (post-start, only for newly started containers)
detect_info=$(lib/resolve-rhbk.sh --detect-info)
# → grep container logs (--since compose up timestamp) for DETECT_READY_LOG (wait up to 120s)
# → if DETECT_HEALTH_CHECKS non-empty: curl each endpoint (per-container port via podman port)
# → if post-start set (label or RESOLVE_POST_START_CMD): podman exec <container> <command>
```

Each resolver handles **all versions** of its product (e.g. `resolve-eap.sh` handles both EAP 7.x and 8.x with internal `if/else`). One resolver per product, not per version.

## Examples

```bash
# Add first service
initcaseenv.sh 04393780 start -t eap -v 8.1.4

# Add second service (ports auto-incremented)
initcaseenv.sh 04393780 start -t rhbk -v 26.4.7 -d

# Add another version of the same product
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d

# Override container command
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d -c "start-dev --http-port=9090"

# Override post-start and database config
initcaseenv.sh 04393780 start -t rhbk -v 26.4.5 -d --post-start "kcadm.sh config credentials" --db-name mydb --db-user myuser

# Re-run same service → reuses existing container
initcaseenv.sh 04393780 start -t rhbk -v 26.4.7

# Multi-service from JSON
initcaseenv.sh 04393780 start -m multi-env.json

# Execute command inside a container
initcaseenv.sh 04393780 exec rhbk-2647-04393780 kcadm.sh get realms/master
initcaseenv.sh 04393780 exec jbosseap-814-04393780 /opt/jboss/wildfly/bin/jboss-cli.sh -c --command=":read-attribute(name=server-state)"

# Remove specific container
initcaseenv.sh 04393780 rm rhbk-2645-04393780

# Remove multiple containers
initcaseenv.sh 04393780 rm rhbk-2645-04393780 rhbk-2647-04393780

# Remove everything
initcaseenv.sh 04393780 rm --all

# Stop specific container
initcaseenv.sh 04393780 stop rhbk-2645-04393780

# Logs for one container
initcaseenv.sh 04393780 logs jbosseap-814-04393780

# Lifecycle (all containers)
initcaseenv.sh 04393780 stop
initcaseenv.sh 04393780 restart
```

## Sub-scripts

Product resolvers and helpers in `lib/`:
- `resolve-amq.sh` — product resolver for AMQ Broker
- `resolve-eap.sh` — product resolver for JBoss EAP (7.x + 8.x)
- `resolve-rhbk.sh` — product resolver for RHBK
- `resolve-sso.sh` — product resolver for RHSSO (7.x)
- `get-eap-channel.sh` — resolve EAP Galleon channel/feature-pack
- `get-rhbk-image.sh` — resolve RHBK container image by version
- `prepare-new-resolver.sh` — interactive generator for new product resolvers

## Platform compatibility

Works on both Linux and macOS (bash 3.2 + BSD tools). Port detection falls back to `lsof -iTCP` when `ss` is not available. No GNU-specific bash features or coreutils are required.

## Dependencies

- `podman`
- `podman-compose`
- `skopeo` (for RHBK image resolution)
- `python3` (for compose file manipulation and multi-service JSON parsing)
- Registry login: `podman login registry.redhat.io`

## Author

Daniele Mammarella <dmammare@redhat.com>
