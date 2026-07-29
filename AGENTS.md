# OtoLog — Agent notes

## Cursor Cloud specific instructions

OtoLog is a **macOS 26+** menu-bar app (Swift 6.2 / SpeechAnalyzer / ScreenCaptureKit). Cloud agents run on Ubuntu Linux, so:

- Do **not** expect `swift build`, `swift test`, `mise run build|test|bundle|install`, or app launch to succeed here.
- Safe cloud checks: edit sources, review diffs, run `mise run` only for tooling that does not need the Apple toolchain (e.g. after `mise install`, `swiftformat Sources Tests --lint`).
- Full build, unit tests, SpeechAnalyzer integration, and Claude CLI integration require a local Mac (see README「開発」).
- CI release builds use `macos-26` runners (`.github/workflows/release.yml`).

Environment bootstrap for Cloud Agents:

- Config: `.cursor/environment.json`
- Install (idempotent): `bash scripts/cursor-cloud-install.sh` — installs [mise](https://mise.jdx.dev/) and tools from `mise.toml` (currently `swiftformat`)

After the first successful agent setup, save a VM snapshot from the [Cloud Agents dashboard](https://cursor.com/dashboard/cloud-agents#environments) so later runs start faster.
