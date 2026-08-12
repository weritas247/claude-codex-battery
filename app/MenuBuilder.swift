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
  var rateLimited: RateLimitState = .none
  var health: ProviderHealth = .unknown
}

// Seconds until each provider's API may be called again, or nil when it is free.
struct RateLimitState {
  let claude: Int?
  let codex: Int?
  static let none = RateLimitState(claude: nil, codex: nil)
}

// ── Why the numbers stopped updating ───────────────────────────────────────
// "check login/network" was the only thing a stale row could say, so a throttled account, a
// signed-out profile and an offline Mac all read the same and none of them named a fix. Each case
// here has a different remedy, which is what the recovery submenu is built from.
enum LiveFailure: Equatable {
  case liveDisabled // the .no-live opt-out is in place
  case signedOut // no credentials for the selected profile
  case authExpired // credentials exist but the server refused them
  case rateLimited(Int) // seconds left on the cooldown
  case unreachable // request attempted, no usable answer
}

struct ProviderHealth {
  let claude: LiveFailure?
  let codex: LiveFailure?
  static let unknown = ProviderHealth(claude: nil, codex: nil)
}

// Pure so the ordering can be asserted without a network, a keychain, or a clock.
// Order is "what blocks the next request first": an opt-out beats a missing login, a missing login
// beats a cooldown (no token means no request was ever sent to be throttled), and a refusal only
// means anything once credentials exist.
// credentialsPresent is autoclosured because answering it costs a keychain lookup, and the opt-out
// case above it must not pay for a question it never asks.
func diagnoseLive(liveOff: Bool, credentialsPresent: @autoclosure () -> Bool,
                  credentialsExpired: @autoclosure () -> Bool = false, rateLimitedFor: Int?,
                  lastStatus: Int?) -> LiveFailure {
  if liveOff { return .liveDisabled }
  if !credentialsPresent() { return .signedOut }
  // A lapsed deadline is known locally, so there is no reason to make the user wait for the 401
  // that would otherwise be the only evidence.
  if credentialsExpired() { return .authExpired }
  if let wait = rateLimitedFor, wait > 0 { return .rateLimited(wait) }
  // A 429 seen after the local cooldown lapsed is the case that produced the bogus login warning:
  // the server is still throttling even though this Mac thinks the penalty is served.
  if lastStatus == 429 { return .rateLimited(0) }
  if lastStatus == 401 || lastStatus == 403 { return .authExpired }
  return .unreachable
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

// Why the numbers are stale. A 429 is neither a login nor a network fault, so saying
// "check login/network" sends the user hunting for a problem that isn't there — name the throttle
// and when the app will try again instead.
func freshnessText(live: Bool, measuredAt: Int, now: Int, rateLimitedFor: Int?, language: String,
                   failure: LiveFailure? = nil) -> String {
  if live { return tr("live · updated just now", language: language) }
  let age = fmtDur(max(0, now - measuredAt))
  let warn = { (key: String) in "⚠ " + trf(key, language: language, age) }
  // Ordered like diagnoseLive, and for the same reason. A cooldown running alongside a dead login
  // is a symptom of retrying with it, so promising "retrying in 10m" would send the user off to
  // wait out a deadline that cannot fix anything — the login has to be named first.
  switch failure {
  case .liveDisabled: return warn("cached %@ ago — live updates are off")
  case .signedOut: return warn("cached %@ ago — no login found")
  case .authExpired: return warn("cached %@ ago — login expired, sign in again")
  case .unreachable: return warn("cached %@ ago — can't reach the server")
  case .rateLimited, nil:
    if let wait = rateLimitedFor, wait > 0 {
      return "⚠ " + trf("rate limited — retrying in %@ (cached %@ ago)", language: language,
                        fmtDur(wait), age)
    }
    // A throttle with no countdown left means the server is still refusing past the local
    // cooldown; "retrying in 0m" would be a promise the next 429 immediately breaks.
    return failure == nil ? warn("cached %@ ago — check login/network")
      : warn("cached %@ ago — still rate limited by the server")
  }
}

// ── Recovery flow ──────────────────────────────────────────────────────────
// Hung off the warning row itself rather than added as sibling rows: the fix belongs exactly where
// the problem is reported, and a submenu costs no vertical space in the common healthy case.
// Every action here is one the user takes deliberately — nothing switches logins on its own,
// because a silent switch would change which account the numbers describe.
func loginLabel(_ login: ClaudeLogin, isCurrent: Bool, language: String) -> String {
  let name = login.dir == DEFAULT_CLAUDE_PROFILE
    ? tr("Default (~/.claude)", language: language)
    : (login.dir as NSString).lastPathComponent
  if !login.present { return "\(name) — " + tr("no login", language: language) }
  if login.expired { return "\(name) — " + tr("login expired", language: language) }
  if let wait = login.cooldown {
    return "\(name) — " + trf("rate limited %@", language: language, fmtDur(wait))
  }
  return isCurrent ? name : "\(name) — " + tr("ready", language: language)
}

func recoveryMenu(for failure: LiveFailure, provider: Provider, logins: [ClaudeLogin],
                  currentProfile: String, appPath: String?, target: AppDelegate,
                  language: String) -> NSMenu? {
  let sub = NSMenu()
  let usageURL = provider == .claude ? CLAUDE_USAGE_URL : CODEX_USAGE_URL

  if failure == .liveDisabled {
    row(sub, tr("Turn live updates back on", language: language),
        action: #selector(AppDelegate.enableLiveUpdates), target: target)
    return sub
  }

  let loginProblem = isRateLimited(failure) || failure == .signedOut || failure == .authExpired
  let alternatives = logins.filter { $0.dir != currentProfile && $0.usable }

  // Every login is listed with the state it is actually in, and only the ones that can answer are
  // clickable. Listing bare names let a logged-out or months-expired profile look like a working
  // escape from a throttle — the user switches, gets refused, and switches back none the wiser.
  if provider == .claude, logins.count > 1, loginProblem {
    let switcher = NSMenu()
    for login in logins {
      let isCurrent = login.dir == currentProfile
      let item = row(switcher, loginLabel(login, isCurrent: isCurrent, language: language),
                     action: #selector(AppDelegate.switchClaudeProfileFromMenu(_:)),
                     target: target, repr: login.dir, state: isCurrent ? .on : .off)
      // Switching to the login already in use, or to one that cannot answer, changes nothing.
      item.isEnabled = login.usable && !isCurrent
    }
    switcher.autoenablesItems = false // otherwise AppKit re-enables the dead logins on display
    let parent = row(sub, tr("Switch Claude login", language: language))
    parent.submenu = switcher
  }

  // Only worth saying when a switcher is sitting right above it full of logins that can't help.
  if provider == .claude, logins.count > 1, loginProblem, alternatives.isEmpty {
    row(sub, tr("No other login is available to switch to", language: language),
        size: 11, color: GRAY)
  }

  // Signing in has to happen here rather than be described: the row launches Claude Code against
  // the config dir it names. Which dirs are worth offering depends on what is actually broken —
  // a throttled-but-valid login does not need signing in, whereas the dead profiles beside it do,
  // because reviving one is what creates something to switch to.
  if provider == .claude, loginProblem {
    let needSignIn = logins.filter { !$0.present || $0.expired }
    let signInRow = { (login: ClaudeLogin, menu: NSMenu, titleKey: String) in
      let name = login.dir == DEFAULT_CLAUDE_PROFILE
        ? tr("Default (~/.claude)", language: language)
        : (login.dir as NSString).lastPathComponent
      let item = row(menu, titleKey.isEmpty ? name : trf(titleKey, language: language, name),
                     action: #selector(AppDelegate.signInToProfile(_:)), target: target,
                     repr: login.dir)
      item.toolTip = signInCommand(for: login.dir)
    }
    if needSignIn.count == 1 {
      signInRow(needSignIn[0], sub, "Sign in to %@…") // a submenu for one entry is just a detour
    } else if needSignIn.count > 1 {
      let signIns = NSMenu()
      for login in needSignIn { signInRow(login, signIns, "") }
      let parent = row(sub, tr("Sign in to a login", language: language))
      parent.submenu = signIns
    }
  }
  if provider == .codex, failure == .signedOut || failure == .authExpired, let appPath {
    row(sub, tr("Sign in with the Codex app", language: language),
        action: #selector(AppDelegate.openProviderApp(_:)), target: target, repr: appPath)
  }

  if isRateLimited(failure) {
    // Named as a hazard, not a remedy. Anthropic restarts the penalty clock on every request made
    // during one, so an innocuous-looking "Retry" here is how a short throttle becomes a long one.
    row(sub, tr("Force retry now — may extend the limit", language: language),
        color: WARN, action: #selector(AppDelegate.forceRetry(_:)), target: target,
        repr: provider == .claude ? "claude" : "codex")
  } else {
    row(sub, tr("Retry now", language: language), action: #selector(AppDelegate.refresh), target: target)
  }

  sub.addItem(.separator())
  let openTitle = provider == .claude
    ? tr("Open Claude usage", language: language)
    : tr("Open Codex usage", language: language)
  row(sub, openTitle, action: #selector(AppDelegate.openLink(_:)), target: target, repr: usageURL)
  return sub.items.isEmpty ? nil : sub
}

private func isRateLimited(_ failure: LiveFailure) -> Bool {
  if case .rateLimited = failure { return true }
  return false
}

private func resetText(_ resetsAt: Int?, now: Int, language: String) -> String? {
  guard let reset = resetsAt else { return nil }
  return reset <= now ? tr("reset", language: language)
    : tr("resets", language: language) + " " + fmtDur(reset - now)
}

// `claudeProfiles`/`currentClaudeProfile` stay nil in production and are resolved only when a
// recovery submenu is actually built — a healthy menu must not pay for a $HOME scan every refresh.
// Tests pass them explicitly so profile switching can be asserted without touching the filesystem.
func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate,
               assets: ProviderAssetContext = .production(), language: String = UI_LANG,
               batteryGreen: String? = nil, logins: [ClaudeLogin]? = nil,
               currentClaudeProfile: String? = nil) -> NSMenu {
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
      let failure = usage.live ? nil : snap.health.claude
      let freshness = freshnessText(live: usage.live, measuredAt: usage.measuredAt, now: now,
                                    rateLimitedFor: snap.rateLimited.claude, language: language,
                                    failure: failure)
      let freshnessRow = row(menu, freshness, size: 11, color: usage.live ? GRAY : WARN)
      if let failure {
        freshnessRow.submenu = recoveryMenu(for: failure, provider: .claude,
                                            logins: logins ?? claudeLogins(now: now),
                                            currentProfile: currentClaudeProfile ?? claudeProfileDir(),
                                            appPath: assets.installedApp(for: .claude)?.path,
                                            target: target, language: language)
      }
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
    let codexFailure = codex.live ? nil : snap.health.codex
    let freshness = freshnessText(live: codex.live, measuredAt: codex.measuredAt, now: now,
                                  rateLimitedFor: snap.rateLimited.codex, language: language,
                                  failure: codexFailure)
    let codexFreshnessRow = row(menu, freshness, size: 11, color: codex.live ? GRAY : WARN)
    if let codexFailure {
      codexFreshnessRow.submenu = recoveryMenu(for: codexFailure, provider: .codex,
                                               logins: [], currentProfile: "",
                                               appPath: assets.installedApp(for: .codex)?.path,
                                               target: target, language: language)
    }
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
