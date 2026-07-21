# mlisp

A collection of small, REPL-first networking tools written in Common Lisp for macOS.

The repository currently contains two related experiments:

- **[`vpn/`](vpn/)** — a minimal TUN-based VPN controller that drives `sing-box` and `tun2socks` from a Common Lisp REPL.
- **Speed test UI** — a local web UI and command-line tooling for testing and ranking `vless://` and `ss://` configurations by measured throughput and stability.

This is a personal, macOS-focused systems-programming project, not a polished end-user VPN product. Use it only after reading the implementation and setup notes.

## Why this exists

Most VPN clients hide the mechanics behind a GUI. This project takes the opposite approach: it makes process supervision, routing, TUN setup, and recovery behavior explicit and inspectable from a Lisp REPL.

The interesting part is not proxy protocol implementation—`sing-box` and `xray-core` do that—but safely coordinating the operating-system pieces around them.

## VPN controller

[`vpn/`](vpn/) routes system traffic through this pipeline:

```text
system traffic
  → TUN interface
  → tun2socks
  → local SOCKS5 inbound
  → sing-box outbound
  → proxy server
```

Highlights:

- Controls `sing-box`, `tun2socks`, TUN setup, and route changes from Common Lisp.
- Keeps the proxy server outside the TUN route to prevent routing loops.
- Uses a watcher thread to detect proxy failures and network changes, then reconnect or safely fall back to a direct connection.
- Supports pools of VLESS and Shadowsocks servers with failover.
- Detaches the unprivileged `sing-box` process so a REPL crash or closed terminal does not automatically tear down an established tunnel.
- Places privileged actions behind a deliberately narrow, root-owned C helper rather than granting broad passwordless `sudo` access.
- Stores and restores the original default gateway inside that helper, keeping route swap and rollback together.

The complete setup, security model, configuration examples, and known caveats are documented in **[`vpn/README.md`](vpn/README.md)** (currently in Russian).

## Configuration speed tests

The top-level Lisp files implement a local speed-test service:

1. Fetch a text list of `vless://` and `ss://` configuration URIs.
2. Filter configurations with a raw TCP connectivity check.
3. Start a temporary local `xray-core` SOCKS5 instance for each candidate.
4. Download test files through it, measure throughput and stability, and rank the results.
5. Stream progress and results to a small browser UI using Server-Sent Events.

It can test several configurations concurrently and can keep test traffic outside an active system VPN, so results reflect the physical network path rather than recursively traversing the tunnel being managed.

Main files:

| File | Purpose |
| --- | --- |
| [`speedtest-configs.lisp`](speedtest-configs.lisp) | URI parsing, temporary `xray-core` configuration, connectivity and throughput testing |
| [`speedweb.lisp`](speedweb.lisp) | Local HTTP server and SSE progress stream |
| [`index.html`](index.html) / [`index.js`](index.js) | Browser UI |
| [`io.lisp`](io.lisp) | Input helpers |

## Requirements

The project targets **macOS** and assumes a working Common Lisp environment (developed with SBCL). Depending on the component, it also uses:

- [`sing-box`](https://sing-box.sagernet.org/)
- [`tun2socks`](https://github.com/xjasonlyu/tun2socks)
- [`xray-core`](https://github.com/XTLS/Xray-core)
- `curl`, `setsid`, and standard macOS networking tools
- a C compiler for the privileged VPN helper

See [`vpn/README.md`](vpn/README.md) and [`vpn/priv/README.md`](vpn/priv/README.md) before installing the helper or changing `sudoers`.

## Status and safety

- Experimental and built for one macOS environment.
- No installer, package manager integration, CI, or compatibility promise yet.
- VPN route management changes the system default route and requires a carefully scoped privileged helper. Review the source and the `sudoers` instructions before use.
- Do not commit subscription URLs, server credentials, private keys, or local configuration files.

## Repository layout

```text
.
├── vpn/                     # TUN VPN controller and documentation
│   └── priv/                # narrow root helper written in C
├── speedtest-configs.lisp   # configuration test runner
├── speedweb.lisp            # local web server
├── index.html               # speed-test UI
├── index.js                 # browser client
└── io.lisp                  # shared input helpers
```
