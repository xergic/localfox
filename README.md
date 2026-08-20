# Localfox

A macOS menu bar app that starts your local development servers and serves them at
stable, trusted HTTPS domains.

Instead of remembering which project owns which port, you open
`https://wishfox.localhost`. Localfox detects the framework, the package manager and the
dev command, starts the server, finds the port it actually bound, and points a bundled
Caddy reverse proxy at it. When the port changes, the domain does not.

Pre-release. Nothing is published yet.

## Requirements

- macOS 15 or newer, Apple Silicon
- [Xcode](https://developer.apple.com/xcode/) 26 or newer
- `brew install xcodegen swiftlint`

Caddy is fetched and checksum-verified into `Vendor/` by the build. You do not install it.

## Build and run

```sh
make run      # regenerate the project, build, relaunch the app
make test     # swift test, the whole kit suite
make detect DIR=~/Projects/wishfox   # run detection headless
make env      # print the resolved login shell environment
make lint     # SwiftLint, must stay clean
make gen      # regenerate Localfox.xcodeproj from project.yml
make caddy    # fetch and verify the pinned Caddy binary
make snapshot # render the UI surfaces to snapshots/
make archive  # ad hoc signed Release app and DMG into dist/
```

## Layout

| Path | Holds |
|---|---|
| `Sources/LocalfoxKit/` | The whole pipeline. No SwiftUI, no AppKit, no UI state. |
| `Sources/localfox-run/` | CLI over the same pipeline. |
| `App/Localfox/` | SwiftUI shell: `AppState`, views, theme. |
| `Helper/Sources/` | The root LaunchDaemon. The security boundary. |
| `Tests/LocalfoxKitTests/` | Tests for the kit only. |
| `Vendor/caddy/` | Pinned upstream Caddy. Git-ignored. |
| `Tools/` | `fetch-caddy.sh`, `fetch-icons.py`, `archive.sh`, `make-dmg.sh`. |

## Architecture

```
DirectoryContext → DetectionEngine → WorkspaceScanner → CommandBuilder
    → ProjectStore
        ↓
ShellEnvironment → ProcessSpawner → PortDiscovery
        ↓
CaddyConfigBuilder → HelperProtocol (XPC) → CaddySupervisor → Caddy
```

- **DirectoryContext** loads a project directory once. Every detector is a pure function
  over that value, so detection tests never touch the disk.
- **DetectionEngine** scores every detector and takes the highest, applying `supersedes`
  over the full hit set. SvelteKit, Astro, Nuxt and Remix all depend on Vite and would
  otherwise all report as Vite.
- **ShellEnvironment** probes your login shell interactively for its real PATH. A GUI app
  inherits launchd's PATH and cannot find `pnpm`, `bun`, or nvm-managed `node`.
- **ProcessSpawner** uses `posix_spawn` with `POSIX_SPAWN_SETSID`, so the whole dev server
  tree lands in one process group that can be stopped reliably.
- **PortDiscovery** walks libproc for listening sockets in that process group, scores the
  candidates, and confirms the winner with an HTTP request before trusting it.
- **HelperService** runs as root, owns ports 80 and 443, and is the only thing that talks
  to Caddy.

Every stage takes and returns plain `Sendable` value types. `localfox-run` drives the
identical pipeline, so detection and runtime are developable without the GUI.

## Why `.localhost`

macOS already resolves any `*.localhost` name to `127.0.0.1` and `::1`, so Localfox never
touches `/etc/hosts` or runs a DNS server.

`.test` and `.local` were both rejected. `.local` is reserved for multicast DNS and
fights Bonjour. `.test` has no resolver support, and more importantly Vite explicitly
allow-lists `localhost` and `*.localhost` in its host check, so any other suffix would be
refused by every Vite-based dev server with "Blocked request. This host is not allowed."

## HTTPS

Localfox runs a local certificate authority through Caddy's internal PKI and installs its
root into the System keychain, once, after you explicitly ask it to.

The CA is Localfox's own, named separately from Caddy's default, so it never collides with
a root left behind by a hand-run `caddy trust`. Caddy's automatic trust installation is
disabled: Localfox owns trust so that removing it actually works.

Trust is verified by evaluating a real issued certificate with `SecTrust`, not by checking
whether a file exists. Removal matches the stored SHA-256 fingerprint, so it cannot delete
a different CA that happens to share a name.

Node, Bun and Deno ignore the system trust store, so Localfox injects
`NODE_EXTRA_CA_CERTS` into every dev server it starts. A server component calling
`fetch("https://api.wishfox.localhost")` works without further setup.

## Ports and privilege

Binding ports 80 and 443 requires root. Localfox registers a LaunchDaemon through
`SMAppService`, which you approve once in System Settings under Login Items & Extensions.

There is no unprivileged fallback. Serving on `:8443` would break the one promise the
product makes, and people would hardcode the port into their configs. Until the helper is
approved, the app shows a setup wall.

The helper never receives a Caddy config. It receives typed `{ id, domain, port }` values
and builds the config itself, so a non-loopback upstream is not expressible across the
boundary rather than merely rejected. Every connecting client is checked against a code
signing requirement pinned to the bundle ID and Team ID.

## Known limitations

- Apple Silicon only.
- Firefox is not covered automatically. It imports roots from the System keychain by
  default, but that can be disabled by policy.
- A dev server that pins `server.hmr.port` in its Vite config bypasses the proxy and its
  HMR socket will not connect.
- A dev server bound to `0.0.0.0` is already reachable from your LAN regardless of what
  Localfox does. Localfox flags this rather than claiming otherwise.
- A process that daemonizes and escapes its process group cannot be attributed or stopped.
- Only Next.js and Vite have verified HMR behaviour behind the proxy. Other frameworks are
  detected but not yet proven end to end.

## License

MIT.

## Icons

Framework marks come from [simple-icons](https://github.com/simple-icons/simple-icons),
CC0. Caddy is bundled under the Apache License 2.0; see `Vendor/caddy/LICENSE`.
