# Localfox

A macOS menu bar app that starts your local development servers and serves them at
stable, trusted HTTPS domains.

Instead of remembering which project owns which port, you open
`https://wishfox.localhost`. Localfox detects the framework, the package manager and the
dev command, starts the server, finds the port it actually bound, and points a bundled
Caddy reverse proxy at it. When the port changes, the domain does not.

## Install

```sh
brew install --cask xergic/tap/localfox
```

Or download the DMG from [Releases](https://github.com/xergic/localfox/releases/latest). Every release is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper warning.

Localfox needs macOS 15 or newer on Apple Silicon.

On first launch, Localfox asks you to approve its helper in System Settings and to trust
its certificate authority. macOS may ask for your password for each. See [HTTPS](#https) for
what is trusted and where.

Remove it with `brew uninstall --cask localfox`. Add `--zap` to also delete its data and
remove its certificate authority from your login keychain.

## Requirements for building

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
| `App/Localfox/Telemetry.swift` | Anonymous usage signals through TelemetryDeck. |
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

Localfox runs a local certificate authority through Caddy's internal PKI and trusts its
root in your login keychain, once, after you explicitly ask it to. macOS asks for your
password to confirm. The trust covers your user account only.

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

## Port routes

A port route gives a domain to something Localfox did not start. A Docker container, a
database admin page or an SSH forward all work. Use **Route a Port** from the **+** button
in the dashboard, or add one when you edit a project.

A route has a domain and a fixed port, and no command. **Start** begins watching the port.
**Stop** stops watching it and removes the domain. Localfox never signals the process that
holds the port, because it did not start it.

While the port accepts connections, the route shows as running and the domain serves it.
While it does not, the route shows as waiting and the domain is not served. Localfox checks
every two seconds.

The check dials `127.0.0.1`, because the proxy does. A server that listens on `::1` only
will show as waiting. Bind it to `127.0.0.1` too.

Quitting Localfox clears every route from the proxy, even though the servers behind them
keep running. A route cannot be shared publicly yet.

Routes need a newer configuration format. Localfox 1.2.0 cannot read a configuration saved
by this version and may overwrite it, so do not open it with 1.2.0. Builds from this
version on leave an unreadable file alone.

## Requests

Localfox can record what the proxy handled. Turn on **Record requests** in Preferences and
each service's detail pane lists its recent traffic: method, path, status, duration and
size. Caddy writes it, one JSON line per request, next to its own log.

The file holds the request line and the response, and nothing else. Request and response
headers are deleted before the line is written, so no cookie, `Authorization` value or
custom `X-API-Key` reaches disk. Caddy's own redaction covers only four header names, which
is not enough to make that promise, so Localfox drops both header maps outright.

The URL is recorded as sent, query string included. Turning the setting off removes the
logger from the proxy config entirely rather than leaving it running and ignored.

## Sharing

A running service can be shared on the public internet from the **Share** button. There
are three ways to do it. `localfox-run tunnel 5173` does the first one headless.

**Quick tunnel.** The default, and the only one that needs no setup. Localfox opens a
Cloudflare quick tunnel with the bundled `cloudflared` and hands you a random
`https://….trycloudflare.com` address. No Cloudflare account is involved. The address
changes every time and is not reserved to you.

**Named tunnel.** If you have a Cloudflare account with a domain, create a tunnel in Zero
Trust, point its public hostname at `http://localhost:<port>`, and paste the tunnel token
into the project's edit sheet. You get a stable address that survives a restart, and none
of the quick tunnel's limits. The token is stored in your Keychain and passed to
`cloudflared` through the environment, never on the command line.

A named tunnel is managed by Cloudflare, so the origin lives in your dashboard rather than
in Localfox. That means the service needs a **fixed port**, and Localfox refuses a named
share on a service set to Auto rather than publishing whatever last held the port.

**SSH tunnel.** If you have a VPS, Localfox can run `ssh -N -R` to it and let the share
answer there. Nothing goes through a third party. The remote `sshd` needs `GatewayPorts
yes`, or the forward only listens on the server's own loopback, and Localfox says so
rather than reporting a tunnel that appears to work. The forward is plain HTTP unless you
terminate TLS on that box yourself, which is what the Public address field is for.

Localfox runs `ssh` in batch mode, so it will not accept an unknown host key on your
behalf. Connect to the host once from Terminal first.

Sharing is the one thing Localfox does that reaches past the loopback interface, so it is
worth being plain about what it means. Anyone with the link reaches your dev server
directly, with no authentication in front of it: your source maps, your `.env` values and
every API route. Sharing stops when the service stops and when Localfox quits, and is
never restored on relaunch, whichever mode you used.

A Cloudflare tunnel dials `127.0.0.1:<port>` directly rather than going through the proxy,
so it works before the helper is installed and does not depend on the certificate being
trusted. For a quick tunnel Localfox rewrites the origin `Host` header to
`localhost:<port>` by default, which is what stops Vite and Next rejecting the request as
an unknown host. Turn that off in Preferences if your app builds absolute URLs from the
header, such as Django's `ALLOWED_HOSTS` or an OAuth callback. A named tunnel takes that
setting from your Cloudflare dashboard instead.

## Privacy

Localfox uses [TelemetryDeck](https://telemetrydeck.com/privacy/) for anonymous usage
counts. It is on by default and sends:

- A session start, with the app and macOS version.
- That one of these happened: a project was added or removed, a service was started, the
  certificate was trusted or untrusted, the helper was installed, or a share was opened.
  Shares and installs carry only a coarse kind or outcome, such as `quick` or `success`.

It never sends domains, hostnames, ports, paths, project names, URLs, tunnel addresses,
certificate fingerprints or error messages.

Turn it off with **Share anonymous usage data** in Preferences. It takes effect at once and
nothing more is sent.

Only the official release builds report. The TelemetryDeck app ID is injected by the release workflow, so a build from source or a fork sends nothing.

## Known limitations

- Apple Silicon only.
- Firefox is not covered automatically. It can import roots from the macOS keychain, but
  that depends on its settings and on policy.
- A dev server that pins `server.hmr.port` in its Vite config bypasses the proxy and its
  HMR socket will not connect.
- A dev server bound to `0.0.0.0` is already reachable from your LAN regardless of what
  Localfox does. Localfox flags this rather than claiming otherwise.
- A process that daemonizes and escapes its process group cannot be attributed or stopped.
- Cloudflare quick tunnels do not support Server-Sent Events, and cap at 200 concurrent
  in-flight requests. WebSocket HMR works over a quick share; an SSE-based reload does not.
  A named tunnel lifts both, and needs a Cloudflare account with a domain.
- A quick tunnel's address is assigned by Cloudflare, so Localfox cannot reserve, rename or
  password-protect it. Use a named tunnel for an address you control.
- A named tunnel needs a service with a fixed port, because Cloudflare owns the origin.
- A shared address is public for as long as the share is open, in every mode.
- Only Next.js and Vite have verified HMR behaviour behind the proxy. Other frameworks are
  detected but not yet proven end to end.

## License

MIT.

## Icons

Framework marks come from [simple-icons](https://github.com/simple-icons/simple-icons),
CC0. Caddy is bundled under the Apache License 2.0; see `Vendor/caddy/LICENSE`.
