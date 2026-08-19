# tmux attach/create helper for interactive Bash and Zsh shells

unalias mux 2>/dev/null || :

_mux_error() {
  printf 'mux: %s\n' "$*" >&2
}

_mux_usage() {
  printf '%s\n' \
    'Usage: mux [session_name]' \
    '       mux --refresh <session_name>' \
    '       mux --ls' \
    '       mux --kill <session_name>'
}

_mux_require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    _mux_error "tmux is not installed"
    return 1
  fi
}

mux() {
  local mode name current_dir

  _mux_require_tmux || return 1
  if [ -n "${TMUX-}" ]; then
    _mux_error "cannot be used from inside tmux"
    return 1
  fi

  case "${1-}" in
    --refresh)
      if [ "$#" -ne 2 ] || [ -z "$2" ]; then
        _mux_usage >&2
        return 1
      fi
      mode=refresh
      name="$2"
      ;;
    --ls)
      if [ "$#" -ne 1 ]; then
        _mux_usage >&2
        return 1
      fi
      command tmux list-sessions
      return
      ;;
    --kill)
      if [ "$#" -ne 2 ] || [ -z "$2" ]; then
        _mux_usage >&2
        return 1
      fi
      command tmux kill-session -t "$2"
      return
      ;;
    -*)
      _mux_error "unknown option: $1"
      _mux_usage >&2
      return 1
      ;;
    *)
      if [ "$#" -gt 1 ]; then
        _mux_usage >&2
        return 1
      fi
      mode=attach
      name="${1-}"
      ;;
  esac

  current_dir=$(pwd -P) || {
    _mux_error "cannot determine the current directory"
    return 1
  }
  [ -n "$name" ] || name=$(basename -- "$current_dir") || return 1

  if [ "$mode" = refresh ]; then
    if command tmux has-session -t "$name" 2>/dev/null; then
      command tmux kill-session -t "$name" || return 1
    fi
    command tmux new-session -s "$name" -c "$current_dir"
  else
    command tmux new-session -A -s "$name" -c "$current_dir"
  fi
}
