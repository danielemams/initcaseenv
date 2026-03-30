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
# Product resolver for Red Hat Enterprise Application Platform (JBoss EAP).
#
# Called by initcaseenv.sh to resolve image and configuration.
# Output (stdout): RESOLVE_* variable assignments (sourced by caller).
# Messages (stderr): human-readable progress info.
#
# Supports EAP 8.x (Galleon channel, local image build) and
# EAP 7.x (pre-built registry image, no build needed).
#
# Usage: resolve-red-hat-enterprise-application-platform.sh <version> [--cached VALUE] [--env-dir DIR]
#        resolve-red-hat-enterprise-application-platform.sh --detect-info
#
# Author: Daniele Mammarella <dmammare@redhat.com>

set -euo pipefail

_self="$0"
[ -L "$_self" ] && _self="$(readlink -f "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

VERSION=""
CACHED=""
ENV_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --detect-info)
      cat <<'DETECT'
DETECT_GREP_PATTERN=\bEAP\b|JBoss EAP|Enterprise Application Platform|standalone[.-]xml|jboss-cli
DETECT_VERSION_PATTERN=(EAP|JBoss EAP) [0-9]+\.[0-9]+(\.[0-9]+)*
DETECT_DB_MODE=detect
DETECT_DEFAULT_PORTS=8080:8080,8443:8443,9990:9990
DETECT_READY_LOG=WFLYSRV0025.*started in
DETECT_HEALTH_CHECKS=http:8080:/
DETECT
      exit 0 ;;
    --cached)  CACHED="$2"; shift 2 ;;
    --env-dir) ENV_DIR="$2"; shift 2 ;;
    *)         VERSION="$1"; shift ;;
  esac
done

[ -z "$VERSION" ] && { echo "Error: version required." >&2; exit 1; }

IFS='.' read -r EAP_MAJOR EAP_MINOR _ <<< "$VERSION"

_resolve_channel() {
  local label="$1" fatal="$2"
  if [ -n "$CACHED" ]; then
    CHANNEL_ENV_LINE="$CACHED"
    return 0
  fi
  echo "Resolving EAP ${label} for version ${VERSION}..." >&2
  local channel_output
  if channel_output="$("${SCRIPT_DIR}/get-eap-channel.sh" "$VERSION")"; then
    CHANNEL_ENV_LINE=$(echo "$channel_output" | grep -v '^#' | tail -1)
    local resolved_info
    resolved_info=$(echo "$channel_output" | grep '^#' | head -1)
    echo "Found: ${resolved_info#\# }" >&2
  else
    if [ "$fatal" = true ]; then
      echo "ERROR: could not resolve EAP ${label}." >&2
      exit 1
    else
      echo "WARNING: could not resolve EAP ${label} info." >&2
    fi
  fi
}

IMAGE=""
CHANNEL_ENV_LINE=""
CONTAINERFILE_NAME=""

if [ "$EAP_MAJOR" = "7" ]; then
  IMAGE="registry.redhat.io/jboss-eap-7/eap7${EAP_MINOR}-openjdk11-openshift-rhel8:latest"
  _resolve_channel "feature-pack" false
  echo "Using image: $IMAGE (pre-built, no build needed)" >&2
else
  IMAGE="localhost/eap-${VERSION}"
  CONTAINERFILE_NAME="Containerfile-eap-${VERSION}"
  _resolve_channel "channel" true

  if [ -n "$ENV_DIR" ]; then
    cat > "${ENV_DIR}/${CONTAINERFILE_NAME}" <<'CEOF'
FROM registry.redhat.io/jboss-eap-8/eap81-openjdk21-builder-openshift-rhel9:latest AS builder

ENV GALLEON_PROVISION_FEATURE_PACKS org.jboss.eap:wildfly-ee-galleon-pack,org.jboss.eap.cloud:eap-cloud-galleon-pack
ENV GALLEON_PROVISION_LAYERS cloud-default-config
CEOF
    echo "${CHANNEL_ENV_LINE}" >> "${ENV_DIR}/${CONTAINERFILE_NAME}"
    cat >> "${ENV_DIR}/${CONTAINERFILE_NAME}" <<'CEOF'

RUN /usr/local/s2i/assemble

FROM registry.redhat.io/jboss-eap-8/eap81-openjdk21-runtime-openshift-rhel9:latest AS runtime

COPY --from=builder --chown=jboss:root $JBOSS_HOME $JBOSS_HOME

RUN chmod -R ug+rwX $JBOSS_HOME
CEOF
  fi
fi

cat <<EOF
RESOLVE_IMAGE=${IMAGE}
RESOLVE_CONTAINER_PREFIX=jbosseap
RESOLVE_COMMAND=
RESOLVE_DEFAULT_ENVS=CONFIG_IS_FINAL=true
RESOLVE_DB_NAME=eap
RESOLVE_DB_USER=eap
RESOLVE_DB_ENVS=CONFIG_IS_FINAL=true|DB_SERVICE_PREFIX_MAPPING=postgres-eap=DB|DB_DRIVER=postgresql|DB_DATABASE=__DB_NAME__|DB_USERNAME=__DB_USER__|DB_PASSWORD=password|DB_JNDI=java:jboss/datasources/PostgreSQLDS|DB_NONXA=true|TX_DATABASE_PREFIX_MAPPING=postgres-eap=DB|POSTGRESQL_SERVICE_HOST=__DB_HOST__|POSTGRESQL_SERVICE_PORT=5432
RESOLVE_CONTAINERFILE=${CONTAINERFILE_NAME}
RESOLVE_CACHE_VALUE=${CHANNEL_ENV_LINE}
EOF
