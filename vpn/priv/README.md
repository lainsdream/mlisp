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

## Commands

- `start-tun utunN` / `stop-tun` — run/stop tun2socks, PID tracked in
  `/var/run/lisp-vpn-tun2socks.pid`.
- `assign-tun utunN` — bring the TUN interface up with the fixed tunnel IP.
- `setup-routes proxy-IPv4` — the whole route transaction, atomically owned
  by the helper: capture the current default gateway itself, persist it,
  add a host route for `proxy-IPv4` via that gateway (so proxy traffic
  itself doesn't get pulled into the tunnel), then point the default route
  at the TUN interface. Any step failing after the gateway is captured
  rolls back everything already done and clears the captured state, so a
  failed `setup-routes` never leaves the machine half-configured.
- `teardown-routes proxy-IPv4` — the inverse: read back the captured
  gateway, restore it as the default route, remove the proxy host route,
  and clear the captured-gateway state — unconditionally, even if
  restoring the route itself failed (e.g. the gateway isn't reachable
  because the network changed underneath the tunnel). A failed
  `teardown-routes` still leaves the helper ready for the next
  `setup-routes`, it just also tells you the route wasn't actually
  restored so you can check `route -n get default` by hand.

## Boundaries and deliberate limitations

- The helper can modify the default route and one IPv4 host route; that is its
  necessary job, but it cannot execute arbitrary programs as root.
- It only allows `utun` followed by digits, one fixed **root-owned** tun2socks
  binary, the fixed local SOCKS endpoint, and IPv4 arguments parsed by `inet_pton`.
- It stores the tun2socks PID in `/var/run/lisp-vpn-tun2socks.pid`. A stale PID
  file must be inspected and removed manually if the machine rebooted or the
  process died unexpectedly.
- It stores the captured original gateway in `/var/run/lisp-vpn-original-gw`,
  written with `O_EXCL` — a second `setup-routes` without an intervening
  `teardown-routes` refuses outright rather than overwriting it (that would
  risk capturing the _tunnel's_ gateway as if it were the original one). If
  the machine crashed or rebooted mid-tunnel and this file is stale, inspect
  `route -n get default` and remove the file by hand before the next
  `setup-routes`.
- The caller (Lisp) never sees or passes a gateway address anywhere in this
  interface — it can't hand the helper a stale or forged one, because it
  never holds one in the first place. This was the "next hardening step"
  from the previous version of this document; it's now done.
