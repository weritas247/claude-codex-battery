# PROJECT KNOWLEDGE BASE

**Generated:** 2026-08-14 11:00 KST
**Commit:** b7fd0b2
**Branch:** main

## OVERVIEW

Claude & Codex Usage Battery is a dependency-free usage-limit widget.
Product surfaces: Bun-powered SwiftBar plugin, native macOS menu-bar app, experimental Windows tray app.

## STRUCTURE

```
claude-codex-battery/
├── claude-codex-usage.2m.js  # self-contained SwiftBar executable; filename sets refresh cadence
├── install.sh                # deploys plugin and supervises SwiftBar with launchd
├── ccb-update.sh             # guarded in-place plugin updater
├── app/                      # native Swift macOS app and packaging scripts
├── windows/                  # experimental C# 5/.NET Framework tray app and parser tests
├── docs/                     # screenshots plus historical feature specs and plans
└── .github/workflows/        # Windows build and parser-test CI
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| SwiftBar behavior | `claude-codex-usage.2m.js` | One executable owns collection, caching, rendering, localization, and menu markup. |
| Plugin deployment/update | `install.sh`, `ccb-update.sh` | Deployment rewrites the Bun shebang; updater retains a `.bak` and validates downloaded content. |
| Native macOS lifecycle | `app/main.swift` | CLI diagnostics, app delegate, snapshot collection, refresh, UI state, self-tests. |
| Native provider data | provider Swift files + `Util.swift` | OAuth, credentials, caches, fallback, rate limits. |
| Native display/menu | rendering, menu, sprite Swift files | Pixel/modern rendering, dropdown, mascot. |
| Native packaging | `app/build.sh`, `app/release.sh`, `app/Updater.swift` | Local arm64 build versus signed/notarized public release. |
| Windows runtime/tests | `windows/ClaudeCodexBattery.cs`, `windows/tests/ParserTests.cs` | Single-file WinForms app with fixture parser tests. |
| Windows CI | `.github/workflows/windows-build.yml` | The authoritative C# compiler invocation and test command. |

## CODE MAP

| Symbol / entry | Type | Location | Role |
|---|---|---|---|
| `claude-codex-usage.2m.js` | executable script | root | SwiftBar collection, PNG output, menu and update checks. |
| `collectSnapshot()` | function | `app/main.swift` | Native collection hub: Claude, block/model details, Codex, update, health, and rate limits. |
| `AppDelegate` | class | `app/main.swift` | Status-item lifecycle, timer-driven refresh, actions, and headless diagnostics. |
| `battItems` / `providerSummaries` | functions | `app/main.swift` | Converts normalized provider state into visible battery metrics. |
| `getClaudeUsage` | function | `app/ClaudeUsage.swift` | Claude credential/API/cache pipeline. |
| `getCodex` | function | `app/CodexUsage.swift` | Codex auth/API/session-cache pipeline. |
| `ClaudeCodexBattery.cs` | executable class set | `windows/` | Separate Windows tray UI, transport, cache, and rendering implementation. |

## CONVENTIONS

- Keep all product paths dependency-free; there is no package manifest, formatter, or lint configuration.
- Swift compilation globs every `app/*.swift`; a new Swift file there is automatically part of the native binary.
- `app/build.sh` targets arm64 macOS 12+ and links Cocoa, QuartzCore, and ServiceManagement.
- Windows stays C# 5 on .NET Framework assemblies. Its CI invokes the Framework64 v4.0.30319 compiler directly.
- `docs/superpowers/` preserves design/planning records; it is not product source.

## ANTI-PATTERNS (THIS PROJECT)

- Never expose OAuth tokens in logs, files, command arguments, or calls to unapproved endpoints.
- Never invent a percentage for missing or unrecognized provider data; preserve unavailable state.
- Keep Claude and Codex cooldowns independent; do not shorten an active cooldown after another 429.
- Preserve signature/integrity gates in both update paths.
- Do not commit generated `.app`, `.dmg`, `.zip`, or Windows `.exe` output.

## COMMANDS

```bash
# Native macOS build and self-test (macOS with Swift toolchain)
cd app && ./build.sh
./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core

# Native diagnostic output
./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --dump

# Deploy the SwiftBar plugin (requires bun and SwiftBar)
./install.sh

# Windows build/install (PowerShell on Windows)
cd windows && .\install.ps1
```

## NOTES

- The native app refreshes every five minutes; the SwiftBar filename currently drives a two-minute refresh.
- macOS release packaging requires Developer ID and notarization credentials; use `app/release.sh` only for that release path.
- `app/ClaudeCodexBattery.app/` is build output, not a source module. Exclude `.gjc/` and `.superpowers/` from product-code exploration.
