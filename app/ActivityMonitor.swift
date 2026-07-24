import Foundation

// Detects real Claude/Codex work from append-only session logs. This works
// across terminal clients and desktop clients that share the same session
// stores, without reading terminal windows or inspecting message contents.
final class ProviderActivityMonitor {
  typealias Handler = (Provider, Bool) -> Void

  private struct Fingerprint: Equatable {
    let path: String
    let modifiedAt: TimeInterval
    let size: Int
  }

  private let roots: [Provider: String]
  private let queue = DispatchQueue(label: "com.dennykim.ccb.activity", qos: .utility)
  private let handler: Handler
  private var timer: Timer?
  private var fingerprints: [Provider: Fingerprint] = [:]
  private var activeUntil: [Provider: Date] = [:]
  private var reported: Set<Provider> = []
  private var scanning = false

  init(roots: [Provider: String]? = nil, handler: @escaping Handler) {
    self.roots = roots ?? [
      .claude: "\(HOME)/.claude/projects",
      .codex: "\(HOME)/.codex/sessions",
    ]
    self.handler = handler
  }

  func start() {
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
      var latest: [Provider: Fingerprint] = [:]
      for (provider, root) in self.roots {
        latest[provider] = self.latestFingerprint(root: root)
      }
      DispatchQueue.main.async {
        self.apply(latest: latest, initial: initial)
        self.scanning = false
      }
    }
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
        handler(provider, active)
      }
    }
  }
}
