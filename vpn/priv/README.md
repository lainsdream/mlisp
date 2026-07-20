# Narrow sudo wrapper for lisp-vpn

This replaces the unsafe sudoers grant for `setsid`, `route`, `ifconfig`, and
`kill`. The helper accepts a small fixed command vocabulary, validates all
variable arguments, invokes only fixed absolute-path binaries, and never
passes data through a shell.

## Build and install — macOS

Review the source first, then run:

```sh
clang -Wall -Wextra -Werror -O2 lisp-vpn-priv.c -o lisp-vpn-priv
sudo install -d -o root -g wheel -m 0755 /usr/local/libexec
sudo install -o root -g wheel -m 0755 lisp-vpn-priv /usr/local/libexec/lisp-vpn-priv
# Copy the real tun2socks executable from its package-managed location.
# Do not let the root helper execute a Homebrew/user-writable binary in place.
sudo install -o root -g wheel -m 0755 /usr/local/bin/tun2socks \
  /usr/local/libexec/lisp-vpn-tun2socks
```

The helper deliberately executes `/usr/local/libexec/lisp-vpn-tun2socks`, a
root-owned copy. Substitute your actual package-managed `tun2socks` path only
in the _source_ argument to `install`; do not change the helper to execute a
binary from a user-writable Homebrew prefix.

## sudoers

Use `sudo visudo` and grant only the helper:

```sudoers
your_username ALL=(root) NOPASSWD: /usr/local/libexec/lisp-vpn-priv
```

Remove the previous entries for `setsid`, `/sbin/route`, `/sbin/ifconfig`, and
`kill`. A `NOPASSWD` permission for generic `setsid` is equivalent to an
arbitrary root command launcher.

## Boundaries and deliberate limitations

- The helper can modify the default route and one IPv4 host route; that is its
  necessary job, but it cannot execute arbitrary programs as root.
- It only allows `utun` followed by digits, one fixed **root-owned** tun2socks
  binary, the fixed local SOCKS endpoint, and IPv4 arguments parsed by `inet_pton`.
- It stores the tun2socks PID in `/var/run`. A stale PID file must be inspected
  and removed manually if the machine rebooted or the process died unexpectedly.
- This is not yet an atomic network transaction. The next hardening step is to
  have the helper capture and persist the original route, then perform setup and
  rollback itself.
