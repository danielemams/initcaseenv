# resolve-amq.sh

Product resolver for Red Hat AMQ Broker (ActiveMQ Artemis).

## Interface

```
resolve-amq.sh <version> [--cached VALUE] [--env-dir DIR]
resolve-amq.sh --detect-info
```

- `version`: AMQ Broker version (e.g. `7.12`, `7.12.3`)
- `--detect-info`: print detection metadata (DETECT_*) and exit
- `--cached VALUE`: skip resolution, use cached image reference
- `--env-dir DIR`: ignored (AMQ uses pre-built images, `RESOLVE_CONTAINERFILE=` empty)

## Detection metadata (--detect-info)

Used by `_detect_environment()` in the agent to auto-detect this product
in case text. See `resolve-rhbk.sh-README.md` for field descriptions.

## Image resolution

Uses the floating stream tag from `registry.redhat.io/amq7/amq-broker-rhel8`.
For version `7.12.3`, resolves to tag `7.12`.

Optionally verifies the image via `skopeo inspect` if skopeo is available.

## Output variables

| Variable | Value |
|----------|-------|
| `RESOLVE_IMAGE` | `registry.redhat.io/amq7/amq-broker-rhel8:<stream>` |
| `RESOLVE_CONTAINER_PREFIX` | `amq` |
| `RESOLVE_COMMAND` | (empty — uses image default) |
| `RESOLVE_DEFAULT_ENVS` | `AMQ_USER=admin`, `AMQ_PASSWORD=admin`, `AMQ_ROLE=admin`, `AMQ_REQUIRE_LOGIN=true` |
| `RESOLVE_DB_*` | (empty — AMQ does not require an external database) |
| `RESOLVE_CONTAINERFILE` | (empty — pre-built image, no build needed) |
| `RESOLVE_POST_START_CMD` | (empty) |

## Default ports

AMQ Broker exposes: 8161 (web console), 61616 (Artemis core), 5672 (AMQP), 1883 (MQTT), 61613 (STOMP).

## Dependencies

- skopeo (optional, for image verification)
- podman login to `registry.redhat.io`

## Author

Daniele Mammarella <dmammare@redhat.com>
