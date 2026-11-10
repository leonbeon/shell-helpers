# Shell Helpers

This is a collection of shell scripts/helpers I use. Works for bash and zsh

## Installation

Clone the repository, then source the tools you want from `~/.bashrc` or `~/.zshrc`:

```sh
git clone https://github.com/leonbeon/shell-helpers.git "$HOME/shell-helpers"

source "$HOME/shell-helpers/docker/docker.sh"
source "$HOME/shell-helpers/mux/mux.sh"
source "$HOME/shell-helpers/mnt/mnt.sh"
```

For [Oh My Bash](https://github.com/ohmybash/oh-my-bash) or [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh), clone the repository as a custom plugin instead:

```sh
# Oh My Bash
git clone https://github.com/leonbeon/shell-helpers.git "$HOME/.oh-my-bash/custom/plugins/shell-helpers"

# Oh My Zsh
git clone https://github.com/leonbeon/shell-helpers.git "$HOME/.oh-my-zsh/custom/plugins/shell-helpers"
```

Add `shell-helpers` to the end of the framework's `plugins` array so its commands take precedence over conflicting aliases:

```sh
plugins=(git shell-helpers)
```

Install Docker with the modern Compose plugin, tmux, and SSHFS separately as needed.

## `docker` helpers

Docker helpers for operating containers directly and services in a Compose project. Commands honor `COMPOSE_FILE` or discover the nearest standard Compose file, then load permitted `.env` files from its directory and up to two parents, with nearer files taking precedence. Environment files at `/`, directly below `/`, or anywhere under `/home` are never inspected.

| Command | Explanation | Example |
| --- | --- | --- |
| `dlogs [container]` | Follows logs, resolving the local Compose container when omitted. | `dlogs traefik` |
| `dbuild [service]` | Builds one Compose service, resolving the local service when omitted. | `dbuild web` |
| `drecreate [service]` | Recreates one Compose service with `--force-recreate`. | `drecreate web` |
| `dup [service]` | Starts or updates one Compose service without forcing recreation. | `dup web` |
| `drm [container]` | Gracefully stops and removes a container. | `drm traefik` |
| `dexec [-c container] [--] [command [arg ...]]` | Runs a command in a container, or opens `sh` when no command is given. | `dexec -c postgres psql -U postgres` |
| `drebuild [service]` | Builds and then recreates one Compose service. | `drebuild web` |

## `mux`

A small tmux session helper for managing named sessions, typically one per project folder. It creates, attaches, lists, refreshes, and kills sessions, and must be run outside tmux. 
I usually use this to manage a tmux session per project folder.

| Command | Explanation | Example |
| --- | --- | --- |
| `mux [session_name]` | Attaches to or creates a session, defaulting to the current directory name. | `mux website` |
| `mux --refresh <session_name>` | Recreates or creates a named session in the current directory, which is useful for reloading shell environment variables. | `mux --refresh website` |
| `mux --ls` | Lists active tmux sessions. | `mux --ls` |
| `mux --kill <session_name>` | Kills a named session. | `mux --kill website` |
| `mux --help` | Prints the command summary. | `mux --help` |

## `mnt`

SSHFS helpers for mounting configured remote directories and safely unmounting them by shortcut or mount point.

Shortcuts live in `${XDG_CONFIG_HOME:-$HOME/.config}/mnt/mnt.conf`:

```ini
[documents]
host = user@example.com
remote_path = /srv/documents
mount_point = /mnt/remote_documents
windows_drive = any

[media]
host = media-server
remote_path = /srv/media
mount_point = /mnt/remote_media
```

Add windows_drive = <letter> or windows_drive = any to a shortcut to also map it as a Windows drive in WSL (see below).  

For mount points under `/mnt`, create the directory once and grant your user write access:

```sh
sudo mkdir -p /mnt/remote_documents
sudo chown "$(id -un):$(id -gn)" /mnt/remote_documents
```

Uncomment or add `user_allow_other` in `/etc/fuse.conf` because the helper uses SSHFS's `allow_other` option.

| Command | Explanation | Example |
| --- | --- | --- |
| `mnt` | Lists configured shortcuts and their state and their Windows drives. | `mnt` |
| `mnt <shortcut>` | Mounts a configured SSHFS shortcut and maps `windows_drive` in WSL (if provided). | `mnt documents` |
| `mnt <host> <remote_path> <mount_point>` | Mounts an explicit SSHFS source. | `mnt server /srv/documents /mnt/documents` |
| `mnt --help` | Prints the mount command summary. | `mnt --help` |
| `umnt` | Lists active configured shortcuts, including leftover Windows drives if applicable. | `umnt` |
| `umnt <shortcut_or_mount_point>` | Unmounts an SSHFS mount by shortcut or path, and removes associated Windows drives. | `umnt documents` |
| `umnt --help` | Prints the unmount command summary. | `umnt --help` |

### Windows drives in WSL

When browsing a mounted drive in Explorer via WSL, previews and thumbnails are slow. That's why, using the `windows_drive` option in the config file, mount points are also mapped as Windows network drives using [SSHFS-Win](https://github.com/winfsp/sshfs-win). How this works:  

- `mnt` maps the drive after mounting, or maps only the drive when the shortcut is already mounted. If mapping fails, the WSL mount is kept and a warning is printed.
- `umnt` removes the drive after unmounting, including a drive left over without its WSL mount. If the WSL mount is busy, both stay.
- `windows_drive = any` picks the first free letter from `Z:` downwards.
- Drives are not restored after a reboot. The `net use` persistence default is left unchanged.

#### One-time setup

One-time setup, replacing `<you>` with your Windows user name:

1. Install [WinFsp](https://winfsp.dev) and SSHFS-Win.
2. SSHFS-Win can neither use your SSH agent nor ask for passphrases, so create a passphrase-less key in your Windows profile:

```sh
ssh-keygen -t ed25519 -N '' -C sshfs-win -f /mnt/c/Users/<you>/.ssh/id_sshfs
```

3. Authorize the key on every remote account you map, restricted to SFTP so it cannot open a shell. The `sftp-server` path depends on the server's distribution (see
`Subsystem` in its `sshd_config`):

```sh
printf 'restrict,command="/usr/lib/openssh/sftp-server" %s\n' "$(cat /mnt/c/Users/<you>/.ssh/id_sshfs.pub)" |
ssh <host> 'cat >> ~/.ssh/authorized_keys'
```

4. Register the `sshfs.mnt` SSHFS-Win service from an elevated command prompt (interactively, not as a batch file):

```bat
set K=HKLM\SOFTWARE\WOW6432Node\WinFsp\Services\sshfs.mnt
reg add %K% /v Executable    /t REG_SZ    /d "C:\Program Files\SSHFS-Win\bin\sshfs-win.exe" /f
reg add %K% /v CommandLine   /t REG_SZ    /d "svc %1 %2 %U -oIdentityFile=/cygdrive/c/Users/<you>/.ssh/id_sshfs -oBatchMode=yes" /f
reg add %K% /v Security      /t REG_SZ    /d "D:P(A;;RPWPLC;;;WD)" /f
reg add %K% /v JobControl    /t REG_DWORD /d 1 /f
reg add %K% /v Credentials   /t REG_DWORD /d 0 /f
reg add %K% /v sshfs.rootdir /t REG_DWORD /d 1 /f
```

`BatchMode=yes` stops SSH from waiting for the passphrase of `id_rsa`, which SSHFS-Win always tries first.

Drives are mapped as `\\sshfs.mnt\user@host[!port]\remote\path`. The user, host, and port come from `ssh -G`, so host aliases from your WSL SSH config work, but other
settings such as `IdentityFile` do not apply. Hosts that need `ProxyJump` or `ProxyCommand` and relative `remote_path` values are not supported. SSHFS-Win disables host
key checking, which is another reason to restrict the key to SFTP.

## Note on AI use

I understand the complicated discussion around AI code in general. For my philosophy, having an AI agent write a semi-private productivity bash tool after having a focused discussion about the use cases with it is fine. This code is not meant to be state of the art or particularly pretty, it's short enough to at least take a glance at it and confirm it is not doing anything malicious, and this was not a one-shot either. AI commits are clearly marked via git author.
