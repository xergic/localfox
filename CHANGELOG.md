# Changelog

Notable changes to Localfox. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.2.1] - 2026-10-02

### Added
- Port routes. Give a domain to a port Localfox did not start, such as a Docker container or an SSH forward. Add one with **Route a Port** in the dashboard, or when editing a project.
- A route shows as waiting while its port is closed, and is served only while the port accepts connections.
- The header summary shows a count of waiting routes.

### Changed
- Updating with Homebrew no longer asks for your password. Localfox replaces an outdated helper itself on first launch. The update to this version still asks once.
- `brew uninstall --cask localfox` leaves the helper loaded until you restart your Mac. Add `--zap` to remove it at once.
- The configuration becomes version 2 once it holds a port route or a service with no folder. Localfox 1.2.0 cannot open that file and may overwrite it.
- Quitting clears every route from the proxy, since a route's server keeps running.
- The dashboard **+** button opens a menu to add a project or route a port.
- The preferences and sheets are redesigned to match the popover and dashboard.

### Fixed
- The configuration store no longer saves over a file it could not load.
- A share badge no longer cuts off a long service name. When a row is too narrow for both, the badge moves to its own line.

## [1.2.0] - 2026-10-01

### Changed
- The menu bar popover is redesigned. It has a header with the app icon, a status summary line (running, stopped, failed, shared), and services shown as cards.
- The dashboard is redesigned to match. It has the same header and summary, card rows in the sidebar, and cleaner detail cards with consistent action buttons.
- The setup screen uses the new header and button style.
- The header refresh button checks the helper and the certificate again. Use it after you approve the helper in System Settings.
- Section titles and labels use sentence case in the system font. Domains, paths, commands, ports and versions stay monospace.
- A shared service is shown in blue, so it is easy to tell apart from a running one.
