# docker
dlogs() {
  if [ -z "$1" ]; then set -- "$(basename "$PWD")"; fi
  docker logs -f "$1"
}

dbuild() {
  if [ -z "$1" ]; then set -- "$(basename "$PWD")"; fi
  docker compose build "$1"
}

drecreate() {
  if [ -z "$1" ]; then set -- "$(basename "$PWD")"; fi
  docker compose up -d --force-recreate "$1"
}

drm() {
  if [ -z "$1" ]; then set -- "$(basename "$PWD")"; fi
  docker stop "$1" && docker rm "$1"
}

dexec() {
  local folder cmd
  folder=$(basename "$PWD")
  if [ -n "$1" ]; then
    cmd="$1"
    shift
  fi
  if [ -n "$1" ]; then
    folder="$1"
  fi
  eval "docker exec -it $folder $cmd"
}

drebuild() {
  if [ -z "$1" ]; then set -- "$(basename "$PWD")"; fi
  dbuild "$1" && drecreate "$1"
}
