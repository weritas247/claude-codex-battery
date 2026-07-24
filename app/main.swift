// Claude & Codex Usage Battery — a fully standalone native menu bar app (RunCat style)
// Runs independently without SwiftBar/bun: keychain/auth file → queries the usage API directly → renders the battery.
import Cocoa
import ServiceManagement

let REFRESH_SECONDS = 120.0

// If SwiftBar has the same widget plugin enabled, the battery shows up twice — detect and warn
func swiftBarDuplicate() -> Bool {
  guard FileManager.default.fileExists(atPath: "\(HOME)/.swiftbar-plugins/claude-codex-usage.2m.js"),
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ameba.SwiftBar").isEmpty
  else { return false }
  let disabled = UserDefaults(suiteName: "com.ameba.SwiftBar")?.array(forKey: "DisabledPlugins") as? [String] ?? []
  return !disabled.contains("claude-codex-usage.2m.js")
}

// Batch data collection (called from a background thread)
func collectSnapshot() -> Snapshot {
  let now = Int(Date().timeIntervalSince1970)
  return Snapshot(now: now,
                  usage: getClaudeUsage(now: now),
                  block: getClaudeBlock(now: now),
                  models: getClaudeModels(),
                  codex: getCodex(now: now),
                  update: getUpdateInfo(now: now))
}

// Snapshot → menu bar battery items (same logic as the widget JS's rendering code)
func battItems(_ snap: Snapshot) -> [BattItem] {
  var items: [BattItem] = []
  if let u = snap.usage {
    if isMetricVisible("claude5") { items.append(BattItem(label: "C5", remain: u.fiveHour.map { max(0, 100 - $0.pct) })) }
    if isMetricVisible("claudeWeek") { items.append(BattItem(label: "CW", remain: u.weekly.map { max(0, 100 - $0.pct) })) }
    if isMetricVisible("claudeFable"), let f = u.fable { items.append(BattItem(label: "CF", remain: max(0, 100 - f.pct))) }
  } else if let b = snap.block, isMetricVisible("claude5") {
    items.append(BattItem(label: "C5", remain: max(0, 100 - b.elapsedPct)))
  }
  if let cx = snap.codex, cx.primary != nil || cx.secondary != nil {
    // Only draws whichever window is active at the time — a missing window is omitted rather than shown as an empty capsule
    if isMetricVisible("codex5"), let p = windowState(cx.primary, now: snap.now) {
      items.append(BattItem(label: "X5", remain: max(0, 100 - p.pct)))
    }
    if isMetricVisible("codexWeek"), let s = windowState(cx.secondary, now: snap.now) {
      items.append(BattItem(label: "XW", remain: max(0, 100 - s.pct)))
    }
  } else if let cr = snap.codex?.credits {
    // premium consumable-style: has credits=100 / exhausted=0 / unlimited=100
    let remain: Double = cr.unlimited ? 100 : (cr.hasCredits && (cr.balance ?? 0) > 0 ? 100 : 0)
    items.append(BattItem(label: "X", remain: remain))
  }
  // For visually testing the golden battery (dev only)
  if ProcessInfo.processInfo.environment["CCB_GOLD_TEST"] != nil {
    return items.map { BattItem(label: $0.label, remain: $0.remain == nil ? nil : 100) }
  }
  return items
}

// Cat state from the snapshot: burn rate → speed, projected depletion → panic
// (CCB_CAT_TEST=sleep|walk|run|dash|panic forces a state for testing)
func catState(_ snap: Snapshot) -> CatState {
  if let t = ProcessInfo.processInfo.environment["CCB_CAT_TEST"],
     let s = CatState(rawValue: t) { return s }
  if let w = snap.usage?.fiveHour, let ra = w.resetsAt,
     max(0, 100 - w.pct) < 12, ra - snap.now > 1800 { return .panic }
  let items = battItems(snap)
  if !items.isEmpty, items.allSatisfy({ isGolden($0.remain) }) { return .happy }
  let cph = snap.block?.costPerHour ?? 0
  if cph < 0.5 { return .sleep }
  if cph < 8 { return .walk }
  if cph < 40 { return .run }
  return .dash
}

// Startup sequence: starting from the leftmost battery, fills from 0 → actual remaining value in order (the number counts up too)
func introFrames(items: [BattItem], dark: Bool, cat: CatState) -> [NSImage] {
  var out: [NSImage] = []
  let steps = 4
  for i in 0 ..< items.count {
    for s in 1 ... steps {
      let t = Double(s) / Double(steps)
      let frame = items.enumerated().map { j, it -> BattItem in
        let r: Double? = j < i ? it.remain
          : j == i ? it.remain.map { $0 * t }
          : it.remain == nil ? nil : 0
        return BattItem(label: it.label, remain: r)
      }
      if let img = renderBatteryImage(dark: dark, items: frame, cat: cat) { out.append(img) }
    }
  }
  return out
}

// Golden battery glint sweep (when at least one capsule is golden)
func glintFrames(items: [BattItem], dark: Bool, cat: CatState) -> [NSImage] {
  guard items.contains(where: { isGolden($0.remain) }) else { return [] }
  var out: [NSImage] = []
  for g in stride(from: 0, to: batteryGlintSpan() + 2, by: 2) {
    if let img = renderBatteryImage(dark: dark, items: items, glintX: g, cat: cat) { out.append(img) }
  }
  return out
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var statusItem: NSStatusItem!
  var timer: Timer?
  var glintTimer: Timer?
  var catTimer: Timer?
  var catIdx = 0
  var lastSnap: Snapshot? // last collected result — size/theme changes re-render from this instantly without re-collecting
  var settingsWindow: NSWindow?

  var loginItemEnabled: Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    // Refresh battery colors on dark/light mode switch
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(rerender),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: REFRESH_SECONDS, repeats: true) { [weak self] _ in
      self?.refresh()
    }
    // The golden battery glint plays every 30s independently of data refresh (replays from cached state without re-collecting)
    let glintEvery = ProcessInfo.processInfo.environment["CCB_GLINT_SECONDS"].flatMap(Double.init) ?? 30.0
    glintTimer = Timer.scheduledTimer(withTimeInterval: glintEvery, repeats: true) { [weak self] _ in
      self?.playGoldenGlint()
    }
  }

  // Advance the cat one frame and redraw the icon only (menu untouched)
  @objc func catTick() {
    if currentDisplayMode() == "modern" { return }
    if currentCatStyle() == .none { return }
    if animTimer?.isValid == true { return } // don't fight intro/glint playback
    guard let snap = lastSnap, let btn = statusItem.button else { return }
    catIdx += 1
    let items = battItems(snap)
    guard !items.isEmpty else { return }
    let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if let img = renderBatteryImage(dark: dark, items: items,
                                    cat: catState(snap), catFrameIndex: catIdx) {
      setButtonImage(img)
    }
  }

  // Cat style choice from Settings → Cat
  @objc func setCatStyle(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String else { return }
    UserDefaults.standard.set(raw, forKey: "catStyle")
    rerender()
  }

  // (Re)start the cat cycle at the pace of the current state
  func restartCatTimer(_ state: CatState) {
    catTimer?.invalidate()
    catTimer = Timer.scheduledTimer(withTimeInterval: catTickInterval(state), repeats: true) { [weak self] _ in
      self?.catTick()
    }
  }

  // Based on the cached snapshot, plays the glint sweep once if a golden battery is present
  func playGoldenGlint() {
    if currentDisplayMode() == "modern" { return }
    if ProcessInfo.processInfo.environment["CCB_DEBUG"] != nil {
      FileHandle.standardError.write(Data("glint tick: lastSnap=\(lastSnap != nil)\n".utf8))
    }
    guard let snap = lastSnap, let btn = statusItem.button else { return }
    let items = battItems(snap)
    let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var frames = glintFrames(items: items, dark: dark, cat: catState(snap))
    guard !frames.isEmpty, let final = renderBatteryImage(dark: dark, items: items) else { return }
    frames.append(final)
    let interval = ProcessInfo.processInfo.environment["CCB_ANIM_INTERVAL"].flatMap(Double.init) ?? 0.045
    playFrames(frames, interval: interval)
  }

  // First run only: prompts to register auto-start at login (RunCat-style onboarding)
  func firstRunAutoStartPrompt() {
    guard #available(macOS 13.0, *),
          !UserDefaults.standard.bool(forKey: "askedAutoStart"),
          SMAppService.mainApp.status != .enabled else { return }
    UserDefaults.standard.set(true, forKey: "askedAutoStart")
    let a = NSAlert()
    a.messageText = tr("Start automatically at login?")
    a.informativeText = tr("The usage battery will appear in your menu bar every time you start your Mac. You can change this anytime from the menu.")
    a.addButton(withTitle: tr("Start at Login"))
    a.addButton(withTitle: tr("Later"))
    NSApp.activate(ignoringOtherApps: true)
    if a.runModal() == .alertFirstButtonReturn {
      try? SMAppService.mainApp.register()
    }
  }

  @objc func refresh() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let snap = collectSnapshot()
      DispatchQueue.main.async { self?.render(snap) }
    }
  }

  // Redraws immediately from the last snapshot without re-collecting data (for size/theme changes)
  @objc func rerender() {
    if let s = lastSnap { render(s) } else { refresh() }
  }

  // Divides by the display scale factor based on pixel size (Retina ÷2, 1x monitor ÷1) — safe to reapply
  func setButtonImage(_ img: NSImage) {
    guard let btn = statusItem.button else { return }
    let scale = btn.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let rep = img.representations.first
    let pw = CGFloat(rep?.pixelsWide ?? Int(img.size.width))
    let ph = CGFloat(rep?.pixelsHigh ?? Int(img.size.height))
    img.size = NSSize(width: pw / scale, height: ph / scale)
    img.isTemplate = false
    btn.title = ""
    btn.image = img
  }

  // Plays a frame sequence — stops on the last frame
  private var animTimer: Timer?
  func playFrames(_ frames: [NSImage], interval: TimeInterval) {
    animTimer?.invalidate()
    guard !frames.isEmpty else { return }
    var i = 0
    animTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
      guard let self = self, i < frames.count else { t.invalidate(); return }
      self.setButtonImage(frames[i])
      i += 1
    }
  }

  private var introPlayed = false

  func render(_ snap: Snapshot) {
    lastSnap = snap
    let items = battItems(snap)
    if let btn = statusItem.button {
      let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let st = catState(snap)
      let finalImg = currentDisplayMode() == "modern"
        ? renderModernBatteryImage(dark: dark, items: items)
        : renderBatteryImage(dark: dark, items: items, cat: st, catFrameIndex: catIdx)
      if !items.isEmpty, let finalImg = finalImg {
        if currentDisplayMode() == "modern" { catTimer?.invalidate() }
        restartCatTimer(st)
        // Startup sequence (once only) + golden battery glint sweep (whenever present) → the last frame is the actual state
        var frames: [NSImage] = []
        if !introPlayed {
          introPlayed = true
          frames += introFrames(items: items, dark: dark, cat: st)
        }
        frames += glintFrames(items: items, dark: dark, cat: st)
        if frames.isEmpty {
          setButtonImage(finalImg)
        } else {
          frames.append(finalImg)
          // CCB_ANIM_INTERVAL: overrides the frame interval (for verification/demo)
          let interval = ProcessInfo.processInfo.environment["CCB_ANIM_INTERVAL"].flatMap(Double.init) ?? 0.045
          playFrames(frames, interval: interval)
        }
      } else {
        btn.image = nil
        btn.title = "🔋 —"
      }
    }
    statusItem.menu = buildMenu(snap, swiftBarDup: swiftBarDuplicate(), target: self)
    // --pop-menu: pops the menu open by itself right after the first render (for screenshots/verification — no accessibility access needed)
    if CommandLine.arguments.contains("--pop-menu"), !menuPopped {
      menuPopped = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, let btn = self.statusItem.button, let win = btn.window,
              let menu = self.statusItem.menu else { return }
        _ = (btn, win)
        NSApp.activate(ignoringOtherApps: true)
        // Pops open at a fixed coordinate under the menu bar on the main display (origin 0,0) — keeps the capture position fixed even on multiple monitors
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        let pt = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 28)
        FileHandle.standardError.write(Data("popup: at \(pt)\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          menu.popUp(positioning: nil, at: pt, in: nil)
        }
      }
      return
    }
    // Onboarding runs only after the first render has hit the screen — so the modal doesn't block the data from showing
    if !promptShown {
      promptShown = true
      DispatchQueue.main.async { [weak self] in self?.firstRunAutoStartPrompt() }
    }
  }

  private var menuPopped = false

  private var promptShown = false

  @objc func openLink(_ sender: NSMenuItem) {
    if let s = sender.representedObject as? String, let url = URL(string: s) {
      NSWorkspace.shared.open(url)
    }
  }

  // Language choice: "auto" or a code from SUPPORTED_LANGS; also mirrored to
  // ~/.claude/swiftbar/.lang so the SwiftBar widget follows the same choice
  @objc func setLang(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    UserDefaults.standard.set(code, forKey: "uiLang")
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    if code == "auto" {
      try? FileManager.default.removeItem(atPath: LANG_FILE)
    } else {
      try? code.write(toFile: LANG_FILE, atomically: true, encoding: .utf8)
    }
    UI_LANG = resolveLang()
    rerender()
  }

  @objc func setSizeBig() { setBattSize("big") }
  @objc func setSizeSmall() { setBattSize("small") }
  private func setBattSize(_ s: String) {
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    try? s.write(toFile: SIZE_FILE, atomically: true, encoding: .utf8)
    rerender() // re-render only — the data is unchanged so this reflects instantly
  }

  @objc func setDisplayMode(_ sender: NSMenuItem) {
    guard let mode = sender.representedObject as? String else { return }
    UserDefaults.standard.set(mode, forKey: DISPLAY_MODE_KEY)
    rerender()
  }

  @objc func showSettings() {
    if let window = settingsWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = tr("Settings")
    window.isReleasedWhenClosed = false
    window.delegate = self
    let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
    root.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView(); content.addSubview(root); window.contentView = content
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
      root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
    ])
    func heading(_ text: String) {
      let label = NSTextField(labelWithString: text); label.font = .boldSystemFont(ofSize: 14); root.addArrangedSubview(label)
    }
    func popup(_ items: [String], selected: Int, action: Selector) -> NSPopUpButton {
      let p = NSPopUpButton(); p.addItems(withTitles: items); p.selectItem(at: selected); p.target = self; p.action = action; p.widthAnchor.constraint(equalToConstant: 230).isActive = true; return p
    }
    heading(tr("Appearance"))
    let appearance = NSGridView(views: [
      [NSTextField(labelWithString: tr("Display style")), popup([tr("Modern batteries"), tr("Pixel batteries")], selected: currentDisplayMode() == "modern" ? 0 : 1, action: #selector(settingsDisplayChanged(_:)))],
      [NSTextField(labelWithString: tr("Battery size")), popup([tr("Big"), tr("Small")], selected: currentBattSize() == "big" ? 0 : 1, action: #selector(settingsSizeChanged(_:)))],
      [NSTextField(labelWithString: tr("Cat")), popup([tr("Off"), tr("Wide face"), tr("Slim face"), tr("Slime")], selected: [CatStyle.none, .nyan, .slim, .slime].firstIndex(of: currentCatStyle()) ?? 0, action: #selector(settingsCatChanged(_:)))],
    ])
    appearance.rowSpacing = 10; appearance.columnSpacing = 18; root.addArrangedSubview(appearance)
    heading(tr("Menu bar items"))
    let choices: [(String, String)] = [("claude5", "Claude 5h"), ("claudeWeek", "Claude week"), ("claudeFable", "Claude Fable"), ("codex5", "Codex 5h"), ("codexWeek", "Codex week")]
    let metrics = NSStackView(); metrics.orientation = .vertical; metrics.alignment = .leading; metrics.spacing = 7
    for (key, title) in choices {
      let button = NSButton(checkboxWithTitle: tr(title), target: self, action: #selector(toggleMetric(_:))); button.identifier = NSUserInterfaceItemIdentifier("visible_\(key)"); button.state = isMetricVisible(key) ? .on : .off; metrics.addArrangedSubview(button)
    }
    root.addArrangedSubview(metrics)
    heading(tr("General"))
    let langCodes = ["auto"] + LANG_DISPLAY.map { $0.code }
    let langTitles = [tr("System default")] + LANG_DISPLAY.map { $0.name }
    let savedLang = UserDefaults.standard.string(forKey: "uiLang") ?? "auto"
    let general = NSGridView(views: [[NSTextField(labelWithString: tr("Language")), popup(langTitles, selected: langCodes.firstIndex(of: savedLang) ?? 0, action: #selector(settingsLanguageChanged(_:)))]]); general.rowSpacing = 10; general.columnSpacing = 18; root.addArrangedSubview(general)
    if #available(macOS 13.0, *) { let login = NSButton(checkboxWithTitle: tr("Start at login"), target: self, action: #selector(toggleLoginItem)); login.state = loginItemEnabled ? .on : .off; root.addArrangedSubview(login) }
    let links = NSStackView(); links.orientation = .horizontal; links.spacing = 10
    if lastSnap?.block != nil { let cc = NSButton(title: tr("Open ccusage dashboard"), target: self, action: #selector(openDashboard)); links.addArrangedSubview(cc) }
    let gh = NSButton(title: tr("Open GitHub page"), target: self, action: #selector(openGitHubFromSettings)); links.addArrangedSubview(gh); root.addArrangedSubview(links)
    let close = NSButton(title: tr("Close"), target: self, action: #selector(closeSettings)); close.keyEquivalent = "\r"; close.controlSize = .large; close.widthAnchor.constraint(equalToConstant: 110).isActive = true; root.addArrangedSubview(close)
    settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }

  @objc func settingsDisplayChanged(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.indexOfSelectedItem == 0 ? "modern" : "pixel", forKey: DISPLAY_MODE_KEY); rerender() }
  @objc func settingsSizeChanged(_ sender: NSPopUpButton) { setBattSize(sender.indexOfSelectedItem == 0 ? "big" : "small") }
  @objc func settingsCatChanged(_ sender: NSPopUpButton) { UserDefaults.standard.set([CatStyle.none, .nyan, .slim, .slime][sender.indexOfSelectedItem].rawValue, forKey: "catStyle"); rerender() }
  @objc func settingsLanguageChanged(_ sender: NSPopUpButton) { let codes = ["auto"] + LANG_DISPLAY.map { $0.code }; let item = NSMenuItem(); item.representedObject = codes[sender.indexOfSelectedItem]; setLang(item) }
  @objc func toggleMetric(_ sender: NSButton) { if let key = sender.identifier?.rawValue { UserDefaults.standard.set(sender.state == .on, forKey: key); rerender() } }
  @objc func openGitHubFromSettings() { NSWorkspace.shared.open(URL(string: REPO_URL)!) }
  @objc func closeSettings() { settingsWindow?.close() }
  func windowWillClose(_ notification: Notification) { settingsWindow = nil }

  @objc func toggleLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    let svc = SMAppService.mainApp
    if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
    rerender() // only the checkmark needs updating — no need to re-collect
  }

  // One-click auto-update — download → verify signature → replace self → relaunch. Falls back to the releases page on failure
  @objc func selfUpdate(_ sender: NSMenuItem) {
    guard let v = sender.representedObject as? String else { return }
    statusItem.button?.image = nil
    statusItem.button?.title = tr("⬇︎ Updating…")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try downloadAndInstallUpdate(version: v) { _ in }
        DispatchQueue.main.async { relaunchAfterUpdate() }
      } catch {
        DispatchQueue.main.async {
          self?.rerender()
          if let url = URL(string: "\(REPO_URL)/releases") { NSWorkspace.shared.open(url) }
        }
      }
    }
  }

  // Opens the ccusage dashboard in Terminal — via a .command file (runs Terminal without a permission prompt)
  @objc func openDashboard() {
    guard let bin = ccusagePath() else { return }
    let f = "\(STATE_DIR)/ccusage-dashboard.command"
    let sh = "#!/bin/sh\nexec \"\(bin)\" blocks --active\n"
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    try? sh.write(toFile: f, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
    NSWorkspace.shared.open(URL(fileURLWithPath: f))
  }
}

// ── --render-glint <path>: saves an intermediate glint frame as PNG (for render verification) ──
if let idx = CommandLine.arguments.firstIndex(of: "--render-glint"), CommandLine.arguments.count > idx + 1 {
  let items = [BattItem(label: "C5", remain: 100), BattItem(label: "CW", remain: 100),
               BattItem(label: "X5", remain: 100)]
  if let img = renderBatteryImage(dark: true, items: items, glintX: 12),
     let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
     let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
    print("saved")
  }
  exit(0)
}

// ── --self-update: checks the latest version and installs it immediately (for headless verification/manual updates) ──
if CommandLine.arguments.contains("--self-update") {
  guard let latest = fetchLatestVersion() else { print("version check failed"); exit(1) }
  if cmpVer(latest, APP_VERSION) > 0 {
    do {
      try downloadAndInstallUpdate(version: latest) { print($0) }
      print("updated: v\(APP_VERSION) → v\(latest) at \(Bundle.main.bundlePath)")
    } catch {
      print("update failed: \(error)")
      exit(1)
    }
  } else {
    print("already latest (v\(APP_VERSION), remote v\(latest))")
  }
  exit(0)
}

// ── --dump-menu: prints the dropdown menu structure as text without UI (for verification) ──
if CommandLine.arguments.contains("--dump-menu") {
  let snap = collectSnapshot()
  let d = AppDelegate()
  func walk(_ m: NSMenu, _ indent: String) {
    for it in m.items {
      if it.isSeparatorItem { print(indent + "────────") }
      else {
        print(indent + it.title + (it.state == .on ? "  [✓]" : "") + (it.submenu != nil ? "  ▸" : ""))
        if let sub = it.submenu { walk(sub, indent + "        ") }
      }
    }
  }
  walk(buildMenu(snap, swiftBarDup: swiftBarDuplicate(), target: d), "")
  exit(0)
}

// ── --dump: prints collection/render data as text without UI (for pipeline verification) ──
if CommandLine.arguments.contains("--dump") {
  let snap = collectSnapshot()
  print("now:", snap.now)
  if let u = snap.usage {
    print("claude.live:", u.live)
    if let w = u.fiveHour { print("claude.5h: used \(w.pct)% resetsAt \(w.resetsAt ?? -1)") }
    if let w = u.weekly { print("claude.weekly: used \(w.pct)% resetsAt \(w.resetsAt ?? -1)") }
    if let f = u.fable { print("claude.fable(\(f.model)): used \(f.pct)%") }
  } else { print("claude: nil") }
  if let b = snap.block {
    print(String(format: "ccusage.block: cost $%.2f tokens %@ elapsed %.0f%%", b.cost, fmtTok(b.tokens), b.elapsedPct))
  } else { print("ccusage.block: nil") }
  if let m = snap.models {
    print("ccusage.models:", m.models.map { "\(shortModel($0.name)) $\(String(format: "%.1f", $0.cost))" }.joined(separator: ", "))
  }
  if let cx = snap.codex {
    print("codex.live:", cx.live, "plan:", cx.plan ?? "-")
    if let p = windowState(cx.primary, now: snap.now) { print("codex.5h: used \(p.pct)% resetsIn \(p.resetsIn ?? -1)s") }
    if let s = windowState(cx.secondary, now: snap.now) { print("codex.weekly: used \(s.pct)% resetsIn \(s.resetsIn ?? -1)s") }
    if let cr = cx.credits { print("codex.credits: has \(cr.hasCredits) unlimited \(cr.unlimited) balance \(cr.balance ?? 0)") }
  } else { print("codex: nil") }
  print("battItems:", battItems(snap).map { "\($0.label)=\($0.remain.map { String(Int($0.rounded())) } ?? "nil")" }.joined(separator: " "))
  print("swiftBarDuplicate:", swiftBarDuplicate())
  exit(0)
}

// ── Duplicate-launch guard — quits silently if an instance with the same bundle ID is already running ──
let myID = Bundle.main.bundleIdentifier ?? "com.dennykim.claude-codex-battery-app"
let myPID = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: myID)
  .contains(where: { $0.processIdentifier != myPID }) {
  exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only (no Dock icon)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
