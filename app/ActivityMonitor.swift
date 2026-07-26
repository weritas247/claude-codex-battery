import Foundation

// If CCB_DEBUG=1, traces discovery/scans/transitions to stderr (for diagnostics). Read once and
// taken @autoclosure so a scan builds no strings while it is off.
private let activityDebugEnabled = ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil

private func activityDebug(_ message: @autoclosure () -> String) {
  guard activityDebugEnabled else { return }
  FileHandle.standardError.write(Data("[activity] \(message())\n".utf8))
}

private func activityLabel(_ provider: Provider) -> String {
  provider == .claude ? "claude" : "codex"
}

// Rollout logs live under a codex home's sessions/ subtree.
func codexSessionsRoot(codexHome: String) -> String {
  URL(fileURLWithPath: codexHome, isDirectory: true)
    .appendingPathComponent("sessions", isDirectory: true).path
}

// Every root a provider's scan walks: its default first, then whatever discovery found, deduped
// so a discovered root that repeats the default is not stat'd twice.
func activityWatchRoots(default fallback: String, discovered: [String]) -> [String] {
  var seen = Set<String>()
  return ([fallback] + discovered).filter { !$0.isEmpty && seen.insert($0).inserted }
}

// GUI clients (Orca) run `codex` with a private CODEX_HOME, so the session it is appending right
// now lives there and ~/.codex/sessions only catches up once the session is copied back. Read the
// environment of every running `codex` to find those homes — plus our own, if we were given one.
// Anything unavailable degrades to no extra roots rather than failing the scan.
func discoverCodexSessionRoots() -> [Provider: [String]] {
  var homes: [String] = []
  if let own = ProcessInfo.processInfo.environment["CODEX_HOME"], !own.isEmpty {
    homes.append(own)
    activityDebug("discover: own CODEX_HOME=\(own)")
  }
  let pids = runningProcessIDs()
  var named = 0
  var withoutHome = 0
  for pid in pids where processName(pid) == "codex" {
    named += 1
    guard let home = processEnvironmentValue(pid: pid, key: "CODEX_HOME"), !home.isEmpty else {
      withoutHome += 1
      continue
    }
    homes.append(home)
  }
  var seen = Set<String>() // several codex processes usually share one home
  let roots = homes.compactMap { home -> String? in
    let root = codexSessionsRoot(codexHome: home)
    return seen.insert(root).inserted ? root : nil
  }
  activityDebug("discover: pids=\(pids.count) named-codex=\(named) without-home=\(withoutHome)"
                  + " roots=\(roots)")
  return roots.isEmpty ? [:] : [.codex: roots]
}

private func runningProcessIDs() -> [pid_t] {
  let capacity = proc_listallpids(nil, 0)
  guard capacity > 0, capacity < 100_000 else {
    activityDebug("discover: proc_listallpids sizing returned \(capacity) errno=\(errno)")
    return []
  }
  // Headroom because processes can start between sizing the buffer and filling it
  var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
  let count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
  guard count > 0 else {
    activityDebug("discover: proc_listallpids returned \(count) errno=\(errno)")
    return []
  }
  return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
}

private func processName(_ pid: pid_t) -> String? {
  var buffer = [UInt8](repeating: 0, count: 256)
  guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}

// KERN_PROCARGS2 lays out: argc (Int32), the exec path, NUL padding, argc argv strings, then the
// environment. Fails (and so returns nil) for processes owned by another user.
private func processEnvironmentValue(pid: pid_t, key: String) -> String? {
  var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
  let header = MemoryLayout<Int32>.size
  var size = 0
  guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > header else {
    activityDebug("discover: pid \(pid) procargs sizing failed errno=\(errno) size=\(size)")
    return nil
  }
  var buffer = [UInt8](repeating: 0, count: size)
  guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > header else {
    activityDebug("discover: pid \(pid) procargs read failed errno=\(errno) size=\(size)")
    return nil
  }
  let end = min(size, buffer.count)
  var argc: Int32 = 0
  withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer[0..<header]) }
  guard argc >= 0 else { return nil }

  var offset = header
  func nextString() -> String? {
    guard offset < end else { return nil }
    let start = offset
    while offset < end && buffer[offset] != 0 { offset += 1 }
    let value = String(decoding: buffer[start..<offset], as: UTF8.self)
    if offset < end { offset += 1 }
    return value
  }
  func skipPadding() { while offset < end && buffer[offset] == 0 { offset += 1 } }

  _ = nextString()
  skipPadding()
  var remaining = Int(argc) // bounded by `end` too, so a bogus argc cannot spin
  while remaining > 0, offset < end {
    _ = nextString()
    remaining -= 1
  }
  skipPadding()
  let prefix = "\(key)="
  var entries = 0
  while let entry = nextString(), !entry.isEmpty {
    entries += 1
    if entry.hasPrefix(prefix) { return String(entry.dropFirst(prefix.count)) }
  }
  // Distinguishes "the key is not set" from "the environment came back empty"
  activityDebug("discover: pid \(pid) has no \(key) among \(entries) env entries (argc=\(argc))")
  return nil
}

// Detects real Claude/Codex work from append-only session logs. This works
// across terminal clients and desktop clients that share the same session
// stores, without reading terminal windows or inspecting message contents.
final class ProviderActivityMonitor {
  typealias Handler = (Provider, Bool) -> Void
  // Extra session roots found at runtime, per provider (see discoverCodexSessionRoots).
  typealias RootDiscovery = () -> [Provider: [String]]

  private struct Fingerprint: Equatable {
    let path: String
    let modifiedAt: TimeInterval
    let size: Int
  }

  private let roots: [Provider: String]
  private let discovery: RootDiscovery
  private let queue = DispatchQueue(label: "com.dennykim.ccb.activity", qos: .utility)
  private let handler: Handler
  private var timer: Timer?
  private var fingerprints: [Provider: Fingerprint] = [:]
  private var activeUntil: [Provider: Date] = [:]
  private var reported: Set<Provider> = []
  private var scanning = false
  private var discovered: [Provider: [String]] = [:] // queue only
  private var discoveredAt = Date.distantPast        // queue only

  init(roots: [Provider: String]? = nil,
       discovery: @escaping RootDiscovery = discoverCodexSessionRoots,
       handler: @escaping Handler) {
    self.roots = roots ?? [
      .claude: "\(HOME)/.claude/projects",
      .codex: "\(HOME)/.codex/sessions",
    ]
    self.discovery = discovery
    self.handler = handler
  }

  func start() {
    activityDebug("start: default roots=\(roots.map { "\(activityLabel($0.key))=\($0.value)" }.sorted())")
    scan(initial: true)
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.scan(initial: false)
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func scan(initial: Bool) {
    guard !scanning else { return }
    scanning = true
    queue.async { [weak self] in
      guard let self else { return }
      self.refreshDiscoveryIfDue()
      var latest: [Provider: Fingerprint] = [:]
      for (provider, root) in self.roots {
        let roots = activityWatchRoots(default: root, discovered: self.discovered[provider] ?? [])
        let newest = self.newestFingerprint(roots: roots)
        activityDebug("scan \(activityLabel(provider)) roots=\(roots) newest="
                        + (newest.map { "\($0.path) mtime=\($0.modifiedAt) size=\($0.size)" }
                            ?? "none"))
        latest[provider] = newest
      }
      DispatchQueue.main.async {
        self.apply(latest: latest, initial: initial)
        self.scanning = false
      }
    }
  }

  // Walking every running process costs far more than stat'ing a directory tree, and a codex turn
  // outlives this cadence — so discovery deliberately lags the 1s scan.
  private func refreshDiscoveryIfDue() {
    let now = Date()
    guard now.timeIntervalSince(discoveredAt) >= 5.0 else { return }
    discoveredAt = now
    discovered = discovery()
    activityDebug("discovery refreshed: "
                    + discovered.map { "\(activityLabel($0.key))=\($0.value)" }.sorted()
                      .joined(separator: " ")
                    + (discovered.isEmpty ? "(none)" : ""))
  }

  private func newestFingerprint(roots: [String]) -> Fingerprint? {
    var newest: Fingerprint?
    for root in roots {
      guard let candidate = latestFingerprint(root: root) else { continue }
      if newest == nil || candidate.modifiedAt > newest!.modifiedAt { newest = candidate }
    }
    return newest
  }

  private func latestFingerprint(root: String) -> Fingerprint? {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return nil }

    var newest: Fingerprint?
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true,
            let date = values.contentModificationDate else { continue }
      let candidate = Fingerprint(path: url.path,
                                  modifiedAt: date.timeIntervalSinceReferenceDate,
                                  size: values.fileSize ?? 0)
      if newest == nil || candidate.modifiedAt > newest!.modifiedAt {
        newest = candidate
      }
    }
    return newest
  }

  private func apply(latest: [Provider: Fingerprint], initial: Bool) {
    let now = Date()
    let forced = ProcessInfo.processInfo.environment["CCB_ACTIVITY_TEST"]

    for provider in [Provider.claude, .codex] {
      let previous = fingerprints[provider]
      let current = latest[provider]
      fingerprints[provider] = current

      let forcedActive = forced == "both"
        || (forced == "claude" && provider == .claude)
        || (forced == "codex" && provider == .codex)
      if forcedActive || (!initial && current != nil && current != previous) {
        activeUntil[provider] = now.addingTimeInterval(forcedActive ? 3600 : 4.0)
      }

      let active = (activeUntil[provider] ?? .distantPast) > now
      let wasActive = reported.contains(provider)
      if active != wasActive {
        if active { reported.insert(provider) } else { reported.remove(provider) }
        activityDebug("\(activityLabel(provider)) -> \(active ? "ACTIVE" : "idle")")
        handler(provider, active)
      }
    }
  }
}
