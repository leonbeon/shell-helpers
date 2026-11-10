# SSHFS mount and unmount helpers for interactive Bash and Zsh shells

for _mnt_public_name in mnt umnt; do
  unalias "$_mnt_public_name" 2>/dev/null || :
done
unset _mnt_public_name

_mnt_error() {
  printf 'mnt: %s\n' "$*" >&2
}

_mnt_warn() {
  printf 'mnt: warning: %s\n' "$*" >&2
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
      print (windows_drive == "" ? "-" : windows_drive)
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^[#;]/) next

      if (line ~ /^\[[A-Za-z0-9._-]+\]$/) {
        emit()
        name = substr(line, 2, length(line) - 2)
        if (seen[name]++) fail("duplicate shortcut: " name)
        host = remote_path = mount_point = windows_drive = ""
        host_count = remote_count = mount_count = drive_count = 0
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
        } else if (key == "windows_drive") {
          if (drive_count++) fail("duplicate windows_drive in shortcut \047" name "\047")
          windows_drive = toupper(value)
          sub(/:$/, "", windows_drive)
          if (windows_drive == "ANY")
            windows_drive = "any"
          else if (windows_drive ~ /^[DEFGHIJKLMNOPQRSTUVWXYZ]$/)
            windows_drive = windows_drive ":"
          else
            fail("windows_drive in shortcut \047" name "\047 must be a letter from D to Z or any")
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

# Prints host, remote_path, mount_point, and windows_drive ('-' when unset) of
# the shortcut named $1, or of the shortcut mounted at $1 when $2 is 'path'
_mnt_find_shortcut() {
  local wanted by records name host remote_path mount_point windows_drive
  wanted="$1"
  by="${2-name}"
  [ "$by" = path ] && [ "$wanted" != / ] && wanted=${wanted%/}
  records=$(_mnt_read_shortcuts) || return 1

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    IFS= read -r host || return 1
    IFS= read -r remote_path || return 1
    IFS= read -r mount_point || return 1
    IFS= read -r windows_drive || return 1
    if { [ "$by" = name ] && [ "$name" = "$wanted" ]; } ||
      { [ "$by" = path ] && [ "${mount_point%/}" = "$wanted" ]; }; then
      printf '%s\n%s\n%s\n%s\n' "$host" "$remote_path" "$mount_point" "$windows_drive"
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

# Windows drives mirror shortcuts with windows_drive through SSHFS-Win under WSL.
# Only exit codes and untranslated tokens of Windows tool output are relied on.

_mnt_win_ready() {
  local tool
  if [ -z "${WSL_DISTRO_NAME-}" ] &&
    [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ] &&
    [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]; then
    _mnt_warn "windows_drive is ignored outside WSL"
    return 1
  fi
  for tool in net.exe fsutil.exe reg.exe; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      _mnt_warn "windows_drive requires Windows interop, but $tool is not available"
      return 1
    fi
  done
}

# Runs a Windows tool from a Windows directory so it never starts inside a mount
_mnt_win_run() {
  (
    cd /mnt/c >/dev/null 2>&1 || cd / >/dev/null 2>&1 || exit 1
    command "$@" </dev/null
  )
}

# Converts Windows console output on stdin to indented UTF-8 lines
_mnt_win_text() {
  local codepage
  codepage=$(_mnt_win_run reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage' /v OEMCP 2>/dev/null |
    command tr -d '\r' | command awk '$1 == "OEMCP" { print $3 }')
  if [ -n "$codepage" ] && command -v iconv >/dev/null 2>&1 &&
    command iconv -f "CP$codepage" -t UTF-8 </dev/null >/dev/null 2>&1; then
    command tr -d '\r' | command iconv -f "CP$codepage" -t UTF-8 2>/dev/null
  else
    command tr -d '\r'
  fi | command awk 'NF { print "  " $0 }'
}

# Prints the SSHFS-Win UNC path for host and an absolute remote_path
_mnt_win_unc() {
  local host remote_path settings user hostname port proxy unc_path
  host="$1"
  remote_path="$2"

  case "$remote_path" in
    /*) ;;
    *)
      _mnt_warn "windows_drive requires an absolute remote_path: $remote_path"
      return 1
      ;;
  esac
  settings=$(command ssh -G "$host" </dev/null 2>/dev/null) || {
    _mnt_warn "cannot resolve SSH settings for host: $host"
    return 1
  }
  {
    IFS= read -r user
    IFS= read -r hostname
    IFS= read -r port
    IFS= read -r proxy
  } <<EOF
$(printf '%s\n' "$settings" | command awk '
    $1 == "user" { user = $2 }
    $1 == "hostname" { hostname = $2 }
    $1 == "port" { port = $2 }
    ($1 == "proxyjump" || $1 == "proxycommand") && $2 != "none" { proxy = $1 }
    END { print user; print hostname; print port; print proxy }
  ')
EOF
  if [ -n "$proxy" ]; then
    _mnt_warn "windows_drive does not support hosts using $proxy: $host"
    return 1
  fi
  if [ -z "$user" ] || [ -z "$hostname" ]; then
    _mnt_warn "cannot resolve SSH user and hostname for host: $host"
    return 1
  fi

  unc_path=$(printf '%s\n' "$remote_path" | command sed -e 's#//*#/#g' -e 's#/$##' | command tr '/' '\\')
  if [ -z "$port" ] || [ "$port" = 22 ]; then
    port=
  else
    port='!'$port
  fi
  printf '%s%s@%s%s%s\n' '\\sshfs.mnt\' "$user" "$hostname" "$port" "$unc_path"
}

# Prints drive letters that net use output on stdin maps to the UNC path $1,
# or all mapped drive letters when $1 is empty
_mnt_win_mapped_drives() {
  MNT_UNC="$1" command awk '
    match($0, /(^|[ \t])[A-Za-z]:[ \t]+\\\\/) {
      start = RSTART
      if (substr($0, start, 1) ~ /[ \t]/) start++
      drive = toupper(substr($0, start, 1)) ":"
      rest = substr($0, RSTART + RLENGTH - 2)
      unc = ENVIRON["MNT_UNC"]
      after = substr(rest, length(unc) + 1, 1)
      if (unc == "" || (substr(rest, 1, length(unc)) == unc && (after == "" || after ~ /[ \t]/)))
        print drive
    }
  '
}

# Maps drive $1 (a letter or any) to the UNC path $2; returns 2 if already mapped
_mnt_win_map() {
  local drive unc mappings mapped used letter saved output rc
  drive="$1"
  unc="$2"

  mappings=$(_mnt_win_run net.exe use 2>/dev/null | command tr -d '\r')
  mapped=$(printf '%s\n' "$mappings" | _mnt_win_mapped_drives "$unc" | command head -n 1)
  if [ -n "$mapped" ]; then
    printf 'Windows drive %s already maps %s\n' "$mapped" "$unc"
    return 2
  fi

  used=$({
    _mnt_win_run fsutil.exe fsinfo drives 2>/dev/null | command grep -oE '[A-Za-z]:\\' | command tr -d '\\'
    printf '%s\n' "$mappings" | _mnt_win_mapped_drives ''
  } | command tr '[:lower:]\n' '[:upper:] ')
  if [ "$drive" = any ]; then
    drive=
    for letter in Z Y X W V U T S R Q P O N M L K J I H G F E D; do
      case " $used " in
        *" $letter: "*) ;;
        *)
          drive="$letter:"
          break
          ;;
      esac
    done
    if [ -z "$drive" ]; then
      _mnt_warn "no free Windows drive letter for $unc"
      return 1
    fi
  else
    case " $used " in
      *" $drive "*)
        _mnt_warn "Windows drive $drive is already in use"
        return 1
        ;;
    esac
  fi

  # /persistent:no also changes the default for later net use calls, so restore it
  saved=$(_mnt_win_run reg.exe query 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Network\Persistent Connections' /v SaveConnections 2>/dev/null |
    command tr -d '\r' | command awk '$1 == "SaveConnections" { print tolower($3) }')
  output=$(_mnt_win_run net.exe use "$drive" "$unc" /persistent:no 2>&1)
  rc=$?
  if [ "$saved" != no ] && ! _mnt_win_run net.exe use /persistent:yes >/dev/null 2>&1; then
    _mnt_warn "failed to restore the net use default /persistent:yes"
  fi

  if [ "$rc" -ne 0 ]; then
    _mnt_warn "failed to map Windows drive $drive -> $unc"
    printf '%s\n' "$output" | _mnt_win_text >&2
    if ! _mnt_win_run reg.exe query 'HKLM\SOFTWARE\WinFsp\Services\sshfs.mnt' /reg:32 >/dev/null 2>&1; then
      _mnt_warn "the SSHFS-Win service 'sshfs.mnt' is not registered"
    fi
    return 1
  fi
  printf 'Mapped Windows drive %s -> %s\n' "$drive" "$unc"
}

# Removes every Windows drive mapped to the UNC path $1; returns 2 if none was
_mnt_win_unmap() {
  local unc drives drive output failed
  unc="$1"

  drives=$(_mnt_win_run net.exe use 2>/dev/null | command tr -d '\r' | _mnt_win_mapped_drives "$unc")
  [ -n "$drives" ] || return 2

  failed=0
  while IFS= read -r drive; do
    [ -n "$drive" ] || continue
    if output=$(_mnt_win_run net.exe use "$drive" /delete /y 2>&1); then
      printf 'Removed Windows drive %s\n' "$drive"
    else
      _mnt_warn "failed to remove Windows drive $drive"
      printf '%s\n' "$output" | _mnt_win_text >&2
      failed=1
    fi
  done <<EOF
$drives
EOF
  return "$failed"
}

_mnt_list_shortcuts() {
  local filter heading records name host remote_path mount_point windows_drive state shown
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
    IFS= read -r windows_drive || return 1
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
  local shortcut host remote_path mount_point windows_drive resolved rc unmount_target unc

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
  windows_drive=-
  case "$#" in
    1)
      shortcut="$1"
      if resolved=$(_mnt_find_shortcut "$shortcut"); then
        {
          IFS= read -r host
          IFS= read -r remote_path
          IFS= read -r mount_point
          IFS= read -r windows_drive
        } <<EOF
$resolved
EOF
      else
        rc=$?
        [ "$rc" -eq 2 ] && _mnt_error "unknown shortcut: $shortcut"
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
    # An active shortcut may still lack its Windows drive, so map only that
    if [ "$windows_drive" != - ] &&
      [ "$(_mnt_shortcut_state "$host" "$remote_path" "$mount_point")" = active ] &&
      _mnt_win_ready && unc=$(_mnt_win_unc "$host" "$remote_path"); then
      _mnt_win_map "$windows_drive" "$unc"
      rc=$?
      [ "$rc" -eq 2 ] || return "$rc"
    fi
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
  # The WSL mount stays when the Windows drive fails; warnings explain why
  if [ "$windows_drive" != - ] && _mnt_win_ready &&
    unc=$(_mnt_win_unc "$host" "$remote_path"); then
    _mnt_win_map "$windows_drive" "$unc"
  fi
  if [ -n "$shortcut" ]; then
    unmount_target="$shortcut"
  else
    unmount_target="$mount_point"
  fi
  printf 'Unmount with: umnt %s\n' "$unmount_target"
}

umnt() {
  local target resolved rc filesystem unmounter host remote_path mount_point windows_drive state unc

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
  resolved=
  case "$target" in
    */*)
      # A broken configuration must not prevent unmounting by path
      resolved=$(_mnt_find_shortcut "$target" path 2>/dev/null) || resolved=
      ;;
    *)
      if resolved=$(_mnt_find_shortcut "$target"); then
        :
      else
        rc=$?
        [ "$rc" -eq 2 ] || return 1
        resolved=
      fi
      ;;
  esac
  windows_drive=-
  if [ -n "$resolved" ]; then
    {
      IFS= read -r host
      IFS= read -r remote_path
      IFS= read -r mount_point
      IFS= read -r windows_drive
    } <<EOF
$resolved
EOF
    target="$mount_point"
  fi

  _mnt_require findmnt || return 1
  state=
  [ "$windows_drive" = - ] || state=$(_mnt_shortcut_state "$host" "$remote_path" "$mount_point")
  filesystem=$(command findmnt -n -M "$target" -o FSTYPE 2>/dev/null) || {
    # The Windows drive follows the WSL mount, so remove a leftover one
    if [ "$windows_drive" != - ] && _mnt_win_ready &&
      unc=$(_mnt_win_unc "$host" "$remote_path"); then
      _mnt_win_unmap "$unc"
      rc=$?
      [ "$rc" -eq 2 ] || return "$rc"
    fi
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
  # Only the shortcut's own mount has a Windows drive; failures only warn
  if [ "$state" = active ] && _mnt_win_ready &&
    unc=$(_mnt_win_unc "$host" "$remote_path"); then
    _mnt_win_unmap "$unc"
  fi
  return 0
}
