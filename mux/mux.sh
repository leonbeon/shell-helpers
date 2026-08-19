# tmux attach/create helper for interactive Bash and Zsh shells

unalias mux 2>/dev/null || :

_mux_error() {
  printf 'mux: %s\n' "$*" >&2
}

_mux_usage() {
  printf '%s\n' \
    'Usage: mux [session_name]' \
    '   or: mux refresh [session_name]'
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

  current_dir=$(pwd -P) || {
    _mux_error "cannot determine the current directory"
    return 1
  }

  mode=attach
  if [ "${1-}" = refresh ]; then
    mode=refresh
    if [ "$#" -gt 2 ]; then
      _mux_usage >&2
      return 1
    fi
    name="${2:-$(basename -- "$current_dir")}"
  else
    if [ "$#" -gt 1 ]; then
      _mux_usage >&2
      return 1
    fi
    name="${1:-$(basename -- "$current_dir")}"
  fi

  if [ "$mode" = refresh ]; then
    if command tmux has-session -t "$name" 2>/dev/null; then
      command tmux kill-session -t "$name" || return 1
    fi
    command tmux new-session -s "$name" -c "$current_dir"
  else
    command tmux new-session -A -s "$name" -c "$current_dir"
  fi
}
