// Dropdown menu construction — macOS system-menu tone: gauges live in the body, settings go in a submenu.
// All UI strings go through tr()/trf() (see Localization.swift).
import Cocoa

private let GRAY = "#8b949e"
private let WARN = "#d29922"

private func providerMenuImage(_ provider: Provider) -> NSImage? {
  if provider == .codex, let app = installedProviderApp(.codex) {
    let image = NSWorkspace.shared.icon(forFile: app.path)
    image.size = NSSize(width: 16, height: 16)
    return image
  }
  let name = provider == .claude ? "ClaudeProvider" : "CodexProvider"
  guard let path = Bundle.main.path(forResource: name, ofType: "svg"), let image = NSImage(contentsOfFile: path) else { return nil }
  image.size = NSSize(width: 16, height: 16)
  image.isTemplate = true
  return image
}

private func appMenuImage(_ provider: Provider) -> NSImage? {
  if provider == .claude {
    guard let path = Bundle.main.path(forResource: "ClaudeProvider", ofType: "svg"),
          let image = NSImage(contentsOfFile: path) else { return nil }
    image.size = NSSize(width: 16, height: 16)
    image.isTemplate = true
    return image
  }
  guard let app = installedProviderApp(provider) else { return nil }
  let image = NSWorkspace.shared.icon(forFile: app.path)
  image.size = NSSize(width: 16, height: 16)
  return image
}

// Full state collected in a single refresh
struct Snapshot {
  let now: Int
  let usage: ClaudeUsage?
  let block: ClaudeBlock?
  let models: (models: [ModelUse], total: Double)?
  let codex: CodexUsage?
  let update: (latest: String?, hasUpdate: Bool)
}

@discardableResult
private func row(_ menu: NSMenu, _ text: String, mono: Bool = false, size: CGFloat = 0,
                 color: String? = nil, action: Selector? = nil, target: AnyObject? = nil,
                 repr: Any? = nil, key: String = "", state: NSControl.StateValue? = nil) -> NSMenuItem {
  let item = NSMenuItem(title: text, action: action, keyEquivalent: key)
  var font = NSFont.menuFont(ofSize: size)
  if mono { font = NSFont(name: "Menlo", size: size == 0 ? 12 : size) ?? font }
  var attrs: [NSAttributedString.Key: Any] = [.font: font]
  if let c = color.flatMap(hexColor) { attrs[.foregroundColor] = c }
  item.attributedTitle = NSAttributedString(string: text, attributes: attrs)
  item.target = target
  item.representedObject = repr
  if let s = state { item.state = s }
  menu.addItem(item)
  return item
}

// One remaining-percentage gauge line, e.g. "5h    ▕████████████░░░░░░░░▏  85%  ·  resets 3h 57m"
private func gaugeRow(_ menu: NSMenu, _ label: String, pct: Double, resetText: String?) {
  let used = max(0, min(100, 100 - pct))
  let left = max(0, 100 - used)
  var t = "\(label) ▕\(gaugeBar(used, 20))▏ \(Int(used.rounded()))% \(tr("used")) · \(Int(left.rounded()))% \(tr("left"))"
  if let reset = resetText { t += "  ·  \(reset)" }
  row(menu, t, mono: true, color: usageColor(used).hex)
}

private func resetText(_ resetsAt: Int?, now: Int) -> String? {
  guard let ra = resetsAt else { return nil }
  return ra < now ? tr("reset") : tr("resets") + " " + fmtDur(ra - now)
}

func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate) -> NSMenu {
  let menu = NSMenu()
  let now = snap.now
  let hasClaude = snap.usage != nil || snap.block != nil
  let hasCodex = snap.codex != nil
  let labels = gaugeLabels()

  if swiftBarDup {
    row(menu, tr("⚠️ SwiftBar widget is also running — batteries appear twice"),
        size: 12, color: "#FF9F0A")
    menu.addItem(.separator())
  }

  // ── Claude ──
  if hasClaude {
    let header = row(menu, "Claude Code · " + tr("usage"), size: 13, color: GRAY)
    header.image = providerMenuImage(.claude)
    if let u = snap.usage {
      if let w = u.fiveHour { gaugeRow(menu, labels.five, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
      // Time-attack lap row: reach the reset (the finish line) before hitting 0%
      if let w = u.fiveHour, let ra = w.resetsAt, ra > now {
        let toFinish = fmtDur(ra - now)
        let panicking = max(0, 100 - w.pct) < 12 && ra - now > 1800
        if panicking {
          row(menu, "🏁 " + trf("lap: %@ to the finish — projected empty ⚠", toFinish),
              size: 11, color: "#f85149")
        } else {
          row(menu, "🏁 " + trf("lap: %@ to the finish — on pace ✓", toFinish),
              size: 11, color: "#3fb950")
        }
      }
      if let w = u.weekly { gaugeRow(menu, labels.week, pct: w.pct, resetText: resetText(w.resetsAt, now: now)) }
      if let f = u.fable { gaugeRow(menu, f.model, pct: f.pct, resetText: resetText(f.resetsAt, now: now)) }
      if !u.live {
        row(menu, "⚠ " + trf("cached %@ ago — check login/network", fmtDur(now - u.measuredAt)),
            size: 11, color: WARN)
      }
    }
    if let b = snap.block {
      let cph = b.costPerHour.map { String(format: "%.1f", $0) } ?? "?"
      row(menu, trf("this block  $%.2f · %@ tokens · $%@/h", b.cost, fmtTok(b.tokens), cph),
          mono: true, size: 11, color: GRAY)
    }
    // Per-model detail lives in a submenu to keep the body short
    if let m = snap.models, !m.models.isEmpty {
      let sub = NSMenu()
      let maxCost = m.models[0].cost > 0 ? m.models[0].cost : 1
      for mu in m.models {
        let label = shortModel(mu.name).padding(toLength: 9, withPad: " ", startingAt: 0)
        row(sub, String(format: "%@▕%@▏ $%.1f  %@", label, gaugeBar(mu.cost / maxCost * 100, 12),
                        mu.cost, fmtTok(mu.tokens)), mono: true)
      }
      let parent = row(menu, trf("today by model · $%.0f total", m.total), size: 11, color: GRAY)
      parent.submenu = sub
    }
    let usage = row(menu, tr("Open Claude usage"), action: #selector(AppDelegate.openLink(_:)), target: target, repr: CLAUDE_USAGE_URL)
    usage.image = providerMenuImage(.claude)
    if let app = installedProviderApp(.claude) {
      let open = row(menu, tr("Open Claude app"), action: #selector(AppDelegate.openProviderApp(_:)), target: target, repr: app.path)
      open.image = appMenuImage(.claude)
    }
    menu.addItem(.separator())
  }

  // ── Codex ──
  if let cx = snap.codex {
    let suffix = cx.plan.map { " · \($0)" } ?? cx.limitId.map { " · \($0)" } ?? ""
    let header = row(menu, "Codex\(suffix) · " + tr("usage"), size: 13, color: GRAY)
    header.image = providerMenuImage(.codex)
    let p = windowState(cx.primary, now: now)
    let s = windowState(cx.secondary, now: now)
    if p == nil, s == nil, let cr = cx.credits {
      if cr.unlimited {
        row(menu, tr("credits  unlimited"), mono: true, color: "#3fb950")
      } else if !cr.hasCredits || (cr.balance ?? 0) <= 0 {
        row(menu, tr("credits  exhausted — buy more or wait for reset"), mono: true, color: "#f85149")
      } else {
        row(menu, trf("credits  balance %.0f", cr.balance ?? 0), mono: true, color: "#3fb950")
      }
    }
    func codexReset(_ w: WindowState) -> String? {
      w.stale ? tr("reset") : w.resetsIn.map { tr("resets") + " " + fmtDur($0) }
    }
    if let p = p { gaugeRow(menu, labels.five, pct: p.pct, resetText: codexReset(p)) }
    if let s = s { gaugeRow(menu, labels.week, pct: s.pct, resetText: codexReset(s)) }
    if !cx.live {
      row(menu, "⚠ " + trf("data from %@ ago — check login/network", fmtDur(now - cx.measuredAt)),
          size: 11, color: WARN)
    }
    let usage = row(menu, tr("Open Codex usage"), action: #selector(AppDelegate.openLink(_:)), target: target, repr: CODEX_USAGE_URL)
    usage.image = providerMenuImage(.codex)
    if let app = installedProviderApp(.codex) {
      let open = row(menu, tr("Open Codex app"), action: #selector(AppDelegate.openProviderApp(_:)), target: target, repr: app.path)
      open.image = appMenuImage(.codex)
    }
    menu.addItem(.separator())
  }

  if !hasClaude, !hasCodex {
    row(menu, tr("Run Claude Code or Codex and usage will appear here"), size: 12, color: GRAY)
    menu.addItem(.separator())
  }

  // ── footer ──
  if snap.update.hasUpdate, let latest = snap.update.latest {
    row(menu, trf("Install v%@ update — one click (current v%@)", latest, APP_VERSION),
        color: "#28963f", action: #selector(AppDelegate.selfUpdate(_:)), target: target, repr: latest)
  }
  row(menu, tr("Refresh"), action: #selector(AppDelegate.refresh), target: target, key: "r")

  row(menu, tr("Settings"), action: #selector(AppDelegate.showSettings), target: target)

  menu.addItem(.separator())
  menu.addItem(NSMenuItem(title: tr("Quit"),
                          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  return menu
}
