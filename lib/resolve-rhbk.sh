#!/bin/bash
# Product resolver for Red Hat build of Keycloak (RHBK).
#
# Called by initcaseenv.sh to resolve image and configuration.
# Output (stdout): RESOLVE_* variable assignments (sourced by caller).
# Messages (stderr): human-readable progress info.
#
# Usage: resolve-rhbk.sh <version> [--cached VALUE] [--env-dir DIR]
#        resolve-rhbk.sh --detect-info
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
DETECT_GREP_PATTERN=\bKeycloak\b|\bRHBK\b|Red Hat build of Keycloak|kcadm
DETECT_VERSION_PATTERN=(Keycloak|RHBK) [0-9]+\.[0-9]+(\.[0-9]+)?
DETECT_DB_MODE=always
DETECT_DEFAULT_PORTS=8080:8080,8443:8443
DETECT_READY_LOG=Listening on: http://
DETECT_HEALTH_CHECKS=http:8080:/realms/master
DETECT
      exit 0 ;;
    --cached)  CACHED="$2"; shift 2 ;;
    --env-dir) shift 2 ;;  # not used by RHBK (no build needed)
    *)         VERSION="$1"; shift ;;
  esac
done

[ -z "$VERSION" ] && { echo "Error: version required." >&2; exit 1; }

IMAGE=""

if [ -n "$CACHED" ]; then
  IMAGE="$CACHED"
  echo "Using image: $IMAGE (cached)" >&2
else
  echo "Resolving RHBK image for version ${VERSION}..." >&2
  image_output=$("${SCRIPT_DIR}/get-rhbk-image.sh" "$VERSION") \
    || { echo "ERROR: could not resolve RHBK image." >&2; exit 1; }
  IMAGE=$(echo "$image_output" | grep -v '^#' | tail -1)
  echo "Found image version: ${IMAGE##*/}" >&2
  echo "Using image: $IMAGE" >&2
fi

cat <<EOF
RESOLVE_IMAGE=${IMAGE}
RESOLVE_CONTAINER_PREFIX=rhbk
RESOLVE_COMMAND=start-dev
RESOLVE_DEFAULT_ENVS=KC_BOOTSTRAP_ADMIN_USERNAME=admin|KC_BOOTSTRAP_ADMIN_PASSWORD=admin|KC_HTTP_ENABLED=true|KC_HOSTNAME_STRICT=false
RESOLVE_DB_NAME=keycloak
RESOLVE_DB_USER=keycloak
RESOLVE_DB_ENVS=KC_DB=postgres|KC_DB_URL=jdbc:postgresql://__DB_HOST__:5432/__DB_NAME__|KC_DB_USERNAME=__DB_USER__|KC_DB_PASSWORD=password|KC_BOOTSTRAP_ADMIN_USERNAME=admin|KC_BOOTSTRAP_ADMIN_PASSWORD=admin|KC_HTTP_ENABLED=true|KC_HOSTNAME_STRICT=false
RESOLVE_CONTAINERFILE=
RESOLVE_POST_START_CMD=/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password admin && /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE --server http://localhost:8080 --realm master
RESOLVE_CACHE_VALUE=${IMAGE}
EOF
