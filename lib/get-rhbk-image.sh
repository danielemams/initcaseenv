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
# Given an RHBK product version (e.g. 26.4.5), returns the container image
# reference for registry.redhat.io/rhbk/keycloak-rhel9.
#
# IMPORTANT: The image tag build number (e.g. 26.4-4) does NOT match the
# product micro version (e.g. 26.4.5). This script runs `podman run --version`
# on each build to find the correct mapping.
#
# Usage:
#   ./get-rhbk-image.sh 26.4.5         Find the image for RHBK 26.4.5
#   ./get-rhbk-image.sh 26.4           Latest build of RHBK 26.4 stream
#   ./get-rhbk-image.sh --list         List all available streams
#   ./get-rhbk-image.sh --list 26.4    List builds for RHBK 26.4 with product versions
#
# Author: Daniele Mammarella <dmammare@redhat.com>

set -euo pipefail

_self="$0"
[ -L "$_self" ] && _self="$(readlink -f "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

REGISTRY="registry.redhat.io"
IMAGE="rhbk/keycloak-rhel9"
FULL_IMAGE="${REGISTRY}/${IMAGE}"

usage() {
  cat <<'EOF'
Usage: get-rhbk-image.sh [--list] [<rhbk-version>]

  rhbk-version  X.Y     → latest build of stream (floating tag, e.g. 26.4)
                X.Y.Z   → find the image containing product version X.Y.Z
                          (e.g. 26.4.5 → discovers tag 26.4-4)

  --list        Show available image tags.
                Without version → list all streams (22, 24, 26.0, 26.2, …)
                With X.Y        → list all builds with their product versions
                                  (requires podman to check each image)

Requires: skopeo, podman (for version detection)
EOF
  exit 1
}

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: $1 is required but not found in PATH" >&2
    exit 1
  fi
}

# Get the Keycloak product version from an image tag via podman
# Returns e.g. "26.4.5" from "Keycloak 26.4.5.redhat-00001"
get_product_version() {
  local tag="$1"
  podman run --rm "${FULL_IMAGE}:${tag}" --version 2>/dev/null \
    | head -1 \
    | sed -E 's/^Keycloak ([0-9]+\.[0-9]+\.[0-9]+)\.redhat.*/\1/' \
    || echo "unknown"
}

# Fetch all non-source, non-sha, non-timestamp tags sorted by version
fetch_tags() {
  require_cmd skopeo
  skopeo list-tags "docker://${FULL_IMAGE}" 2>/dev/null \
    | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
tags = [t for t in data['Tags']
        if not t.endswith('-source') and not t.startswith('sha256-')
        and not re.search(r'-\d{6,}$', t)]  # exclude timestamp builds
def sort_key(tag):
    parts = tag.replace('-', '.').split('.')
    result = []
    for p in parts:
        try:
            result.append((0, int(p)))
        except ValueError:
            result.append((1, p))
    return result
for t in sorted(tags, key=sort_key):
    print(t)
" || {
    echo "Error: cannot fetch tags from ${FULL_IMAGE}" >&2
    echo "Make sure you are logged in: podman login ${REGISTRY}" >&2
    exit 1
  }
}

# Get build tags for a stream (e.g. "26.4" → "26.4-2 26.4-3 ...")
get_build_tags() {
  local stream="$1"
  local all_tags="$2"
  local escaped
  escaped=$(printf '%s' "$stream" | sed 's/\./\\./g')
  echo "$all_tags" | grep -E -- "^${escaped}-[0-9]+$" || true
}

LIST_MODE=false
if [ "${1:-}" = "--list" ]; then
  LIST_MODE=true
  shift
fi

# --- List mode ---
if [ "$LIST_MODE" = true ]; then
  require_cmd skopeo
  ALL_TAGS=$(fetch_tags)

  if [ -z "${1:-}" ]; then
    # List all streams
    echo "Available RHBK streams (${FULL_IMAGE}):"
    echo ""
    STREAMS=$(echo "$ALL_TAGS" | grep -vE -- '-[0-9]+$')
    while IFS= read -r stream; do
      count=$(get_build_tags "$stream" "$ALL_TAGS" | wc -l)
      latest_build=$(get_build_tags "$stream" "$ALL_TAGS" | tail -1 || true)
      if [ -n "$latest_build" ]; then
        echo "  ${stream}  (${count} builds, latest: ${latest_build})"
      else
        echo "  ${stream}  (floating tag only)"
      fi
    done <<< "$STREAMS"
  else
    STREAM="$1"
    echo "Available builds for RHBK ${STREAM} (${FULL_IMAGE}):"
    echo ""

    BUILDS=$(get_build_tags "$STREAM" "$ALL_TAGS")
    HAS_FLOATING=$(echo "$ALL_TAGS" | grep -xF -- "$STREAM" || true)

    if [ -z "$BUILDS" ] && [ -z "$HAS_FLOATING" ]; then
      echo "  Error: stream ${STREAM} not found." >&2
      echo "" >&2
      echo "Available streams:" >&2
      echo "$ALL_TAGS" | grep -vE -- '-[0-9]+$' | sed 's/^/  /' >&2
      exit 1
    fi

    if [ -n "$HAS_FLOATING" ]; then
      echo "  ${STREAM}  (floating, always latest)"
    fi

    # Show builds with product versions (requires podman)
    if [ -n "$BUILDS" ]; then
      require_cmd podman
      echo ""
      echo "  TAG                  PRODUCT VERSION"
      echo "  ---                  ---------------"
      while IFS= read -r tag; do
        pv=$(get_product_version "$tag")
        printf "  %-20s %s\n" "${tag}" "${pv}"
      done <<< "$BUILDS"
    fi
  fi
  exit 0
fi

_get_build_date() {
  # Extract build-date label from a container image tag via skopeo.
  skopeo inspect "docker://${FULL_IMAGE}:${1}" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Labels',{}).get('build-date','unknown'))" 2>/dev/null || echo "unknown"
}

# --- Resolve mode ---
[ -z "${1:-}" ] && usage

INPUT="$1"

# Parse version components
IFS='.' read -r v1 v2 v3 <<< "$INPUT"

if [ -z "$v1" ]; then
  usage
fi

require_cmd skopeo

# Single component (e.g. "22") → floating tag
if [ -z "${v2:-}" ]; then
  TAG="${v1}"
  if skopeo inspect "docker://${FULL_IMAGE}:${TAG}" &>/dev/null; then
    BUILD_DATE=$(_get_build_date "$TAG")
    echo "# RHBK ${v1} (latest) (built ${BUILD_DATE})"
    echo "${FULL_IMAGE}:${TAG}"
    exit 0
  else
    echo "Error: stream ${v1} not found for ${FULL_IMAGE}" >&2
    echo "Run with --list to see available streams." >&2
    exit 1
  fi
fi

# Two components (e.g. "26.4") → try as floating tag, fall back to old-style (22-10)
if [ -z "${v3:-}" ]; then
  STREAM="${v1}.${v2}"
  if skopeo inspect "docker://${FULL_IMAGE}:${STREAM}" &>/dev/null; then
    BUILD_DATE=$(_get_build_date "$STREAM")
    echo "# RHBK ${STREAM} (latest) (built ${BUILD_DATE})"
    echo "${FULL_IMAGE}:${STREAM}"
    exit 0
  else
    # Fall back: maybe it's old-style stream (e.g. 22.10 → 22-10)
    FALLBACK_TAG="${v1}-${v2}"
    if skopeo inspect "docker://${FULL_IMAGE}:${FALLBACK_TAG}" &>/dev/null; then
      BUILD_DATE=$(_get_build_date "$FALLBACK_TAG")
      echo "# RHBK ${v1} build ${v2} (built ${BUILD_DATE})"
      echo "${FULL_IMAGE}:${FALLBACK_TAG}"
      exit 0
    fi
    echo "Error: stream ${STREAM} not found for ${FULL_IMAGE}" >&2
    echo "Run with --list to see available streams." >&2
    exit 1
  fi
fi

# Three components (e.g. "26.4.5") → find the image containing this product version
STREAM="${v1}.${v2}"
TARGET_VERSION="${v1}.${v2}.${v3}"

require_cmd podman

echo "Looking for RHBK ${TARGET_VERSION} in stream ${STREAM}..." >&2

ALL_TAGS=$(fetch_tags)
BUILDS=$(get_build_tags "$STREAM" "$ALL_TAGS")

if [ -z "$BUILDS" ]; then
  echo "Error: stream ${STREAM} not found." >&2
  echo "" >&2
  echo "Available streams:" >&2
  ALL_TAGS=$(fetch_tags)
  echo "$ALL_TAGS" | grep -vE -- '-[0-9]+$' | sed 's/^/  /' >&2
  exit 1
fi

# Check each build to find the matching product version
FOUND_TAG=""
while IFS= read -r tag; do
  pv=$(get_product_version "$tag")
  echo "  checking ${tag} → ${pv}" >&2
  if [ "$pv" = "$TARGET_VERSION" ]; then
    FOUND_TAG="$tag"
    break
  fi
done <<< "$BUILDS"

if [ -z "$FOUND_TAG" ]; then
  echo "" >&2
  echo "Error: RHBK ${TARGET_VERSION} not found in any ${STREAM} build." >&2
  echo "" >&2
  echo "Use --list ${STREAM} to see all builds and their product versions." >&2
  exit 1
fi

BUILD_DATE=$(_get_build_date "$FOUND_TAG")

echo "# RHBK ${TARGET_VERSION} (built ${BUILD_DATE})"
echo "${FULL_IMAGE}:${FOUND_TAG}"
