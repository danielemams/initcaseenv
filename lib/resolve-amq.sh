#!/bin/bash
# Product resolver for Red Hat AMQ Broker (ActiveMQ Artemis).
#
# Called by initcaseenv.sh to resolve image and configuration.
# Output (stdout): RESOLVE_* variable assignments (sourced by caller).
# Messages (stderr): human-readable progress info.
#
# Usage: resolve-amq.sh <version> [--cached VALUE] [--env-dir DIR]
#        resolve-amq.sh --detect-info
#
# Author: Daniele Mammarella <dmammare@redhat.com>

set -euo pipefail

_self="$0"
[ -L "$_self" ] && _self="$(readlink -f "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

VERSION=""
CACHED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --detect-info)
      cat <<'DETECT'
DETECT_GREP_PATTERN=\bAMQ\b|ActiveMQ|Artemis|AMQ Broker|amq-broker
DETECT_VERSION_PATTERN=(AMQ|AMQ Broker) [0-9]+\.[0-9]+(\.[0-9]+)?
DETECT_DB_MODE=never
DETECT_DEFAULT_PORTS=8161:8161,61616:61616,5672:5672
DETECT_READY_LOG=Apache ActiveMQ Artemis.*started
DETECT_HEALTH_CHECKS=http:8161:/console/login
DETECT
      exit 0 ;;
    --cached)  CACHED="$2"; shift 2 ;;
    --env-dir) shift 2 ;;  # not used by AMQ (no build needed)
    *)         VERSION="$1"; shift ;;
  esac
done

[ -z "$VERSION" ] && { echo "Error: version required." >&2; exit 1; }

# AMQ Broker image: registry.redhat.io/amq7/amq-broker-rhel8
# Tag format: <major>.<minor>-<build> (e.g. 7.12-1)
# For simplicity, use the stream tag (e.g. 7.12) as floating tag.
REGISTRY="registry.redhat.io"
IMAGE_BASE="amq7/amq-broker-rhel8"

# Parse version: X.Y or X.Y.Z
IFS='.' read -r v1 v2 v3 <<< "$VERSION"
STREAM="${v1}.${v2}"

IMAGE=""

if [ -n "$CACHED" ]; then
  IMAGE="$CACHED"
  echo "Using image: $IMAGE (cached)" >&2
else
  # Use floating stream tag (e.g. 7.12)
  IMAGE="${REGISTRY}/${IMAGE_BASE}:${STREAM}"
  echo "Resolving AMQ Broker image for version ${VERSION}..." >&2

  if command -v skopeo &>/dev/null; then
    if skopeo inspect "docker://${IMAGE}" &>/dev/null; then
      echo "Found image: ${IMAGE}" >&2
    else
      echo "Warning: cannot verify image ${IMAGE} (skopeo inspect failed)." >&2
      echo "Make sure you are logged in: podman login ${REGISTRY}" >&2
    fi
  else
    echo "Note: skopeo not available, using image tag directly." >&2
  fi

  echo "Using image: $IMAGE" >&2
fi

cat <<EOF
RESOLVE_IMAGE=${IMAGE}
RESOLVE_CONTAINER_PREFIX=amq
RESOLVE_COMMAND=
RESOLVE_DEFAULT_ENVS=AMQ_USER=admin|AMQ_PASSWORD=admin|AMQ_ROLE=admin|AMQ_REQUIRE_LOGIN=true
RESOLVE_DB_NAME=
RESOLVE_DB_USER=
RESOLVE_DB_ENVS=
RESOLVE_CONTAINERFILE=
RESOLVE_CACHE_VALUE=${IMAGE}
EOF
