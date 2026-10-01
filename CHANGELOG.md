# Changelog

Notable changes to Localfox. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- The menu bar popover is redesigned. It has a header with the app icon, a status summary line (running, stopped, failed, shared), and services shown as cards.
- The dashboard is redesigned to match. It has the same header and summary, card rows in the sidebar, and cleaner detail cards with consistent action buttons.
- The setup screen uses the new header and button style.
- The header refresh button checks the helper and the certificate again. Use it after you approve the helper in System Settings.
- Section titles and labels use sentence case in the system font. Domains, paths, commands, ports and versions stay monospace.
- A shared service is shown in blue, so it is easy to tell apart from a running one.
