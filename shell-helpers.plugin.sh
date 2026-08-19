# Oh My Bash plugin loader

_shell_helpers_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1

source "$_shell_helpers_dir/docker/docker.sh" || return 1
source "$_shell_helpers_dir/mux/mux.sh" || return 1
source "$_shell_helpers_dir/mnt/mnt.sh" || return 1

unset _shell_helpers_dir
