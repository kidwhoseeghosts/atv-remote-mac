# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning: [SemVer](https://semver.org/).

## [1.0.0] - 2026-11-01

First public release.

### Added
- **Localization:** the UI is available in English (development language) and Russian via a String Catalog (`Localizable.xcstrings`, `InfoPlist.xcstrings`) and follows the system language; user-facing messages from the Python service are localized too (`--lang`).
- Menu-bar Apple TV remote (no Dock icon): clickpad, Back / Home (TV) / Play-Pause / Mute / Volume ± buttons, ±10 s skip, power.
- Device discovery over mDNS, pairing with PIN for Companion, AirPlay and MRP; keys are stored locally and reconnect is automatic.
- "Now Playing" card with artwork, title and progress; Apple TV app grid with search and launch; text input into on-screen keyboards.
- Global hotkeys (configurable, with conflict warnings), floating always-on-top remote window, launch at login.
- Volume with ordered fallbacks (MRP HID over the AirPlay tunnel, Companion HID, `remote_control`, `audio`, AirPlay `set_volume`).
- **Volume diagnostics** (Settings → Volume → Volume diagnostics): shows active protocols and the MRP tunnel state, runs every method one by one, lets you pick the one that works and pins it as the preferred method.
- Demo mode with a virtual Apple TV (pairing PIN `1234`).
- macOS 26-style app icon (MacBook with the Siri Remote on its screen) and template menu-bar icons.
- Bundled [pyatv](https://pyatv.dev) 0.18.0 daemon (JSON Lines over stdin/stdout), installed into a private venv on first launch.
- Build tooling: XcodeGen project, `scripts/build.sh`, `scripts/release.sh` (universal ad-hoc-signed zip; prints the `.app` path and reveals it in Finder), GitHub Actions workflow, Python/Swift checks in `tests/`.

