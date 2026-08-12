// Shared utilities — path/format/process/HTTP/JSON helpers (ported from the widget JS's shared code)
import Cocoa

let HOME = NSHomeDirectory()
let STATE_DIR = "\(HOME)/.claude/swiftbar" // Shares cache/settings with the SwiftBar widget (same file format)
// The single source of truth for which repository this build updates from. UpdateCheck derives its
// raw.githubusercontent URL from this, so a fork only ever has to change this one line.
let REPO_URL = "https://github.com/weritas247/claude-codex-battery"
let CLAUDE_USAGE_URL = "https://claude.ai/settings/usage"
let CODEX_USAGE_URL = "https://chatgpt.com/codex/settings/usage"

func installedProviderApp(_ provider: Provider) -> URL? {
  let bundleIDs: [String] = provider == .claude
    ? ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
    : ["com.openai.codex", "com.openai.chatgpt"]
  for id in bundleIDs {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
  }
  let names = provider == .claude ? ["Claude.app", "Claude Code.app"] : ["Codex.app", "ChatGPT.app"]
  let roots = ["/Applications", "\(HOME)/Applications"]
  for root in roots {
    for name in names {
      let path = "\(root)/\(name)"
      if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    }
  }
  return nil
}
let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

func firstExisting(_ paths: [String]) -> String? { paths.first { FileManager.default.fileExists(atPath: $0) } }
func findBin(_ name: String) -> String? {
  firstExisting(["\(HOME)/.bun/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"])
}

// Claude Code's own installer puts the CLI in ~/.local/bin, which findBin does not cover. The
// sign-in script needs an absolute path: a .command file runs under a non-login shell, so the PATH
// the user set up in their shell profile is not there to find a bare `claude`.
func claudeCLIPath() -> String? {
  firstExisting(["\(HOME)/.local/bin/claude"]) ?? findBin("claude")
}

// Opt-out switch for live queries (same as the widget: touch ~/.claude/swiftbar/.no-live)
func liveDisabled() -> Bool { FileManager.default.fileExists(atPath: "\(STATE_DIR)/.no-live") }


func fmtDur(_ secs: Int) -> String {
  if secs <= 0 { return "0m" }
  let h = secs / 3600, m = (secs % 3600) / 60
  if h >= 24 { return "\(h / 24)d \(h % 24)h" }
  return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func fmtTok(_ n: Double) -> String {
  if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
  if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
  if n >= 1e3 { return String(format: "%.0fK", n / 1e3) }
  return String(format: "%.0f", n)
}

// Partial-block gauge (▕█████▏) — ported from the widget's bar()
func gaugeBar(_ pctIn: Double, _ w: Int) -> String {
  let pct = max(0, min(100, pctIn))
  let filled = pct / 100 * Double(w)
  var fb = Int(filled)
  var idx = Int(((filled - Double(fb)) * 8).rounded())
  if idx == 8 { fb += 1; idx = 0 }
  fb = min(fb, w)
  let part = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
  var s = String(repeating: "█", count: fb)
  var used = fb
  if idx > 0 && fb < w { s += part[idx]; used += 1 }
  s += String(repeating: "░", count: max(0, w - used))
  return s
}

struct UsageColor {
  let r: UInt8
  let g: UInt8
  let b: UInt8
  var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

// Dropdown gauge colors. Menu bar capsule uses heatRemain in BatteryRenderer. Shares custom green; separate built-ins.
func usageColor(forRemaining remaining: Double, custom: String? = nil) -> UsageColor {
  switch remainingBand(remaining) {
  case .red: return UsageColor(r: 255, g: 105, b: 97)
  case .amber: return UsageColor(r: 255, g: 179, b: 64)
  case .green:
    if let custom, let rgb = rgbFromHex(custom) { return UsageColor(r: rgb.r, g: rgb.g, b: rgb.b) }
    return UsageColor(r: 52, g: 138, b: 69)
  }
}

func hexColor(_ s: String) -> NSColor? {
  guard let rgb = rgbFromHex(s) else { return nil }
  return NSColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
}

// Hex → raw RGB bytes. Deliberately not routed through hexColor(): that builds an sRGB NSColor
// while the battery renderer works in calibrated RGB, and round-tripping the two shifts the color.
func rgbFromHex(_ s: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
  var h = s
  guard h.hasPrefix("#") else { return nil }
  h.removeFirst()
  guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
  return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
}

// Run an external command (with timeout, nil on failure) — for ccusage/security only
func runCmd(_ bin: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: bin)
  p.arguments = args
  var env = ProcessInfo.processInfo.environment
  env["PATH"] = "\(HOME)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  p.environment = env
  let out = Pipe()
  p.standardOutput = out
  p.standardError = Pipe()
  p.standardInput = FileHandle.nullDevice
  do { try p.run() } catch { return nil }
  let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
  DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
  let data = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  killer.cancel()
  guard p.terminationStatus == 0 else { return nil }
  return String(data: data, encoding: .utf8)
}

// ── Rate-limit cooldown ────────────────────────────────────────────────────
// A 429 answer carries "retry-after: <seconds>". Retrying on the fixed REFRESH_SECONDS timer
// anyway keeps renewing the penalty, so the app can never climb back out — that is how four
// straight days of stale Claude data happened. Cooldowns are keyed by host, so one throttled
// provider never silences the other, and they survive a relaunch (see rateLimitStorePath).
let RATE_LIMIT_FALLBACK_SECONDS = 600 // a 429 with no usable header still has to back off

// The hosts the usage fetchers call. Cooldowns are keyed by host, so these have to be the same
// strings the request URLs are built from — hence both fetchers interpolate these constants.
let CLAUDE_API_HOST = "api.anthropic.com"
let CODEX_API_HOST = "chatgpt.com"

// Cooldowns are persisted, not just remembered. Anthropic restarts its clock on every request made
// during an active penalty, so an app that forgets its cooldown on relaunch re-arms the very
// lockout it was waiting out — and quitting, logging in, or updating all count as a relaunch.
var rateLimitStorePath = "\(STATE_DIR)/.rate-limits.json"
private var rateLimitUntil: [String: Int] = [:]
private var rateLimitLoaded = false
private let rateLimitLock = NSLock()

// Callers below already hold rateLimitLock.
private func loadRateLimitsLocked() {
  guard !rateLimitLoaded else { return }
  rateLimitLoaded = true
  guard let stored = jd(readJSONFile(rateLimitStorePath)) else { return }
  for (host, value) in stored {
    guard let until = jn(value).map({ Int($0) }) else { continue }
    rateLimitUntil[host] = max(rateLimitUntil[host] ?? 0, until)
  }
}

private func saveRateLimitsLocked(now: Int) {
  // Expired entries are dropped rather than carried forward forever.
  writeJSONFile(rateLimitStorePath, rateLimitUntil.filter { $0.value > now })
}

// Retry-After as a plain seconds count. Anthropic sends that form; anything else (an HTTP date,
// junk, or a non-positive value) means "we don't know", and the caller falls back.
func parseRetryAfter(_ raw: String?) -> Int? {
  guard let seconds = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 else { return nil }
  return seconds
}

func noteRateLimit(host: String, retryAfter: Int?, now: Int) {
  let until = now + (retryAfter ?? RATE_LIMIT_FALLBACK_SECONDS)
  rateLimitLock.lock()
  defer { rateLimitLock.unlock() }
  loadRateLimitsLocked()
  // Never shorten an active cooldown: a later 429 with a small Retry-After must not undo a long one.
  rateLimitUntil[host] = max(rateLimitUntil[host] ?? 0, until)
  saveRateLimitsLocked(now: now)
}

// Seconds still to wait, or nil when the host is free to call.
func rateLimitRemaining(host: String, now: Int) -> Int? {
  rateLimitLock.lock()
  defer { rateLimitLock.unlock() }
  loadRateLimitsLocked()
  guard let until = rateLimitUntil[host], until > now else { return nil }
  return until - now
}

// Drops one bucket's cooldown. Only the user's explicit "force retry" calls this — the penalty is
// the server's, so clearing it locally does not shorten it, it just permits one more request.
func clearRateLimit(host: String, now: Int) {
  rateLimitLock.lock()
  defer { rateLimitLock.unlock() }
  loadRateLimitsLocked()
  rateLimitUntil.removeValue(forKey: host)
  saveRateLimitsLocked(now: now)
}

func resetRateLimits() {
  rateLimitLock.lock()
  defer { rateLimitLock.unlock() }
  rateLimitUntil.removeAll()
  rateLimitLoaded = true // the store is gone too — nothing left to hydrate from
  try? FileManager.default.removeItem(atPath: rateLimitStorePath)
}

// Drops the in-memory table so the next read comes off disk — what a relaunch does.
func reloadRateLimitsFromDisk() {
  rateLimitLock.lock()
  defer { rateLimitLock.unlock() }
  rateLimitUntil.removeAll()
  rateLimitLoaded = false
}

// ── Last transport outcome ─────────────────────────────────────────────────
// The fetchers collapse every failure into `nil`, which is why the stale row could only offer the
// catch-all "check login/network". The status code is the one thing that separates an expired
// login (401) from an unreachable server, and those need different fixes — so it is kept here.
// Deliberately not persisted: a code from before a relaunch says nothing about the network now.
private var lastHTTPStatusByBucket: [String: Int] = [:]
private let httpStatusLock = NSLock()
let HTTP_STATUS_TRANSPORT_ERROR = -1 // no HTTP response at all — DNS, offline, timeout

func noteHTTPStatus(bucket: String, status: Int) {
  httpStatusLock.lock()
  defer { httpStatusLock.unlock() }
  lastHTTPStatusByBucket[bucket] = status
}

// nil when this bucket has not been called yet this run.
func lastHTTPStatus(bucket: String) -> Int? {
  httpStatusLock.lock()
  defer { httpStatusLock.unlock() }
  return lastHTTPStatusByBucket[bucket]
}

// Synchronous HTTP GET (only 2xx counts as success) — token stays in headers only, never in files/process args
// If CCB_DEBUG=1, prints status/errors to stderr (for diagnostics)
var providerActivityHandler: ((Provider, Bool) -> Void)?

// `bucket` is the cooldown key, defaulting to the host. Callers whose throttle is scoped narrower
// than the host — Claude's is per login, not per server — pass their own key.
func httpGet(_ urlStr: String, headers: [String: String], timeout: TimeInterval = 8,
             provider: Provider? = nil, bucket: String? = nil) -> Data? {
  guard let url = URL(string: urlStr) else { return nil }
  let host = bucket ?? url.host ?? urlStr
  // Still serving a 429 penalty — don't spend the request, and don't renew the penalty.
  if let wait = rateLimitRemaining(host: host, now: Int(Date().timeIntervalSince1970)) {
    if ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
      FileHandle.standardError.write(Data("[httpGet] \(host) rate-limited, \(wait)s left — skipped\n".utf8))
    }
    return nil
  }
  var req = URLRequest(url: url, timeoutInterval: timeout)
  headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
  let sem = DispatchSemaphore(value: 0)
  var result: Data? = nil
  if let provider { providerActivityHandler?(provider, true) }
  URLSession.shared.dataTask(with: req) { d, r, e in
    let response = r as? HTTPURLResponse
    let code = response?.statusCode ?? HTTP_STATUS_TRANSPORT_ERROR
    noteHTTPStatus(bucket: host, status: code)
    if (200 ..< 300).contains(code) { result = d }
    if code == 429 {
      let header = response?.value(forHTTPHeaderField: "Retry-After")
      noteRateLimit(host: host, retryAfter: parseRetryAfter(header),
                    now: Int(Date().timeIntervalSince1970))
    }
    if ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
      let msg = "[httpGet] \(url.host ?? "?") status=\(code)\(e.map { " err=\($0.localizedDescription)" } ?? "")\n"
      FileHandle.standardError.write(Data(msg.utf8))
    }
    if let provider { providerActivityHandler?(provider, false) }
    sem.signal()
  }.resume()
  if sem.wait(timeout: .now() + timeout + 2) == .timedOut,
     ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
    FileHandle.standardError.write(Data("[httpGet] \(url.host ?? "?") semaphore TIMEOUT\n".utf8))
  }
  return result
}

// JSON access helpers (dynamic schema — built on JSONSerialization)
func jd(_ a: Any?) -> [String: Any]? { a as? [String: Any] }
func ja(_ a: Any?) -> [Any]? { a as? [Any] }
func jn(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue }
func jstr(_ a: Any?) -> String? { a as? String }

func readJSONFile(_ path: String) -> Any? {
  guard let d = FileManager.default.contents(atPath: path) else { return nil }
  return try? JSONSerialization.jsonObject(with: d)
}

func writeJSONFile(_ path: String, _ obj: Any) {
  try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
  if let d = try? JSONSerialization.data(withJSONObject: obj) {
    try? d.write(to: URL(fileURLWithPath: path))
  }
}

func parseISO(_ s: String?) -> Int? {
  guard let s = s else { return nil }
  let f1 = ISO8601DateFormatter()
  f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let d = f1.date(from: s) { return Int(d.timeIntervalSince1970) }
  let f2 = ISO8601DateFormatter()
  if let d = f2.date(from: s) { return Int(d.timeIntervalSince1970) }
  return nil
}

// Reset time: accepts both a number (epoch seconds) and an ISO string
func resetTs(_ v: Any?) -> Int? {
  if let n = jn(v) { return Int(n) }
  return parseISO(jstr(v))
}

func fileMtime(_ path: String) -> Int {
  let d = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
  return Int(d?.timeIntervalSince1970 ?? 0)
}
