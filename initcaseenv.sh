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
# Initialize and manage containerized case environments with podman.
#
# Product resolution is handled by plug-in resolver scripts in lib/:
# lib/resolve-<type>.sh    (e.g. resolve-rhbk.sh, resolve-eap.sh)
# Adding a new product type only requires creating a new resolver script.
#
# Resolved images/channels are cached in $CASES_DIR/.resolved-images
# so that repeated starts for the same product version skip resolution.
#
# All containers run via podman-compose, even single-product setups.
# The docker-compose.yml in initcaseenv-data/ is the source of truth.
#
# Flows:
# script <CASEID> setup [-t -v [-d] [-e K=V] [-p H:C]]  Add service (no start)
# script <CASEID> start [-t -v [-d] [-e K=V] [-p H:C]]  Add service + start all
# script <CASEID> setup -m FILE                          Add services from JSON (no start)
# script <CASEID> start -m FILE                          Add services from JSON + start all
# script <CASEID> exec    CONTAINER CMD [ARG...]           Run command inside container
# script <CASEID> stop    [CONTAINER...]                  Stop containers
# script <CASEID> restart [CONTAINER...]                  Restart containers
# script <CASEID> rm      [CONTAINER...] [--all]         Remove containers or everything
# script <CASEID> status  [CONTAINER...]                  Show status
# script <CASEID> logs    [CONTAINER...]                  Show container logs
# script <CASEID> healthcheck [CONTAINER...]              Run health checks
#
# Author: Daniele Mammarella <dmammare@redhat.com>
#

set -euo pipefail

_self="$0"
[ -L "$_self" ] && _self="$(readlink -f "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

CASES_DIR="${CASES_DIR:-/opt/initcaseenv/data}"
INITCASEENV_SUBDIR="${INITCASEENV_SUBDIR:-initcaseenv-data}"
mkdir -p "$CASES_DIR"

# ============================================================================
# Helpers
# ============================================================================

# K8s mode: detected by KUBERNETES_SERVICE_HOST (injected by kubelet in every K8s pod).
# When running on K8s/OpenShift, product containers run inside the AI runner Pod
# (managed by AiService.java), not via podman-compose. initcaseenv.sh still handles
# setup (resolve images, generate docker-compose.yml) and image builds (via BuildConfig).
_is_k8s_mode() { [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; }

# Extract a key from resolver output (set _RESOLVE_OUTPUT before calling).
_rv() { echo "$_RESOLVE_OUTPUT" | sed -n "s/^${1}=//p"; }

_available_types() {
  ls "${SCRIPT_DIR}/lib/resolve-"*.sh 2>/dev/null \
    | sed 's|.*/resolve-||;s|\.sh||' \
    | tr '\n' '/' | sed 's|/$||'
}

# Lowercase + resolve product alias → canonical type.
_resolve_type() {
  local t
  t=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  local aliases_file
  for aliases_file in \
    "${SCRIPT_DIR}/../../config/product-aliases.conf" \
    "${SCRIPT_DIR}/../product-aliases.conf"; do
    [ -f "$aliases_file" ] || continue
    local line
    while IFS= read -r line; do
      [[ "$line" =~ ^#|^$ ]] && continue
      local alias="${line%%=*}" canonical="${line#*=}"
      if [ "$t" = "$alias" ]; then
        echo "$canonical"
        return
      fi
    done < "$aliases_file"
    break
  done
  echo "$t"
}

# ============================================================================
# Usage
# ============================================================================

print_commands_usage() {
  local caseid_label="$1"
  local cmd
  cmd=$(basename "$0")
  local types
  types=$(_available_types)
  cat <<EOF
  ${cmd} ${caseid_label} setup [-t -v [-d] [-e K=V] [-p H:C] [-c CMD] [--post-start CMD] [--db-name N] [--db-user U]]
  ${cmd} ${caseid_label} start [-t -v [-d] [-e K=V] [-p H:C] [-c CMD] [--post-start CMD] [--db-name N] [--db-user U]]
  ${cmd} ${caseid_label} setup -i IMAGE:TAG [same flags as -t -v]
  ${cmd} ${caseid_label} start -i IMAGE:TAG [same flags as -t -v]
  ${cmd} ${caseid_label} setup -m FILE
  ${cmd} ${caseid_label} start -m FILE
  ${cmd} ${caseid_label} exec    CONTAINER CMD [ARG ...]        Run command inside a container
  ${cmd} ${caseid_label} stop    [CONTAINER ...]               Stop containers (default: all)
  ${cmd} ${caseid_label} restart [CONTAINER ...]               Restart containers (default: all)
  ${cmd} ${caseid_label} status  [CONTAINER ...]               Show status (default: all)
  ${cmd} ${caseid_label} logs    [CONTAINER ...]               Show logs (default: all)
  ${cmd} ${caseid_label} healthcheck [CONTAINER ...]           Run health checks (default: all)
  ${cmd} ${caseid_label} rm      [CONTAINER ...]               Remove specific containers
  ${cmd} ${caseid_label} rm --all                              Remove everything (compose + containers)

Options (with setup/start):
  -t TYPE         Product type (${types})
  -v VERSION      Product version (e.g. 26.4.5 for rhbk, 8.1.1 for eap)
  -i IMAGE:TAG    Image reference (auto-detects type and version)
  -d              Include a PostgreSQL database
  -e KEY=VAL      Environment variable (repeatable, overrides resolver defaults)
  -p HOST:CTR     Port mapping (repeatable, overrides defaults)
  -c CMD          Override container command
  --post-start CMD  Override post-start command
  --db-name NAME  Override database name
  --db-user USER  Override database user
  -m FILE         JSON file defining multiple services (see docs)
EOF
}

usage() {
  local cmd
  cmd=$(basename "$0")
  echo "Usage:"
  echo "  ${cmd} [-h]                                        Show this help"
  print_commands_usage "<CASEID>"
  echo ""
  echo "Options:"
  echo "  -h           Show this help"
  exit 1
}

case_usage() {
  echo ""
  echo "Usage:"
  print_commands_usage "$CASEID"
}

# ============================================================================
# Cache helpers
# ============================================================================

RESOLVED_IMAGES_FILE="${CASES_DIR}/.resolved-images"

cache_lookup() {
  local key="$1"
  if [ -f "$RESOLVED_IMAGES_FILE" ]; then
    grep -m1 "^${key}=" "$RESOLVED_IMAGES_FILE" 2>/dev/null | cut -d= -f2- || true
  fi
}

cache_save() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$RESOLVED_IMAGES_FILE")"
  if [ -f "$RESOLVED_IMAGES_FILE" ]; then
    grep -v "^${key}=" "$RESOLVED_IMAGES_FILE" > "${RESOLVED_IMAGES_FILE}.tmp" 2>/dev/null || true
    mv "${RESOLVED_IMAGES_FILE}.tmp" "$RESOLVED_IMAGES_FILE"
  fi
  echo "${key}=${value}" >> "$RESOLVED_IMAGES_FILE"
}

# Build an image on K8s via OpenShift BuildConfig (oc start-build).
# Creates a BuildConfig if it doesn't exist, then starts a binary build
# uploading the Containerfile context directory.
_k8s_build_image() {
  local image="$1" containerfile_path="$2"
  local bc_name
  bc_name="initcaseenv-$(echo "$image" | tr '/:.' '-' | tr '[:upper:]' '[:lower:]')"
  # Truncate to 63 chars (K8s name limit)
  bc_name="${bc_name:0:63}"

  local namespace
  namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "default")

  # Check if image already exists in the internal registry
  local imagestream_tag="${bc_name}:latest"
  if oc get istag "$imagestream_tag" -n "$namespace" >/dev/null 2>&1; then
    echo "Using image: $image (already built in cluster)"
    _K8S_BUILT_IMAGE=$(oc get is "$bc_name" -n "$namespace" \
      -o jsonpath='{.status.dockerImageRepository}' 2>/dev/null || echo "")
    [ -n "$_K8S_BUILT_IMAGE" ] && _K8S_BUILT_IMAGE="${_K8S_BUILT_IMAGE}:latest"
    return 0
  fi

  echo "Building image on OpenShift: $image (BuildConfig: ${bc_name})..."
  local context_dir
  context_dir=$(dirname "$containerfile_path")
  local dockerfile_name
  dockerfile_name=$(basename "$containerfile_path")

  # Create BuildConfig if it doesn't exist
  if ! oc get bc "$bc_name" -n "$namespace" >/dev/null 2>&1; then
    oc new-build --name="$bc_name" \
      --binary \
      --strategy=docker \
      --to="$bc_name:latest" \
      --dockerfile="$(cat "$containerfile_path")" \
      -n "$namespace" 2>&1 || {
        echo "ERROR: failed to create BuildConfig '${bc_name}'." >&2
        return 1
      }
  fi

  # Start a binary build uploading the context directory
  if oc start-build "$bc_name" \
    --from-dir="$context_dir" \
    --follow \
    -n "$namespace" 2>&1; then
    echo "Image $image built successfully via BuildConfig."
    # Return internal registry image path via _K8S_BUILT_IMAGE
    # Caller uses this to update compose file with the correct image reference
    _K8S_BUILT_IMAGE=$(oc get is "$bc_name" -n "$namespace" \
      -o jsonpath='{.status.dockerImageRepository}' 2>/dev/null || echo "")
    if [ -n "$_K8S_BUILT_IMAGE" ]; then
      _K8S_BUILT_IMAGE="${_K8S_BUILT_IMAGE}:latest"
      echo "  Internal image: ${_K8S_BUILT_IMAGE}"
    fi
  else
    echo "ERROR: BuildConfig build failed for '${bc_name}'." >&2
    return 1
  fi
}

get_exposed_ports() {
  local image="$1"
  local ports
  ports=$(podman image inspect "$image" --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}' 2>/dev/null) \
    || ports=$(skopeo inspect --config "docker://${image}" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.get('config',{}).get('ExposedPorts',{}).keys()))" 2>/dev/null) \
    || true
  echo "$ports" | tr ' ' '\n' | sed 's|/.*||' | grep -E '^[0-9]+$' | while read -r p; do
    echo -n "${p}:${p} "
  done
}

# ============================================================================
# Port helpers
# ============================================================================

_used_host_ports() {
  {
    # Ports from running containers
    podman ps --format '{{.Ports}}' 2>/dev/null \
      | tr ',' '\n' | sed -n 's/.*:\([0-9]*\)->.*/\1/p'
    # Ports already allocated in our compose file (even if container not running)
    if [ -f "$(_compose_file)" ]; then
      sed -n 's/^[[:space:]]*-[[:space:]]*"\([0-9]*\):.*/\1/p' "$(_compose_file)"
    fi
    # Ports used by any process on the system (TCP LISTEN)
    { ss -tlnH 2>/dev/null || lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1{print $9}'; } \
      | grep -oE '[0-9]+$'
  } | sort -un
}

_resolve_ports() {
  local ports="$1"
  local used
  used=$(_used_host_ports)
  local resolved=""
  for mapping in $ports; do
    local host_port="${mapping%%:*}"
    local container_port="${mapping#*:}"
    while echo "$used" | grep -qx "$host_port"; do
      host_port=$(( host_port + 1 ))
    done
    if [ "$host_port" != "${mapping%%:*}" ]; then
      echo "Port ${mapping%%:*} already in use, using ${host_port} instead." >&2
    fi
    used+=$'\n'"$host_port"
    resolved+="${host_port}:${container_port} "
  done
  echo "$resolved"
}

# ============================================================================
# Compose file management
# ============================================================================

_compose_file() {
  echo "${INITCASEENV_DIR}/docker-compose.yml"
}

_compose_base() {
  echo "podman-compose -p case-${CASEID} -f $(_compose_file)"
}

is_initialized() {
  [ -f "$(_compose_file)" ]
}

ensure_case_folder() {
  mkdir -p "${CASE_DIR}/${INITCASEENV_SUBDIR}"
}

# Get list of product container names from compose file (excludes postgres-* containers).
_get_service_containers() {
  [ -f "$(_compose_file)" ] || return 0
  grep '^\s*container_name:' "$(_compose_file)" \
    | awk '{print $2}' \
    | grep -v '^postgres-' || true
}

# Get all container names from compose file (including postgres).
_get_all_containers() {
  [ -f "$(_compose_file)" ] || return 0
  grep '^\s*container_name:' "$(_compose_file)" \
    | awk '{print $2}' || true
}

# Warn about ignored flags when reusing an existing container.
_warn_ignored_flags() {
  local cname="$1"
  if [ "$with_db" = "true" ] || [ -n "$custom_ports" ] || [ -n "$custom_envs" ] \
     || [ -n "$custom_command" ] || [ -n "$custom_post_start" ] \
     || [ -n "$custom_db_name" ] || [ -n "$custom_db_user" ]; then
    local diff_flags=""
    [ "$with_db" = "true" ] && diff_flags+="-d "
    [ -n "$custom_ports" ] && diff_flags+="-p "
    [ -n "$custom_envs" ] && diff_flags+="-e "
    [ -n "$custom_command" ] && diff_flags+="-c "
    [ -n "$custom_post_start" ] && diff_flags+="--post-start "
    echo "  NOTE: ${diff_flags}flags ignored — existing container retains its original configuration."
    echo "  To apply new configuration: rm ${cname}, then re-add."
  fi
}

# Extract type and version from a container name (e.g. "rhbk-2647-12345678" → "rhbk" "26.4.7").
# Convention: <prefix>-<version_nodots>-<caseid>
_parse_container_name() {
  local cname="$1"
  local without_caseid="${cname%-${CASEID}}"
  local prefix="${without_caseid%-*}"
  local version_nodots="${without_caseid##*-}"

  # Resolve prefix back to type via resolver
  local rtype=""
  for resolver in "${SCRIPT_DIR}"/lib/resolve-*.sh; do
    [ -f "$resolver" ] || continue
    local t
    t=$(basename "$resolver" | sed 's/^resolve-//; s/\.sh$//')
    local rprefix
    _RESOLVE_OUTPUT=$("$resolver" "0.0" --cached "dummy" 2>/dev/null) || continue
    rprefix=$(_rv RESOLVE_CONTAINER_PREFIX) || continue
    if [ "$prefix" = "$rprefix" ]; then
      rtype="$t"
      break
    fi
  done

  # Fallback: use prefix as type
  [ -z "$rtype" ] && rtype="$prefix"

  # Reconstruct dotted version from nodots via cache lookup.
  # e.g. "2647" → "26.4.7", "814" → "8.1.4", "76" → "7.6"
  local version="$version_nodots"
  if [ -f "$RESOLVED_IMAGES_FILE" ]; then
    while IFS= read -r cache_line; do
      local cached_version
      cached_version=$(echo "$cache_line" | cut -d: -f2 | cut -d= -f1)
      if [ -n "$cached_version" ] && [ "${cached_version//./}" = "$version_nodots" ]; then
        version="$cached_version"
        break
      fi
    done < <(grep "^${rtype}:" "$RESOLVED_IMAGES_FILE" 2>/dev/null)
  fi

  echo "${rtype} ${version}"
}

# Check if a service with given type+version already exists in compose.
# Matches by the full container name ({prefix}-{version_nodots}-{CASEID})
# so alias types (eap / red-hat-enterprise-application-platform) with the
# same RESOLVE_CONTAINER_PREFIX are correctly detected as duplicates.
# Args: type version
_service_exists_in_compose() {
  local type="$1" version="${2:-}"
  [ -f "$(_compose_file)" ] || return 1
  local containers
  containers=$(_get_service_containers)
  [ -z "$containers" ] && return 1

  # Resolve the prefix for the requested type
  local resolver="${SCRIPT_DIR}/lib/resolve-${type}.sh"
  if [ -f "$resolver" ] && [ -n "$version" ]; then
    local req_prefix
    _RESOLVE_OUTPUT=$("$resolver" "0.0" --cached "dummy" 2>/dev/null) || true
    req_prefix=$(_rv RESOLVE_CONTAINER_PREFIX 2>/dev/null) || req_prefix=""
    if [ -n "$req_prefix" ]; then
      local expected_cname="${req_prefix}-${version//./}-${CASEID}"
      while IFS= read -r cname; do
        [ "$cname" = "$expected_cname" ] && return 0
      done <<< "$containers"
      return 1
    fi
  fi

  # Fallback: match by parsed type name
  while IFS= read -r cname; do
    local parsed
    parsed=$(_parse_container_name "$cname")
    local existing_type="${parsed%% *}"
    local existing_version="${parsed#* }"
    if [ "$existing_type" = "$type" ]; then
      if [ -z "$version" ] || [ "${version//./}" = "${existing_version//./}" ]; then
        return 0
      fi
    fi
  done <<< "$containers"
  return 1
}

# ============================================================================
# Service resolution and compose generation
# ============================================================================

# Resolve a single service and add it to the compose file.
# Args: type version db custom_ports custom_envs
_add_service() {
  local type="$1" version="$2" with_db="${3:-false}"
  local custom_ports="${4:-}" custom_envs="${5:-}"
  local custom_command="${6:-}" custom_post_start="${7:-}"
  local custom_db_name="${8:-}" custom_db_user="${9:-}"

  # Show existing services if any
  local existing
  existing=$(_get_service_containers)
  if [ -n "$existing" ]; then
    echo "==> Existing services:"
    while IFS= read -r ecname; do
      local ep
      ep=$(_parse_container_name "$ecname")
      local etype="${ep%% *}" eversion="${ep#* }"
      local estate
      estate=$(podman inspect --format '{{.State.Status}}' "$ecname" 2>/dev/null || echo "not found")
      echo "    ${etype} ${eversion} (${ecname}): ${estate}"
    done <<< "$existing"
  fi

  # Check if already exists (same type + same version)
  if _service_exists_in_compose "$type" "$version"; then
    # Build the expected container name to find it
    local existing_cname=""
    local _tmp_prefix=""
    local _tmp_resolver="${SCRIPT_DIR}/lib/resolve-${type}.sh"
    if [ -f "$_tmp_resolver" ]; then
      _RESOLVE_OUTPUT=$("$_tmp_resolver" "0.0" --cached "dummy" 2>/dev/null) || true
      _tmp_prefix=$(_rv RESOLVE_CONTAINER_PREFIX 2>/dev/null) || _tmp_prefix=""
    fi
    if [ -n "$_tmp_prefix" ]; then
      existing_cname="${_tmp_prefix}-${version//./}-${CASEID}"
    fi
    local cstate
    cstate=$(podman inspect --format '{{.State.Status}}' "$existing_cname" 2>/dev/null || echo "not found")
    case "$cstate" in
      running)
        echo "Service ${type} ${version} already running (${existing_cname}), reusing."
        _warn_ignored_flags "$existing_cname" ;;
      exited|stopped)
        echo "Service ${type} ${version} exists but stopped (${existing_cname}), will be restarted."
        _warn_ignored_flags "$existing_cname" ;;
      created)
        # Container was created but never started (e.g. port conflict after agent restart).
        # Remove it and its compose entry so it gets recreated with fresh ports.
        echo "Service ${type} ${version} stuck in 'created' state (${existing_cname}), recreating."
        _remove_service_from_compose "$existing_cname"
        existing_cname="" ;;
      *)
        existing_cname=""
        echo "Service ${type} ${version} container not found, will be created." ;;
    esac
    [ -n "$existing_cname" ] && return 0
  fi

  local resolver="${SCRIPT_DIR}/lib/resolve-${type}.sh"
  if [ ! -f "$resolver" ]; then
    echo "Error: no resolver for product type '${type}'." >&2
    echo "  Available: $(_available_types)" >&2
    return 1
  fi

  echo "==> Resolving ${type} ${version}..."

  # Check cache
  local cache_key="${type}:${version}"
  local cached
  cached=$(cache_lookup "$cache_key")

  local resolve_args=("$version")
  [ -n "$cached" ] && resolve_args+=(--cached "$cached")
  resolve_args+=(--env-dir "$INITCASEENV_DIR")

  _RESOLVE_OUTPUT=$("$resolver" "${resolve_args[@]}") || return 1

  local r_image r_prefix r_command r_default_envs
  local r_db_name r_db_user r_db_envs
  local r_containerfile r_cache_value
  r_image=$(_rv RESOLVE_IMAGE)
  r_prefix=$(_rv RESOLVE_CONTAINER_PREFIX)
  r_command=$(_rv RESOLVE_COMMAND)
  r_default_envs=$(_rv RESOLVE_DEFAULT_ENVS)
  r_db_name=$(_rv RESOLVE_DB_NAME)
  r_db_user=$(_rv RESOLVE_DB_USER)
  r_db_envs=$(_rv RESOLVE_DB_ENVS)
  r_containerfile=$(_rv RESOLVE_CONTAINERFILE)
  r_cache_value=$(_rv RESOLVE_CACHE_VALUE)

  # Derived names (single source: type + version + CASEID)
  local version_nodots="${version//./}"
  local container_name="${r_prefix}-${version_nodots}-${CASEID}"

  # Cache
  if [ -n "$r_cache_value" ] && [ -z "$cached" ]; then
    cache_save "$cache_key" "$r_cache_value"
  fi

  # Build image if needed (RESOLVE_CONTAINERFILE non-empty = build required)
  if [ -n "$r_containerfile" ]; then
    local containerfile_path="${INITCASEENV_DIR}/${r_containerfile}"
    if _is_k8s_mode; then
      _K8S_BUILT_IMAGE=""
      _k8s_build_image "$r_image" "$containerfile_path"
      # Use the internal registry image in compose (so runner Pod pulls the right image)
      if [ -n "$_K8S_BUILT_IMAGE" ]; then
        r_image="$_K8S_BUILT_IMAGE"
      fi
    elif podman image exists "$r_image" 2>/dev/null; then
      echo "Using image: $r_image (already present)"
    else
      echo "Building image: $r_image ..."
      if podman build -t "$r_image" -f "$containerfile_path" .; then
        echo "Image $r_image built successfully."
      else
        echo "ERROR: image build failed." >&2
        return 1
      fi
    fi
  fi

  # Build ports (custom or auto-detected, with auto-increment)
  local raw_ports=""
  if [ -n "$custom_ports" ]; then
    raw_ports="$custom_ports"
  else
    raw_ports=$(get_exposed_ports "$r_image")
  fi
  local resolved_ports
  resolved_ports=$(_resolve_ports "$raw_ports")

  # Apply overrides
  local final_command="${custom_command:-$r_command}"
  local final_db_name="${custom_db_name:-$r_db_name}"
  local final_db_user="${custom_db_user:-$r_db_user}"

  # Build env vars: resolver defaults merged with custom (-e overrides same key)
  local envs_str=""
  if [ "$with_db" = "true" ] && [ -n "$r_db_envs" ]; then
    local postgres_name="postgres-${type}-${CASEID}"
    envs_str="$r_db_envs"
    envs_str="${envs_str//__DB_HOST__/${postgres_name}}"
    envs_str="${envs_str//__DB_NAME__/${final_db_name}}"
    envs_str="${envs_str//__DB_USER__/${final_db_user}}"
  elif [ -n "$r_default_envs" ]; then
    envs_str="$r_default_envs"
  fi

  # Merge: custom_envs override resolver defaults (same key = custom wins)
  if [ -n "$custom_envs" ] && [ -n "$envs_str" ]; then
    while IFS= read -r ce; do
      [ -z "$ce" ] && continue
      local ce_key="${ce%%=*}"
      # Remove existing key from envs_str (pipe-separated)
      envs_str=$(echo "$envs_str" | tr '|' '\n' | grep -v "^${ce_key}=" | tr '\n' '|' | sed 's/|$//')
    done <<< "$custom_envs"
  fi

  # Now generate/update the compose file
  _update_compose_file "$type" "$container_name" "$r_image" "$final_command" \
    "$envs_str" "$custom_envs" "$resolved_ports" "$with_db" \
    "${final_db_name:-}" "${final_db_user:-}" "${custom_post_start:-}"

  echo "Service ${type} ${version} added (container: ${container_name})."
}

# Generate or update the docker-compose.yml with a new service.
_update_compose_file() {
  local type="$1" container_name="$2" image="$3" command="${4:-}"
  local envs_str="${5:-}" custom_envs="${6:-}" resolved_ports="${7:-}"
  local with_db="${8:-false}" db_name="${9:-}" db_user="${10:-}"
  local custom_post_start="${11:-}"

  local compose_file
  compose_file=$(_compose_file)
  local network_name="case-${CASEID}"

  # Build YAML fragments for the new service
  local ports_yaml=""
  for p in $resolved_ports; do
    ports_yaml+="      - \"${p}\"\n"
  done

  local env_yaml=""
  if [ -n "$envs_str" ]; then
    IFS='|' read -ra env_arr <<< "$envs_str"
    for e in "${env_arr[@]}"; do
      [ -z "$e" ] && continue
      local key="${e%%=*}" val="${e#*=}"
      env_yaml+="      ${key}: \"${val}\"\n"
    done
  fi
  if [ -n "$custom_envs" ]; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      local key="${e%%=*}" val="${e#*=}"
      env_yaml+="      ${key}: \"${val}\"\n"
    done <<< "$custom_envs"
  fi

  # DB service fragment
  local db_fragment=""
  if [ "$with_db" = "true" ]; then
    local postgres_name="postgres-${type}-${CASEID}"
    local volume_name="postgres_${type}_data-${CASEID}"
    db_fragment+="  ${postgres_name}:\n"
    db_fragment+="    container_name: ${postgres_name}\n"
    db_fragment+="    image: postgres:14\n"
    db_fragment+="    volumes:\n"
    db_fragment+="      - ${volume_name}:/var/lib/postgresql/data\n"
    db_fragment+="    environment:\n"
    db_fragment+="      POSTGRES_DB: ${db_name}\n"
    db_fragment+="      POSTGRES_USER: ${db_user}\n"
    db_fragment+="      POSTGRES_PASSWORD: password\n"
    db_fragment+="    networks:\n"
    db_fragment+="      - ${network_name}\n"
  fi

  # Product service fragment
  local svc_fragment=""
  svc_fragment+="  ${container_name}:\n"
  svc_fragment+="    container_name: ${container_name}\n"
  svc_fragment+="    image: ${image}\n"
  [ -n "$command" ] && svc_fragment+="    command: ${command}\n"
  if [ -n "$env_yaml" ]; then
    svc_fragment+="    environment:\n"
    svc_fragment+="$env_yaml"
  fi
  if [ -n "$ports_yaml" ]; then
    svc_fragment+="    ports:\n"
    svc_fragment+="$ports_yaml"
  fi
  if [ "$with_db" = "true" ]; then
    local postgres_name="postgres-${type}-${CASEID}"
    svc_fragment+="    depends_on:\n"
    svc_fragment+="      - ${postgres_name}\n"
  fi
  if [ -n "$custom_post_start" ]; then
    svc_fragment+="    labels:\n"
    svc_fragment+="      initcaseenv.post_start: \"${custom_post_start}\"\n"
  fi
  svc_fragment+="    networks:\n"
  svc_fragment+="      - ${network_name}\n"

  # Volume fragment
  local vol_fragment=""
  if [ "$with_db" = "true" ]; then
    local volume_name="postgres_${type}_data-${CASEID}"
    vol_fragment+="  ${volume_name}:\n"
  fi

  if [ -f "$compose_file" ]; then
    # Incremental: insert new service(s) into existing compose via python
    python3 -c "
import sys

compose_file = sys.argv[1]
db_fragment = sys.argv[2]
svc_fragment = sys.argv[3]
vol_fragment = sys.argv[4]

with open(compose_file, 'r') as f:
    content = f.read()

lines = content.split('\n')
result = []
in_services = False
in_volumes = False
inserted_svc = False
inserted_vol = False

i = 0
while i < len(lines):
    line = lines[i]

    # Insert before 'networks:' section (after all services)
    if line.startswith('networks:') and not inserted_svc:
        if db_fragment.strip():
            result.append(db_fragment.rstrip())
            result.append('')
        result.append(svc_fragment.rstrip())
        result.append('')
        inserted_svc = True
        result.append(line)
        i += 1
        continue

    # Insert volume before end of volumes section or at end of file
    if line.startswith('volumes:') and vol_fragment.strip():
        result.append(line)
        i += 1
        # Copy existing volume entries
        while i < len(lines) and (lines[i].startswith('  ') or lines[i] == ''):
            result.append(lines[i])
            i += 1
        result.append(vol_fragment.rstrip())
        inserted_vol = True
        continue

    result.append(line)
    i += 1

# If no volumes section existed but we need one
if vol_fragment.strip() and not inserted_vol:
    result.append('')
    result.append('volumes:')
    result.append(vol_fragment.rstrip())

with open(compose_file, 'w') as f:
    f.write('\n'.join(result))
    if not result[-1] == '':
        f.write('\n')
" "$compose_file" "$(printf '%b' "$db_fragment")" "$(printf '%b' "$svc_fragment")" "$(printf '%b' "$vol_fragment")"
  else
    # First service: create compose from scratch
    {
      echo "version: '3.8'"
      echo ""
      echo "services:"
      [ -n "$db_fragment" ] && printf "%b\n" "$db_fragment"
      printf "%b\n" "$svc_fragment"
      echo "networks:"
      echo "  ${network_name}:"
      echo "    name: ${network_name}"
      if [ -n "$vol_fragment" ]; then
        echo ""
        echo "volumes:"
        printf "%b" "$vol_fragment"
      fi
    } > "$compose_file"
  fi
}

# Remove a service from compose by container name.
_remove_service_from_compose() {
  local target_container="$1"
  local compose_file
  compose_file=$(_compose_file)
  [ -f "$compose_file" ] || return 0

  # Derive type from container name
  local parsed
  parsed=$(_parse_container_name "$target_container")
  local rm_type="${parsed%% *}"

  # Stop and remove the specific containers (skip on K8s — no local podman)
  local postgres_name="postgres-${rm_type}-${CASEID}"
  if ! _is_k8s_mode; then
    for cn in "$target_container" "$postgres_name"; do
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cn"; then
        podman stop "$cn" >/dev/null 2>&1 || true
      fi
      if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$cn"; then
        podman rm "$cn" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Remove service from compose via python
  python3 -c "
import sys, re

compose_file = sys.argv[1]
target = sys.argv[2]
postgres = sys.argv[3]
volume_prefix = sys.argv[4]

with open(compose_file, 'r') as f:
    content = f.read()

# Remove service blocks (indent-based)
def remove_service_block(content, service_name):
    lines = content.split('\n')
    result = []
    skip = False
    for line in lines:
        if re.match(r'^  ' + re.escape(service_name) + r':', line):
            skip = True
            continue
        if skip and (line.startswith('    ') or line == ''):
            if line == '' and result and result[-1] == '':
                continue  # skip double blank
            if line.startswith('    '):
                continue
            skip = False
        if skip and not line.startswith('    ') and line != '':
            skip = False
        if not skip:
            result.append(line)
    return '\n'.join(result)

content = remove_service_block(content, target)
content = remove_service_block(content, postgres)

# Remove volume
lines = content.split('\n')
result = []
skip_vol = False
for line in lines:
    if re.match(r'^  ' + re.escape(volume_prefix), line):
        skip_vol = True
        continue
    if skip_vol and (line.startswith('    ') or line == ''):
        continue
    skip_vol = False
    result.append(line)
content = '\n'.join(result)

# Clean up double blank lines
while '\n\n\n' in content:
    content = content.replace('\n\n\n', '\n\n')

with open(compose_file, 'w') as f:
    f.write(content)
" "$compose_file" "$target_container" "$postgres_name" "postgres_${rm_type}_data-${CASEID}"

  echo "Service ${rm_type} removed (container: ${target_container})."

  # If no product services left, remove compose file
  local remaining
  remaining=$(_get_service_containers)
  if [ -z "$remaining" ]; then
    rm -f "$compose_file"
    echo "No services remaining — configuration removed."
  fi
}

# ============================================================================
# Howto & port history
# ============================================================================

_write_howto() {
  local howto_file="${INITCASEENV_DIR}/buildenv-${CASEID}-howto.txt"
  local -a howto_lines=()
  howto_lines+=("Build Environment for Case ${CASEID}")
  howto_lines+=("Date: $(date '+%Y-%m-%d %H:%M:%S')")
  howto_lines+=("")

  local containers
  containers=$(_get_service_containers)
  if [ -n "$containers" ]; then
    while IFS= read -r cname; do
      local parsed
      parsed=$(_parse_container_name "$cname")
      local stype="${parsed%% *}" sversion="${parsed#* }"
      howto_lines+=("Service: ${stype} ${sversion}")
      howto_lines+=("  Container: ${cname}")
    done <<< "$containers"
    howto_lines+=("")
  fi

  howto_lines+=("Compose: $(_compose_file)")
  howto_lines+=("")
  howto_lines+=("Commands:")
  howto_lines+=("  Start:   $(_compose_base) up -d")
  howto_lines+=("  Stop:    $(_compose_base) down")
  howto_lines+=("  Remove:  $(_compose_base) down -v")

  printf '%s\n' "${howto_lines[@]}" > "$howto_file"
}

_append_run_history() {
  local howto_file="${INITCASEENV_DIR}/buildenv-${CASEID}-howto.txt"
  [ -f "$howto_file" ] || return 0

  local containers
  containers=$(_get_service_containers)
  [ -z "$containers" ] && return 0

  {
    echo ""
    echo "--- Run $(date '+%Y-%m-%d %H:%M:%S') ---"
    echo "  Invocation: initcaseenv.sh ${_ORIGINAL_ARGS:-}"
    echo "  Compose command: $(_compose_base) up -d"
    echo ""
    while IFS= read -r cname; do
      local parsed
      parsed=$(_parse_container_name "$cname")
      local stype="${parsed%% *}" sversion="${parsed#* }"

      # Ports
      local ports
      ports=$(podman port "$cname" 2>/dev/null \
        | awk -F'[ /]+' '{split($4,a,":"); print a[2]":"$1}' \
        | tr '\n' ', ' | sed 's/,$//')

      # Image
      local img
      img=$(podman inspect --format '{{.Config.Image}}' "$cname" 2>/dev/null || echo "?")

      # Command
      local cmd
      cmd=$(podman inspect --format '{{join .Config.Cmd " "}}' "$cname" 2>/dev/null || echo "")

      # State
      local state
      state=$(podman inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "?")

      echo "  ${stype} ${sversion} (${cname}): ${state}"
      echo "    image: ${img}"
      [ -n "$cmd" ] && echo "    command: ${cmd}"
      echo "    ports: ${ports:-(none)}"

      # Environment (non-default, from container)
      local envs
      envs=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cname" 2>/dev/null \
        | grep -vE '^(PATH=|HOME=|HOSTNAME=|container=|TERM=)' \
        | tr '\n' ', ' | sed 's/,$//')
      [ -n "$envs" ] && echo "    envs: ${envs}"
    done <<< "$containers"
  } >> "$howto_file"
}

# ============================================================================
# Container name resolution
# ============================================================================

# Resolve target containers from user args.
# If names given: validate each against compose, return matched list.
# If no names: return all service containers.
# Args: container_names...
# Prints matching container names (one per line).
_resolve_target_containers() {
  local all_containers
  all_containers=$(_get_all_containers)
  [ -z "$all_containers" ] && { echo "No containers configured." >&2; return 1; }

  if [ $# -eq 0 ]; then
    echo "$all_containers"
    return 0
  fi

  local result=""
  for name in "$@"; do
    name="${name// /}"
    if echo "$all_containers" | grep -qx "$name"; then
      result+="${name}"$'\n'
    else
      echo "Error: container '${name}' not found in compose." >&2
      echo "  Available:" >&2
      while IFS= read -r c; do
        echo "    ${c}" >&2
      done <<< "$all_containers"
      return 1
    fi
  done
  echo -n "$result" | grep .
}

# Same as above but only product containers (excludes postgres-*).
_resolve_target_service_containers() {
  local all_services
  all_services=$(_get_service_containers)
  [ -z "$all_services" ] && { echo "No services configured." >&2; return 1; }

  if [ $# -eq 0 ]; then
    echo "$all_services"
    return 0
  fi

  local all_containers
  all_containers=$(_get_all_containers)
  local result=""
  for name in "$@"; do
    name="${name// /}"
    if echo "$all_containers" | grep -qx "$name"; then
      result+="${name}"$'\n'
    else
      echo "Error: container '${name}' not found in compose." >&2
      echo "  Available:" >&2
      while IFS= read -r c; do
        echo "    ${c}" >&2
      done <<< "$all_containers"
      return 1
    fi
  done
  echo -n "$result" | grep .
}

# ============================================================================
# Actions
# ============================================================================

do_start() {
  local compose_file
  compose_file=$(_compose_file)

  if [ ! -f "$compose_file" ]; then
    echo "ERROR: no compose file found. Run setup first." >&2
    return 1
  fi

  # K8s mode: product containers run inside the AI runner Pod (managed by AiService.java).
  # initcaseenv.sh only generates docker-compose.yml — AiService reads it to build the Pod spec.
  if _is_k8s_mode; then
    echo "K8s mode: product containers will start with the next AI run (runner Pod)."
    echo "  Compose file: ${compose_file}"
    _ALREADY_RUNNING=""
    return 0
  fi

  # Track which containers were already running before start
  _ALREADY_RUNNING=""
  local containers
  containers=$(_get_service_containers)
  local all_running=true
  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
      _ALREADY_RUNNING+="${cname}"$'\n'
    else
      all_running=false
    fi
  done <<< "$containers"

  if [ "$all_running" = true ] && [ -n "$containers" ]; then
    echo "All containers already running."
    return 0
  fi

  echo "Starting containers..."
  _START_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S')
  local cmd_output
  if cmd_output=$($(_compose_base) up -d 2>&1); then
    echo "Compose up completed."
    _append_run_history
  else
    echo "ERROR: container start failed." >&2
    echo "$cmd_output" | tail -5 >&2
    if echo "$cmd_output" | grep -qi "address already in use\|port is already allocated\|bind:"; then
      echo "" >&2
      echo "  Host ports are already in use." >&2
      echo "  Check with: podman ps --format '{{.Ports}}'" >&2
    fi
    return 1
  fi
}

_health_check_endpoint() {
  local proto="$1" host_port="$2" path="$3" label="$4"
  # When running inside a container, use host.containers.internal to reach
  # host-mapped ports (localhost inside the container is the container itself,
  # not the host). On bare-metal, use localhost directly.
  local target="localhost"
  if [ -n "${CONTAINER_HOST:-}" ]; then
    target="host.containers.internal"
  fi
  local port="$host_port"
  local url="${proto}://${target}:${port}${path}"
  local curl_args=(-s -o /dev/null -w '%{http_code}' --max-time 5)
  [ "$proto" = "https" ] && curl_args+=(-k)

  local code
  code=$(curl "${curl_args[@]}" "$url" 2>/dev/null || echo "000")
  if [ "$code" != "000" ] && [ "$code" -gt 0 ] 2>/dev/null; then
    echo "  PASS: ${label} ${url} → HTTP ${code}"
    return 0
  fi
  echo "  FAIL: ${label} ${url} → HTTP ${code} (connection refused or timeout)" >&2
  return 1
}

do_health_check() {
  # K8s mode: health checks run inside the runner Pod (AiService manages readiness)
  if _is_k8s_mode; then return 0; fi

  echo "==> Health check..."

  local containers
  if [ $# -gt 0 ]; then
    containers=$(_resolve_target_service_containers "$@") || return 1
  else
    containers=$(_get_service_containers)
  fi
  [ -z "$containers" ] && { echo "  No services configured."; return 0; }

  local all_pass=true

  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    local parsed
    parsed=$(_parse_container_name "$cname")
    local type="${parsed%% *}"
    local version="${parsed#* }"

    # Skip entirely if container was already running before this start
    # (only applies when called from do_start, not standalone)
    if [ -n "${_ALREADY_RUNNING:-}" ] && echo "$_ALREADY_RUNNING" | grep -qx "$cname" 2>/dev/null; then
      echo "  ${type} ${version} already running (${cname}), skipping."
      continue
    fi

    local resolver="${SCRIPT_DIR}/lib/resolve-${type}.sh"
    [ -f "$resolver" ] || continue

    local detect_info
    detect_info=$(bash "$resolver" --detect-info 2>/dev/null) || continue

    # Wait for ready log
    local ready_log
    ready_log=$(echo "$detect_info" | grep '^DETECT_READY_LOG=' | cut -d= -f2-)
    if [ -n "$ready_log" ]; then
      echo "  Waiting for ${type} ${version} to be ready (${cname})..."
      local wait_sec=0
      while [ $wait_sec -lt 120 ]; do
        sleep 3
        wait_sec=$((wait_sec + 3))
        if podman logs --since "${_START_TIMESTAMP:-0}" "$cname" 2>&1 | grep -qE "$ready_log"; then
          echo "  ${type} ${version} ready."
          break
        fi
      done
      if [ $wait_sec -ge 120 ]; then
        echo "  WARNING: ${type} ${version} did not report ready within 120s." >&2
        all_pass=false
        continue
      fi
    fi

    # Endpoint checks (opt-in) — use podman port for per-container port mapping
    local checks_str
    checks_str=$(echo "$detect_info" | grep '^DETECT_HEALTH_CHECKS=' | cut -d= -f2-)
    if [ -z "$checks_str" ]; then
      continue
    fi

    # Build per-container port map from podman port
    local _port_map=""
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local cport hport
      cport=$(echo "$line" | grep -oE '^[0-9]+')
      hport=$(echo "$line" | grep -oE '[0-9]+$')
      _port_map="${_port_map}${cport}=${hport} "
    done < <(podman port "$cname" 2>/dev/null)

    IFS=',' read -ra checks <<< "$checks_str"
    for check in "${checks[@]}"; do
      IFS=':' read -r proto container_port path <<< "$check"
      local check_port="$container_port"
      if [ -z "${KUBERNETES_SERVICE_HOST:-}" ]; then
        # Not on K8s — use container IP + container port (works from agent container or host)
        # Fall back to host-mapped port with localhost if no container IP
        local _pm
        for _pm in $_port_map; do
          [ "${_pm%%=*}" = "$container_port" ] && check_port="${_pm#*=}" && break
        done
      fi
      if ! _health_check_endpoint "$proto" "$check_port" "$path" "${type} ${version}"; then
        all_pass=false
      fi
    done
  done <<< "$containers"

  if [ "$all_pass" = true ]; then
    echo "  All health checks passed."
  else
    echo "  WARNING: some health checks failed." >&2
  fi
}

do_post_start() {
  # K8s mode: post-start handled by AiService runner Pod lifecycle hooks
  if _is_k8s_mode; then _POST_START_RAN=false; return 0; fi

  # Re-resolve post-start commands from resolvers (no cached CONF_POST_START_CMDS).
  local containers
  containers=$(_get_service_containers)
  _POST_START_RAN=false
  [ -z "$containers" ] && return 0

  local has_commands=false

  while IFS= read -r cname; do
    [ -z "$cname" ] && continue

    # Skip containers that were already running before this start
    if echo "$_ALREADY_RUNNING" | grep -qx "$cname" 2>/dev/null; then
      continue
    fi

    local parsed
    parsed=$(_parse_container_name "$cname")
    local type="${parsed%% *}" version="${parsed#* }"

    local resolver="${SCRIPT_DIR}/lib/resolve-${type}.sh"
    [ -f "$resolver" ] || continue

    # Check for custom post-start in container label first
    local post_cmd=""
    post_cmd=$(podman inspect --format '{{index .Config.Labels "initcaseenv.post_start"}}' "$cname" 2>/dev/null || true)
    # podman returns "<no value>" if label not set
    [ "$post_cmd" = "<no value>" ] && post_cmd=""

    # Fallback to resolver post-start command
    if [ -z "$post_cmd" ]; then
      local cache_key="${type}:${version}"
      local cached
      cached=$(cache_lookup "$cache_key")
      local resolve_args=("$version")
      [ -n "$cached" ] && resolve_args+=(--cached "$cached")
      resolve_args+=(--env-dir "$INITCASEENV_DIR")

      _RESOLVE_OUTPUT=$("$resolver" "${resolve_args[@]}" 2>/dev/null) || continue
      post_cmd=$(_rv RESOLVE_POST_START_CMD)
    fi
    [ -z "$post_cmd" ] && continue

    if [ "$has_commands" = false ]; then
      echo "==> Post-start configuration..."
      has_commands=true
    fi

    echo "  Running post-start on ${cname}..."
    if podman exec "$cname" sh -c "$post_cmd" >/dev/null 2>&1; then
      echo "  DONE: ${cname} post-start completed."
    else
      echo "  WARNING: post-start command failed on ${cname}." >&2
      echo "  Command: ${post_cmd}" >&2
    fi
  done <<< "$containers"

  _POST_START_RAN="$has_commands"
}

do_stop() {
  if [ ! -f "$(_compose_file)" ]; then
    echo "No environment configured for case ${CASEID}." >&2
    return 1
  fi

  # K8s mode: product containers run inside runner Pod, managed by AiService
  if _is_k8s_mode; then
    echo "K8s mode: product containers are managed by the runner Pod."
    echo "  Use the agent API or delete the runner Pod to stop containers."
    return 0
  fi

  if [ $# -eq 0 ]; then
    # Stop all via compose down
    if $(_compose_base) down >/dev/null 2>&1; then
      echo "Containers stopped."
    else
      echo "ERROR: container stop failed." >&2
      return 1
    fi
  else
    # Stop specific containers
    local targets
    targets=$(_resolve_target_containers "$@") || return 1
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        podman stop "$cname" >/dev/null 2>&1 || true
        echo "Stopped: ${cname}"
      else
        echo "Already stopped: ${cname}"
      fi
    done <<< "$targets"
  fi
}

do_restart() {
  # K8s mode: delegate to do_stop (which prints the K8s message)
  if _is_k8s_mode; then do_stop; return $?; fi

  if [ $# -eq 0 ]; then
    # Restart all via compose
    local containers
    containers=$(_get_service_containers)
    local any_running=false
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        any_running=true
        break
      fi
    done <<< "$containers"

    if [ "$any_running" = true ]; then
      do_stop
    else
      echo "No containers running, skipping stop."
    fi
    do_start
  else
    # Restart specific containers
    local targets
    targets=$(_resolve_target_containers "$@") || return 1
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
        podman stop "$cname" >/dev/null 2>&1 || true
      fi
      podman start "$cname" >/dev/null 2>&1 || true
      echo "Restarted: ${cname}"
    done <<< "$targets"
  fi
}

do_status() {
  echo "=== Case ${CASEID} ==="
  echo "  Case dir: ${CASE_DIR}"
  echo ""

  if [ ! -f "$(_compose_file)" ]; then
    echo "  (no environment configured)"
    return
  fi

  local targets
  if [ $# -gt 0 ]; then
    targets=$(_resolve_target_containers "$@") || return 1
  else
    targets=$(_get_all_containers)
  fi

  if [ -z "$targets" ]; then
    echo "  (no services in compose)"
    return
  fi

  # K8s mode: show configured services from compose file (no podman inspect)
  if _is_k8s_mode; then
    echo "  Mode: Kubernetes (product containers run inside runner Pod)"
    echo ""
    echo "  Configured services:"
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      [[ "$cname" == postgres-* ]] && continue
      local parsed
      parsed=$(_parse_container_name "$cname")
      local stype="${parsed%% *}" sversion="${parsed#* }"
      echo "    ${stype} ${sversion} (${cname})"
    done <<< "$targets"
    # Show DB
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      [[ "$cname" == postgres-* ]] && echo "    db: ${cname}"
    done <<< "$targets"
    return
  fi

  echo "  Services:"
  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    if [[ "$cname" == postgres-* ]]; then
      continue  # show after services
    fi
    local parsed
    parsed=$(_parse_container_name "$cname")
    local stype="${parsed%% *}" sversion="${parsed#* }"
    local state
    state=$(podman inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "not found")
    echo "    ${stype} ${sversion} (${cname}): ${state}"
  done <<< "$targets"
  echo ""

  # Show DB containers
  local has_db=false
  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    if [[ "$cname" == postgres-* ]]; then
      if [ "$has_db" = false ]; then
        echo "  Databases:"
        has_db=true
      fi
      local state
      state=$(podman inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "not found")
      echo "    ${cname}: ${state}"
    fi
  done <<< "$targets"
}

do_logs() {
  # K8s mode: logs are available via kubectl logs on the runner Pod
  if _is_k8s_mode; then
    local namespace
    namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "default")
    echo "K8s mode: product container logs are in the runner Pod."
    echo "  Use: kubectl logs <runner-pod> -c <container> -n ${namespace}"
    # List runner pods for this case
    local pods
    pods=$(kubectl get pods -n "$namespace" -l "initcaseenv.io/case=${CASEID}" \
      --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    if [ -n "$pods" ]; then
      echo "  Active runner pods:"
      while IFS= read -r pod; do
        [ -z "$pod" ] && continue
        echo "    ${pod}"
      done <<< "$pods"
    else
      echo "  No active runner pods for case ${CASEID}."
    fi
    return 0
  fi

  local targets
  if [ $# -gt 0 ]; then
    targets=$(_resolve_target_containers "$@") || return 1
  else
    targets=$(_get_all_containers)
  fi

  if [ -z "$targets" ]; then
    echo "No containers configured." >&2
    return 1
  fi

  while IFS= read -r cname; do
    [ -z "$cname" ] && continue
    echo "=== Logs: ${cname} ==="
    podman logs --tail 50 "$cname" 2>&1 || echo "  (container not found)"
    echo ""
  done <<< "$targets"
}

do_exec() {
  local container="$1"; shift
  local all_containers
  all_containers=$(_get_all_containers)
  if ! echo "$all_containers" | grep -qx "$container"; then
    echo "Error: container '${container}' not found in compose." >&2
    echo "  Available:" >&2
    while IFS= read -r c; do
      echo "    ${c}" >&2
    done <<< "$all_containers"
    return 1
  fi

  # K8s mode: exec into the container running inside the runner Pod
  if _is_k8s_mode; then
    local namespace
    namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "default")
    # Find the runner pod for this case
    local pod
    pod=$(kubectl get pods -n "$namespace" -l "initcaseenv.io/case=${CASEID}" \
      --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -z "$pod" ]; then
      echo "Error: no active runner pod for case ${CASEID}." >&2
      return 1
    fi
    kubectl exec -n "$namespace" "$pod" -c "$container" -- "$@"
  else
    podman exec "$container" "$@"
  fi
}

do_rm() {
  local rm_all="${1:-false}"
  shift || true

  if [ ! -f "$(_compose_file)" ]; then
    echo "No environment configured for case ${CASEID}." >&2
    return 0
  fi

  # K8s mode: only manage compose file and BuildConfig resources (no podman containers)
  if _is_k8s_mode; then
    if [ "$rm_all" = true ] && [ $# -eq 0 ]; then
      # Delete runner pods for this case
      local namespace
      namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "default")
      kubectl delete pods -n "$namespace" -l "initcaseenv.io/case=${CASEID}" --ignore-not-found 2>/dev/null || true
      rm -f "$(_compose_file)"
      rm -f "${INITCASEENV_DIR}/buildenv-${CASEID}-howto.txt"
      echo "Configuration and runner pods removed for case ${CASEID}."
    elif [ $# -gt 0 ]; then
      local targets
      targets=$(_resolve_target_service_containers "$@") || return 1
      while IFS= read -r cname; do
        [ -z "$cname" ] && continue
        _remove_service_from_compose "$cname"
      done <<< "$targets"
    else
      echo "K8s mode: no running containers to stop (managed by runner Pod)."
      echo "  Use --all to remove configuration."
    fi
    return 0
  fi

  if [ "$rm_all" = true ] && [ $# -eq 0 ]; then
    # rm --all: remove everything
    $(_compose_base) down -v >/dev/null 2>&1 || true
    rm -f "$(_compose_file)"
    rm -f "${INITCASEENV_DIR}/buildenv-${CASEID}-howto.txt"
    echo "All containers and configuration removed for case ${CASEID}."

  elif [ $# -gt 0 ]; then
    # rm CONTAINER...: remove specific containers by name
    local targets
    targets=$(_resolve_target_service_containers "$@") || return 1
    while IFS= read -r cname; do
      [ -z "$cname" ] && continue
      _remove_service_from_compose "$cname"
    done <<< "$targets"

  else
    # rm (no args, no --all): stop all containers but keep compose
    $(_compose_base) down >/dev/null 2>&1 || true
    echo "Containers removed (configuration kept). Use --all to remove configuration too."
  fi
}

# ============================================================================
# Prepare services (unified entry for -t/-v and -m)
# ============================================================================

_prepare_services() {
  if [ -n "$MULTI_FILE" ]; then
    # Parse JSON and add each service
    local parsed
    parsed=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
if 'services' not in data or not data['services']:
    print('ERROR: no services defined in JSON.', file=sys.stderr)
    sys.exit(1)
for i, svc in enumerate(data['services']):
    parts = [
        str(i),
        svc['type'],
        svc['version'],
        'true' if svc.get('db') else 'false',
        ','.join(svc.get('ports', [])),
        ','.join(svc.get('envs', [])),
        svc.get('command', ''),
        svc.get('post_start', ''),
        svc.get('db_name', ''),
        svc.get('db_user', '')
    ]
    print('|'.join(parts))
" "$MULTI_FILE") || { echo "Error: failed to parse ${MULTI_FILE}" >&2; return 1; }

    while IFS='|' read -r idx svc_type svc_version svc_db svc_ports svc_envs svc_command svc_post_start svc_db_name svc_db_user; do
      svc_type="$(_resolve_type "$svc_type")"
      local custom_ports_str="${svc_ports//,/ }"
      local custom_envs_str="${svc_envs//,/$'\n'}"
      if ! _add_service "$svc_type" "$svc_version" "$svc_db" "$custom_ports_str" "$custom_envs_str" \
           "$svc_command" "$svc_post_start" "$svc_db_name" "$svc_db_user"; then
        return 1
      fi
    done <<< "$parsed"

  elif [ -n "$TYPE" ] && [ -n "$VERSION" ]; then
    # Single service via -t -v
    local custom_ports_str="${CUSTOM_PORTS[*]:-}"
    local custom_envs_str=""
    if [ ${#CUSTOM_ENVS[@]} -gt 0 ]; then
      custom_envs_str=$(printf '%s\n' "${CUSTOM_ENVS[@]}")
    fi
    if ! _add_service "$TYPE" "$VERSION" "$WITH_DB" "$custom_ports_str" "$custom_envs_str" \
         "$CUSTOM_COMMAND" "$CUSTOM_POST_START" "$CUSTOM_DB_NAME" "$CUSTOM_DB_USER"; then
      return 1
    fi

  else
    # Interactive: ask for type and version
    local available
    available=$(_available_types)
    while true; do
      read -rp "Product type (${available}): " TYPE
      TYPE="$(_resolve_type "$TYPE")"
      if [ -f "${SCRIPT_DIR}/lib/resolve-${TYPE}.sh" ]; then break; fi
      echo "Error: unsupported type '${TYPE}'. Available: ${available}"
    done
    while true; do
      read -rp "Version: " VERSION
      if [ -n "$VERSION" ]; then break; fi
      echo "Error: version is required."
    done
    read -rp "Include PostgreSQL database? (y/N): " db_answer
    if [[ "$db_answer" =~ ^[yY]$ ]]; then WITH_DB=true; fi
    echo ""

    if ! _add_service "$TYPE" "$VERSION" "$WITH_DB" "" ""; then
      return 1
    fi
  fi

  # Write/update howto
  _write_howto
}

# ============================================================================
# Argument parsing
# ============================================================================

# Save original invocation for howto logging
_ORIGINAL_ARGS="$*"

# Step 1: Extract CASEID and ACTION (first two non-flag args), collect remaining args.
CASEID=""
ACTION=""
REMAINING_ARGS=()

for arg in "$@"; do
  if [ -z "$CASEID" ] && [[ "$arg" != -* ]]; then
    CASEID="${arg// /}"
  elif [ -z "$ACTION" ] && [[ "$arg" != -* ]]; then
    ACTION="$arg"
  else
    REMAINING_ARGS+=("$arg")
  fi
done

# Handle -h anywhere
for arg in "$@"; do
  [ "$arg" = "-h" ] && usage
done

# Step 2: Parse flags based on ACTION context.
TYPE=""
VERSION=""
WITH_DB=false
MULTI_FILE=""
CUSTOM_ENVS=()
CUSTOM_PORTS=()
CUSTOM_COMMAND=""
CUSTOM_POST_START=""
CUSTOM_DB_NAME=""
CUSTOM_DB_USER=""
RM_ALL=false
CONTAINER_NAMES=()
EXEC_CONTAINER=""
EXEC_CMD=()

set -- ${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}

case "$ACTION" in
  setup|start)
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) [ -z "${2:-}" ] && { echo "Error: -t requires a value." >&2; usage; }
            TYPE="$(_resolve_type "${2// /}")"; shift 2 ;;
        -v) [ -z "${2:-}" ] && { echo "Error: -v requires a value." >&2; usage; }
            VERSION="${2// /}"; shift 2 ;;
        -i) [ -z "${2:-}" ] && { echo "Error: -i requires an image." >&2; usage; }
            _img="${2// /}"
            _img_name="${_img%%:*}"
            _img_tag="${_img##*:}"
            for _r in "${SCRIPT_DIR}"/lib/resolve-*.sh; do
              [ -f "$_r" ] || continue
              _rtype=$(basename "$_r" | sed 's/^resolve-//; s/\.sh$//')
              if [[ "$_img_name" == *"${_rtype}"* ]] || [[ "$_img_name" == *"sso"* && "$_rtype" == "sso" ]] || [[ "$_img_name" == *"eap"* && "$_rtype" == "eap" ]] || [[ "$_img_name" == *"keycloak"* && "$_rtype" == "rhbk" ]] || [[ "$_img_name" == *"amq"* && "$_rtype" == "amq" ]]; then
                TYPE="$_rtype"
                break
              fi
            done
            VERSION="${_img_tag//-/.}"
            [ -z "$TYPE" ] && { echo "Error: cannot determine product type from image '${2}'." >&2; exit 1; }
            shift 2 ;;
        -d) WITH_DB=true; shift ;;
        -e) [ -z "${2:-}" ] && { echo "Error: -e requires KEY=VALUE." >&2; usage; }
            CUSTOM_ENVS+=("$2"); shift 2 ;;
        -p) [ -z "${2:-}" ] && { echo "Error: -p requires HOST:CONTAINER." >&2; usage; }
            CUSTOM_PORTS+=("$2"); shift 2 ;;
        -c) [ -z "${2:-}" ] && { echo "Error: -c requires a command." >&2; usage; }
            CUSTOM_COMMAND="$2"; shift 2 ;;
        --post-start) [ -z "${2:-}" ] && { echo "Error: --post-start requires a command." >&2; usage; }
            CUSTOM_POST_START="$2"; shift 2 ;;
        --db-name) [ -z "${2:-}" ] && { echo "Error: --db-name requires a value." >&2; usage; }
            CUSTOM_DB_NAME="$2"; shift 2 ;;
        --db-user) [ -z "${2:-}" ] && { echo "Error: --db-user requires a value." >&2; usage; }
            CUSTOM_DB_USER="$2"; shift 2 ;;
        -m) [ -z "${2:-}" ] && { echo "Error: -m requires a JSON file path." >&2; usage; }
            MULTI_FILE="$2"; shift 2 ;;
        *)  echo "Error: unknown flag '${1}' for ${ACTION}." >&2; usage ;;
      esac
    done
    # Validate: -m cannot be combined with inline flags
    if [ -n "$MULTI_FILE" ]; then
      if [ -n "$TYPE" ] || [ -n "$VERSION" ] || [ "$WITH_DB" = "true" ] || [ ${#CUSTOM_ENVS[@]} -gt 0 ] || [ ${#CUSTOM_PORTS[@]} -gt 0 ] \
         || [ -n "$CUSTOM_COMMAND" ] || [ -n "$CUSTOM_POST_START" ] || [ -n "$CUSTOM_DB_NAME" ] || [ -n "$CUSTOM_DB_USER" ]; then
        echo "Error: -m cannot be combined with -t, -v, -d, -e, -p, -c, --post-start, --db-name, --db-user." >&2
        usage
      fi
      if [ ! -f "$MULTI_FILE" ]; then
        echo "Error: multi-service file not found: ${MULTI_FILE}" >&2
        exit 1
      fi
    fi
    ;;
  rm)
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) RM_ALL=true; shift ;;
        -*)   echo "Error: unknown flag '${1}' for rm." >&2; usage ;;
        *)    CONTAINER_NAMES+=("${1// /}"); shift ;;
      esac
    done
    # Validate: --all with container names makes no sense
    if [ "$RM_ALL" = true ] && [ ${#CONTAINER_NAMES[@]} -gt 0 ]; then
      echo "Error: --all cannot be combined with container names." >&2
      usage
    fi
    ;;
  exec)
    # First non-flag arg = container name, rest = command
    if [ $# -lt 2 ]; then
      echo "Error: exec requires CONTAINER and CMD." >&2
      echo "Usage: $(basename "$0") ${CASEID} exec CONTAINER CMD [ARG ...]" >&2
      exit 1
    fi
    EXEC_CONTAINER="${1// /}"; shift
    EXEC_CMD=("$@"); set --
    ;;
  stop|restart|status|logs|healthcheck)
    while [ $# -gt 0 ]; do
      case "$1" in
        -*)  echo "Error: unknown flag '${1}' for ${ACTION}." >&2; usage ;;
        *)   CONTAINER_NAMES+=("${1// /}"); shift ;;
      esac
    done
    ;;
  "") ;;  # no action yet, will be caught below
esac

# ============================================================================
# Dispatch
# ============================================================================

if [ -z "$CASEID" ]; then
  usage
fi

if ! [[ "$CASEID" =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$ ]]; then
  echo "Error: CASEID must be alphanumeric (got '${CASEID}')." >&2
  exit 1
fi

CASE_DIR="${CASE_DIR:-${CASES_DIR}/${CASEID}}"
INITCASEENV_DIR="${CASE_DIR}/${INITCASEENV_SUBDIR}"

if [ -z "$ACTION" ]; then
  echo "Error: command is required." >&2
  case_usage
  exit 1
fi

echo "Case folder: ${CASE_DISPLAY_DIR:-$CASE_DIR}"
echo ""

case "$ACTION" in
  exec)
    do_exec "$EXEC_CONTAINER" "${EXEC_CMD[@]}"
    ;;
  setup)
    ensure_case_folder
    if ! _prepare_services; then
      echo "Setup failed — you can retry."
      exit 1
    fi
    ;;
  start)
    ensure_case_folder
    if [ -n "$TYPE" ] || [ -n "$MULTI_FILE" ] || ! is_initialized; then
      if ! _prepare_services; then
        echo "Setup failed — you can retry."
        exit 1
      fi
    fi
    if ! do_start; then
      exit 1
    fi
    do_health_check
    do_post_start
    if [ "$_POST_START_RAN" = true ]; then do_health_check; fi
    ;;
  stop)
    do_stop ${CONTAINER_NAMES[@]+"${CONTAINER_NAMES[@]}"}
    ;;
  restart)
    do_restart ${CONTAINER_NAMES[@]+"${CONTAINER_NAMES[@]}"}
    if [ ${#CONTAINER_NAMES[@]} -eq 0 ]; then
      do_health_check
      do_post_start && do_health_check
    fi
    ;;
  status)
    do_status ${CONTAINER_NAMES[@]+"${CONTAINER_NAMES[@]}"}
    ;;
  logs)
    do_logs ${CONTAINER_NAMES[@]+"${CONTAINER_NAMES[@]}"}
    ;;
  healthcheck)
    do_health_check ${CONTAINER_NAMES[@]+"${CONTAINER_NAMES[@]}"}
    ;;
  rm)
    do_rm "$RM_ALL" ${CONTAINER_NAMES[@]+"${CONTAINER_NAMES[@]}"}
    ;;
  *)
    echo "Error: unknown action '${ACTION}'." >&2
    usage
    ;;
esac
