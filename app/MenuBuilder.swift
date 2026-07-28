// Dropdown menu construction — macOS system-menu tone: gauges live in the body, settings go in a submenu.
// All UI strings go through tr()/trf() (see Localization.swift).
import Cocoa

private let GRAY = "#8b949e"
private let WARN = "#d29922"

struct Snapshot {
  let now: Int
  let usage: ClaudeUsage?
  let block: ClaudeBlock?
  let models: (models: [ModelUse], total: Double)?
  let codex: CodexUsage?
  let update: (latest: String?, hasUpdate: Bool)
  // A `var` with a default keeps the existing construction sites compiling — a `let` with a
  // default drops out of the memberwise initializer entirely.
  var accounts: AccountNames = .none
}

// Header strings are pure functions so they can be asserted without a filesystem. With no account
// the segment is dropped whole, leaving a header identical to the one before this feature.
func accountSuffix(_ account: String?) -> String {
  guard let account, !account.isEmpty else { return "" }
  return " · \(account)"
}

func claudeHeaderTitle(account: String?, usageWord: String) -> String {
  "Claude Code\(accountSuffix(account)) · \(usageWord) ↗"
}

func codexHeaderTitle(plan: String?, limitId: String?, account: String?, usageWord: String) -> String {
  let planSuffix = plan.map { " · \($0)" } ?? limitId.map { " · \($0)" } ?? ""
  return "Codex\(planSuffix)\(accountSuffix(account)) · \(usageWord) ↗"
}

func headerAccessibilityLabel(_ base: String, account: String?) -> String {
  guard let account, !account.isEmpty else { return base }
  return "\(base) — \(account)"
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

private func gaugeRow(_ menu: NSMenu, _ label: String, remaining: Double, resetText: String?,
                      usageURL: String, usageTitle: String, target: AppDelegate, language: String,
                      batteryGreen: String?) {
  let value = normalizedRemaining(remaining)
  let remainingText = trf("%d%% remaining", language: language, Int(value.rounded()))
  var semanticTitle = "\(label) \(remainingText)"
  var text = "\(label) ▕\(gaugeBar(value, 20))▏ \(remainingText)"
  if let resetText {
    semanticTitle += ", \(resetText)"
    text += "  ·  \(resetText)"
  }
  text += "  ↗"
  let item = row(menu, text, mono: true, color: usageColor(forRemaining: value, custom: batteryGreen).hex,
                 action: #selector(AppDelegate.openLink(_:)), target: target, repr: usageURL)
  item.toolTip = usageTitle
  item.setAccessibilityLabel(semanticTitle)
  item.setAccessibilityHelp(usageTitle)
}

private func resetText(_ resetsAt: Int?, now: Int, language: String) -> String? {
  guard let reset = resetsAt else { return nil }
  return reset <= now ? tr("reset", language: language)
    : tr("resets", language: language) + " " + fmtDur(reset - now)
}

func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate,
               assets: ProviderAssetContext = .production(), language: String = UI_LANG, batteryGreen: String? = nil) -> NSMenu {
  let menu = NSMenu()
  let now = snap.now
  let hasClaude = snap.usage != nil || snap.block != nil
  let hasCodex = snap.codex != nil
  let labels = gaugeLabels(language: language)

  if swiftBarDup {
    row(menu, tr("⚠️ SwiftBar widget is also running — batteries appear twice", language: language),
        size: 12, color: "#FF9F0A")
    menu.addItem(.separator())
  }

  if hasClaude {
    let usageTitle = tr("Open Claude usage", language: language)
    let header = row(menu, claudeHeaderTitle(account: snap.accounts.claude,
                                             usageWord: tr("usage", language: language)),
                     size: 13, color: GRAY, action: #selector(AppDelegate.openLink(_:)),
                     target: target, repr: CLAUDE_USAGE_URL)
    header.image = assets.providerImage(for: .claude)
    header.toolTip = usageTitle
    header.setAccessibilityLabel(headerAccessibilityLabel(usageTitle, account: snap.accounts.claude))
    if let usage = snap.usage {
      if let window = usage.fiveHour {
        let remaining = normalizedRemaining(fromUsed: window.pct)
        gaugeRow(menu, labels.five, remaining: remaining,
                 resetText: resetText(window.resetsAt, now: now, language: language),
                 usageURL: CLAUDE_USAGE_URL, usageTitle: usageTitle, target: target, language: language, batteryGreen: batteryGreen)
        if let reset = window.resetsAt, reset > now,
           hasLowRemainingResetDistantRisk(remaining: remaining, resetSeconds: Double(reset - now)) {
          row(menu, "⚠ " + trf("5h remaining is low and reset is still %@ away",
                                language: language, fmtDur(reset - now)), size: 11, color: "#f85149")
        }
      }
      if let window = usage.weekly {
        gaugeRow(menu, labels.week, remaining: normalizedRemaining(fromUsed: window.pct),
                 resetText: resetText(window.resetsAt, now: now, language: language),
                 usageURL: CLAUDE_USAGE_URL, usageTitle: usageTitle, target: target, language: language, batteryGreen: batteryGreen)
      }
      if let window = usage.fable {
        gaugeRow(menu, window.model, remaining: normalizedRemaining(fromUsed: window.pct),
                 resetText: resetText(window.resetsAt, now: now, language: language),
                 usageURL: CLAUDE_USAGE_URL, usageTitle: usageTitle, target: target, language: language, batteryGreen: batteryGreen)
      }
      let freshness = usage.live
        ? tr("live · updated just now", language: language)
        : "⚠ " + trf("cached %@ ago — check login/network", language: language,
                       fmtDur(max(0, now - usage.measuredAt)))
      row(menu, freshness, size: 11, color: usage.live ? GRAY : WARN)
    }
    if let block = snap.block {
      let cph = block.costPerHour.map { String(format: "%.1f", $0) } ?? "?"
      row(menu, trf("this block  $%.2f · %@ tokens · $%@/h", language: language,
                    block.cost, fmtTok(block.tokens), cph), mono: true, size: 11, color: GRAY)
    }
    if let models = snap.models, !models.models.isEmpty {
      let sub = NSMenu()
      let maxCost = models.models[0].cost > 0 ? models.models[0].cost : 1
      for model in models.models {
        let label = shortModel(model.name).padding(toLength: 9, withPad: " ", startingAt: 0)
        row(sub, String(format: "%@▕%@▏ $%.1f  %@", label, gaugeBar(model.cost / maxCost * 100, 12),
                        model.cost, fmtTok(model.tokens)), mono: true)
      }
      let parent = row(menu, trf("today by model · $%.0f total", language: language, models.total),
                       size: 11, color: GRAY)
      parent.submenu = sub
    }
    if let app = assets.installedApp(for: .claude) {
      let title = tr("Open Claude app", language: language)
      let open = row(menu, title, action: #selector(AppDelegate.openProviderApp(_:)), target: target, repr: app.path)
      open.image = assets.applicationImage(for: .claude)
      open.toolTip = title
      open.setAccessibilityLabel(title)
    }
    menu.addItem(.separator())
  }

  if let codex = snap.codex {
    let usageTitle = tr("Open Codex usage", language: language)
    let header = row(menu, codexHeaderTitle(plan: codex.plan, limitId: codex.limitId,
                                            account: snap.accounts.codex,
                                            usageWord: tr("usage", language: language)),
                     size: 13, color: GRAY, action: #selector(AppDelegate.openLink(_:)),
                     target: target, repr: CODEX_USAGE_URL)
    header.image = assets.providerImage(for: .codex)
    header.toolTip = usageTitle
    header.setAccessibilityLabel(headerAccessibilityLabel(usageTitle, account: snap.accounts.codex))
    let primary = windowState(codex.primary, now: now)
    let secondary = windowState(codex.secondary, now: now)
    if primary == nil, secondary == nil, let credits = codex.credits {
      if credits.unlimited {
        row(menu, tr("credits  unlimited", language: language), mono: true, color: "#3fb950")
      } else if !credits.hasCredits || (credits.balance ?? 0) <= 0 {
        row(menu, tr("credits  exhausted — buy more or wait for reset", language: language), mono: true, color: "#f85149")
      } else {
        row(menu, trf("credits  balance %.0f", language: language, credits.balance ?? 0), mono: true, color: "#3fb950")
      }
    }
    func codexReset(_ window: WindowState) -> String? {
      window.stale ? tr("reset", language: language)
        : window.resetsIn.map { tr("resets", language: language) + " " + fmtDur($0) }
    }
    if let primary {
      gaugeRow(menu, labels.five, remaining: normalizedRemaining(fromUsed: primary.pct), resetText: codexReset(primary),
               usageURL: CODEX_USAGE_URL, usageTitle: usageTitle, target: target, language: language, batteryGreen: batteryGreen)
    }
    if let secondary {
      gaugeRow(menu, labels.week, remaining: normalizedRemaining(fromUsed: secondary.pct), resetText: codexReset(secondary),
               usageURL: CODEX_USAGE_URL, usageTitle: usageTitle, target: target, language: language, batteryGreen: batteryGreen)
    }
    let freshness = codex.live
      ? tr("live · updated just now", language: language)
      : "⚠ " + trf("cached %@ ago — check login/network", language: language,
                     fmtDur(max(0, now - codex.measuredAt)))
    row(menu, freshness, size: 11, color: codex.live ? GRAY : WARN)
    if let app = assets.installedApp(for: .codex) {
      let title = tr("Open Codex app", language: language)
      let open = row(menu, title, action: #selector(AppDelegate.openProviderApp(_:)), target: target, repr: app.path)
      open.image = assets.applicationImage(for: .codex)
      open.toolTip = title
      open.setAccessibilityLabel(title)
    }
    menu.addItem(.separator())
  }

  if !hasClaude, !hasCodex {
    row(menu, tr("Run Claude Code or Codex and usage will appear here", language: language), size: 12, color: GRAY)
    menu.addItem(.separator())
  }
  if snap.update.hasUpdate, let latest = snap.update.latest {
    row(menu, trf("Install v%@ update — one click (current v%@)", language: language, latest, APP_VERSION),
        color: "#28963f", action: #selector(AppDelegate.selfUpdate(_:)), target: target, repr: latest)
  }
  row(menu, tr("Refresh", language: language), action: #selector(AppDelegate.refresh), target: target, key: "r")
  row(menu, tr("Settings", language: language), action: #selector(AppDelegate.showSettings), target: target)
  menu.addItem(.separator())
  menu.addItem(NSMenuItem(title: tr("Quit", language: language),
                          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  return menu
}
