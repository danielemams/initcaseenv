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
# Interactive generator for new product resolvers.
#
# Creates a resolve-<type>.sh file in the same directory as this script,
# ready to be used by initcaseenv.sh. Callable from anywhere.
#
# Usage: prepare-new-resolver.sh [PRODUCT_NAME] [VERSION_OR_IMAGE]
#
# Examples:
#   prepare-new-resolver.sh                              # fully interactive
#   prepare-new-resolver.sh sso 7.6                      # minimal, fills defaults
#   prepare-new-resolver.sh sso sso76-openshift-rhel8:7.6-73  # from image tag
#
# Author: Daniele Mammarella <dmammare@redhat.com>

set -euo pipefail

_self="$0"
[ -L "$_self" ] && _self="$(readlink -f "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

_ask() {
  local prompt="$1" value
  if [ $# -ge 2 ]; then
    local default="$2"
    if [ -n "$default" ]; then
      read -rp "  $prompt [$default]: " value
    else
      read -rp "  $prompt (optional): " value
    fi
    echo "${value:-$default}"
  else
    while true; do
      read -rp "  $prompt: " value
      [ -n "$value" ] && break
      echo "    (required)" >&2
    done
    echo "$value"
  fi
}

_ask_yn() {
  local prompt="$1" default="${2:-n}" value
  read -rp "  $prompt [$default]: " value
  value="${value:-$default}"
  [[ "$value" =~ ^[yY] ]] && echo "true" || echo "false"
}

# --- Parse CLI args -----------------------------------------------------------

ARG_TYPE="${1:-}"
ARG_VERSION_OR_IMAGE="${2:-}"

# Try to extract info from image tag (e.g. sso76-openshift-rhel8:7.6-73)
ARG_IMAGE=""
ARG_VERSION=""
if [[ "$ARG_VERSION_OR_IMAGE" == *":"* ]]; then
  # Looks like an image tag
  ARG_IMAGE="$ARG_VERSION_OR_IMAGE"
  # Extract version from tag (after :)
  local_tag="${ARG_VERSION_OR_IMAGE##*:}"
  ARG_VERSION="${local_tag}"
elif [[ "$ARG_VERSION_OR_IMAGE" =~ ^[0-9] ]]; then
  ARG_VERSION="$ARG_VERSION_OR_IMAGE"
fi

echo ""
echo "============================================================"
echo "  New product resolver generator"
echo "============================================================"
echo ""

# --- Required ---
echo "--- Required ---"
TYPE=$(_ask "Product type (lowercase, e.g. amq, sso, fuse)" "$ARG_TYPE")
DESCRIPTION=$(_ask "Short description (e.g. 'Red Hat AMQ Broker')")

# Image pattern: if image was given, derive the pattern
IMAGE_DEFAULT=""
if [ -n "$ARG_IMAGE" ]; then
  # If user gave full image, use it as-is but replace version with ${VERSION}
  if [[ "$ARG_IMAGE" == *"registry"* ]] || [[ "$ARG_IMAGE" == *"/"* ]]; then
    IMAGE_DEFAULT="${ARG_IMAGE%:*}:\${VERSION}"
  else
    IMAGE_DEFAULT="registry.redhat.io/${ARG_IMAGE%:*}:\${VERSION}"
  fi
fi
IMAGE_PATTERN=$(_ask "Container image pattern (use \${VERSION} for version)" "$IMAGE_DEFAULT")

# --- Detection (for auto-detect from case text) ---
echo ""
echo "--- Auto-detection (for recognizing this product in case text) ---"
GREP_DEFAULT="\\\\b${TYPE^^}\\\\b"
GREP_PATTERN=$(_ask "Grep pattern (regex, case-insensitive)" "$GREP_DEFAULT")
VERSION_PATTERN=$(_ask "Version pattern (regex to extract version)" "(${TYPE^^}) [0-9]+\\\\.[0-9]+(\\\\.[0-9]+)?")

# --- Ports ---
echo ""
echo "--- Ports (host:container, comma-separated) ---"
DEFAULT_PORTS=$(_ask "Default ports" "8080:8080,8443:8443")

# --- Health checks ---
echo ""
echo "--- Readiness & Health checks ---"
echo "  Ready log: grep pattern in container logs that means 'app started'"
echo "  Example: WFLYSRV0025.*started in"
READY_LOG=$(_ask "Ready log pattern (regex)" "started in")
echo ""
echo "  Health checks: proto:container_port:path (comma-separated)"
echo "  Example: http:8080:/,https:8443:/,http:8080:/admin/console"
HEALTH_CHECKS=$(_ask "Health check endpoints" "http:8080:/")

# --- Optional with defaults ---
echo ""
echo "--- Optional (press Enter for defaults) ---"
CONTAINER_PREFIX=$(_ask "Container name prefix" "$TYPE")
COMMAND=$(_ask "Container command (empty if default entrypoint)" "")
DEFAULT_ENVS=$(_ask "Default env vars (pipe-separated KEY=val|KEY=val)" "")

echo ""
echo "--- Database support ---"
WITH_DB=$(_ask_yn "Does this product support database?" "n")
DB_MODE="never"

DB_NAME="" DB_USER="" DB_ENVS=""
if [ "$WITH_DB" = "true" ]; then
  DB_MODE=$(_ask "DB mode (always|detect)" "always")
  DB_NAME=$(_ask "DB name" "${TYPE}_db")
  DB_USER=$(_ask "DB user" "${TYPE}")
  echo ""
  echo "  DB env vars use placeholders: __DB_HOST__, __DB_NAME__, __DB_USER__"
  echo "  These are replaced automatically in the generated compose file."
  DB_ENVS=$(_ask "DB env vars (pipe-separated)" "DB_HOST=__DB_HOST__|DB_NAME=__DB_NAME__|DB_USER=__DB_USER__|DB_PASSWORD=password")
fi

echo ""
echo "--- Build ---"
BUILD_REQUIRED=$(_ask_yn "Requires custom image build (Containerfile)?" "n")
if [ "$BUILD_REQUIRED" = "true" ]; then
  echo "  Containerfile will be named: Containerfile-${TYPE}-<version> (convention)"
fi

# --- Generate ---
TARGET="${SCRIPT_DIR}/resolve-${TYPE}.sh"

if [ -f "$TARGET" ]; then
  echo ""
  echo "  WARNING: $TARGET already exists."
  read -rp "  Overwrite? [n]: " ow
  [[ "$ow" =~ ^[yY] ]] || { echo "  Aborted."; exit 0; }
fi

cat > "$TARGET" <<RESOLVER
#!/bin/bash
# Product resolver for ${DESCRIPTION}.
#
# Called by initcaseenv.sh to resolve image and configuration.
# Output (stdout): RESOLVE_* variable assignments (sourced by caller).
# Messages (stderr): human-readable progress info.
#
# Usage: resolve-${TYPE}.sh <version> [--cached VALUE] [--env-dir DIR]
#        resolve-${TYPE}.sh --detect-info
#
# Author: Daniele Mammarella <dmammare@redhat.com>
#

set -euo pipefail

VERSION=""
CACHED=""
ENV_DIR=""

while [ \$# -gt 0 ]; do
  case "\$1" in
    --detect-info)
      cat <<'DETECT'
DETECT_GREP_PATTERN=${GREP_PATTERN}
DETECT_VERSION_PATTERN=${VERSION_PATTERN}
DETECT_DB_MODE=${DB_MODE}
DETECT_DEFAULT_PORTS=${DEFAULT_PORTS}
DETECT_READY_LOG=${READY_LOG}
DETECT_HEALTH_CHECKS=${HEALTH_CHECKS}
DETECT
      exit 0 ;;
    --cached)  CACHED="\$2"; shift 2 ;;
    --env-dir) ENV_DIR="\$2"; shift 2 ;;
    *)         VERSION="\$1"; shift ;;
  esac
done

[ -z "\$VERSION" ] && { echo "Error: version required." >&2; exit 1; }

IMAGE=""

if [ -n "\$CACHED" ]; then
  IMAGE="\$CACHED"
  echo "Using image: \$IMAGE (cached)" >&2
else
  # TODO: add resolution logic here (skopeo, curl, etc.)
  IMAGE="${IMAGE_PATTERN}"
  echo "Resolved ${DESCRIPTION} \${VERSION}: \$IMAGE" >&2
fi
RESOLVER

if [ "$BUILD_REQUIRED" = "true" ]; then
  cat >> "$TARGET" <<RESOLVER

# Generate Containerfile if env-dir provided
if [ -n "\$ENV_DIR" ]; then
  cat > "\${ENV_DIR}/Containerfile-${TYPE}-\${VERSION}" <<'CEOF'
# TODO: add Containerfile content for ${DESCRIPTION}
# FROM registry.redhat.io/...
CEOF
fi
RESOLVER
fi

if [ "$BUILD_REQUIRED" = "true" ]; then
  cat >> "$TARGET" <<RESOLVER

cat <<EOF
RESOLVE_IMAGE=\${IMAGE}
RESOLVE_CONTAINER_PREFIX=${CONTAINER_PREFIX}
RESOLVE_COMMAND=${COMMAND}
RESOLVE_DEFAULT_ENVS=${DEFAULT_ENVS}
RESOLVE_DB_NAME=${DB_NAME}
RESOLVE_DB_USER=${DB_USER}
RESOLVE_DB_ENVS=${DB_ENVS}
RESOLVE_CONTAINERFILE=Containerfile-${TYPE}-\${VERSION}
RESOLVE_CACHE_VALUE=\${IMAGE}
EOF
RESOLVER
else
  cat >> "$TARGET" <<RESOLVER

cat <<EOF
RESOLVE_IMAGE=\${IMAGE}
RESOLVE_CONTAINER_PREFIX=${CONTAINER_PREFIX}
RESOLVE_COMMAND=${COMMAND}
RESOLVE_DEFAULT_ENVS=${DEFAULT_ENVS}
RESOLVE_DB_NAME=${DB_NAME}
RESOLVE_DB_USER=${DB_USER}
RESOLVE_DB_ENVS=${DB_ENVS}
RESOLVE_CONTAINERFILE=
RESOLVE_CACHE_VALUE=\${IMAGE}
EOF
RESOLVER
fi

chmod +x "$TARGET"

echo ""
echo "============================================================"
echo "  Generated: $TARGET"
echo "============================================================"
echo ""
echo "  Next steps:"
echo "  1. Edit the resolver to add actual image resolution logic"
if [ "$BUILD_REQUIRED" = "true" ]; then
  echo "  2. Edit the Containerfile generation in the resolver"
fi
echo "  3. Test: $TARGET --detect-info"
echo "  4. Test: $TARGET ${ARG_VERSION:-<version>}"
echo ""
