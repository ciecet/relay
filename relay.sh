#!/bin/sh
# relay: socket switch for the relay SSH account.
# (Relay, not connect: this script creates nothing itself, it only
#  forwards Muse's stdin/stdout to a socket pc-relay already provides.)
#
# Intended use (public server side).
# Install this file as /home/relay/bin/relay on the public server.
# Layer 1 - login shell, in /etc/passwd (root-owned, so the relay
# account itself cannot change it; do NOT use nologin/false here,
# sshd runs every session through this shell):
#   relay:x:<uid>:<gid>::/home/relay:/home/relay/bin/relay
#   (password field locked: '!' or '*', key auth only)
# Layer 2 - forced commands, in /home/relay/.ssh/authorized_keys
# (two keys, two duties; neither key can do the other's job):
#     command="/home/relay/bin/relay",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <Muse public key>
#     command="/home/relay/bin/register",no-agent-forwarding,no-X11-forwarding,no-pty <PC public key>
#   CRITICAL: the PC key must NOT have restrict or
#   no-port-forwarding. restrict implies no-port-forwarding, and
#   the PC script's -R tunnel IS port forwarding: with restrict,
#   sshd refuses every -R request with "remote port forwarding
#   failed", and pc-relay.sh retries forever to no effect. The
#   Muse key keeps restrict (it never needs forwarding); the PC
#   key allows forwarding because its whole job is the tunnel.
#   Do NOT set a per-user sshd_config AllowTcpForwarding no for
#   relay either: Match is per-user, not per-key, so it would
#   block the PC key's tunnel just as surely as restrict does.
# No blanket sshd_config ForceCommand in this two-key design: a
# "Match User relay / ForceCommand /home/relay/bin/relay" would
# override the register key's forced command too, and register
# would never run. Layers 1+2 are the complete design.
# Layers 1+2 stack: sshd then runs "relay -c /home/relay/bin/relay"
# with SSH_ORIGINAL_COMMAND set, and this script prefers the env
# var, so the -c wrapper is ignored. Layer 1 alone is NOT enough
# for internal-sftp: sshd handles that subsystem in-process and
# never reaches the login shell. Layer 2 (or 3) is what blocks
# sftp/scp, because a forced command supersedes shell, command
# AND subsystem execution. restrict/no-port-forwarding alone do
# NOT block sftp/scp; they only block forwarding and pty.
#   (restrict already implies no-pty, no-port-forwarding,
#   no-agent-forwarding and no-X11-forwarding; listing them is
#   explicit documentation, not a second mechanism.)
# Client side, use -T as well, e.g.:
#   ssh -T -i ~/.ssh/<agent-key> relay@<public> <name>
# PTY: the server side is the enforcement point. authorized_keys
# no-pty (inside restrict) makes sshd refuse any pty request, so
# this script always gets plain pipes even if the client forgets
# -T. -T is still the right client default: it stops the client
# from requesting a pty in the first place, instead of asking for
# one and having the server refuse it. Plain pipes are what a
# socket relay wants: no echo, no CRLF translation, no
# bracketed-paste / prompt-redraw noise.
#
# How it works:
#   1. Muse SSHs to the relay account, optionally with one argument:
#        ssh relay@<public>            -> default socket
#        ssh relay@<public> <name>     -> socket named <name>
#      sshd puts that argument in SSH_ORIGINAL_COMMAND. This script
#      ignores everything else about the request; it never runs a
#      shell for Muse and never evaluates Muse input.
#   2. The script looks up <name> in $XDG_RUNTIME_DIR/relay, one
#      info file per socket, written by register only (see
#      register.sh). The runtime directory is per-user (700) and
#      is created by pam_systemd on login; no /tmp, no fallback.
#   3. It connects Muse's stdin/stdout to that connection and execs
#      the connector, so this script process becomes the connection.
#
# Security properties (must hold on the public server):
#   - This script is /home/relay/bin/relay, owned by the personal
#     account or root, mode 755. The relay account may read and
#     execute it, never write it, and /home/relay/bin is not
#     writable by relay.
#   - Connection info lives in $XDG_RUNTIME_DIR/relay, owned by
#     the relay account (that is what register needs in order to
#     publish). This script never writes there; it only reads.
#     The runtime directory is removed by logind when the last
#     relay session closes, which is the backup cleanup for a
#     register session that died without removing its file; the
#     primary cleanup is register's own trap on exit.
#   - A name is only [A-Za-z0-9_-]+, so it cannot contain a slash,
#     a space, or shell metacharacters, and cannot escape the dir.
#   - Connection info is never evaluated as shell code. It is
#     parsed with a case statement and passed as separate arguments.
#   - TCP targets are restricted to localhost. A Unix socket target
#     must be an absolute path to an existing socket.
#
# Connection info file format (one file per name, one line):
#   unix:/path/to/socket
#   tcp:127.0.0.1:PORT
#   tcp:::1:PORT
# Lines starting with '#' and empty lines are ignored; the first
# non-empty, non-comment line wins. Anything else is an error.
#
# Defaults (override with environment, only for testing):
#   RELAY_CONNECTIONS_DIR : connection info directory, normally
#                          $XDG_RUNTIME_DIR/relay
#   RELAY_DEFAULT_NAME    : name used when no argument is given
#
# Exit codes: 2 = bad name / bad info / XDG_RUNTIME_DIR unset,
#             3 = connection info missing,
#             otherwise the connector's exit status (via exec).

set -u

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    printf 'relay: XDG_RUNTIME_DIR is not set\n' >&2
    exit 2
fi
CONNECTIONS_DIR="${RELAY_CONNECTIONS_DIR:-$XDG_RUNTIME_DIR/relay}"
DEFAULT_NAME="${RELAY_DEFAULT_NAME:-default}"

die() {
    printf 'relay: %s\n' "$*" >&2
    exit "${2:-2}"
}

# --- 1. Pick the socket name -------------------------------------------
# Invocation forms, in priority order. sshd always runs a session
# through the login shell with -c, so a login shell is just
# another way this script gets called.
#   1. Forced command (authorized_keys command= or ForceCommand):
#      SSH_ORIGINAL_COMMAND holds the client command. It may be
#      empty (no argument -> default). If it is set at all, it is
#      authoritative and any -c wrapper is ignored; this is the
#      stacked shell=relay + command=relay case.
#   2. Login shell only (shell=relay, no forced command):
#      sshd runs "relay -c '<client command>'" for exec, and
#      "relay" with no arguments for a shell request (default).
#      A subsystem request arrives here as -c with the sftp-server
#      path, which fails the name check below. scp arrives as
#      -c "scp -f ..." / "scp -t ...", which is more than one word
#      and is rejected. (internal-sftp never reaches here, see header.)
#   3. No argument at all: default.
# Anything else is rejected. The name is never evaluated as code.
name="$DEFAULT_NAME"
if [ "${SSH_ORIGINAL_COMMAND+x}" = "x" ]; then
    if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
        # shellcheck disable=SC2086
        set -- $SSH_ORIGINAL_COMMAND
        if [ "$#" -ne 1 ]; then
            die "expected zero or one argument, got $#" 2
        fi
        name="$1"
    fi
elif [ "$#" -eq 0 ]; then
    :
elif [ "$#" -eq 2 ] && [ "$1" = "-c" ]; then
    # shellcheck disable=SC2086
    set -- $2
    if [ "$#" -ne 1 ]; then
        die "expected zero or one argument, got $#" 2
    fi
    name="$1"
else
    die "unexpected invocation arguments" 2
fi

case "$name" in
    ''|*[!A-Za-z0-9_-]*)
        die "invalid socket name: '$name'" 2
        ;;
esac
# Defensive length cap (names are short labels, not paths).
if [ "${#name}" -gt 64 ]; then
    die "socket name too long" 2
fi

# --- 2. Read the connection info file ----------------------------------
if [ -L "$CONNECTIONS_DIR" ]; then
    die "connections dir must not be a symlink" 2
fi
info_file="$CONNECTIONS_DIR/$name"
if [ ! -f "$info_file" ]; then
    die "no such socket: '$name'" 3
fi
if [ -L "$info_file" ]; then
    die "connection info must not be a symlink: '$name'" 2
fi

# First non-empty, non-comment line. No eval, no sourcing.
info=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*) continue ;;
    esac
    info="$line"
    break
done < "$info_file"

if [ -z "$info" ]; then
    die "empty connection info: '$name'" 2
fi

# --- 3. Parse and connect (exec replaces this script) -------------------
case "$info" in
    unix:*)
        sock_path="${info#unix:}"
        case "$sock_path" in
            /*) ;;
            *) die "unix socket path must be absolute: '$info'" 2 ;;
        esac
        if [ ! -S "$sock_path" ]; then
            die "unix socket not present: '$sock_path'" 3
        fi
        if command -v socat >/dev/null 2>&1; then
            exec socat - "UNIX-CONNECT:$sock_path"
        elif command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q '\-U'; then
            exec nc -U "$sock_path"
        else
            die "no unix-socket connector available (need socat, or nc with -U)" 2
        fi
        ;;
    tcp:*)
        rest="${info#tcp:}"
        # Host is the part before the last ':', port is after it.
        # This handles 127.0.0.1:PORT and ::1:PORT.
        host="${rest%:*}"
        port="${rest##*:}"
        case "$host" in
            127.0.0.1|::1) ;;
            *) die "tcp target must be localhost: '$info'" 2 ;;
        esac
        case "$port" in
            ''|*[!0-9]*) die "invalid tcp port: '$info'" 2 ;;
        esac
        if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            die "tcp port out of range: '$info'" 2
        fi
        if command -v socat >/dev/null 2>&1; then
            exec socat - "TCP:$host:$port"
        elif command -v nc >/dev/null 2>&1; then
            exec nc "$host" "$port"
        else
            die "no tcp connector available (need socat or nc)" 2
        fi
        ;;
    *)
        die "unknown connection info format: '$info'" 2
        ;;
esac
