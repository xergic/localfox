# CLAUDE.md

Project instructions for Localfox. Read `README.md` for the user-facing description.

## What this is

A macOS 15+ app that starts local development servers and exposes them at stable
HTTPS `*.localhost` domains through a bundled Caddy reverse proxy. Swift 6, SwiftUI,
strict concurrency, no third-party Swift dependencies. Sibling project to Portfox
(`/Users/ondra/Work/Portfox/portfox`), whose conventions and design this follows.

## Commands

```sh
make run      # regenerate the project, build, relaunch the app
make test     # swift test, the whole kit suite
make detect   # run detection headless: make detect DIR=~/Projects/wishfox
make env      # print the resolved login shell environment
make lint     # SwiftLint, must stay clean
make gen      # regenerate Localfox.xcodeproj from project.yml
make caddy    # fetch and verify the pinned Caddy binary into Vendor/
make snapshot # render the popover and dashboard to snapshots/
make archive  # Release app and DMG into dist/
```

The Makefile does `-include .env` and `export`, so per-repo settings live in a
git-ignored `.env`. See `.env.example`. Make is not a shell, so values take no
quotes: `DEVELOPMENT_TEAM="X"` keeps the quote characters inside the value, which
is why `Tools/archive.sh` validates the shape before it does any work.

`make archive` is ad hoc signed by default, and an ad hoc build **can never
register a working helper**: the signature carries no Team ID, so
`HelperIdentity.currentTeamIdentifier()` returns nil and `HelperService` refuses
every XPC peer. Set `DEVELOPMENT_TEAM` to sign with an Apple Development identity
and install to `/Applications`, which is the only way to exercise the privileged
path locally. Developer ID stays required for distribution, via CI.

Run `make lint` and `make test` after every code change. Run `make snapshot` after a
UI change and look at the PNGs.

`Localfox.xcodeproj` is generated and git-ignored. Never edit it. Change `project.yml`
and run `make gen`.

`Vendor/`, `snapshots/` and `dist/` are git-ignored. Never commit the Caddy binary,
PNGs, or build output.

## Layout

| Path | Holds |
|---|---|
| `Sources/LocalfoxKit/` | The whole pipeline. No SwiftUI, no AppKit, no UI state. |
| `Sources/localfox-run/` | CLI over the same pipeline. |
| `App/Localfox/` | SwiftUI shell: `AppState`, views, theme. |
| `Helper/Sources/` | The root LaunchDaemon. The security boundary. |
| `Tests/LocalfoxKitTests/` | Tests for the kit only. The app and helper targets have none. |
| `Vendor/caddy/` | Pinned upstream Caddy, fetched by `Tools/fetch-caddy.sh`. |
| `Tools/` | `fetch-caddy.sh`, `fetch-icons.py`, `archive.sh`, `make-dmg.sh`. |
| `.github/` | CI on every push, the signed release pipeline on a tag. |

## What is built

`localfox-run` drives the whole pipeline headless:

```sh
localfox-run detect <dir>            # framework, package manager, command, domains
localfox-run env                     # the PATH recovered from your login shell
localfox-run run <dir> -- <cmd>      # spawn a dev server, report the port it bound
localfox-run caddy-config <h:p>...   # the proxy config Localfox would use
localfox-run up <h:p>...             # run the proxy on 8080/8443, unprivileged
```

The app builds and runs as a menu bar agent with a setup wall. The helper compiles
and is bundled, but registering it needs a Developer ID certificate, so the
privileged path is not yet exercised end to end.


## Architecture

```
DirectoryContext → DetectionEngine → WorkspaceScanner → CommandBuilder
    → ProjectStore
        ↓
ShellEnvironment → ProcessSpawner → PortDiscovery
        ↓
CaddyConfigBuilder → HelperProtocol (XPC) → CaddySupervisor → Caddy
```

- **DirectoryContext** loads a directory once. Every detector is a pure function over
  it, so detection tests never touch the disk.
- **DetectionEngine** runs every `RuleBasedDetector`, takes the highest score, and
  applies `supersedes` over the full hit set so the result is order-independent.
- **ShellEnvironment** probes the user's login shell interactively for the real PATH.
  A GUI app inherits launchd's PATH and cannot find `pnpm`, `bun` or nvm-managed `node`.
- **ProcessSpawner** uses `posix_spawn` with `POSIX_SPAWN_SETSID` so the whole dev
  server tree lands in one process group that `killpg` can reach.
- **PortDiscovery** walks libproc for listening sockets belonging to that process
  group, scores the candidates and confirms the winner with an HTTP `HEAD`.
- **CaddyConfigBuilder** produces the proxy JSON. Pure, golden-file tested.
- **HelperService** is the only thing that talks to Caddy. It runs as root and owns
  ports 80 and 443.

Every stage takes and returns plain `Sendable` value types. `localfox-run` drives the
identical pipeline, so detection and runtime can be developed without the GUI.

## Rules

**The kit never imports SwiftUI or AppKit.** If a change needs UI types in
`LocalfoxKit`, the change is in the wrong layer.

**The app never talks to Caddy's admin API.** It sends typed `ProxyRoute` values over
XPC and the helper builds the config. A non-loopback upstream must not be expressible
across that boundary, which is what makes the security model real rather than a
promise.

**The helper validates its XPC peer before doing anything.** `SecCodeCopyGuestWithAttributes`
on the connection's audit token, against a requirement pinned to the bundle ID and the
Team ID the helper reads from its *own* signature. A root Mach service without this is a
local privilege escalation.

**No Team ID is written in source.** It is derived at runtime, and supplied to a build
through `DEVELOPMENT_TEAM`, matching how Portfox keeps it in a CI variable. A constant
drifts from whatever identity actually signed the build, and a drifted constant either
breaks the boundary or points it at the wrong team.

**Caddy listens on loopback explicitly.** `":443"` binds every interface and puts every
dev server on the LAN. It is always `["127.0.0.1:443", "[::1]:443"]`.

**Four proxy settings decide whether HMR works.** `flush_interval: -1`,
`versions: ["1.1"]`, `idle_timeout: 24h`, `stream_close_delay: 5m`. Without the first
one, Next.js RSC streaming and Vite's event stream sit in a buffer and HMR silently
does nothing.

**Signals go to the process group, not a single pid.** Localfox owns the group because
it created it with `SETSID`. This is the opposite of Portfox's rule, which avoids
`killpg` only because a terminal-started server shares its group with the user's shell.
Escalate SIGINT, then SIGTERM, then SIGKILL: Vite and Next unbind cleanly on SIGINT and
leak lock files on SIGKILL.

**Verify process identity before every signal.** A snapshot can be seconds old, and the
kernel can hand the same pid to a different process in that window.

**Command matching is word-boundary aware.** Use `String.containsToken`, not `contains`.
A plain substring search labels `ngrok` as Angular via `/bin/ng`.

**Do not write to `@Observable` state unless the value moved.** Compare before
assigning. A blind write on a poll tick redraws the whole window.

**No comments that restate the code.** The existing comments explain *why* a non-obvious
choice was made, usually with the concrete bug that forced it. Match that bar or write
nothing. Code ported from Portfox keeps its comments verbatim.

## Adding a framework detector

Three edits, no new code paths:

1. A case in `ServiceType` with its display name, default ports, `defaultDevScript` and
   `portFlagStyle`.
2. A `RuleBasedDetector` row in `Sources/LocalfoxKit/Detection/Detectors/`.
3. An entry in `Tools/fetch-icons.py`, then `python3 Tools/fetch-icons.py`.

Then a test in the matching `Tests/LocalfoxKitTests/Detection/` file.

Unlike Portfox, detectors here run against a cold directory with no process, so rows use
`requiredGroup: nil` and weight config files and dependencies rather than argv.

Portfox's detector catalogue is actively growing. Keep `Signal` and `RuleBasedDetector`
structurally identical to `PortfoxKit`'s so new rows port across as data.

## Ports and privilege

Binding 80 and 443 requires root, so the app registers an `SMAppService.daemon` that
launchd runs as root. There is **no unprivileged fallback in the app**: a `:8443` URL
would break the one promise the product makes, and users would hardcode it. Until the
helper is approved, the app shows a setup wall.

`localfox-run up` serves on 8080 and 8443 so the whole path stays developable without
root. That is a CLI affordance only; the app has no such fallback.

## Releases

Push a `vMAJOR.MINOR.PATCH` tag. `.github/workflows/release.yml` archives, signs with
Developer ID, notarizes, staples, builds the DMG and publishes it.

Signing is inside-out and never uses `--deep`: caddy, then the helper, then the app.
`--deep` is fine for `--verify` only.

Caddy must be signed **after** it lands in the bundle, which is what `codeSign: true`
on the copy phase does.

The daemon plist is sealed into the bundle, so changing it needs a re-sign *and* an
`unregister()`/`register()` cycle or launchd keeps the stale copy.

Both the app and the DMG get notarized and stapled. A ticket stapled to the DMG alone
leaves the copied app waiting on an online check at first launch.

## Git

Conventional Commits, single short sentence, no body, no co-author trailer.
Work on `main` unless the change is large enough to want review in isolation.
