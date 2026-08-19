# SSHFS mount and unmount helpers for interactive Bash and Zsh shells

for _mnt_public_name in mnt umnt; do
  unalias "$_mnt_public_name" 2>/dev/null || :
done
unset _mnt_public_name

_mnt_error() {
  printf 'mnt: %s\n' "$*" >&2
}

_mnt_require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    _mnt_error "$1 is not installed"
    return 1
  fi
}

_mnt_require_allow_other() {
  if [ ! -r /etc/fuse.conf ] ||
    ! command grep -Eq '^[[:space:]]*user_allow_other[[:space:]]*(#.*)?$' /etc/fuse.conf; then
    _mnt_error "allow_other requires an enabled 'user_allow_other' line in /etc/fuse.conf"
    return 1
  fi
}

_mnt_prepare_mount_point() {
  local mount_point parent user
  mount_point="$1"
  user=$(id -un) || return 1

  if [ -e "$mount_point" ] && [ ! -d "$mount_point" ]; then
    _mnt_error "mount point is not a directory: $mount_point"
    return 1
  fi

  if [ ! -e "$mount_point" ]; then
    parent=$(dirname -- "$mount_point") || return 1
    while [ ! -e "$parent" ]; do
      [ "$parent" = / ] && break
      parent=$(dirname -- "$parent") || return 1
    done
    if [ ! -d "$parent" ] || [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
      _mnt_error "cannot create mount point: $mount_point"
      _mnt_error "create it and grant user '$user' access before retrying"
      return 1
    fi
    command mkdir -p -- "$mount_point" || {
      _mnt_error "failed to create mount point: $mount_point"
      return 1
    }
  fi

  if [ ! -w "$mount_point" ] || [ ! -x "$mount_point" ]; then
    _mnt_error "user '$user' needs write access to mount point: $mount_point"
    return 1
  fi
}

_mnt_config_file() {
  if [ -n "${XDG_CONFIG_HOME-}" ]; then
    printf '%s/mnt/mnt.conf\n' "$XDG_CONFIG_HOME"
  elif [ -n "${HOME-}" ]; then
    printf '%s/.config/mnt/mnt.conf\n' "$HOME"
  else
    _mnt_error "neither XDG_CONFIG_HOME nor HOME is set"
    return 1
  fi
}

_mnt_read_shortcuts() {
  local file
  file=$(_mnt_config_file) || return 1
  [ -e "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    _mnt_error "configuration is not a readable regular file: $file"
    return 1
  fi
  _mnt_require awk || return 1

  command awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function fail(message) {
      printf "mnt: %s:%d: %s\n", FILENAME, NR, message > "/dev/stderr"
      failed = 1
      exit 1
    }
    function emit() {
      if (name == "") return
      if (host_count != 1 || host == "")
        fail("shortcut \047" name "\047 requires one non-empty host")
      if (remote_count != 1 || remote_path == "")
        fail("shortcut \047" name "\047 requires one non-empty remote_path")
      if (mount_count != 1 || mount_point == "")
        fail("shortcut \047" name "\047 requires one non-empty mount_point")
      print name
      print host
      print remote_path
      print mount_point
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^[#;]/) next

      if (line ~ /^\[[A-Za-z0-9._-]+\]$/) {
        emit()
        name = substr(line, 2, length(line) - 2)
        if (seen[name]++) fail("duplicate shortcut: " name)
        host = remote_path = mount_point = ""
        host_count = remote_count = mount_count = 0
        next
      }

      equals = index(line, "=")
      if (equals) {
        if (name == "") fail("setting appears before a shortcut section")
        key = trim(substr(line, 1, equals - 1))
        value = trim(substr(line, equals + 1))
        if (key == "host") {
          if (host_count++) fail("duplicate host in shortcut \047" name "\047")
          host = value
        } else if (key == "remote_path") {
          if (remote_count++) fail("duplicate remote_path in shortcut \047" name "\047")
          remote_path = value
        } else if (key == "mount_point") {
          if (mount_count++) fail("duplicate mount_point in shortcut \047" name "\047")
          mount_point = value
        } else {
          fail("unknown setting: " key)
        }
        next
      }

      fail("expected a section, setting, or comment")
    }
    END {
      if (!failed) emit()
    }
  ' "$file"
}

_mnt_find_shortcut() {
  local wanted records name host remote_path mount_point
  wanted="$1"
  records=$(_mnt_read_shortcuts) || return 1

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    IFS= read -r host || return 1
    IFS= read -r remote_path || return 1
    IFS= read -r mount_point || return 1
    if [ "$name" = "$wanted" ]; then
      printf '%s\n%s\n%s\n' "$host" "$remote_path" "$mount_point"
      return 0
    fi
  done <<EOF
$records
EOF

  return 2
}

_mnt_shortcut_state() {
  local host remote_path mount_point source filesystem
  host="$1"
  remote_path="$2"
  mount_point="$3"

  source=$(command findmnt -n -M "$mount_point" -o SOURCE 2>/dev/null) || {
    printf 'inactive\n'
    return 0
  }
  filesystem=$(command findmnt -n -M "$mount_point" -o FSTYPE 2>/dev/null) || {
    printf 'occupied\n'
    return 0
  }

  if [ "$filesystem" = fuse.sshfs ] && [ "$source" = "$host:$remote_path" ]; then
    printf 'active\n'
  else
    printf 'occupied\n'
  fi
}

_mnt_list_shortcuts() {
  local filter heading records name host remote_path mount_point state shown
  filter="$1"
  heading="$2"
  _mnt_require findmnt || return 1
  records=$(_mnt_read_shortcuts) || return 1

  printf '%s\n' "$heading"
  shown=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    IFS= read -r host || return 1
    IFS= read -r remote_path || return 1
    IFS= read -r mount_point || return 1
    state=$(_mnt_shortcut_state "$host" "$remote_path" "$mount_point") || return 1
    if [ -z "$filter" ] || [ "$state" = "$filter" ]; then
      printf '  %-16s %-8s %s:%s -> %s\n' "$name" "$state" "$host" "$remote_path" "$mount_point"
      shown=$((shown + 1))
    fi
  done <<EOF
$records
EOF

  [ "$shown" -gt 0 ] || printf '  (none)\n'
}

_mnt_usage() {
  printf '%s\n' \
    'Usage: mnt <shortcut>' \
    '   or: mnt <host> <remote_path> <mount_point>'
}

_umnt_usage() {
  printf 'Usage: umnt <shortcut_or_mount_point>\n'
}

mnt() {
  local shortcut host remote_path mount_point resolved status unmount_target

  if [ "$#" -eq 1 ] && [ "$1" = --help ]; then
    _mnt_usage
    return 0
  fi

  if [ "$#" -eq 0 ]; then
    _mnt_usage
    printf '\n'
    _mnt_list_shortcuts '' 'Shortcuts:'
    return 1
  fi

  shortcut=
  case "$#" in
    1)
      shortcut="$1"
      if resolved=$(_mnt_find_shortcut "$shortcut"); then
        host=${resolved%%$'\n'*}
        resolved=${resolved#*$'\n'}
        remote_path=${resolved%%$'\n'*}
        mount_point=${resolved#*$'\n'}
      else
        status=$?
        [ "$status" -eq 2 ] && _mnt_error "unknown shortcut: $shortcut"
        return 1
      fi
      ;;
    3)
      host="$1"
      remote_path="$2"
      mount_point="$3"
      ;;
    *)
      _mnt_usage >&2
      return 1
      ;;
  esac

  _mnt_require sshfs || return 1
  _mnt_require findmnt || return 1
  _mnt_require grep || return 1
  if command findmnt -n -M "$mount_point" >/dev/null 2>&1; then
    _mnt_error "mount point is already in use: $mount_point"
    return 1
  fi
  _mnt_require_allow_other || return 1
  _mnt_prepare_mount_point "$mount_point" || return 1

  if ! command sshfs "$host:$remote_path" "$mount_point" \
    -o "allow_other,uid=$(id -u),gid=$(id -g)"; then
    return 1
  fi

  printf 'Mounted %s:%s -> %s\n' "$host" "$remote_path" "$mount_point"
  if [ -n "$shortcut" ]; then
    unmount_target="$shortcut"
  else
    unmount_target="$mount_point"
  fi
  printf 'Unmount with: umnt %s\n' "$unmount_target"
}

umnt() {
  local target resolved status filesystem unmounter

  if [ "$#" -eq 1 ] && [ "$1" = --help ]; then
    _umnt_usage
    return 0
  fi

  if [ "$#" -eq 0 ]; then
    _umnt_usage
    _mnt_list_shortcuts active 'Active shortcuts:'
    return 1
  fi
  if [ "$#" -ne 1 ]; then
    _umnt_usage >&2
    return 1
  fi

  target="$1"
  case "$target" in
    */*) ;;
    *)
      if resolved=$(_mnt_find_shortcut "$target"); then
        target=${resolved##*$'\n'}
      else
        status=$?
        [ "$status" -eq 2 ] || return 1
      fi
      ;;
  esac

  _mnt_require findmnt || return 1
  filesystem=$(command findmnt -n -M "$target" -o FSTYPE 2>/dev/null) || {
    _mnt_error "not a mount point: $target"
    return 1
  }
  if [ "$filesystem" != fuse.sshfs ]; then
    _mnt_error "not an SSHFS mount: $target"
    return 1
  fi

  if command -v fusermount3 >/dev/null 2>&1; then
    unmounter=$(command -v fusermount3)
    command "$unmounter" -u "$target" || return 1
  elif command -v fusermount >/dev/null 2>&1; then
    unmounter=$(command -v fusermount)
    command "$unmounter" -u "$target" || return 1
  elif command -v umount >/dev/null 2>&1; then
    unmounter=$(command -v umount)
    command "$unmounter" "$target" || return 1
  else
    _mnt_error "no supported unmount utility is installed"
    return 1
  fi

  printf 'Unmounted %s\n' "$target"
}
