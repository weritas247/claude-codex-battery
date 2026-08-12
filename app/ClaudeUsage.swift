// Claude's actual rate limit — queries the Anthropic OAuth usage API directly (ported from widget 1c)
// Fetches /usage data straight from the server using this Mac's Claude Code login token (keychain).
// Figures are aggregated at the account level. On failure: own cache → legacy usage-cache.json fallback.
import CryptoKit
import Foundation

struct UsageWindow {
  let pct: Double // usage %
  let resetsAt: Int? // epoch seconds
}

struct FableWindow {
  let pct: Double
  let resetsAt: Int?
  let model: String
}

struct ClaudeUsage {
  let measuredAt: Int
  let live: Bool
  let fiveHour: UsageWindow?
  let weekly: UsageWindow?
  let fable: FableWindow?
}

private let USAGE_CACHE = "\(STATE_DIR)/.claude-usage.json"
private let LEGACY_USAGE_FILES = [
  "\(HOME)/.claude/.statusline-usage-cache.json",
  "\(HOME)/.claude/MEMORY/STATE/usage-cache.json",
  "\(HOME)/.claude/PAI/MEMORY/STATE/usage-cache.json",
]

// ── Which Claude Code login to read ──────────────────────────────────────────────────────────
// Anthropic rate limits this endpoint per config dir, not per account. When ~/.claude gets
// throttled the widget goes dark for days even though another login for the same account still
// answers — so the profile is selectable. The figures are account-level, so every login for the
// account reports identical numbers; only the throttling differs.
let CLAUDE_PROFILE_KEY = "claudeProfileDir"
let DEFAULT_CLAUDE_PROFILE = "\(HOME)/.claude"

func normalizedProfileDir(_ dir: String) -> String {
  var d = dir.trimmingCharacters(in: .whitespaces)
  while d.count > 1 && d.hasSuffix("/") { d.removeLast() }
  return d
}

// Claude Code keys its keychain entry by config dir: the default dir uses the bare service name,
// anything else appends the first 8 hex of sha256(dir). Verified against this Mac's keychain.
func claudeKeychainService(for dir: String) -> String {
  let d = normalizedProfileDir(dir)
  guard d != DEFAULT_CLAUDE_PROFILE else { return "Claude Code-credentials" }
  let digest = SHA256.hash(data: Data(d.utf8)).map { String(format: "%02x", $0) }.joined()
  return "Claude Code-credentials-\(digest.prefix(8))"
}

func claudeProfileDir(_ saved: String? = UserDefaults.standard.string(forKey: CLAUDE_PROFILE_KEY)) -> String {
  guard let saved, !saved.trimmingCharacters(in: .whitespaces).isEmpty else { return DEFAULT_CLAUDE_PROFILE }
  return normalizedProfileDir(saved)
}

// Config dirs the user could pick, default first. Claude Code profiles live in ~/.claude* and hold
// either a login file or the per-profile state Claude Code writes.
func discoverClaudeProfiles() -> [String] {
  var found = [DEFAULT_CLAUDE_PROFILE]
  let fm = FileManager.default
  for name in ((try? fm.contentsOfDirectory(atPath: HOME)) ?? []).sorted() where name.hasPrefix(".claude") {
    let path = "\(HOME)/\(name)"
    var isDir: ObjCBool = false
    guard path != DEFAULT_CLAUDE_PROFILE,
          fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
          fm.fileExists(atPath: "\(path)/.credentials.json")
            || fm.fileExists(atPath: "\(path)/.claude.json")
            || fm.fileExists(atPath: "\(path)/projects")
    else { continue }
    found.append(path)
  }
  return found
}

// The throttle applies to the login, not the host, so each profile gets its own cooldown. Sharing
// one host-wide cooldown would make a switch to a healthy login inherit the throttled one's penalty
// — and switching back would forget a penalty that is still running server-side.
func claudeRateLimitBucket(_ dir: String = claudeProfileDir()) -> String {
  "\(CLAUDE_API_HOST)|\(normalizedProfileDir(dir))"
}

// Token exists only in the return value — never left in files, logs, or process arguments
private func readClaudeToken() -> String? {
  if liveDisabled() { return nil }
  let dir = claudeProfileDir()
  if let raw = runCmd("/usr/bin/security", ["find-generic-password", "-s", claudeKeychainService(for: dir), "-w"], timeout: 3),
     let obj = try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    return t
  }
  // For environments without a keychain — Claude Code's file-based credentials
  if let obj = readJSONFile("\(dir)/.credentials.json"),
     let t = jstr(jd(jd(obj)?["claudeAiOauth"])?["accessToken"]) {
    return t
  }
  return nil
}

// Whether a login is usable, and when it stops being usable — never the token itself. Presence of
// a keychain entry is not enough to go on: a logged-out profile keeps its entry with an empty
// token, and an abandoned one keeps a token that expired months ago. Both look identical to a
// file-exists check, which is how a dead login can be offered as a working alternative.
func claudeTokenStatus(_ dir: String) -> (present: Bool, expiresAt: Int?) {
  let d = normalizedProfileDir(dir)
  var payload: Any? = nil
  if let raw = runCmd("/usr/bin/security",
                      ["find-generic-password", "-s", claudeKeychainService(for: d), "-w"], timeout: 3) {
    payload = try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
  }
  if payload == nil { payload = readJSONFile("\(d)/.credentials.json") }
  guard let oauth = jd(jd(payload)?["claudeAiOauth"]) else { return (false, nil) }
  guard let token = jstr(oauth["accessToken"]), !token.isEmpty else { return (false, nil) }
  // Claude Code stores the deadline in milliseconds; 0 is what a cleared login leaves behind.
  let expires = jn(oauth["expiresAt"]).map { Int($0 / 1000) }
  return (true, (expires ?? 0) > 0 ? expires : nil)
}

func claudeCredentialsPresent(_ dir: String = claudeProfileDir()) -> Bool {
  claudeTokenStatus(dir).present
}

// Expired here means expired for this app's purposes: it sends the stored access token as-is and
// never performs a refresh, so a lapsed deadline guarantees the 401 rather than merely risking it.
func claudeCredentialsExpired(_ dir: String = claudeProfileDir(), now: Int) -> Bool {
  guard let expires = claudeTokenStatus(dir).expiresAt else { return false }
  return expires <= now
}

// What actually refreshes a named profile's token: Claude Code started against that config dir.
// Pure, so the exact string the user is handed can be asserted rather than hoped for.
func signInCommand(for dir: String, cli: String = "claude") -> String {
  "CLAUDE_CONFIG_DIR=\"\(normalizedProfileDir(dir))\" \(cli)"
}

// A double-clickable script, because a menu item labelled "sign in" has to sign the user in rather
// than describe how. Terminal runs a .command in a non-login shell, hence the absolute CLI path
// and the explicit interpreter; the trailing pause keeps the window up if the CLI exits at once.
func signInScript(for dir: String, cli: String) -> String {
  """
  #!/bin/bash
  # Written by Claude Codex Battery to sign in to a Claude Code login. Safe to delete.
  echo "Signing in to \(normalizedProfileDir(dir))…"
  \(signInCommand(for: dir, cli: cli))
  status=$?
  if [ $status -ne 0 ]; then
    echo
    echo "Claude Code exited with status $status. Press return to close."
    read -r _
  fi
  """
}

// Everything the login switcher needs to tell the truth about an alternative before it is picked.
struct ClaudeLogin {
  let dir: String
  let present: Bool
  let expired: Bool
  let cooldown: Int? // seconds left on this login's own throttle
  var usable: Bool { present && !expired && cooldown == nil }
}

func claudeLogins(_ dirs: [String] = discoverClaudeProfiles(), now: Int) -> [ClaudeLogin] {
  dirs.map { dir in
    let status = claudeTokenStatus(dir)
    return ClaudeLogin(dir: dir, present: status.present,
                       expired: (status.expiresAt ?? Int.max) <= now,
                       cooldown: rateLimitRemaining(host: claudeRateLimitBucket(dir), now: now))
  }
}

private func fetchLive(now: Int) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  guard let token = readClaudeToken() else { return nil }
  guard let raw = httpGet("https://\(CLAUDE_API_HOST)/api/oauth/usage",
                          headers: ["Authorization": "Bearer \(token)",
                                    "anthropic-beta": "oauth-2025-04-20"], timeout: 5, provider: .claude,
                          bucket: claudeRateLimitBucket()),
        let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
        obj["five_hour"] != nil
  else { return nil }
  writeJSONFile(USAGE_CACHE, ["fetchedAt": now, "data": obj])
  return (obj, now, true)
}

private func readFallback() -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  if let c = jd(readJSONFile(USAGE_CACHE)), let data = jd(c["data"]), data["five_hour"] != nil {
    return (data, Int(jn(c["fetchedAt"]) ?? 0), false)
  }
  for f in LEGACY_USAGE_FILES {
    if let root = jd(readJSONFile(f)) {
      // Claude Code's statusline cache wraps the usage payload in `data`.
      let d = jd(root["data"]) ?? root
      if d["five_hour"] != nil {
        let measuredAt = jn(root["timestamp"]).map { Int($0) } ?? fileMtime(f)
        return (d, measuredAt, false)
      }
    }
  }
  return nil
}

// 5-hour session / overall weekly / Fable weekly-scoped usage rates
func getClaudeUsage(now: Int) -> ClaudeUsage? {
  guard let src = fetchLive(now: now) ?? readFallback() else { return nil }
  let d = src.data
  func win(_ o: Any?) -> UsageWindow? {
    guard let w = jd(o) else { return nil }
    return UsageWindow(pct: jn(w["utilization"]) ?? 0, resetsAt: parseISO(jstr(w["resets_at"])))
  }
  // Fable's (or the top-tier model's) weekly-scoped limit
  var fable: FableWindow? = nil
  for l0 in ja(d["limits"]) ?? [] {
    guard let l = jd(l0) else { continue }
    if jstr(l["group"]) == "weekly",
       let mdl = jstr(jd(jd(l["scope"])?["model"])?["display_name"]) {
      fable = FableWindow(pct: jn(l["percent"]) ?? 0, resetsAt: parseISO(jstr(l["resets_at"])), model: mdl)
      break
    }
  }
  return ClaudeUsage(measuredAt: src.measuredAt, live: src.live,
                     fiveHour: win(d["five_hour"]), weekly: win(d["seven_day"]), fable: fable)
}
