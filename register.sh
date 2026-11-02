#!/bin/sh
# relay register: publish one socket for the relay account.
#
# Install this file as /home/relay/bin/register on the public server,
# next to relay.sh. It is the forced command for the PC key only:
#   command="/home/relay/bin/register",no-agent-forwarding,no-X11-forwarding,no-pty <PC public key>
# NOTE: no restrict and no no-port-forwarding on this key. The PC
# script's -R tunnel is port forwarding, and restrict would make
# sshd refuse it ("remote port forwarding failed") on every
# attempt. Only the Muse key gets restrict.
# The Muse key's forced command is relay.sh, never this script, so
# Muse can connect to a published socket but cannot publish one.
#
# How it is used (from the PC, by pc-relay.sh):
#   ssh -T -R 127.0.0.1:<port>:127.0.0.1:<port> relay \
#       "register <name> <port>"
# sshd replaces the client command with this script and puts the
# client command in SSH_ORIGINAL_COMMAND. This script:
#   1. Validates the command: exactly "register <name> <port>".
#   2. If an info file for the same name already exists, checks
#      whether its port is still listening (ss, not a connect
#      probe: connecting would fork a command copy on the PC).
#      Live port -> rejects with "already in use" (exit 3) and
#      leaves the existing file untouched. Dead port -> stale,
#      takes over by replacing the file (the normal
#      restart-after-crash case). Reject is by port liveness,
#      not by file existence alone: cleanup cannot be
#      guaranteed for SIGKILL / power loss, so file-existence
#      reject would block restarts forever on a stale file.
#      Writes $XDG_RUNTIME_DIR/relay/<name> with one line:
#        tcp:127.0.0.1:<port>
#      atomically, via a temp file + mv in the same directory.
#   3. Prints "registered <name> tcp:127.0.0.1:<port>" to stdout
#      so the PC script knows publication succeeded, then blocks
#      until the ssh connection ends.
#   4. On exit, removes the info file, but only if it still
#      contains this register's own port AND this register
#      actually published it. An old register exiting late
#      (e.g. after a new register took over a stale name) must
#      not delete the new register's file. The runtime directory
#      itself is removed by logind when the last relay session
#      closes, which is only a backup: if a Muse session is
#      still open, the directory survives, but the tunnel is
#      dead, so a later Muse connection to the stale port
#      simply fails to connect.
#
# Security properties (must hold on the public server):
#   - This script is owned by the personal account or root, mode
#     755. The relay account may read and execute it, never write
#     it, and /home/relay/bin is not writable by relay.
#   - The name is only [A-Za-z0-9_-]+, at most 64 chars, so it
#     cannot contain a slash, a space, or shell metacharacters,
#     and cannot escape the connections directory.
#   - The port must be numeric and in 20000-39999. Publishing an
#     arbitrary localhost port (e.g. 22, or another service) is
#     refused. pc-relay.sh picks its port from the same range.
#   - Client input is never evaluated as shell code. It is parsed
#     with a case statement and positional parameters only.
#   - This script never runs the published command itself; it only
#     publishes the tunnel port. The command runs on the PC, under
#     pc-relay.sh's socat listener, when Muse connects.
#   - No pty is needed or wanted: the PC script uses ssh -T, and
#     the authorized_keys entry has explicit no-pty.
#
# Exit codes: 2 = bad command / bad name / bad port /
#                 XDG_RUNTIME_DIR unset / ss missing.
#             3 = socket name already in use (live port).
#             Otherwise this script blocks until the connection
#             ends, then exits 0 after removing the info file.

set -u

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    printf 'register: XDG_RUNTIME_DIR is not set\n' >&2
    exit 2
fi

die() {
    printf 'register: %s\n' "$*" >&2
    exit 2
}

# --- 1. Parse SSH_ORIGINAL_COMMAND -------------------------------------
# Must be set (forced command). Empty or anything else is rejected.
if [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then
    die "expected 'register <name> <port>'"
fi
# shellcheck disable=SC2086
set -- $SSH_ORIGINAL_COMMAND
if [ "$#" -ne 3 ]; then
    die "expected 'register <name> <port>', got $# words"
fi
if [ "$1" != "register" ]; then
    die "unknown register command: '$1'"
fi
name="$2"
port="$3"

case "$name" in
    ''|*[!A-Za-z0-9_-]*)
        die "invalid socket name: '$name'"
        ;;
esac
if [ "${#name}" -gt 64 ]; then
    die "socket name too long"
fi
case "$port" in
    ''|*[!0-9]*) die "invalid tcp port: '$port'" ;;
esac
if [ "$port" -lt 20000 ] || [ "$port" -gt 39999 ]; then
    die "tcp port out of allowed range 20000-39999: '$port'"
fi

# --- 2. Publish ----------------------------------------------------------
CONNECTIONS_DIR="$XDG_RUNTIME_DIR/relay"
mkdir -p "$CONNECTIONS_DIR" || die "cannot create $CONNECTIONS_DIR"
if [ -L "$CONNECTIONS_DIR" ]; then
    die "connections dir must not be a symlink"
fi
info_file="$CONNECTIONS_DIR/$name"
tmp_file="$CONNECTIONS_DIR/.${name}.tmp.$$"

# Reject-if-live, before any trap that could delete the file:
# if an existing file points at a still-listening port, the
# old relay is live, so this register must not overwrite it
# and must not touch it on exit. A file pointing at a dead
# port, a malformed file, or no file at all is stale, and
# this register takes over below. ss is used, not a connect
# probe, so a live check does not fork a command on the PC.
if [ -f "$info_file" ]; then
    old_content="$(cat "$info_file" 2>/dev/null || true)"
    old_port="${old_content#tcp:127.0.0.1:}"
    case "$old_port" in
        ''|*[!0-9]*)
            # Malformed: not a live tunnel, treat as stale.
            old_port=""
            ;;
    esac
    if [ -n "$old_port" ]; then
        command -v ss >/dev/null 2>&1 || die "ss is required to check liveness"
        if ss -ltn "sport = :$old_port" 2>/dev/null | grep -q "127\.0\.0\.1:$old_port"; then
            printf "register: socket '%s' already in use (tcp:127.0.0.1:%s is listening)\n" "$name" "$old_port" >&2
            exit 3
        fi
    fi
fi

# Cleanup only deletes the info file if this register
# published it and the file still contains its own port.
# Without both checks, an old register exiting late would
# delete a new register's file for the same name.
published=""
cleanup() {
    rm -f "$tmp_file"
    if [ "$published" = "yes" ]; then
        current_content="$(cat "$info_file" 2>/dev/null || true)"
        if [ "$current_content" = "tcp:127.0.0.1:$port" ]; then
            rm -f "$info_file"
        fi
    fi
}
trap cleanup EXIT
# Kill the background sleep as well, so a signal to this script
# alone still ends the block promptly instead of waiting for a
# foreground sleep to finish.
trap 'kill $sleep_pid 2>/dev/null; exit 0' HUP TERM INT

printf 'tcp:127.0.0.1:%s\n' "$port" > "$tmp_file" \
    || die "cannot write $tmp_file"
chmod 644 "$tmp_file" || die "cannot chmod $tmp_file"
mv "$tmp_file" "$info_file" || die "cannot publish $info_file"
published="yes"

printf 'registered %s tcp:127.0.0.1:%s\n' "$name" "$port"

# --- 3. Block until the ssh connection ends -----------------------------
# Background sleep + wait, not a foreground sleep: a foreground
# sleep would defer the trap until it finished when only this
# script, not its whole process group, gets the signal.
# Do not read stdin: stdin belongs to the ssh session, not to
# this script, and the PC ssh stdin is /dev/null, so stdin EOF
# is not a disconnect signal either.
#
# Why the loop polls the parent (2026-11-01, root cause):
# This is a notty exec session (sshd-session relay@notty, no
# PTY, no controlling terminal). Kernel SIGHUP on disconnect
# is a PTY mechanism: PTY master closes -> kernel sends SIGHUP
# to the session leader. With no PTY, that mechanism does not
# exist, and sshd does not kill a non-PTY exec child on
# disconnect; it just exits its own session process, leaving
# this script orphaned (PPID becomes 1) and still blocked on
# sleep, forever, with the info file still published. That was
# observed on the server: many leaked registers with PPID=1,
# each with a sleep 86400 child, while only the live one had
# a sshd parent. So this script must detect the disconnect
# itself, by polling its parent: when the parent is gone and
# this script has been reparented to init (PPID 1), the ssh
# connection is over, and this script exits (cleanup runs
# via the EXIT trap).
# The $PPID shell variable does NOT update after reparenting
# (tested: it keeps the old value, while ps -o ppid= shows 1),
# so the check must use ps, not $PPID. The initial parent is
# recorded first: if this script was already orphaned at
# start (initial parent 1), polling cannot detect a later
# death, so it does not exit on the first check.
# Poll interval is 5s: leak cleanup latency is at most 5s,
# and one ps fork per 5s is negligible for an idle script.
initial_ppid="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')"
sleep_pid=""
while :; do
    sleep 5 &
    sleep_pid=$!
    wait $sleep_pid || true
    if [ "$initial_ppid" != "1" ] && [ -n "$initial_ppid" ]; then
        current_ppid="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')"
        if [ "$current_ppid" = "1" ]; then
            exit 0
        fi
    fi
done
