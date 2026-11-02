#!/bin/bash
# relay pc-relay: publish a local command as a relay socket.
#
# Install this file as ~/bin/relay (or anywhere on PATH) on the PC.
# It is NOT the server-side relay.sh; that one runs on the relay
# server under the relay account. This one runs on the PC, under
# the user's own account, and publishes a command to the server.
#
# Usage:
#   relay [-n <name>] [<cmd> [args...]]
#   relay -n container docker exec -i mycontainer /bin/bash
#   relay adb shell
#   relay bash
#   relay            (no command -> sh)
# With no -n, the socket name is "default". The name is only
# [A-Za-z0-9_-]+, at most 64 chars. With no command, the default
# command is sh.
#
# Prerequisites (on the PC):
#   - bash, socat, ssh (this script assumes all three).
#   - ~/.ssh/config with a Host entry named "relay" that reaches
#     the relay server with the PC key, e.g.:
#       Host relay
#         HostName <public-server-hostname>
#         User relay
#         IdentityFile ~/.ssh/<pc-relay-key>
#     That key's authorized_keys entry on the server must be:
#       command="/home/relay/bin/register",no-agent-forwarding,no-X11-forwarding,no-pty
#     (the PC key can only register; it cannot connect to sockets,
#     and the Muse key can only connect, never register).
#     Do NOT put restrict / no-port-forwarding on the PC key:
#     restrict implies no-port-forwarding, and this script's -R
#     tunnel is port forwarding, so sshd would refuse it with
#     "remote port forwarding failed" on every retry. The Muse
#     key, by contrast, must keep restrict.
#
# How it works:
#   1. Pick a local port and a remote port INDEPENDENTLY, both in
#      20000-39999 (the range register.sh allows), and start a
#      local socat listener on 127.0.0.1:<local_port>. Each
#      incoming connection forks a fresh copy of <cmd>: socat
#      connects the tunnelled socket to the command's
#      stdin/stdout/stderr. <cmd> is executed directly (no shell
#      parsing of its arguments); for a pipeline, pass an explicit
#      shell, e.g. relay bash -c '...'.
#      The two ports MUST be separate, not the same number: the
#      PC running this script can itself be the relay server
#      (same host, same loopback namespace), in which case a
#      shared number would always collide with the local listener
#      when sshd tries to bind the remote port. Separate numbers
#      also let several relay instances run on one PC, each with
#      its own local and remote port.
#   2. Open one ssh connection to the relay server with a reverse
#      tunnel and the register command in the same connection:
#        ssh -T -R 127.0.0.1:<remote_port>:127.0.0.1:<local_port> \
#            relay "register <name> <remote_port>"
#      Only the remote port is published (that is what relay.sh
#      on the server connects to); the local port never leaves
#      the PC. The tunnel and the registration live and die
#      together: when this ssh connection ends, register.sh
#      removes the info file, and logind removes the runtime
#      directory when the last relay session closes.
#   3. Wait until register.sh prints "registered ..." (read from
#      the ssh session's stdout), then print a banner and wait
#      until the ssh connection ends or the user presses Ctrl-C.
#
# Visibility (in/out on the terminal):
#   Every connection is logged to this terminal, line by line,
#   in order, through a shared log file tailed by this script:
#     << [<elapsed>] <line>  input: every line that arrived
#                       via the relay, each with its own <<
#                       prefix and bracketed elapsed time,
#                       dmesg-style: seconds since this relay
#                       process started, 3 decimal places,
#                       seconds padded to 4 digits, e.g.
#                       << [   0.045] echo hi
#                       The column stays fixed until 9999
#                       seconds (2h46m), which covers a relay
#                       session; relay is not a long-running
#                       daemon, so absolute dates per line
#                       would be waste. The absolute start
#                       time is printed once, at relay start,
#                       so elapsed + start = absolute if needed.
#     <plain>            output: a line the command sent back,
#                       with no prefix, exactly as the command
#                       printed it
#   Only input is prefixed, so the command's output stays clean
#   and readable, while relay input still stands out. Prefixing
#   EVERY input line (not just the first) matters because a
#   single relay input need not be one line: a multi-line
#   command would otherwise blend into its own output.
#   << was chosen over a name prefix (e.g. relay>) because it
#   marks direction per line, like socat's < / > markers, and
#   is greppable. Change INPUT_PREFIX below (one place) if a
#   different marker is wanted; it must not contain & or /
#   (it is inside a double-quoted echo argument in the
#   wrapper), and it should stay short.
#   Trade-off, stated plainly: input is line-buffered by the
#   read loop, and forwarding follows the same rule: a partial
#   input line (no trailing newline yet) neither appears in
#   the log nor reaches the command until its newline arrives
#   (or EOF, when it is forwarded with a newline added). The
#   log write happens before the forward, so an input line
#   always precedes its own output in the log. Output is NOT
#   line-buffered: tee writes command output to the log as
#   bytes arrive, so a prompt with no trailing newline still
#   shows immediately, plain.
#
# Simultaneous connections:
#   socat's fork means each Muse connection runs a fresh copy of
#   <cmd>. That is possible and supported, but expected use is
#   one connection at a time.
#
# Ctrl-C:
#   Ends this script, kills the listener and the ssh connection,
#   which ends register.sh on the server and removes the info
#   file. ServerAliveInterval/CountMax also end a dead tunnel
#   (about 90s after a network drop) instead of hanging forever.
#
# Exit codes: 2 = bad usage / bad name / missing tool,
#             1 = could not publish (ssh or listener failure),
#             130 = interrupted with Ctrl-C.

set -u

PROG="relay"
INPUT_PREFIX='<< '

# Start time, captured once at relay start: absolute time is
# printed once below, and input log lines use elapsed time
# since here (shared across connections, so the shared log
# has one timeline). Times are integer milliseconds since
# epoch, computed with bash builtins when available.
if [ -n "${EPOCHREALTIME:-}" ]; then
    _start_now="$EPOCHREALTIME"
    _start_sec="${_start_now%.*}"
    _start_frac="${_start_now#*.}"
    while [ "${#_start_frac}" -lt 3 ]; do _start_frac="${_start_frac}0"; done
    START_MS=$((10#$_start_sec * 1000 + 10#${_start_frac:0:3}))
    printf -v START_STR '%(%Y/%m/%d %H:%M:%S)T' "$_start_sec"
    START_STR="$START_STR.${_start_frac:0:3}"
else
    START_MS=$(date +%s%3N)
    START_STR=$(date '+%Y/%m/%d %H:%M:%S.%3N')
fi
printf '%s: started at %s\n' "$PROG" "$START_STR"

usage() {
    printf 'usage: %s [-n <name>] [<cmd> [args...]]\n' "$PROG" >&2
    printf '  -n <name>  socket name (default: default)\n' >&2
    printf '  no command defaults to sh\n' >&2
    printf '  -h         show this help\n' >&2
}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit "${2:-2}"
}

name="default"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n)
            [ "$#" -ge 2 ] || die "option -n needs an argument"
            name="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown option: '$1'"
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -ge 1 ]; then
    cmd=("$@")
else
    cmd=("sh")
fi

case "$name" in
    ''|*[!A-Za-z0-9_-]*)
        die "invalid socket name: '$name'"
        ;;
esac
if [ "${#name}" -gt 64 ]; then
    die "socket name too long"
fi

command -v socat >/dev/null 2>&1 || die "socat is required"
command -v ssh >/dev/null 2>&1 || die "ssh is required"

# --- Temp dir + cleanup ---------------------------------------------------
tmpdir="$(mktemp -d)" || die "cannot create temp dir"
conn_wrapper="$tmpdir/conn-wrapper"
log="$tmpdir/relay.log"
ssh_out="$tmpdir/ssh.out"
ssh_err="$tmpdir/ssh.err"
listener_pid=""
ssh_pid=""
tail_pid=""
local_port=""
remote_port=""

cleanup() {
    if [ -n "${ssh_pid:-}" ]; then
        kill "$ssh_pid" 2>/dev/null || true
    fi
    if [ -n "${listener_pid:-}" ]; then
        kill "$listener_pid" 2>/dev/null || true
    fi
    if [ -n "${tail_pid:-}" ]; then
        kill "$tail_pid" 2>/dev/null || true
    fi
    rm -rf "$tmpdir" 2>/dev/null || true
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

# Connection wrapper: one Muse connection. socat EXEC takes a
# single file, so the command and its arguments are embedded here
# (quoted with %q, so arguments with spaces stay intact), which
# avoids socat's comma/space parsing of a command line entirely.
# stdin/stdout of this wrapper are the socket (via socat).
# Data flow, per connection:
#   socket stdin -> a serialized read loop: for EVERY line, it
#     first appends "<< [<elapsed>] <line>" to the shared log,
#     and only then forwards the line to the command's stdin
#     via a FIFO. Logging before forwarding is what guarantees
#     input-before-output order in the log: the old parallel
#     tee design let a fast command's output beat its own
#     input's log line (the input path spawned date per line).
#   command stdout+stderr -> tee -> (a) the socket, plain,
#     (b) the shared log, plain.
# Socket stdin is saved to fd 3 first (exec 3<&0): a background
# job in a non-interactive bash gets /dev/null as stdin (job
# control off), so the input loop MUST take its stdin from fd 3
# explicitly, or it reads EOF at once and the command sees
# nothing. That was the FIFO-wrapper bug: the input tee died
# instantly, not a FIFO open race. The command and the output
# tee close fd 3 (3<&-) so they do not hold the socket open.
# The input loop holds the FIFO writer open (fd 4) for the
# whole connection, so the command does not see EOF between
# lines; fd 4 closes only when the loop ends (socket EOF).
# Time uses bash builtins only (EPOCHREALTIME), no per-line
# date fork, so the serialized loop costs well under 1ms per
# line. Elapsed time is computed from start_ms, which is set
# once per relay process (see top of this script), not per
# connection, so the shared log has one timeline.
# Trade-off, stated plainly: forwarding is now line-buffered,
# like the log already was. A partial line (no newline yet)
# reaches the command only at newline or EOF, and a final
# partial line gains a trailing newline when forwarded. That
# is fine for shell commands, which are the intended use;
# single-character interactive programs were already out of
# scope (no PTY). Cross-connection log order is still racy:
# serialization guarantees input-before-its-own-output per
# connection, not which connection's line lands first.
# The output tee runs in the foreground, so when the command
# exits, this wrapper kills the input loop and exits, closing
# the socket, even if Muse's stdin is still open. FIFOs are per
# connection ($$), so concurrent connections do not share them.
# The shared log is tailed by pc-relay.sh itself (below), so
# both directions appear on this terminal, in order.
{
    printf '#!/bin/bash\n'
    printf 'log=%q\n' "$log"
    printf 'prefix=%q\n' "$INPUT_PREFIX"
    printf 'start_ms=%q\n' "$START_MS"
    printf 'base=%q/conn-$$\n' "$tmpdir"
    printf 'mkfifo "$base.in" "$base.out" || exit 1\n'
    printf 'cmd_pid=""\n'
    printf 'input_pid=""\n'
    printf 'cleanup_conn() {\n'
    printf '    [ -n "$input_pid" ] && kill "$input_pid" 2>/dev/null\n'
    printf '    [ -n "$cmd_pid" ] && kill "$cmd_pid" 2>/dev/null\n'
    printf '    rm -f "$base.in" "$base.out"\n'
    printf '}\n'
    printf 'trap cleanup_conn EXIT\n'
    printf 'trap "exit 0" HUP TERM INT\n'
    printf '# save socket stdin: background jobs get /dev/null stdin\n'
    printf 'exec 3<&0\n'
    printf '# command (background, stdin/out via FIFOs)\n'
    printf ' %q' "${cmd[@]}"
    printf ' < "$base.in" > "$base.out" 2>&1 3<&- &\n'
    printf 'cmd_pid=$!\n'
    printf '# input forwarder (background subshell, stdin from fd 3)\n'
    printf '# Serialized: log first, then forward. Lines below are\n'
    printf '# emitted with %%s, so %% signs in them are data, not formats.\n'
    printf '%s\n' '( exec 4>"$base.in"'
    printf '%s\n' '  while IFS= read -r _line || [ -n "$_line" ]; do'
    printf '%s\n' '    if [ -n "${EPOCHREALTIME:-}" ]; then'
    printf '%s\n' '      _now="${EPOCHREALTIME}"; _now_sec="${_now%.*}"; _now_frac="${_now#*.}"'
    printf '%s\n' '      while [ ${#_now_frac} -lt 3 ]; do _now_frac="${_now_frac}0"; done'
    printf '%s\n' '      _now_ms=$((10#$_now_sec * 1000 + 10#${_now_frac:0:3}))'
    printf '%s\n' '    else'
    printf '%s\n' '      _now_ms=$(date +%s%3N)'
    printf '%s\n' '    fi'
    printf '%s\n' '    _elapsed=$(( _now_ms - start_ms ))'
    printf '%s\n' '    _esec=$(( _elapsed / 1000 )); _ems=$(( _elapsed % 1000 ))'
    printf '%s\n' '    printf "%s[%4d.%03d] %s\n" "$prefix" "$_esec" "$_ems" "$_line" >> "$log"'
    printf '%s\n' '    printf "%s\n" "$_line" >&4'
    printf '%s\n' '  done <&3'
    printf '%s\n' '  exec 4>&- ) &'
    printf 'input_pid=$!\n'
    printf '# output forwarder (foreground, plain to socket and log)\n'
    printf 'tee -a "$log" < "$base.out" 3<&-\n'
} > "$conn_wrapper" || die "cannot write connection wrapper"
chmod 700 "$conn_wrapper" || die "cannot chmod connection wrapper"

# Shared log + tail: tail prints log appends to this terminal.
# Started before the listener, so no connection is missed.
: > "$log" || die "cannot create log"
tail -n 0 -f "$log" &
tail_pid=$!

# --- Publish, with port retries ------------------------------------------
# Local port first, on its own retry loop: the tunnel must never
# forward to a port with nothing listening on it, and a local
# bind failure has nothing to do with the remote port.
for _ in $(seq 1 20); do
    local_port=$((20000 + RANDOM % 20000))
    socat "TCP-LISTEN:$local_port,bind=127.0.0.1,reuseaddr,fork" \
        "EXEC:$conn_wrapper" </dev/null &
    listener_pid=$!
    sleep 0.3
    if kill -0 "$listener_pid" 2>/dev/null; then
        break
    fi
    listener_pid=""
done
[ -n "$listener_pid" ] || die "could not bind a local port" 1

# Remote port on its own retry loop: a remote bind failure only
# restarts ssh with a new remote port. The listener stays up the
# whole time, so its local port does not change across retries.
published=""
for attempt in 1 2 3 4 5; do
    remote_port=$((20000 + RANDOM % 20000))

    ssh -T -o BatchMode=yes -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R "127.0.0.1:$remote_port:127.0.0.1:$local_port" \
        relay "register $name $remote_port" \
        >"$ssh_out" 2>"$ssh_err" </dev/null &
    ssh_pid=$!

    # Wait up to 10s for register.sh's confirmation line, or for
    # ssh to exit early (e.g. remote port already in use).
    registered=""
    for _ in $(seq 1 100); do
        if grep -q "^registered $name " "$ssh_out" 2>/dev/null; then
            registered="yes"
            break
        fi
        if ! kill -0 "$ssh_pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if [ -n "$registered" ]; then
        published="yes"
        break
    fi

    # Failed attempt: show the ssh error, then decide whether a
    # different remote port could help. Auth / host-key failures
    # never will, so abort instead of retrying into a lockout.
    # "already in use" also never will: the name is live, not
    # the port, so another remote port would fail the same way.
    if grep -q 'already in use' "$ssh_err" 2>/dev/null; then
        printf '%s: socket %s already in use, not retrying:\n' "$PROG" "$name" >&2
        cat "$ssh_err" >&2
        exit 1
    fi
    if grep -Eq 'Permission denied|Host key verification failed|Authentication failed|publickey' "$ssh_err" 2>/dev/null; then
        printf '%s: ssh failed (not retrying):\n' "$PROG" >&2
        cat "$ssh_err" >&2
        exit 1
    fi
    if [ -s "$ssh_err" ]; then
        printf '%s: ssh attempt %s failed, retrying with another remote port:\n' "$PROG" "$attempt" >&2
        cat "$ssh_err" >&2
    fi
    kill "$ssh_pid" 2>/dev/null || true
    ssh_pid=""
    : >"$ssh_out"
    : >"$ssh_err"
done

[ -n "$published" ] || die "could not publish socket '$name'" 1

printf '%s: published socket %s (remote port %s, local port %s)\n' "$PROG" "$name" "$remote_port" "$local_port"
printf '%s: command: %s\n' "$PROG" "${cmd[*]}"
printf '%s: log: input lines are << [<elapsed>] <line>, output is plain\n' "$PROG"
printf '%s: press Ctrl-C to stop\n' "$PROG"

# --- Wait until ssh or the listener ends ----------------------------------
while kill -0 "$ssh_pid" 2>/dev/null && kill -0 "$listener_pid" 2>/dev/null; do
    sleep 1
done

if ! kill -0 "$listener_pid" 2>/dev/null; then
    printf '%s: local listener ended\n' "$PROG" >&2
fi
if ! kill -0 "$ssh_pid" 2>/dev/null; then
    printf '%s: register connection ended\n' "$PROG" >&2
    if [ -s "$ssh_err" ]; then
        cat "$ssh_err" >&2
    fi
fi
# cleanup runs via the EXIT trap.
exit 0
