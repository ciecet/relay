# relay: persistent SSH relay for a single command

relay is a small, upterm-like relay system. An agent SSHes to a
pre-shared account on a public server; on login, the connection is
automatically tunnelled to a script on the user's machine, which
bridges it to a user-specified command (a shell, an `adb shell`, a
container shell, and so on). The agent cannot change that command.
The preferred transport is plain stdio redirection; a PTY is used
only when a program truly needs a TTY.

This is not a VPN. It is one SSH session to one host, under one
pre-configured account, auditable and revocable. The scope of what
the agent can do is enforced on the user's machine side, by the
command the user chose, not by the agent.

## Architecture

```
agent ──SSH──> relay@public-server ──forced command──> relay.sh
                                                      │
                                                      │ reads
                                                      ▼
                                            $XDG_RUNTIME_DIR/relay/<name>
                                            tcp:127.0.0.1:<remote-port>
                                                      │
                                                      │ socat / tunnel
                                                      ▼
PC: ssh -R 127.0.0.1:<remote-port>:127.0.0.1:<local-port>
    socat listener on 127.0.0.1:<local-port> ──fork──> <cmd>
```

- The agent connects to a socket by name, or to `default` with no
  argument: `ssh -T relay@<public-server> <name>`.
- The PC publishes a socket by name with one SSH connection that
  carries both the reverse tunnel and the registration.
- Only the remote port is published. The local port never leaves
  the PC.

## Files

| File | Installs as | Runs on |
| --- | --- | --- |
| `relay.sh` | `/home/relay/bin/relay` | Public server, relay account |
| `register.sh` | `/home/relay/bin/register` | Public server, relay account, PC key only |
| `pc-relay.sh` | `~/bin/relay` (or anywhere on PATH) | PC, user's own account |

After cloning, make the scripts executable where they will run:

```sh
chmod +x relay.sh register.sh pc-relay.sh
```

The snapshot that uploads these files does not preserve file
modes, so this step is needed after a fresh clone.

## Server setup

Create a dedicated account, named for its sole function, not for
any particular agent. Its login shell is `relay.sh` itself.

Layer 1 — login shell, in `/etc/passwd` (root-owned, so the relay
account itself cannot change it; do NOT use `nologin`/`false`,
sshd runs every session through the login shell):

```
relay:x:<uid>:<gid>::/home/relay:/home/relay/bin/relay
```

The password field must be locked (`!` or `*`); key auth only.
`/home/relay/bin` must not be writable by the relay account.

Layer 2 — forced commands, in `/home/relay/.ssh/authorized_keys`
(two keys, two duties; neither key can do the other's job):

```
command="/home/relay/bin/relay",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <agent public key>
command="/home/relay/bin/register",no-agent-forwarding,no-X11-forwarding,no-pty <PC public key>
```

Critical details:

- The PC key must NOT have `restrict` or `no-port-forwarding`.
  `restrict` implies `no-port-forwarding`, and the PC script's
  `-R` tunnel IS port forwarding: with `restrict`, sshd refuses
  every `-R` request with "remote port forwarding failed".
  The agent key keeps `restrict`; it never needs forwarding.
- Do NOT set a per-user `sshd_config` `AllowTcpForwarding no`
  for the relay account: `Match` is per-user, not per-key, so it
  would block the PC key's tunnel just as surely as `restrict`.
- Do NOT set a blanket `Match User relay / ForceCommand`. It
  would override the register key's forced command too, and
  registration would never run. Layers 1+2 are the complete
  design.
- A forced command supersedes shell, command, and subsystem
  execution, so it blocks `scp`/`sftp`. The login shell alone
  would NOT block internal-sftp, which sshd handles in-process
  and never reaches the shell.

`relay.sh` accepts all three invocations and prefers
`SSH_ORIGINAL_COMMAND` when present: a forced command, a
`-c <name>` shell invocation, and no arguments (default socket).
A socket name is only `[A-Za-z0-9_-]+`, at most 64 characters.

## PC setup

Prerequisites on the PC: `bash`, `socat`, `ssh`.

`~/.ssh/config` needs a Host entry named `relay` that reaches
the relay server with the PC key, for example:

```
Host relay
  HostName <public-server-hostname>
  User relay
  IdentityFile ~/.ssh/<pc-relay-key>
```

Usage:

```
relay [-n <name>] [<cmd> [args...]]
relay -n container docker exec -i mycontainer /bin/bash
relay adb shell
relay bash
relay            # no command, defaults to sh
```

With no `-n`, the socket name is `default`.

## Ports

Local and remote ports are independent numbers, both in
20000-39999, and both are picked by `pc-relay.sh`. They must be
separate: the PC running the script can itself be the relay
server (same host, same loopback namespace), where a shared
number would always collide with the local listener when sshd
binds the remote port. Only the remote port is published.

`register.sh` validates the same range and the name format,
writes `$XDG_RUNTIME_DIR/relay/<name>` atomically (temp file
plus rename in the same directory) with one line,
`tcp:127.0.0.1:<port>`, prints `registered <name>
tcp:127.0.0.1:<port>`, then blocks until the SSH connection
ends. There is no `/tmp` fallback: if `XDG_RUNTIME_DIR` is
unset, registration fails.

## No PTY, plain pipes

Both sides use `-T` and the server enforces `no-pty`. The
agent therefore gets plain pipes, not a terminal: no echo, no
CRLF translation, no bracketed-paste or prompt-redraw noise.
That is deliberate, and it is also why the cleanup mechanism
below is needed.

## PC terminal log

`pc-relay.sh` logs every connection to its own terminal, line
by line, in order, through a shared log file:

- Input: `<< [<elapsed>] <line>`, where `<elapsed>` is seconds
  since this relay process started, in dmesg style: 3 decimal
  places, seconds padded to 4 digits, for example
  `<< [   0.045] echo hi`. The column stays fixed until 9999
  seconds. The absolute start time is printed once at relay
  start, so elapsed plus start gives absolute time if needed.
- Output: plain, with no prefix, exactly as the command printed
  it.

Input is logged before it is forwarded, so an input line always
precedes its own output in the log. Forwarding is line-buffered,
like the log: a partial line (no trailing newline yet) reaches
the command only at newline or EOF, and a final partial line
gains a trailing newline when forwarded. That is fine for shell
commands, which are the intended use; single-character
interactive programs were already out of scope because there is
no PTY.

## Cleanup and same-name handling

These are the two behaviours that are easiest to get wrong
with a no-PTY exec session, and both are handled here.

### Why a naive register leaks

Kernel `SIGHUP` on disconnect is a PTY mechanism: the PTY
master closes, and the kernel sends `SIGHUP` to the session
leader. With no PTY, that mechanism does not exist, and sshd
does not kill a non-PTY exec child on disconnect; it just exits
its own session process, leaving the register process orphaned
(PPID becomes 1) and still blocked on sleep, forever, with the
info file still published. The register script deliberately
does not read stdin, because the PC ssh stdin is `/dev/null`,
so stdin EOF is not a disconnect signal either.

`register.sh` therefore detects disconnect itself: it polls
its parent with `ps -o ppid=` every 5 seconds (the `$PPID`
shell variable does NOT update after reparenting, so `ps`
must be used) and exits when it has been reparented to init
(PPID 1). A connection file may therefore remain for up to
about 5 seconds after the PC relay stops; that delay is
expected, not a leak.

### Same-name sockets

If an info file for the same name already exists, the new
register checks whether its port is still listening, using
`ss`, not a connect probe (connecting would fork a command
copy on the PC):

- Live port: the new register rejects with `already in use`
  (exit 3) and leaves the existing file untouched.
- Dead port or malformed file: stale, and the new register
  takes over by replacing the file.

Reject is by port liveness, not by file existence alone:
cleanup cannot be guaranteed for `SIGKILL` or power loss, so
file-existence reject would block restarts forever on a stale
file. `pc-relay.sh` aborts immediately on `already in use`;
it does not retry with another remote port, because the name
is live, not the port.

Cleanup only deletes the info file if this register published
it and the file still contains its own port. Without both
checks, an old register exiting late would delete a new
register's file for the same name.

Upgrading from a version without these checks: stop the
running relays first, then `SIGKILL` any old leaked register
processes. `SIGTERM` would run their unconditional cleanup
and could delete a current file; `SIGKILL` bypasses the trap.
Only then start new relays.

## Limitations

- Input forwarding is line-buffered, as above.
- Simultaneous connections are supported: each connection
  forks a fresh copy of the command. Expected use is one
  connection at a time.
- The relay server's `ss` tool is required for the
  same-name liveness check, and `ps` for the parent polling.
- No credentials, keys, hostnames, or other deployment
  specifics are stored in this repository. Replace every
  `<...>` placeholder with your own values when you deploy.
