// Claude's actual rate limit — queries the Anthropic OAuth usage API directly (ported from widget 1c)
// Fetches /usage with this Mac's Claude Code login token (keychain). A lapsed access token is
// refreshed in place so Retry/Refresh can recover without sending the user back to sign-in.
// Figures are aggregated at the account level. On failure: own cache → legacy usage-cache.json fallback.
import Security
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

// Claude Code keys its keychain entry by config dir: first 8 hex of sha256(dir). Older builds
// stored the default profile under the bare service name and left that item behind after login,
// so the default dir still has to try the unhashed name as a fallback.
func claudeKeychainDigest(_ dir: String) -> String {
  let digest = SHA256.hash(data: Data(normalizedProfileDir(dir).utf8))
    .map { String(format: "%02x", $0) }.joined()
  return String(digest.prefix(8))
}

func claudeKeychainService(for dir: String) -> String {
  "Claude Code-credentials-\(claudeKeychainDigest(dir))"
}

func claudeKeychainServiceCandidates(for dir: String) -> [String] {
  let hashed = claudeKeychainService(for: dir)
  let d = normalizedProfileDir(dir)
  if d == DEFAULT_CLAUDE_PROFILE { return [hashed, "Claude Code-credentials"] }
  return [hashed]
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
private let CLAUDE_OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let CLAUDE_TOKEN_SKEW_SECONDS = 60

struct ClaudeOAuthStore {
  var object: [String: Any]
  var source: ClaudeOAuthSource
}

enum ClaudeOAuthSource {
  case keychain(service: String, account: String)
  case file(path: String)
}

func claudeOAuthNeedsRefresh(expiresAt: Int?, now: Int, skew: Int = CLAUDE_TOKEN_SKEW_SECONDS) -> Bool {
  guard let expiresAt else { return false }
  return expiresAt <= now + skew
}

func parseClaudeOAuthRefresh(_ obj: [String: Any], now: Int) -> (access: String, refresh: String?, expiresAtMs: Int)? {
  guard let access = jstr(obj["access_token"]), !access.isEmpty else { return nil }
  let refresh = jstr(obj["refresh_token"]).flatMap { $0.isEmpty ? nil : $0 }
  let expiresAtMs: Int
  if let raw = jn(obj["expires_at"]).map({ Int($0) }) {
    expiresAtMs = raw > 1_000_000_000_000 ? raw : raw * 1_000
  } else {
    let expiresIn = jn(obj["expires_in"]).map { Int($0) } ?? 3_600
    expiresAtMs = (now + max(expiresIn, 1)) * 1_000
  }
  return (access, refresh, expiresAtMs)
}

func appliedClaudeOAuthTokens(_ object: [String: Any], access: String, refresh: String?,
                              expiresAtMs: Int) -> [String: Any] {
  var root = object
  var oauth = jd(root["claudeAiOauth"]) ?? [:]
  oauth["accessToken"] = access
  if let refresh { oauth["refreshToken"] = refresh }
  oauth["expiresAt"] = expiresAtMs
  root["claudeAiOauth"] = oauth
  return root
}

private func claudeOAuthDict(_ object: [String: Any]) -> [String: Any]? { jd(object["claudeAiOauth"]) }

private func claudeOAuthAccessToken(_ object: [String: Any]) -> String? {
  guard let token = jstr(claudeOAuthDict(object)?["accessToken"]), !token.isEmpty else { return nil }
  return token
}

private func claudeOAuthRefreshToken(_ object: [String: Any]) -> String? {
  guard let token = jstr(claudeOAuthDict(object)?["refreshToken"]), !token.isEmpty else { return nil }
  return token
}

private func claudeOAuthExpiresAt(_ object: [String: Any]) -> Int? {
  guard let expires = jn(claudeOAuthDict(object)?["expiresAt"]).map({ Int($0 / 1000) }), expires > 0 else {
    return nil
  }
  return expires
}

private func decodeClaudeOAuthJSON(_ raw: String) -> [String: Any]? {
  jd(try? JSONSerialization.jsonObject(
    with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)))
}

private func readKeychainClaudeOAuth(service: String) -> ClaudeOAuthStore? {
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnData as String: true,
    kSecReturnAttributes as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
  ]
  var out: CFTypeRef?
  if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
     let item = out as? [String: Any],
     let data = item[kSecValueData as String] as? Data,
     let raw = String(data: data, encoding: .utf8),
     let object = decodeClaudeOAuthJSON(raw) {
    return ClaudeOAuthStore(object: object,
                            source: .keychain(service: service,
                                              account: (item[kSecAttrAccount as String] as? String)
                                                ?? NSUserName()))
  }
  // Already-granted /usr/bin/security access still works if this app has not been allowed yet.
  guard let raw = runCmd("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 3),
        let object = decodeClaudeOAuthJSON(raw) else { return nil }
  return ClaudeOAuthStore(object: object, source: .keychain(service: service, account: NSUserName()))
}

func preferredClaudeOAuthStore(_ stores: [ClaudeOAuthStore], now: Int) -> ClaudeOAuthStore? {
  func rank(_ store: ClaudeOAuthStore) -> (Int, Int) {
    let present = claudeOAuthAccessToken(store.object) != nil
    let expires = claudeOAuthExpiresAt(store.object)
    let expired = expires.map { $0 <= now } ?? false
    return (present && !expired ? 1 : 0, expires ?? 0)
  }
  return stores.max { rank($0) < rank($1) }
}

func claudeOAuthLoginFingerprint(_ store: ClaudeOAuthStore) -> String {
  let refresh = claudeOAuthRefreshToken(store.object) ?? ""
  let access = claudeOAuthAccessToken(store.object) ?? ""
  let source: String
  switch store.source {
  case .keychain(let service, _): source = "keychain:\(service)"
  case .file(let path): source = "file:\(path)"
  }
  let digest = SHA256.hash(data: Data("\(source)|\(refresh)|\(access)".utf8))
    .map { String(format: "%02x", $0) }.joined()
  return String(digest.prefix(16))
}

func currentClaudeLoginFingerprint(_ dir: String = claudeProfileDir()) -> String? {
  guard let store = loadClaudeOAuth(dir) else { return nil }
  return claudeOAuthLoginFingerprint(store)
}

private func loadClaudeOAuth(_ dir: String, now: Int = Int(Date().timeIntervalSince1970)) -> ClaudeOAuthStore? {
  let d = normalizedProfileDir(dir)
  var stores = claudeKeychainServiceCandidates(for: d).compactMap(readKeychainClaudeOAuth)
  let path = "\(d)/.credentials.json"
  if let object = jd(readJSONFile(path)) {
    stores.append(ClaudeOAuthStore(object: object, source: .file(path: path)))
  }
  return preferredClaudeOAuthStore(stores, now: now)
}

private func persistClaudeOAuth(_ store: ClaudeOAuthStore) -> Bool {
  guard let data = try? JSONSerialization.data(withJSONObject: store.object),
        let raw = String(data: data, encoding: .utf8) else { return false }
  switch store.source {
  case .keychain(let service, let account):
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attrs: [String: Any] = [kSecValueData as String: Data(raw.utf8)]
    let updated = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if updated == errSecSuccess { return true }
    if updated == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = Data(raw.utf8)
      return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    return false
  case .file(let path):
    writeJSONFile(path, store.object)
    return FileManager.default.fileExists(atPath: path)
  }
}

private func refreshClaudeOAuth(_ store: ClaudeOAuthStore, now: Int) -> ClaudeOAuthStore? {
  guard let refresh = claudeOAuthRefreshToken(store.object),
        let body = try? JSONSerialization.data(withJSONObject: [
          "grant_type": "refresh_token",
          "refresh_token": refresh,
          "client_id": CLAUDE_OAUTH_CLIENT_ID,
        ]) else { return nil }
  let headers = ["Content-Type": "application/json", "User-Agent": "anthropic"]
  let hosts = [CLAUDE_OAUTH_HOST, CLAUDE_OAUTH_HOST_FALLBACK]
  for host in hosts {
    guard let raw = httpPost("https://\(host)/v1/oauth/token", headers: headers, body: body,
                             timeout: 8, provider: .claude,
                             login: claudeOAuthLoginFingerprint(store)),
          let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
          let tokens = parseClaudeOAuthRefresh(obj, now: now) else { continue }
    var next = store
    next.object = appliedClaudeOAuthTokens(store.object, access: tokens.access,
                                           refresh: tokens.refresh, expiresAtMs: tokens.expiresAtMs)
    if !persistClaudeOAuth(next),
       ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
      FileHandle.standardError.write(Data("[claudeOAuth] persist failed after refresh\n".utf8))
    }
    return next
  }
  return nil
}

private func readClaudeToken() -> String? {
  if liveDisabled() { return nil }
  let now = Int(Date().timeIntervalSince1970)
  guard var store = loadClaudeOAuth(claudeProfileDir()) else { return nil }
  if claudeOAuthNeedsRefresh(expiresAt: claudeOAuthExpiresAt(store.object), now: now) {
    if let refreshed = refreshClaudeOAuth(store, now: now) {
      store = refreshed
    } else if claudeOAuthNeedsRefresh(expiresAt: claudeOAuthExpiresAt(store.object), now: now, skew: 0) {
      // A lapsed access token cannot answer; sending it only earns a 401 and a stale cache.
      return nil
    }
  }
  return claudeOAuthAccessToken(store.object)
}

// Whether a login is usable, and when it stops being usable — never the token itself. Presence of
// a keychain entry is not enough to go on: a logged-out profile keeps its entry with an empty
// token, and an abandoned one keeps a token that expired months ago. Both look identical to a
// file-exists check, which is how a dead login can be offered as a working alternative.
func claudeTokenStatus(_ dir: String) -> (present: Bool, expiresAt: Int?) {
  guard let store = loadClaudeOAuth(dir), claudeOAuthAccessToken(store.object) != nil else {
    return (false, nil)
  }
  return (true, claudeOAuthExpiresAt(store.object))
}

func claudeCredentialsPresent(_ dir: String = claudeProfileDir()) -> Bool {
  claudeTokenStatus(dir).present
}

// True while the stored access-token deadline is still in the past. fetchLive refreshes first, so
// this stays true only when refresh failed or has not run yet — not as a reason to skip trying.
func claudeCredentialsExpired(_ dir: String = claudeProfileDir(), now: Int) -> Bool {
  guard let expires = claudeTokenStatus(dir).expiresAt else { return false }
  return expires <= now
}

// What actually refreshes a named profile's token: Claude Code's auth login against that config dir.
// A bare `claude` starts a session in $HOME and asks to trust the folder — that is not a sign-in.
func signInCommand(for dir: String, cli: String = "claude") -> String {
  "CLAUDE_CONFIG_DIR=\"\(normalizedProfileDir(dir))\" \(cli) auth login"
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
                       cooldown: rateLimitRemaining(host: claudeRateLimitBucket(dir), now: now,
                                                    login: currentClaudeLoginFingerprint(dir)))
  }
}

private func fetchClaudeUsagePayload(_ token: String, login: String?) -> [String: Any]? {
  guard let raw = httpGet("https://\(CLAUDE_API_HOST)/api/oauth/usage",
                          headers: ["Authorization": "Bearer \(token)",
                                    "anthropic-beta": "oauth-2025-04-20"], timeout: 5, provider: .claude,
                          bucket: claudeRateLimitBucket(), login: login),
        let obj = jd(try? JSONSerialization.jsonObject(with: raw)),
        obj["five_hour"] != nil else { return nil }
  return obj
}

private func fetchLive(now: Int) -> (data: [String: Any], measuredAt: Int, live: Bool)? {
  guard let token = readClaudeToken() else { return nil }
  let login = currentClaudeLoginFingerprint()
  if let obj = fetchClaudeUsagePayload(token, login: login) {
    writeJSONFile(USAGE_CACHE, ["fetchedAt": now, "data": obj])
    return (obj, now, true)
  }
  // Local expiry can be missing or wrong. A refused access token is still refreshable.
  let status = lastHTTPStatus(bucket: claudeRateLimitBucket())
  guard status == 401 || status == 403,
        let store = loadClaudeOAuth(claudeProfileDir()),
        let refreshed = refreshClaudeOAuth(store, now: now),
        let retry = claudeOAuthAccessToken(refreshed.object),
        let obj = fetchClaudeUsagePayload(retry, login: claudeOAuthLoginFingerprint(refreshed)) else { return nil }
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
