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
# Given an EAP version, returns the appropriate Galleon ENV line(s)
# for a Containerfile.
#
# Supports EAP 8.x (Galleon channels) and EAP 7.x (feature packs).
#
# Usage:
#   ./get-eap-channel.sh 8.1.1         EAP 8.1 Update 1 (latest patch)
#   ./get-eap-channel.sh 8.0.1.1       EAP 8.0 Update 1, Patch 1 (exact)
#   ./get-eap-channel.sh 8.0.1.0       EAP 8.0 Update 1, base (no patch)
#   ./get-eap-channel.sh 7.4.21        EAP 7.4 Update 21
#   ./get-eap-channel.sh --list 8.0    List all updates & patches for EAP 8.0
#   ./get-eap-channel.sh --list 8.1.0  List patches for EAP 8.1 GA
#   ./get-eap-channel.sh --list 7.4    List all updates for EAP 7.4
#
# Author: Daniele Mammarella <dmammare@redhat.com>

set -euo pipefail

_self="$0"
[ -L "$_self" ] && _self="$(readlink -f "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-eap-channel.sh [--list] <eap-version>

  eap-version   X.Y.Z     → latest patch of Update Z  (e.g. 8.1.1, 7.4.21)
                X.Y.Z.P   → exact Patch P of Update Z (EAP 8.x only, e.g. 8.0.1.1)
                            Use P=0 for the base update with no patch.

  --list        Show all available versions instead of the ENV line.
                With X.Y   → list all updates & patches (e.g. --list 8.0, --list 7.4)
                With X.Y.Z → list patches for that update (e.g. --list 8.0.1)
EOF
  exit 1
}

LIST_MODE=false
if [ "${1:-}" = "--list" ]; then
  LIST_MODE=true
  shift
fi

[ -z "${1:-}" ] && usage

INPUT="$1"

# Parse version components
IFS='.' read -r major minor update patch <<< "$INPUT"

if [ -z "$major" ] || [ -z "$minor" ]; then
  echo "Error: version must be at least X.Y (e.g. 8.1, 7.4)" >&2
  exit 1
fi

# ============================================================
# EAP 7.x — feature pack based (no Galleon channels)
# ============================================================
if [ "$major" = "7" ]; then

  MAVEN_BASE="https://maven.repository.redhat.com/ga/org/jboss/eap/wildfly-ee-galleon-pack"

  METADATA=$(curl -sf "${MAVEN_BASE}/maven-metadata.xml" 2>/dev/null) || {
    echo "Error: cannot fetch feature-pack metadata" >&2
    echo "URL: ${MAVEN_BASE}/maven-metadata.xml" >&2
    exit 1
  }

  # Extract 7.<minor>.* versions
  ALL_VERSIONS=$(echo "$METADATA" \
    | sed -n "s/.*<version>\(${major}\.${minor}\.[0-9]*\.GA-redhat-[0-9]*\)<\/version>.*/\1/p" \
    | sort -V)

  if [ -z "$ALL_VERSIONS" ]; then
    echo "Error: no feature-pack versions found for EAP ${major}.${minor}" >&2
    exit 1
  fi

  # --- List mode (EAP 7) ---
  if [ "$LIST_MODE" = true ]; then
    echo "Available feature-pack versions for EAP ${major}.${minor}:"
    echo ""

    if [ -z "${update:-}" ]; then
      # List all updates
      while IFS= read -r ver; do
        u=$(echo "$ver" | sed -E "s/^${major}\.${minor}\.([0-9]+)\..*/\1/")
        if [ "$u" = "0" ]; then
          echo "  EAP ${major}.${minor}.${u} (GA)  → $ver"
        else
          echo "  EAP ${major}.${minor}.${u}       → $ver"
        fi
      done <<< "$ALL_VERSIONS"
    else
      # List builds for a specific update
      FILTERED=$(echo "$ALL_VERSIONS" | grep -E "^${major}\.${minor}\.${update}\.GA-redhat-" || true)
      if [ -z "$FILTERED" ]; then
        echo "  No versions found for EAP ${major}.${minor}.${update}." >&2
        echo "" >&2
        echo "Available updates:" >&2
        echo "$ALL_VERSIONS" | sed -E "s/^${major}\.${minor}\.([0-9]+)\..*/  \1/" | sort -un >&2
        exit 1
      fi
      while IFS= read -r ver; do
        echo "  EAP ${major}.${minor}.${update}  → $ver"
      done <<< "$FILTERED"
    fi
    exit 0
  fi

  # --- Resolve mode (EAP 7) ---
  if [ -z "${update:-}" ]; then
    echo "Error: version must be at least X.Y.Z (e.g. 7.4.21)" >&2
    usage
  fi

  if [ -n "${patch:-}" ]; then
    echo "Error: EAP 7.x does not support patch-level versions (X.Y.Z.P)." >&2
    echo "Use X.Y.Z format instead (e.g. 7.4.21)." >&2
    exit 1
  fi

  FP_VERSION=$(echo "$ALL_VERSIONS" \
    | grep -E "^${major}\.${minor}\.${update}\.GA-redhat-" \
    | sort -V | tail -1 || true)

  if [ -z "$FP_VERSION" ]; then
    echo "Error: no feature-pack found for EAP ${major}.${minor}.${update}" >&2
    echo "" >&2
    echo "Available updates:" >&2
    echo "$ALL_VERSIONS" | sed -E "s/^${major}\.${minor}\.([0-9]+)\..*/  \1/" | sort -un >&2
    exit 1
  fi

  if [ "$update" = "0" ]; then
    LABEL="EAP ${major}.${minor} GA"
  else
    LABEL="EAP ${major}.${minor} Update ${update}"
  fi

  echo "# ${LABEL} (feature-pack ${FP_VERSION})"
  echo "ENV GALLEON_PROVISION_FEATURE_PACKS=\"org.jboss.eap:wildfly-ee-galleon-pack:${FP_VERSION},org.jboss.eap.cloud:eap-cloud-galleon-pack\""
  exit 0
fi

# ============================================================
# EAP 8.x — Galleon channel based
# ============================================================
CHANNEL_ARTIFACT="eap-${major}.${minor}"
MAVEN_BASE="https://maven.repository.redhat.com/ga/org/jboss/eap/channels/${CHANNEL_ARTIFACT}"

# Fetch channel versions from Maven metadata
METADATA=$(curl -sf "${MAVEN_BASE}/maven-metadata.xml" 2>/dev/null) || {
  echo "Error: cannot fetch metadata for channel ${CHANNEL_ARTIFACT}" >&2
  echo "URL: ${MAVEN_BASE}/maven-metadata.xml" >&2
  exit 1
}

# Extract all versions
ALL_VERSIONS=$(echo "$METADATA" \
  | sed -n 's/.*<version>\(1\.[0-9]*\.[0-9]*\.GA-redhat-[0-9]*\)<\/version>.*/\1/p' \
  | sort -V)

if [ -z "$ALL_VERSIONS" ]; then
  echo "Error: no channel versions found for ${CHANNEL_ARTIFACT}" >&2
  exit 1
fi

# --- List mode (EAP 8) ---
if [ "$LIST_MODE" = true ]; then
  echo "Available channels for EAP ${major}.${minor}:"
  echo ""

  if [ -z "${update:-}" ]; then
    # List everything, grouped by update
    prev_update=""
    while IFS= read -r ver; do
      u=$(echo "$ver" | sed -E 's/^1\.([0-9]+)\..*/\1/')
      p=$(echo "$ver" | sed -E 's/^1\.[0-9]+\.([0-9]+)\..*/\1/')
      if [ "$u" != "$prev_update" ]; then
        [ -n "$prev_update" ] && echo ""
        if [ "$u" = "0" ]; then
          echo "  EAP ${major}.${minor} GA (${major}.${minor}.0):"
        else
          echo "  EAP ${major}.${minor} Update ${u} (${major}.${minor}.${u}):"
        fi
        prev_update="$u"
      fi
      if [ "$p" = "0" ]; then
        echo "    base     → $ver"
      else
        echo "    patch $p  → $ver"
      fi
    done <<< "$ALL_VERSIONS"
  else
    # List patches for a specific update
    FILTERED=$(echo "$ALL_VERSIONS" | grep -E "^1\.${update}\.[0-9]+\.GA-redhat-" || true)
    if [ -z "$FILTERED" ]; then
      echo "  No channels found for Update ${update}." >&2
      echo "" >&2
      echo "Available updates:" >&2
      echo "$ALL_VERSIONS" | sed -E 's/^1\.([0-9]+)\..*/  \1/' | sort -un >&2
      exit 1
    fi
    if [ "$update" = "0" ]; then
      echo "  EAP ${major}.${minor} GA (${major}.${minor}.0):"
    else
      echo "  EAP ${major}.${minor} Update ${update} (${major}.${minor}.${update}):"
    fi
    while IFS= read -r ver; do
      p=$(echo "$ver" | sed -E 's/^1\.[0-9]+\.([0-9]+)\..*/\1/')
      if [ "$p" = "0" ]; then
        echo "    base     → $ver"
      else
        echo "    patch $p  → $ver"
      fi
    done <<< "$FILTERED"
  fi
  exit 0
fi

# --- Resolve mode (EAP 8) ---
if [ -z "${update:-}" ]; then
  echo "Error: version must be at least X.Y.Z (e.g. 8.1.1)" >&2
  usage
fi

if [ -n "${patch:-}" ]; then
  # Exact patch requested: match 1.<update>.<patch>.GA-redhat-*
  CHANNEL_VERSION=$(echo "$ALL_VERSIONS" \
    | grep -E "^1\.${update}\.${patch}\.GA-redhat-" \
    | sort -V | tail -1 || true)

  if [ -z "$CHANNEL_VERSION" ]; then
    echo "Error: no channel found for EAP ${major}.${minor} Update ${update} Patch ${patch}" >&2
    echo "" >&2
    echo "Available for Update ${update}:" >&2
    AVAIL=$(echo "$ALL_VERSIONS" | grep -E "^1\.${update}\.[0-9]+\.GA-redhat-" || true)
    if [ -n "$AVAIL" ]; then
      while IFS= read -r ver; do
        p=$(echo "$ver" | sed -E 's/^1\.[0-9]+\.([0-9]+)\..*/\1/')
        echo "  ${major}.${minor}.${update}.${p}  → $ver" >&2
      done <<< "$AVAIL"
    else
      echo "  (none — Update ${update} does not exist)" >&2
      echo "" >&2
      echo "Available updates:" >&2
      echo "$ALL_VERSIONS" | sed -E 's/^1\.([0-9]+)\..*/  \1/' | sort -un >&2
    fi
    exit 1
  fi

  if [ "$update" = "0" ]; then
    UPDATE_LABEL="EAP ${major}.${minor} GA"
  else
    UPDATE_LABEL="EAP ${major}.${minor} Update ${update}"
  fi
  if [ "$patch" = "0" ]; then
    LABEL="$UPDATE_LABEL"
  else
    LABEL="${UPDATE_LABEL} Patch ${patch}"
  fi
else
  # No patch specified: latest within the update (including async patches)
  CHANNEL_VERSION=$(echo "$ALL_VERSIONS" \
    | grep -E "^1\.${update}\.[0-9]+\.GA-redhat-" \
    | sort -V | tail -1 || true)

  if [ -z "$CHANNEL_VERSION" ]; then
    echo "Error: no channel found for EAP ${major}.${minor} Update ${update}" >&2
    echo "" >&2
    echo "Available updates:" >&2
    echo "$ALL_VERSIONS" | sed -E 's/^1\.([0-9]+)\..*/  \1/' | sort -un >&2
    exit 1
  fi

  if [ "$update" = "0" ]; then
    UPDATE_LABEL="EAP ${major}.${minor} GA"
  else
    UPDATE_LABEL="EAP ${major}.${minor} Update ${update}"
  fi
  # Check if we resolved to an async patch
  RESOLVED_PATCH=$(echo "$CHANNEL_VERSION" | sed -E 's/^1\.[0-9]+\.([0-9]+)\..*/\1/')
  if [ "$RESOLVED_PATCH" != "0" ]; then
    LABEL="${UPDATE_LABEL} Patch ${RESOLVED_PATCH} (latest)"
  else
    LABEL="$UPDATE_LABEL"
  fi
fi

echo "# ${LABEL} (channel ${CHANNEL_VERSION})"
echo "ENV GALLEON_PROVISION_CHANNELS=\"org.jboss.eap.channels:${CHANNEL_ARTIFACT}:${CHANNEL_VERSION}\""
