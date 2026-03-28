#!/bin/bash
#
# Copyright 2026 Daniele Mammarella
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
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

# shellcheck source=resolve-image-common.sh
source "${SCRIPT_DIR}/resolve-image-common.sh"

VERSION=""
CACHED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --detect-info)
      cat <<'DETECT'
DETECT_GREP_PATTERN=\bAMQ\b|ActiveMQ|Artemis|AMQ Broker|amq-broker
DETECT_VERSION_PATTERN=(AMQ|AMQ Broker) [0-9]+\.[0-9]+(\.[0-9]+)*
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

BASE_IMAGE="registry.redhat.io/amq7/amq-broker-rhel8"
IMAGE=""

if [ -n "$CACHED" ]; then
  IMAGE="$CACHED"
  echo "Using image: $IMAGE (cached)" >&2
else
  echo "Resolving AMQ Broker image for version ${VERSION}..." >&2
  # Live resolution via skopeo. AMQ tags follow stream format (e.g., 7.12).
  # No version-cmd needed: tag = stream version (no mismatch).
  IMAGE=$(_resolve_image "$BASE_IMAGE" "$VERSION") \
    || { echo "ERROR: could not resolve AMQ Broker image." >&2; exit 1; }
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
