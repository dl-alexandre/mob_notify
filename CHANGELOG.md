# Changelog

All notable changes to **mob_notify** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.3] - 2026-08-09

### Fixed
- Android `MobNotifyBridge` now delivers `{:push_token_error, :android, reason}`
  for blank cached FCM tokens, blank Firebase results, and Firebase task
  failures via a plugin-owned JNI seam (`nativeDeliverNotifyPushTokenError`).
  Host packages no longer need a Casein-only bridge fork for failure reporting.
- Matching Zig NIF thunk sends the three-element BEAM error tuple.

### Tests
- Source-level contract tests pin the Kotlin blank/failure paths and the Zig
  `push_token_error` message shape.

## [0.1.1] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.0] - 2026-06-12

Initial release. Local and push notifications for Mob apps — the device half, pairs with the server-side `mob_push` package.

- `MobNotify.schedule/2`, `cancel/2`, and `register_push/1`; delivery rides mob core.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
