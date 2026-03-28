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
# Shared image resolution functions for product resolvers.
# Source this from resolve-*.sh scripts.
#
# Provides _resolve_image() — generic image tag discovery via skopeo.
# Fast path: tries common tag patterns (skopeo inspect, no container pull).
# Slow path: cycles through build tags and checks product version via podman.
#
# Author: Daniele Mammarella <dmammare@redhat.com>

# Check if image:tag exists in registry via skopeo inspect.
_image_exists() {
  command -v skopeo &>/dev/null || return 1
  skopeo inspect "docker://$1" &>/dev/null
}

# Fetch all tags for an image (filtered, sorted by version).
# Excludes -source, sha256-, and timestamp-build tags.
_fetch_all_tags() {
  local image="$1"
  command -v skopeo &>/dev/null || { echo "Error: skopeo required for tag listing" >&2; return 1; }
  skopeo list-tags "docker://${image}" 2>/dev/null \
    | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
tags = [t for t in data['Tags']
        if not t.endswith('-source') and not t.startswith('sha256-')
        and not re.search(r'-\d{6,}$', t)]
def sort_key(tag):
    parts = tag.replace('-', '.').split('.')
    result = []
    for p in parts:
        try: result.append((0, int(p)))
        except ValueError: result.append((1, p))
    return result
for t in sorted(tags, key=sort_key):
    print(t)
" 2>/dev/null || {
    echo "Error: cannot fetch tags from ${image}" >&2
    echo "Make sure you are logged in: podman login ${image%%/*}" >&2
    return 1
  }
}

# Get build tags for a stream (e.g., "26.4" -> "26.4-2 26.4-3 ...").
_stream_build_tags() {
  local stream="$1" all_tags="$2"
  local escaped
  escaped=$(printf '%s' "$stream" | sed 's/\./\\./g')
  echo "$all_tags" | grep -E "^${escaped}-[0-9]+$" || true
}

# Get product version from inside a container image.
# Runs version_cmd, extracts version number from output.
_get_container_version() {
  local image="$1" cmd="$2" regex="$3"
  local output
  # shellcheck disable=SC2086
  output=$(podman run --rm "$image" $cmd 2>/dev/null | head -1) || { echo "unknown"; return; }
  echo "$output" | grep -oE "$regex" | head -1 || echo "unknown"
}

# Resolve image by version with skopeo discovery fallback.
#
# Usage: _resolve_image <base-image> <version> [<version-cmd>] [<version-regex>]
#
# Arguments:
#   base-image     Full image path without tag (e.g., registry.redhat.io/rhbk/keycloak-rhel9)
#   version        Requested version (X, X.Y, X.Y.Z, X.Y.Z.P, ...)
#   version-cmd    Optional command to run inside container to extract version (e.g., "--version")
#   version-regex  Optional grep -oE regex to extract version from command output
#                  Default: [0-9]+\.[0-9]+(\.[0-9]+)*
#
# Output (stdout): image reference (e.g., registry.redhat.io/rhbk/keycloak-rhel9:26.4-4)
# Messages (stderr): human-readable progress info
#
# Resolution order:
#   1. Try exact version as tag (X.Y.Z)
#   2. Try stream-build format (X.Y-Z)
#   3. If version-cmd provided: cycle build tags, check product version via podman
#   4. Fallback: floating stream tag (X.Y) with warning
_resolve_image() {
  local base_image="$1" version="$2"
  local version_cmd="${3:-}" version_regex="${4:-[0-9]+\.[0-9]+(\.[0-9]+)*}"

  local _v1 _v2 _v3 _vrest
  IFS='.' read -r _v1 _v2 _v3 _vrest <<< "$version"

  if [ -z "$_v1" ]; then
    echo "Error: empty version" >&2
    return 1
  fi

  # Single component (e.g., "22") -> floating tag
  if [ -z "${_v2:-}" ]; then
    if _image_exists "${base_image}:${_v1}"; then
      echo "Using floating tag: ${_v1}" >&2
      echo "${base_image}:${_v1}"
      return 0
    fi
    echo "Error: tag ${_v1} not found for ${base_image}" >&2
    return 1
  fi

  local stream="${_v1}.${_v2}"

  # Stream-only (X.Y): use floating tag
  if [ -z "${_v3:-}" ]; then
    if _image_exists "${base_image}:${stream}"; then
      echo "Using floating tag: ${stream}" >&2
      echo "${base_image}:${stream}"
      return 0
    fi
    # Try alternative: X-Y (old-style tags)
    if _image_exists "${base_image}:${_v1}-${_v2}"; then
      echo "Using tag: ${_v1}-${_v2}" >&2
      echo "${base_image}:${_v1}-${_v2}"
      return 0
    fi
    echo "Error: stream ${stream} not found for ${base_image}" >&2
    return 1
  fi

  # Exact version (X.Y.Z+): try direct tag patterns first (fast, no pull)
  local target_version="${version}"

  # 1. Try exact version as tag (e.g., 26.4.5 or 7.6.3)
  if _image_exists "${base_image}:${version}"; then
    echo "Found exact tag: ${version}" >&2
    echo "${base_image}:${version}"
    return 0
  fi

  # 2. Try stream-patch format: X.Y-Z (e.g., 26.4-5, 7.6-73)
  if _image_exists "${base_image}:${stream}-${_v3}"; then
    # If we have version_cmd, verify the product version matches
    if [ -n "$version_cmd" ] && command -v podman &>/dev/null; then
      local pv
      pv=$(_get_container_version "${base_image}:${stream}-${_v3}" "$version_cmd" "$version_regex")
      if [ "$pv" = "$target_version" ]; then
        echo "Found tag: ${stream}-${_v3} (product version ${pv} verified)" >&2
        echo "${base_image}:${stream}-${_v3}"
        return 0
      fi
      echo "  tag ${stream}-${_v3} contains version ${pv}, not ${target_version}" >&2
    else
      echo "Found tag: ${stream}-${_v3}" >&2
      echo "${base_image}:${stream}-${_v3}"
      return 0
    fi
  fi

  # 3. Slow path: cycle through stream build tags and check product version
  if [ -n "$version_cmd" ] && command -v podman &>/dev/null && command -v skopeo &>/dev/null; then
    echo "Searching ${base_image} tags for version ${target_version}..." >&2
    local all_tags
    all_tags=$(_fetch_all_tags "$base_image") || return 1
    local builds
    builds=$(_stream_build_tags "$stream" "$all_tags")

    if [ -n "$builds" ]; then
      while IFS= read -r tag; do
        local pv
        pv=$(_get_container_version "${base_image}:${tag}" "$version_cmd" "$version_regex")
        echo "  checking ${tag} -> ${pv}" >&2
        if [ "$pv" = "$target_version" ]; then
          echo "Found: ${tag} = version ${target_version}" >&2
          echo "${base_image}:${tag}"
          return 0
        fi
      done <<< "$builds"
    fi
  fi

  # 4. Last resort: floating stream tag with warning
  if _image_exists "${base_image}:${stream}"; then
    echo "Warning: exact version ${target_version} not found, using stream ${stream}" >&2
    echo "${base_image}:${stream}"
    return 0
  fi

  echo "Error: cannot resolve image for ${base_image} version ${version}" >&2
  echo "Make sure you are logged in: podman login ${base_image%%/*}" >&2
  return 1
}
