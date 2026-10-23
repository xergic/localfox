# Changelog

Notable changes to Localfox. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- A banner when a service you started is up while you are in another app. Click it to open the domain. It shares the existing notification preference, now called "Notify when a service is ready or crashes". Localfox still never sends a request of its own, so "ready" means the port is bound and the route is set.
- Pin a project from the pin on its heading to keep it at the top of the popover and the Localfox window.
- Search takes a port range such as `3000-3999` and finds every running service listening inside it.

## [1.3.1] - 2026-10-20

### Fixed
- Install Helper works when an earlier Localfox build left its helper registered, for example after deleting the app or switching between a release and a locally signed build. Before, the button did nothing and only a Terminal command cleared it.

## [1.3.0] - 2026-10-20

### Added
- The menu has a search field. It matches service, domain, framework, command and port, and it takes the keyboard when the menu opens. ↑ and ↓ move through the list, Return opens the selected service or starts it, ⌘⌫ stops it, and Escape clears the search.
- Hovering a service swaps its port for the actions, so the name and domain stay readable. Copy URL is now one of them. A service shared publicly also gets a QR code button, which opens the public URL on your phone.
- A running service shows the status of its last request beside the port, read from the request log the proxy already keeps. Localfox sends nothing to your server to get it. Hover it for the method, path, time taken and when it happened. It needs "Record requests" on, which is the default.
- A banner tells you when a service stops without you asking, with the reason and a Restart button. Localfox asks for notification permission the first time a service starts. Turn it off with "Notify when a service crashes" in Settings › General.
- A global shortcut opens the menu from any app. The default is ⌃⌥L, and you can change it in Settings › General.

### Fixed
- A service whose server exits on its own, crashes or is killed from a terminal is now marked as failed, with the reason and its last output. Before, it kept showing as running.
- The menu no longer shows "Finish setting up local HTTPS" while a service is running and HTTPS works. The trust check left out the proxy's intermediate certificate, so it failed whenever there was a site certificate to check. The menu also checks setup again each time it opens.
- Share Publicly from the menu shows its warning as a normal alert. Before, the first click only dimmed the menu, and the second showed a warning whose Share button did not respond.
- A service that could not start because its port was taken can be started again once the port is free. Before, Start did nothing until Localfox was relaunched.

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
