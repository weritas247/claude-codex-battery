# WINDOWS PORT

## OVERVIEW

`windows/` is the dependency-free Windows 10/11 system-tray port. The runtime is intentionally concentrated in one C# 5/.NET Framework source file.

## STRUCTURE

```
windows/
├── ClaudeCodexBattery.cs  # WinForms tray UI, provider access, cache/fallback, rendering
├── install.ps1            # compile, install, and optionally configure start-at-login
├── uninstall.ps1          # stop/remove installed app and optional Windows cache cleanup
├── tests/ParserTests.cs   # fixture parser, refresh-gate, and atomic-cache tests
├── docs/                  # Windows flyout screenshot
└── README.md              # Windows user and development documentation
```

## WHERE TO LOOK

| Task | Location | Notes |
|---|---|---|
| Runtime behavior | `ClaudeCodexBattery.cs` | WinForms tray UI and all data/rendering implementation. |
| Parser or fallback behavior | `tests/ParserTests.cs` | Executable fixture coverage for API shapes, unavailable state, cooldown and atomic cache behavior. |
| Install/startup behavior | `install.ps1` | Uses built-in .NET Framework compiler and supports auto-start switches. |
| Removal/cache scope | `uninstall.ps1` | Default removal versus `-RemoveCachedUsage`. |
| CI verification | `../.github/workflows/windows-build.yml` | Exact compiler references and parser-test invocation. |

## CONVENTIONS

- Stay compatible with C# 5 and .NET Framework assemblies; CI uses `Framework64\\v4.0.30319\\csc.exe`.
- Keep the port dependency-free and compile it with the supplied PowerShell workflow.
- API data may be unavailable. Preserve unavailable state rather than guessing a value.
- Maintain live-request privacy: credentials are used only for Anthropic and ChatGPT usage endpoints and are not cached as tokens.

## ANTI-PATTERNS

- Do not commit generated `ClaudeCodexBattery.exe` or `ParserTests.exe` files.
- Do not add modern C#/.NET APIs without deliberately changing the compatibility contract.
- Do not make unknown, partial, malformed JSON, or HTML response bodies look like valid usage data.
- Do not shorten an active provider cooldown or merge independent Claude/Codex rate-limit state.

## COMMANDS

```powershell
# Windows PowerShell
cd windows
.\install.ps1

# Use -NoLaunch for a build/install without opening the tray app
.\install.ps1 -NoLaunch
```

Run the compile-plus-parser-test commands in `../.github/workflows/windows-build.yml` to reproduce CI exactly.

## NOTES

- Start-at-login is off by default; `install.ps1 -EnableAutoStart` opts in.
- `README.md` is the authoritative user-facing Windows behavior and privacy reference.
