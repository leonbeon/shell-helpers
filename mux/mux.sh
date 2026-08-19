# tmux
mux() {
  local cmd="$1"
  local name

  if [ "$cmd" = refresh ]; then
    name="${2:-$(basename "$PWD")}"
    tmux kill-session -t "$name" 2>/dev/null
    tmux new-session -s "$name" -c "$PWD"
  else
    name="${1:-$(basename "$PWD")}"
    tmux new-session -A -s "$name" -c "$PWD"
  fi
}
