# NATIVE macOS APP

## OVERVIEW

`app/` is the dependency-free Swift implementation of the menu-bar widget, built directly with `swiftc` rather than an Xcode project.

## WHERE TO LOOK

| Task | Location | Notes |
|---|---|---|
| Runtime, diagnostics, refresh | `main.swift` | Top-level CLI dispatch, `AppDelegate`, collection hub, menus, animation and self-tests. |
| Claude usage | `ClaudeUsage.swift` | Keychain/profile discovery, live fetch, cache and fallback. |
| Codex usage | `CodexUsage.swift` | `~/.codex/auth.json`, live fetch, session/cache fallback and normalization. |
| HTTP, paths, cache, cooldowns | `Util.swift` | Shared process, network, JSON, storage and rate-limit helpers. |
| Presentation policy | `AppPolicy.swift` | Remaining percentages, metric visibility and refresh gates. |
| Status rendering | `BatteryRenderer.swift`, `CatSprite.swift` | Pixel/modern batteries, provider marks and mascot frames. |
| Dropdown | `MenuBuilder.swift` | Snapshot-to-`NSMenu` conversion and action wiring. |
| Optional cost details | `Ccusage.swift` | `ccusage` subprocess integration. |
| Account/localization/update | account, localization, update Swift files | Preferences, six-language strings, daily update, signed replacement. |

## CONVENTIONS

- Source files are all compiled by `build.sh` through the `*.swift` glob; avoid project-file assumptions.
- Preserve provider isolation: a Claude failure/cooldown must not suppress Codex, and vice versa.
- Send credentials only to the provider usage endpoint; keep tokens out of logs, disk caches, and process arguments.
- Caches carry source/age semantics. Missing or malformed data must remain unavailable, never be replaced with invented percentages.
- Localization changes must cover every supported language; native self-tests protect this.
- UI refreshes should update existing layers where appropriate. Do not restart protected animations on no-op presentation updates.

## ANTI-PATTERNS

- Do not weaken `--self-test-core` assertions to mask a presentation, cache, parser, or localization regression.
- Do not replace the native updater's pinned Developer ID/team verification with an unchecked download.
- Do not use `release.sh` for normal iteration: it signs, notarizes, staples, and creates distribution artifacts.
- Do not treat `ClaudeCodexBattery.app/` as source; it is output from `build.sh`.

## COMMANDS

```bash
cd app
./build.sh
./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core
./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --dump
./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --dump-menu
```

## NOTES

- Local builds target arm64 macOS 12.0. build.sh signs with the first working Apple-issued certificate so the Keychain "Always Allow" grant survives rebuilds, falling back to ad-hoc only when no certificate can sign.
- `--self-update`, `--render-glint`, and `--test-activity-monitor` are additional headless paths implemented in `main.swift`.
