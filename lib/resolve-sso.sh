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
# Product resolver for Red Hat Single Sign-On (RHSSO / Keycloak 7.x).
#
# Called by initcaseenv.sh to resolve image and configuration.
# Output (stdout): RESOLVE_* variable assignments (sourced by caller).
# Messages (stderr): human-readable progress info.
#
# Usage: resolve-sso.sh <version> [--cached VALUE] [--env-dir DIR]
#        resolve-sso.sh --detect-info
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
DETECT_GREP_PATTERN=\bRHSSO\b|\bSSO\b|Red Hat Single Sign-On|sso7[0-9]|RH-SSO
DETECT_VERSION_PATTERN=(RHSSO|RH-SSO|SSO) [0-9]+\.[0-9]+(\.[0-9]+)*
DETECT_DB_MODE=always
DETECT_DEFAULT_PORTS=8080:8080,8443:8443
DETECT_READY_LOG=WFLYSRV0025.*started in
DETECT_HEALTH_CHECKS=http:8080:/auth
DETECT
      exit 0 ;;
    --cached)  CACHED="$2"; shift 2 ;;
    --env-dir) shift 2 ;;
    *)         VERSION="$1"; shift ;;
  esac
done

[ -z "$VERSION" ] && { echo "Error: version required." >&2; exit 1; }

# RHSSO image path depends on version: rh-sso-7/sso76-openshift-rhel8
IFS='.' read -r v_major v_minor _ <<< "$VERSION"
SSO_TAG="sso${v_major}${v_minor}"
BASE_IMAGE="registry.redhat.io/rh-sso-7/${SSO_TAG}-openshift-rhel8"

IMAGE=""

if [ -n "$CACHED" ]; then
  IMAGE="$CACHED"
  echo "Using image: $IMAGE (cached)" >&2
else
  echo "Resolving RHSSO image for version ${VERSION}..." >&2
  # Live resolution via skopeo. SSO tags follow stream format (e.g., 7.6, 7.6-73).
  # No version-cmd needed: tag = stream version.
  IMAGE=$(_resolve_image "$BASE_IMAGE" "$VERSION") \
    || { echo "ERROR: could not resolve RHSSO image." >&2; exit 1; }
  echo "Using image: $IMAGE" >&2
fi

cat <<EOF
RESOLVE_IMAGE=${IMAGE}
RESOLVE_CONTAINER_PREFIX=sso
RESOLVE_COMMAND=
RESOLVE_DEFAULT_ENVS=SSO_ADMIN_USERNAME=admin|SSO_ADMIN_PASSWORD=admin|SSO_FORCE_HTTPS=false|SSO_PROXY_HTTPS=false
RESOLVE_DB_NAME=sso
RESOLVE_DB_USER=sso
RESOLVE_DB_ENVS=DB_SERVICE_PREFIX_MAPPING=sso-postgresql=DB|DB_JNDI=java:jboss/datasources/KeycloakDS|DB_USERNAME=__DB_USER__|DB_PASSWORD=password|DB_DATABASE=__DB_NAME__|TX_DATABASE_PREFIX_MAPPING=sso-postgresql=DB|POSTGRESQL_SERVICE_HOST=__DB_HOST__|POSTGRESQL_SERVICE_PORT=5432|SSO_ADMIN_USERNAME=admin|SSO_ADMIN_PASSWORD=admin|SSO_FORCE_HTTPS=false|SSO_PROXY_HTTPS=false
RESOLVE_CONTAINERFILE=
RESOLVE_POST_START_CMD=/opt/eap/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user admin --password admin && /opt/eap/bin/kcadm.sh update realms/master -s sslRequired=NONE --server http://localhost:8080/auth --realm master
RESOLVE_CACHE_VALUE=${IMAGE}
EOF
