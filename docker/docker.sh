# Docker and Docker Compose helpers for interactive Bash and Zsh shells

for _docker_public_name in dlogs dbuild drecreate drm dexec drebuild; do
  unalias "$_docker_public_name" 2>/dev/null || :
done
unset _docker_public_name

_docker_error() {
  printf 'docker: %s\n' "$*" >&2
}

_docker_require() {
  if ! command -v docker >/dev/null 2>&1; then
    _docker_error "docker is not installed"
    return 1
  fi
}

_docker_require_compose() {
  _docker_require || return 1
  if ! command docker compose version >/dev/null 2>&1; then
    _docker_error "the modern 'docker compose' plugin is not available"
    return 1
  fi
}

_docker_canonical_file() {
  local path dir base
  path="$1"

  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac

  dir=$(dirname -- "$path") || return 1
  base=$(basename -- "$path") || return 1
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || {
    _docker_error "cannot access Compose file directory: $dir"
    return 1
  }
  path="$dir/$base"

  if [ ! -f "$path" ]; then
    _docker_error "Compose file not found: $path"
    return 1
  fi

  printf '%s\n' "$path"
}

_docker_find_compose_file() {
  local dir name first separator

  if [ "${COMPOSE_FILE+x}" = x ] && [ -n "${COMPOSE_FILE-}" ]; then
    separator="${COMPOSE_PATH_SEPARATOR-:}"
    first=${COMPOSE_FILE%%"$separator"*}
    _docker_canonical_file "$first"
    return
  fi

  dir=$(pwd -P) || {
    _docker_error "cannot determine the current directory"
    return 1
  }

  while :; do
    for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      if [ -f "$dir/$name" ]; then
        printf '%s\n' "$dir/$name"
        return 0
      fi
    done

    [ "$dir" = / ] && break
    dir=$(dirname -- "$dir") || return 1
  done

  _docker_error "no Compose file found from $PWD upward"
  return 1
}

_docker_env_dir_allowed() {
  local dir
  dir="$1"

  case "$dir" in
    /|/home|/home/*) return 1 ;;
  esac

  [ "$(dirname -- "$dir")" != / ]
}

_docker_compose() {
  local compose_file project_dir parent_dir grandparent_dir candidate resolved base override
  local explicit_compose_file
  local -a env_args file_args

  compose_file="$1"
  shift
  project_dir=$(dirname -- "$compose_file") || return 1
  parent_dir=$(dirname -- "$project_dir") || return 1
  grandparent_dir=$(dirname -- "$parent_dir") || return 1
  env_args=()
  file_args=()

  for candidate in "$grandparent_dir/.env" "$parent_dir/.env" "$project_dir/.env"; do
    _docker_env_dir_allowed "$(dirname -- "$candidate")" || continue
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      resolved=$(readlink -f -- "$candidate") || {
        _docker_error "cannot resolve environment file: $candidate"
        return 1
      }
      _docker_env_dir_allowed "$(dirname -- "$resolved")" || continue
      if [ ! -f "$resolved" ] || [ ! -r "$resolved" ]; then
        _docker_error "environment file is not a readable regular file: $candidate"
        return 1
      fi
      env_args+=(--env-file "$resolved")
    fi
  done

  if [ ${#env_args[@]} -eq 0 ]; then
    env_args+=(--env-file /dev/null)
  fi

  explicit_compose_file=0
  if [ "${COMPOSE_FILE+x}" = x ] && [ -n "${COMPOSE_FILE-}" ]; then
    explicit_compose_file=1
  else
    file_args+=(-f "$compose_file")
    base=$(basename -- "$compose_file") || return 1
    case "$base" in
      compose.*)
        for override in compose.override.yaml compose.override.yml; do
          if [ -f "$project_dir/$override" ]; then
            file_args+=(-f "$project_dir/$override")
            break
          fi
        done
        ;;
      docker-compose.*)
        for override in docker-compose.override.yaml docker-compose.override.yml; do
          if [ -f "$project_dir/$override" ]; then
            file_args+=(-f "$project_dir/$override")
            break
          fi
        done
        ;;
    esac
  fi

  if [ "$explicit_compose_file" -eq 1 ]; then
    command docker compose "${env_args[@]}" "$@"
  else
    (
      cd "$project_dir" || return 1
      command docker compose "${env_args[@]}" "${file_args[@]}" "$@"
    )
  fi
}

_docker_resolve_service() {
  local compose_file policy explicit_hint services service first match project_name count
  compose_file="$1"
  policy="$2"
  explicit_hint="$3"

  services=$(_docker_compose "$compose_file" config --services) || return 1
  first=
  match=
  count=0
  project_name=$(basename -- "$(dirname -- "$compose_file")") || return 1

  while IFS= read -r service; do
    [ -n "$service" ] || continue
    count=$((count + 1))
    [ -n "$first" ] || first="$service"
    [ "$service" = "$project_name" ] && match="$service"
  done <<EOF
$services
EOF

  if [ "$count" -eq 0 ]; then
    _docker_error "the Compose project defines no services"
    return 1
  fi
  if [ -n "$match" ]; then
    printf '%s\n' "$match"
    return 0
  fi
  if [ "$count" -eq 1 ] || [ "$policy" = observational ]; then
    printf '%s\n' "$first"
    return 0
  fi

  _docker_error "multiple Compose services match; specify $explicit_hint explicitly"
  while IFS= read -r service; do
    [ -n "$service" ] && printf '  %s\n' "$service" >&2
  done <<EOF
$services
EOF
  return 1
}

_docker_resolve_container() {
  local policy selector compose_file service containers container first count
  policy="$1"
  selector="$2"

  if [ -n "$selector" ]; then
    if ! command docker container inspect "$selector" >/dev/null; then
      _docker_error "container not found: $selector"
      return 1
    fi
    printf '%s\n' "$selector"
    return 0
  fi

  _docker_require_compose || return 1
  compose_file=$(_docker_find_compose_file) || return 1
  service=$(_docker_resolve_service "$compose_file" "$policy" "a container name or ID") || return 1
  containers=$(_docker_compose "$compose_file" ps -a -q "$service") || return 1
  first=
  count=0

  while IFS= read -r container; do
    [ -n "$container" ] || continue
    count=$((count + 1))
    [ -n "$first" ] || first="$container"
  done <<EOF
$containers
EOF

  if [ "$count" -eq 0 ]; then
    _docker_error "no container exists for Compose service: $service"
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    _docker_error "multiple containers exist for Compose service '$service'; specify a container name or ID"
    while IFS= read -r container; do
      [ -n "$container" ] && printf '  %s\n' "$container" >&2
    done <<EOF
$containers
EOF
    return 1
  fi

  printf '%s\n' "$first"
}

_docker_compose_target() {
  local policy explicit compose_file service
  policy="$1"
  explicit="$2"

  _docker_require_compose || return 1
  compose_file=$(_docker_find_compose_file) || return 1
  if [ -n "$explicit" ]; then
    service="$explicit"
  else
    service=$(_docker_resolve_service "$compose_file" "$policy" "a service") || return 1
  fi

  printf '%s\n%s\n' "$compose_file" "$service"
}

dlogs() {
  local container
  if [ "$#" -gt 1 ]; then
    _docker_error "usage: dlogs [container]"
    return 1
  fi

  _docker_require || return 1
  container=$(_docker_resolve_container observational "${1-}") || return 1
  command docker logs -f "$container"
}

dbuild() {
  local target compose_file service
  if [ "$#" -gt 1 ]; then
    _docker_error "usage: dbuild [service]"
    return 1
  fi

  target=$(_docker_compose_target mutating "${1-}") || return 1
  compose_file=${target%%$'\n'*}
  service=${target#*$'\n'}
  _docker_compose "$compose_file" build "$service"
}

drecreate() {
  local target compose_file service
  if [ "$#" -gt 1 ]; then
    _docker_error "usage: drecreate [service]"
    return 1
  fi

  target=$(_docker_compose_target mutating "${1-}") || return 1
  compose_file=${target%%$'\n'*}
  service=${target#*$'\n'}
  _docker_compose "$compose_file" up -d --force-recreate "$service"
}

drm() {
  local container
  if [ "$#" -gt 1 ]; then
    _docker_error "usage: drm [container]"
    return 1
  fi

  _docker_require || return 1
  container=$(_docker_resolve_container mutating "${1-}") || return 1
  command docker stop "$container" && command docker rm "$container"
}

dexec() {
  local selector container
  selector=

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c|--container)
        if [ "$#" -lt 2 ]; then
          _docker_error "usage: dexec [-c container] [--] [command [arg ...]]"
          return 1
        fi
        selector="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        _docker_error "unknown option: $1"
        return 1
        ;;
      *) break ;;
    esac
  done

  if [ "$#" -eq 0 ]; then
    set -- sh
  fi

  _docker_require || return 1
  container=$(_docker_resolve_container mutating "$selector") || return 1
  if [ -t 0 ] && [ -t 1 ]; then
    command docker exec -it "$container" "$@"
  else
    command docker exec -i "$container" "$@"
  fi
}

drebuild() {
  local target compose_file service
  if [ "$#" -gt 1 ]; then
    _docker_error "usage: drebuild [service]"
    return 1
  fi

  target=$(_docker_compose_target mutating "${1-}") || return 1
  compose_file=${target%%$'\n'*}
  service=${target#*$'\n'}
  _docker_compose "$compose_file" build "$service" &&
    _docker_compose "$compose_file" up -d --force-recreate "$service"
}
