# sshfs mount/unmount helpers
# Source this from .bashrc

# Shortcuts: name → source_path, mount_point
declare -A _MNT_SHORTCUTS=()

mnt() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: mnt <[user@]host> <source_path> <mount_point>"
        echo "   or: mnt <[user@]host> <shortcut>"
        echo ""
        echo "Shortcuts:"
        for k in "${!_MNT_SHORTCUTS[@]}"; do
            IFS=: read -r src dst <<< "${_MNT_SHORTCUTS[$k]}"
            printf "  %-10s %s → %s\n" "$k" "$src" "$dst"
        done
        return 1
    fi

    local hostarg="$1"
    # Add default user if no @ present
    [[ "$hostarg" != *@* ]] && hostarg="$(id -un)@$hostarg"

    local src dst
    if [[ $# -eq 2 && -n "${_MNT_SHORTCUTS[$2]}" ]]; then
        IFS=: read -r src dst <<< "${_MNT_SHORTCUTS[$2]}"
    elif [[ $# -ge 3 ]]; then
        src="$2"
        dst="$3"
    else
        echo "Unknown shortcut: $2"
        mnt
        return 1
    fi

    mkdir -p "$dst"
    sshfs "${hostarg}:${src}" "$dst" -o allow_other,uid=$(id -u),gid=$(id -g)

    if [[ $? -eq 0 ]]; then
        echo "✓ Mounted ${hostarg}:${src} → $dst"
        echo "  Unmount: umnt $dst"
    fi
}

umnt() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: umnt <mount_point>"
        echo "Active sshfs mounts:"
        mount -t fuse.sshfs 2>/dev/null | sed 's/^/  /'
        return 1
    fi
    fusermount3 -u "$1" && echo "✓ Unmounted $1"
}
