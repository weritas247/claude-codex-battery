// Claude & Codex Usage Battery — a fully standalone native menu bar app (RunCat style)
// Runs independently without SwiftBar/bun: keychain/auth file → queries the usage API directly → renders the battery.
import Cocoa
import QuartzCore
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
func battItems(_ snap: Snapshot, configuration: PresentationConfiguration = .production) -> [BattItem] {
  var items: [BattItem] = []
  if let usage = snap.usage {
    if configuration.isMetricVisible("claude5") {
      items.append(BattItem(label: "C5", provider: .claude,
                            remain: usage.fiveHour.map { normalizedRemaining(fromUsed: $0.pct) }))
    }
    if configuration.isMetricVisible("claudeWeek") {
      items.append(BattItem(label: "CW", provider: .claude,
                            remain: usage.weekly.map { normalizedRemaining(fromUsed: $0.pct) }))
    }
    if configuration.isMetricVisible("claudeFable"), let fable = usage.fable {
      items.append(BattItem(label: "CF", provider: .claude,
                            remain: normalizedRemaining(fromUsed: fable.pct)))
    }
  } else if let block = snap.block, configuration.isMetricVisible("claude5") {
    items.append(BattItem(label: "C5", provider: .claude,
                          remain: normalizedRemaining(fromUsed: block.elapsedPct)))
  }
  if let codex = snap.codex, codex.primary != nil || codex.secondary != nil {
    if configuration.isMetricVisible("codex5"), let primary = windowState(codex.primary, now: snap.now) {
      items.append(BattItem(label: "X5", provider: .codex,
                            remain: normalizedRemaining(fromUsed: primary.pct)))
    }
    if configuration.isMetricVisible("codexWeek"), let secondary = windowState(codex.secondary, now: snap.now) {
      items.append(BattItem(label: "XW", provider: .codex,
                            remain: normalizedRemaining(fromUsed: secondary.pct)))
    }
  } else if let credits = snap.codex?.credits {
    let remaining: Double = credits.unlimited || (credits.hasCredits && (credits.balance ?? 0) > 0) ? 100 : 0
    items.append(BattItem(label: "X", provider: .codex, remain: normalizedRemaining(remaining)))
  }
  if configuration.goldTestEnabled() {
    return items.map { BattItem(label: $0.label, provider: $0.provider, remain: $0.remain == nil ? nil : 100) }
  }
  return items
}

func providerSummaries(_ snap: Snapshot,
                       configuration: PresentationConfiguration = .production) -> [ProviderSummary] {
  var summaries: [ProviderSummary] = []
  if let usage = snap.usage {
    var remaining: [Double] = []
    if configuration.isMetricVisible("claude5"), let window = usage.fiveHour {
      remaining.append(normalizedRemaining(fromUsed: window.pct))
    }
    if configuration.isMetricVisible("claudeWeek"), let window = usage.weekly {
      remaining.append(normalizedRemaining(fromUsed: window.pct))
    }
    if configuration.isMetricVisible("claudeFable"), let window = usage.fable {
      remaining.append(normalizedRemaining(fromUsed: window.pct))
    }
    if let mostConstrained = remaining.min() {
      summaries.append(ProviderSummary(provider: .claude, remain: mostConstrained))
    }
  } else if let block = snap.block, configuration.isMetricVisible("claude5") {
    summaries.append(ProviderSummary(provider: .claude,
                                     remain: normalizedRemaining(fromUsed: block.elapsedPct)))
  }
  if let codex = snap.codex {
    var remaining: [Double] = []
    if configuration.isMetricVisible("codex5"), let window = windowState(codex.primary, now: snap.now) {
      remaining.append(normalizedRemaining(fromUsed: window.pct))
    }
    if configuration.isMetricVisible("codexWeek"), let window = windowState(codex.secondary, now: snap.now) {
      remaining.append(normalizedRemaining(fromUsed: window.pct))
    }
    if let mostConstrained = remaining.min() {
      summaries.append(ProviderSummary(provider: .codex, remain: mostConstrained))
    } else if let credits = codex.credits {
      let remaining: Double = credits.unlimited || (credits.hasCredits && (credits.balance ?? 0) > 0) ? 100 : 0
      summaries.append(ProviderSummary(provider: .codex, remain: normalizedRemaining(remaining)))
    }
  }
  return summaries
}

// Cat state from the snapshot: low remaining with a distant reset → panic
// (CCB_CAT_TEST=sleep|walk|run|dash|panic forces a state for testing)
func catState(_ snap: Snapshot, configuration: PresentationConfiguration = .production) -> CatState {
  if let forced = configuration.forcedCatState() { return forced }
  if let window = snap.usage?.fiveHour, let reset = window.resetsAt,
     hasLowRemainingResetDistantRisk(remaining: normalizedRemaining(fromUsed: window.pct),
                                     resetSeconds: Double(reset - snap.now)) { return .panic }
  let items = battItems(snap, configuration: configuration)
  if !items.isEmpty, items.allSatisfy({ isGolden($0.remain) }) { return .happy }
  let costPerHour = snap.block?.costPerHour ?? 0
  if costPerHour < 0.5 { return .sleep }
  if costPerHour < 8 { return .walk }
  if costPerHour < 40 { return .run }
  return .dash
}

// Startup sequence: starting from the leftmost battery, fills from 0 → actual remaining value in order (the number counts up too)
func introFrames(items: [BattItem], dark: Bool, cat: CatState,
                 configuration: PresentationConfiguration = .production) -> [NSImage] {
  var out: [NSImage] = []
  let steps = 4
  for i in 0 ..< items.count {
    for s in 1 ... steps {
      let t = Double(s) / Double(steps)
      let frame = items.enumerated().map { j, it -> BattItem in
        let r: Double? = j < i ? it.remain
          : j == i ? it.remain.map { $0 * t }
          : it.remain == nil ? nil : 0
        return BattItem(label: it.label, provider: it.provider, remain: r)
      }
      if let img = renderBatteryImage(dark: dark, items: frame, cat: cat,
                                      configuration: configuration) { out.append(img) }
    }
  }
  return out
}

// Golden battery glint sweep (when at least one capsule is golden)
func glintFrames(items: [BattItem], dark: Bool, cat: CatState,
                 configuration: PresentationConfiguration = .production) -> [NSImage] {
  guard items.contains(where: { isGolden($0.remain) }) else { return [] }
  var out: [NSImage] = []
  for g in stride(from: 0, to: batteryGlintSpan(configuration: configuration) + 2, by: 2) {
    if let img = renderBatteryImage(dark: dark, items: items, glintX: g, cat: cat,
                                    configuration: configuration) { out.append(img) }
  }
  return out
}

enum StaticStatusOutput {
  case image(NSImage)
  case fallback(String)
}

private func statusAccessibilitySummary(items: [BattItem], summaries: [ProviderSummary],
                                        modern: Bool, hasDisplayData: Bool,
                                        language: String) -> String {
  guard hasDisplayData else {
    return tr("Run Claude Code or Codex and usage will appear here", language: language)
  }
  let metricNames = [
    "C5": "Claude 5h", "CW": "Claude week", "CF": "Claude Fable",
    "X5": "Codex 5h", "XW": "Codex week", "X": "Codex"
  ]
  let values: [(String, Double?)]
  if modern {
    values = summaries.map {
      ($0.provider == .claude ? "Claude" : "Codex", Optional($0.remain))
    }
  } else {
    values = items.map {
      (tr(metricNames[$0.label] ?? $0.label, language: language), $0.remain)
    }
  }
  return values.map { name, remaining in
    guard let remaining else { return "\(name), —" }
    return "\(name), \(trf("%d%% remaining", language: language, Int(remaining.rounded())))"
  }.joined(separator: "; ")
}

struct PreparedPresentation {
  let menu: NSMenu
  let staticOutput: StaticStatusOutput
  let items: [BattItem]
  let summaries: [ProviderSummary]
  let catState: CatState
  let hasDisplayData: Bool
  let accessibilitySummary: String
}

typealias SnapshotCollector = (@escaping (Snapshot) -> Void) -> Void

enum VisualTimerKind {
  case animation
  case cat
  case glint
}

protocol VisualTimerResource: AnyObject {
  var isValid: Bool { get }
  func invalidate()
  func callbackEffectBegan()
}

extension VisualTimerResource {
  func callbackEffectBegan() {}
}

extension Timer: VisualTimerResource {}

typealias VisualTimerFactory = (
  _ kind: VisualTimerKind, _ interval: TimeInterval, _ repeats: Bool,
  _ callback: @escaping (VisualTimerResource) -> Void
) -> VisualTimerResource

func scheduledVisualTimer(kind: VisualTimerKind, interval: TimeInterval, repeats: Bool,
                                  callback: @escaping (VisualTimerResource) -> Void) -> VisualTimerResource {
  Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { timer in callback(timer) }
}

struct VisualResourceSnapshot: Equatable {
  let epoch: Int
  let animationTimer: ObjectIdentifier?
  let catTimer: ObjectIdentifier?
  let glintTimer: ObjectIdentifier?
  let activityLayers: [Provider: ObjectIdentifier]
  let activityTextLayers: [Provider: ObjectIdentifier]
  let refreshTimer: ObjectIdentifier?
  let refreshTimerActive: Bool
  let providerMonitor: ObjectIdentifier?
  let acceptedRenderCount: Int
}

enum RefreshTrigger: Equatable {
  case initial
  case timer
  case manual
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var statusItem: NSStatusItem?
  var timer: Timer?
  var glintTimer: VisualTimerResource?
  var catTimer: VisualTimerResource?
  var providerActivityMonitor: ProviderActivityMonitor?
  private(set) var providerMonitorIdentity: AnyObject?
  var apiActiveProviders: Set<Provider> = []
  var sessionActiveProviders: Set<Provider> = []
  var activeProviders: Set<Provider> = []
  var activityLayers: [Provider: CALayer] = [:]
  // The percentage redrawn above the hatch — created, reused and torn down with its clip layer
  var activityTextLayers: [Provider: CALayer] = [:]
  var catIdx = 0
  private(set) var lastSnap: Snapshot?
  var settingsWindow: NSWindow?

  let presentationConfiguration: PresentationConfiguration
  private let collector: SnapshotCollector
  private let assetContextFactory: () -> ProviderAssetContext
  private let duplicateReader: () -> Bool
  private let opener: (URL) -> Void
  private let reduceMotionReader: () -> Bool
  private let glintIntervalReader: () -> TimeInterval
  private let visualTimerFactory: VisualTimerFactory
  private let allowsHeadlessVisualResources: Bool
  private let motionNotificationCenter: NotificationCenter
  private var motionObserver: NSObjectProtocol?
  private(set) var reduceMotionEnabled = false
  private var motionEpoch = 0
  private var refreshGate = RefreshGate()
  private(set) var acceptedGenerations: [RefreshGeneration] = []
  private(set) var acceptedRenderCount = 0
  private var refreshTriggers: [RefreshGeneration: RefreshTrigger] = [:]
  private(set) var acceptedRefreshTriggers: [RefreshTrigger] = []
  var menuSink: ((NSMenu) -> Void)?
  var staticOutputSink: ((StaticStatusOutput) -> Void)?
  var accessibilitySummarySink: ((String) -> Void)?
  private(set) var appliedAccessibilitySummary: String?
  private var prepared: PreparedPresentation?
  private var introPlayed = false
  private var menuPopped = false
  private var promptShown = false
  private var animTimer: VisualTimerResource?

  init(presentationConfiguration: PresentationConfiguration = .production,
       collector: @escaping SnapshotCollector = { completion in
         DispatchQueue.global(qos: .utility).async {
           let snapshot = collectSnapshot()
           DispatchQueue.main.async { completion(snapshot) }
         }
       },
       assetContextFactory: @escaping () -> ProviderAssetContext = { .production() },
       duplicateReader: @escaping () -> Bool = { swiftBarDuplicate() },
       opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
       reduceMotionReader: @escaping () -> Bool = {
         NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
       },
       glintIntervalReader: @escaping () -> TimeInterval = {
         ProcessInfo.processInfo.environment["CCB_GLINT_SECONDS"].flatMap(Double.init) ?? 30
       },
       motionNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
       visualTimerFactory: @escaping VisualTimerFactory = scheduledVisualTimer,
       allowsHeadlessVisualResources: Bool = false,
       providerMonitorIdentity: AnyObject? = nil) {
    self.presentationConfiguration = presentationConfiguration
    self.collector = collector
    self.assetContextFactory = assetContextFactory
    self.duplicateReader = duplicateReader
    self.opener = opener
    self.reduceMotionReader = reduceMotionReader
    self.glintIntervalReader = glintIntervalReader
    self.visualTimerFactory = visualTimerFactory
    self.allowsHeadlessVisualResources = allowsHeadlessVisualResources
    self.motionNotificationCenter = motionNotificationCenter
    self.providerMonitorIdentity = providerMonitorIdentity
    super.init()
    reduceMotionEnabled = reduceMotionReader()
    motionObserver = motionNotificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.applyReduceMotionPreference() }
    if reduceMotionEnabled { introPlayed = true }
  }

  deinit {
    if let motionObserver { motionNotificationCenter.removeObserver(motionObserver) }
  }

  var loginItemEnabled: Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.button?.title = "…"
    providerActivityHandler = { [weak self] provider, active in
      DispatchQueue.main.async {
        guard let self else { return }
        if active { self.apiActiveProviders.insert(provider) }
        else { self.apiActiveProviders.remove(provider) }
        self.updateActivityAnimation()
      }
    }
    providerActivityMonitor = ProviderActivityMonitor { [weak self] provider, active in
      guard let self else { return }
      if active { self.sessionActiveProviders.insert(provider) }
      else { self.sessionActiveProviders.remove(provider) }
      self.updateActivityAnimation()
    }
    providerMonitorIdentity = providerActivityMonitor
    providerActivityMonitor?.start()
    // Refresh battery colors on dark/light mode switch
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(rerender),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    applyReduceMotionPreference()
    requestRefresh(.initial)
    timer = Timer.scheduledTimer(withTimeInterval: REFRESH_SECONDS, repeats: true) { [weak self] _ in
      self?.requestRefresh(.timer)
    }
    if !reduceMotionEnabled { startGlintTimer() }
  }

  private func startGlintTimer() {
    guard (statusItem != nil || allowsHeadlessVisualResources), glintTimer == nil,
          !reduceMotionEnabled, presentationConfiguration.displayMode() != "modern" else { return }
    let epoch = motionEpoch
    glintTimer = visualTimerFactory(.glint, glintIntervalReader(), true) { [weak self] timer in
      guard let self, self.motionEpoch == epoch, !self.reduceMotionEnabled,
            self.presentationConfiguration.displayMode() != "modern" else { return }
      timer.callbackEffectBegan()
      self.playGoldenGlint()
    }
  }

  // Timers/epoch only — every refresh needs a fresh epoch, but a refresh alone must not reset
  // an unchanged provider's running "drain" animation, so activity layers are handled separately.
  private func invalidateVisualTimers() {
    motionEpoch += 1
    animTimer?.invalidate(); animTimer = nil
    catTimer?.invalidate(); catTimer = nil
    glintTimer?.invalidate(); glintTimer = nil
  }

  private func removeActivityLayers(for provider: Provider) {
    for layer in [activityLayers.removeValue(forKey: provider),
                  activityTextLayers.removeValue(forKey: provider)].compactMap({ $0 }) {
      layer.removeAllAnimations()
      layer.removeFromSuperlayer()
    }
  }

  private func clearActivityLayers() {
    Set(activityLayers.keys).union(activityTextLayers.keys).forEach { removeActivityLayers(for: $0) }
  }

  private func stopVisualMotion() {
    invalidateVisualTimers()
    clearActivityLayers()
  }

  @objc func applyReduceMotionPreference() {
    let next = reduceMotionReader()
    guard next != reduceMotionEnabled else { return }
    reduceMotionEnabled = next
    stopVisualMotion()
    if next {
      introPlayed = true
      if let prepared { applyStaticOutput(prepared.staticOutput, accessibilitySummary: prepared.accessibilitySummary) }
    } else {
      restoreEligibleMotion()
    }
  }

  private func restoreEligibleMotion() {
    guard !reduceMotionEnabled, let snapshot = lastSnap else { return }
    if presentationConfiguration.displayMode() == "modern" {
      updateActivityLayers()
    } else {
      startGlintTimer()
      if presentationConfiguration.catStyle() != .none {
        restartCatTimer(catState(snapshot, configuration: presentationConfiguration))
      }
    }
  }

  func updateActivityAnimation() {
    activeProviders = apiActiveProviders.union(sessionActiveProviders)
    updateActivityLayers()
  }

  func updateActivityLayers() {
    guard !reduceMotionEnabled, presentationConfiguration.displayMode() == "modern",
          let snap = lastSnap, statusItem?.button != nil || allowsHeadlessVisualResources else {
      clearActivityLayers()
      return
    }
    let button = statusItem?.button
    button?.wantsLayer = true
    let summaries = providerSummaries(snap, configuration: presentationConfiguration)
    let imageWidth = button?.image?.size.width ?? 0
    let imageHeight = button?.image?.size.height ?? MODERN_IMAGE_HEIGHT
    let buttonWidth = button?.bounds.width ?? imageWidth
    let buttonHeight = button?.bounds.height ?? imageHeight
    let originX = max(0, (buttonWidth - imageWidth) / 2)
    let originY = hatchOriginY(buttonHeight: buttonHeight, imageHeight: imageHeight)
    // Same fallback as prepareAndApplyCurrent: no button → light, so the hatch matches the base image
    let dark = button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    for provider in [Provider.claude, .codex] {
      guard activeProviders.contains(provider),
            let index = summaries.firstIndex(where: { $0.provider == provider }) else {
        removeActivityLayers(for: provider)
        continue
      }
      let summary = summaries[index]
      let itemX = originX + MODERN_IMAGE_PAD + CGFloat(index) * (MODERN_ITEM_WIDTH + MODERN_ITEM_GAP)
      let bodyX = itemX + MODERN_ICON_WIDTH + MODERN_ICON_GAP
      let fillW = max(0, (MODERN_BODY_WIDTH - 4) * normalizedRemaining(summary.remain) / 100)
      // Too little fill to carry the stripes → run them over the whole body so activity stays visible
      let wide = fillW >= HATCH_MIN_FILL_PT
      let rect = CGRect(x: bodyX + 2, y: originY + 5,
                        width: wide ? fillW : MODERN_BODY_WIDTH - 4, height: 14)
      let colorRGB = wide ? activityHatchRGB(summary.remain, dark: dark) : emptyHatchRGB(dark: dark)
      let alpha: CGFloat = wide ? 0.85 : 0.55
      // Rebuild key = exactly what the stripe tile is baked from. Everything else about a refresh —
      // a narrower fill, a new percentage — is a resize we can apply in place, and must: rebuilding
      // resets "drain" to t=0, and a draining provider changes its fill on every refresh, which is
      // precisely when the animation is on screen.
      let rebuildKey = "\(colorRGB)|\(alpha)"
      let stripesW = rect.width + HATCH_PITCH_PT
      // Origin centers the glyphs the way renderModernSummaryImage centers them, so the redraw lands
      // pixel-on-pixel; the size is the raster's, so .resize gravity doesn't squeeze them.
      func valueTextFrame(_ text: (image: CGImage, size: CGSize, rasterSize: CGSize)) -> CGRect {
        CGRect(x: bodyX + (MODERN_BODY_WIDTH - text.size.width) / 2, y: originY + 5,
               width: text.rasterSize.width, height: text.rasterSize.height)
      }
      let text = modernValueTextImage(normalizedRemaining(summary.remain), dark: dark)
      if let clip = activityLayers[provider], clip.name == rebuildKey,
         let stripes = clip.sublayers?.first, let label = activityTextLayers[provider] {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // implicit actions would slide the resize and crossfade the digits
        if clip.frame != rect {
          clip.frame = rect
          // stripes sits on a left anchor, so its position.x stays 0 and the running drift's
          // absolute from/to values survive the resize
          stripes.frame = CGRect(x: 0, y: 0, width: stripesW, height: rect.height)
          stripes.contents = hatchStripeImage(width: stripesW, height: rect.height,
                                              color: hatchNSColor(colorRGB, alpha: alpha))
        }
        // Baked from the value, so it goes stale even when the geometry doesn't move (below the
        // low-fill threshold the rect is constant for every remaining value in the band)
        if let text {
          label.frame = valueTextFrame(text)
          label.contents = text.image
        }
        CATransaction.commit()
        continue
      }
      removeActivityLayers(for: provider)
      // No number to redraw above the stripes → install nothing, rather than bury the percentage
      // under a hatch that would then rebuild on every refresh
      guard let text else { continue }

      let clip = CALayer()
      clip.name = rebuildKey
      clip.frame = rect
      clip.masksToBounds = true
      clip.cornerRadius = 2.5
      let stripes = CALayer()
      stripes.anchorPoint = CGPoint(x: 0, y: 0.5)   // see the resize path above
      stripes.frame = CGRect(x: 0, y: 0, width: stripesW, height: rect.height)
      stripes.contentsScale = 2
      stripes.contents = hatchStripeImage(width: stripesW, height: rect.height,
                                          color: hatchNSColor(colorRGB, alpha: alpha))
      clip.addSublayer(stripes)
      button?.layer?.addSublayer(clip)
      activityLayers[provider] = clip

      let drift = CABasicAnimation(keyPath: "position.x")
      drift.fromValue = stripes.position.x
      drift.toValue = stripes.position.x - HATCH_PITCH_PT
      drift.duration = HATCH_PERIOD
      drift.repeatCount = .infinity
      drift.isRemovedOnCompletion = false
      stripes.add(drift, forKey: "drain")

      // The clip sits above the button image and would stripe the centered "NN%", so the number is
      // redrawn on top of it.
      let label = CALayer()
      label.frame = valueTextFrame(text)
      label.contentsScale = 2
      label.contents = text.image
      button?.layer?.addSublayer(label)
      activityTextLayers[provider] = label
    }
  }

  // Advance the cat one frame and redraw the icon only (menu untouched)
  @objc func catTick() {
    guard !reduceMotionEnabled, presentationConfiguration.displayMode() != "modern",
          presentationConfiguration.catStyle() != .none,
          animTimer?.isValid != true,
          let snap = lastSnap, let button = statusItem?.button else { return }
    catIdx += 1
    let items = battItems(snap, configuration: presentationConfiguration)
    guard !items.isEmpty else { return }
    let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if let image = renderBatteryImage(dark: dark, items: items,
                                      cat: catState(snap, configuration: presentationConfiguration),
                                      catFrameIndex: catIdx, configuration: presentationConfiguration) {
      setButtonImage(image)
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
    guard (statusItem != nil || allowsHeadlessVisualResources), !reduceMotionEnabled,
          presentationConfiguration.displayMode() != "modern",
          presentationConfiguration.catStyle() != .none else {
      catTimer?.invalidate(); catTimer = nil
      return
    }
    catTimer?.invalidate()
    let epoch = motionEpoch
    catTimer = visualTimerFactory(.cat, catTickInterval(state), true) { [weak self] timer in
      guard let self, self.motionEpoch == epoch, !self.reduceMotionEnabled,
            self.presentationConfiguration.displayMode() != "modern" else { return }
      timer.callbackEffectBegan()
      self.catTick()
    }
  }

  // Based on the cached snapshot, plays the glint sweep once if a golden battery is present
  func playGoldenGlint() {
    guard !reduceMotionEnabled, presentationConfiguration.displayMode() != "modern",
          let snap = lastSnap, let button = statusItem?.button else { return }
    let items = battItems(snap, configuration: presentationConfiguration)
    let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let state = catState(snap, configuration: presentationConfiguration)
    var frames = glintFrames(items: items, dark: dark, cat: state,
                             configuration: presentationConfiguration)
    guard !frames.isEmpty,
          let final = renderBatteryImage(dark: dark, items: items, cat: state,
                                         catFrameIndex: catIdx,
                                         configuration: presentationConfiguration) else { return }
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
    requestRefresh(.manual)
  }

  func requestRefresh(_ trigger: RefreshTrigger) {
    switch refreshGate.request() {
    case .start(let generation):
      refreshTriggers[generation] = trigger
      startActiveCollection()
    case .queueNewest(let generation, let replacing):
      if let replacing { refreshTriggers.removeValue(forKey: replacing) }
      refreshTriggers[generation] = trigger
    }
  }

  private func startActiveCollection() {
    guard let generation = refreshGate.active else { return }
    collector { [weak self] snapshot in
      if Thread.isMainThread { self?.completeCollection(snapshot, generation: generation) }
      else { DispatchQueue.main.async { self?.completeCollection(snapshot, generation: generation) } }
    }
  }

  private func completeCollection(_ snapshot: Snapshot, generation: RefreshGeneration) {
    switch refreshGate.complete(generation) {
    case .accept:
      let trigger = refreshTriggers.removeValue(forKey: generation)
      acceptAndPresent(retainingUnavailableProviders(in: snapshot), generation: generation,
                       trigger: trigger)
    case .discardAndStart:
      refreshTriggers.removeValue(forKey: generation)
      startActiveCollection()
    case .stale:
      break
    }
  }

  private func retainingUnavailableProviders(in snapshot: Snapshot) -> Snapshot {
    guard let previous = lastSnap else { return snapshot }
    let usage = snapshot.usage ?? previous.usage.map {
      ClaudeUsage(measuredAt: $0.measuredAt, live: false, fiveHour: $0.fiveHour,
                  weekly: $0.weekly, fable: $0.fable)
    }
    let codex = snapshot.codex ?? previous.codex.map {
      CodexUsage(measuredAt: $0.measuredAt, live: false, limitId: $0.limitId, plan: $0.plan,
                 primary: $0.primary, secondary: $0.secondary, credits: $0.credits)
    }
    return Snapshot(now: snapshot.now, usage: usage, block: snapshot.block,
                    models: snapshot.models, codex: codex, update: snapshot.update)
  }

  private func acceptAndPresent(_ snapshot: Snapshot, generation: RefreshGeneration,
                                trigger: RefreshTrigger?) {
    lastSnap = snapshot
    acceptedGenerations.append(generation)
    if let trigger { acceptedRefreshTriggers.append(trigger) }
    acceptedRenderCount += 1
    prepareAndApplyCurrent(snapshot)
  }

  @objc func rerender() {
    if let snapshot = lastSnap { prepareAndApplyCurrent(snapshot) } else { refresh() }
  }

  // Divides by the display scale factor based on pixel size (Retina ÷2, 1x monitor ÷1) — safe to reapply
  func setButtonImage(_ img: NSImage) {
    guard let btn = statusItem?.button else { return }
    let scale = btn.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let rep = img.representations.first
    let pw = CGFloat(rep?.pixelsWide ?? Int(img.size.width))
    let ph = CGFloat(rep?.pixelsHigh ?? Int(img.size.height))
    img.size = NSSize(width: pw / scale, height: ph / scale)
    img.isTemplate = false
    btn.title = ""
    btn.image = img
    updateActivityLayers()
  }

  // Plays a frame sequence — stops on the last frame
  func playFrames(_ frames: [NSImage], interval: TimeInterval) {
    animTimer?.invalidate()
    guard (statusItem != nil || allowsHeadlessVisualResources),
          !reduceMotionEnabled, !frames.isEmpty else { return }
    let epoch = motionEpoch
    var index = 0
    animTimer = visualTimerFactory(.animation, interval, true) { [weak self] timer in
      guard let self, self.motionEpoch == epoch, !self.reduceMotionEnabled,
            index < frames.count else {
        timer.invalidate()
        return
      }
      timer.callbackEffectBegan()
      self.setButtonImage(frames[index])
      index += 1
    }
  }

  func visualResourceSnapshot() -> VisualResourceSnapshot {
    VisualResourceSnapshot(
      epoch: motionEpoch,
      animationTimer: animTimer.map { ObjectIdentifier($0) },
      catTimer: catTimer.map { ObjectIdentifier($0) },
      glintTimer: glintTimer.map { ObjectIdentifier($0) },
      activityLayers: activityLayers.mapValues { ObjectIdentifier($0) },
      activityTextLayers: activityTextLayers.mapValues { ObjectIdentifier($0) },
      refreshTimer: timer.map { ObjectIdentifier($0) },
      refreshTimerActive: timer?.isValid == true,
      providerMonitor: providerMonitorIdentity.map { ObjectIdentifier($0) },
      acceptedRenderCount: acceptedRenderCount)
  }

  func preparePresentation(_ snapshot: Snapshot, dark: Bool, swiftBarDuplicate: Bool,
                           assets: ProviderAssetContext) -> PreparedPresentation {
    let items = battItems(snapshot, configuration: presentationConfiguration)
    let summaries = providerSummaries(snapshot, configuration: presentationConfiguration)
    let state = catState(snapshot, configuration: presentationConfiguration)
    let modern = presentationConfiguration.displayMode() == "modern"
    let image = modern
      ? renderModernSummaryImage(dark: dark, summaries: summaries, assetContext: assets)
      : renderBatteryImage(dark: dark, items: items, cat: state, catFrameIndex: catIdx,
                           configuration: presentationConfiguration)
    let hasDisplayData = modern ? !summaries.isEmpty : !items.isEmpty
    let staticOutput: StaticStatusOutput
    if hasDisplayData, let image {
      staticOutput = .image(image)
    } else {
      staticOutput = .fallback("🔋 —")
    }
    let language = presentationConfiguration.language()
    let menu = buildMenu(snapshot, swiftBarDup: swiftBarDuplicate, target: self,
                         assets: assets, language: language)
    let accessibilitySummary = statusAccessibilitySummary(
      items: items, summaries: summaries, modern: modern, hasDisplayData: hasDisplayData,
      language: language)
    return PreparedPresentation(menu: menu, staticOutput: staticOutput, items: items,
                                summaries: summaries, catState: state,
                                hasDisplayData: hasDisplayData,
                                accessibilitySummary: accessibilitySummary)
  }

  func prepareAndApplyCurrent(_ snapshot: Snapshot) {
    // A re-presentation is a new visual epoch. Invalidate every timer callback before reading
    // mutable presentation configuration or installing new output — but leave activity layers
    // alone here; applyEligibleMotion reconciles them below without resetting an unchanged
    // provider's running "drain" animation on every ordinary refresh.
    invalidateVisualTimers()
    let dark = statusItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let next = preparePresentation(snapshot, dark: dark, swiftBarDuplicate: duplicateReader(),
                                   assets: assetContextFactory())
    prepared = next
    applyMenu(next.menu)
    applyStaticOutput(next.staticOutput, accessibilitySummary: next.accessibilitySummary)
    applyEligibleMotion(next, dark: dark)
    applyProductionPostRender()
  }

  private func applyMenu(_ menu: NSMenu) {
    if let menuSink { menuSink(menu) } else { statusItem?.menu = menu }
  }

  private func applyStaticOutput(_ output: StaticStatusOutput, accessibilitySummary: String) {
    appliedAccessibilitySummary = accessibilitySummary
    accessibilitySummarySink?(accessibilitySummary)
    if let staticOutputSink {
      staticOutputSink(output)
      return
    }
    guard let button = statusItem?.button else { return }
    button.setAccessibilityLabel(accessibilitySummary)
    switch output {
    case .image(let image):
      setButtonImage(image)
    case .fallback(let title):
      button.image = nil
      button.title = title
    }
  }

  private func applyEligibleMotion(_ output: PreparedPresentation, dark: Bool) {
    guard !reduceMotionEnabled, statusItem != nil || allowsHeadlessVisualResources,
          output.hasDisplayData else {
      // Ineligible (reduce motion, no button, or nothing to show) — updateActivityLayers() is
      // never reached below to reconcile, so any stale hatch layers must be cleared explicitly.
      clearActivityLayers()
      return
    }
    let modern = presentationConfiguration.displayMode() == "modern"
    if modern {
      updateActivityLayers()
      return
    }
    // Pixel mode doesn't use activity layers — drop any left over from a prior modern presentation.
    clearActivityLayers()
    startGlintTimer()
    restartCatTimer(output.catState)
    var frames: [NSImage] = []
    if !introPlayed {
      introPlayed = true
      frames += introFrames(items: output.items, dark: dark, cat: output.catState,
                            configuration: presentationConfiguration)
    }
    frames += glintFrames(items: output.items, dark: dark, cat: output.catState,
                          configuration: presentationConfiguration)
    if case .image(let finalImage) = output.staticOutput, !frames.isEmpty {
      frames.append(finalImage)
      let interval = ProcessInfo.processInfo.environment["CCB_ANIM_INTERVAL"].flatMap(Double.init) ?? 0.045
      playFrames(frames, interval: interval)
    }
  }

  private func applyProductionPostRender() {
    guard statusItem != nil else { return }
    if CommandLine.arguments.contains("--pop-menu"), !menuPopped {
      menuPopped = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, let button = self.statusItem?.button, button.window != nil,
              let menu = self.statusItem?.menu else { return }
        NSApp.activate(ignoringOtherApps: true)
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        let point = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 28)
        menu.popUp(positioning: nil, at: point, in: nil)
      }
      return
    }
    if !promptShown {
      promptShown = true
      DispatchQueue.main.async { [weak self] in self?.firstRunAutoStartPrompt() }
    }
  }

  @objc func openLink(_ sender: NSMenuItem) {
    if let s = sender.representedObject as? String, let url = URL(string: s) {
      opener(url)
    }
  }

  @objc func openProviderApp(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    opener(URL(fileURLWithPath: path))
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
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = tr("Settings")
    window.isReleasedWhenClosed = false
    window.delegate = self
    let tabs = NSTabView(); tabs.tabViewType = .topTabsBezelBorder; tabs.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView(); content.addSubview(tabs); window.contentView = content
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
    ])
    func page(_ title: String, icon: String) -> (NSTabViewItem, NSStackView) {
      let view = NSView(); let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(stack)
      NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)])
      let item = NSTabViewItem(identifier: title); item.view = view; item.label = title; item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title); tabs.addTabViewItem(item)
      return (item, stack)
    }
    func popup(_ items: [String], selected: Int, action: Selector) -> NSPopUpButton {
      let p = NSPopUpButton(); p.addItems(withTitles: items); p.selectItem(at: selected); p.target = self; p.action = action; p.widthAnchor.constraint(equalToConstant: 230).isActive = true; return p
    }
    func heading(_ stack: NSStackView, _ text: String) { let label = NSTextField(labelWithString: text); label.font = .boldSystemFont(ofSize: 17); stack.addArrangedSubview(label) }
    func separator(_ stack: NSStackView) { let box = NSBox(); box.boxType = .separator; box.translatesAutoresizingMaskIntoConstraints = false; box.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true; stack.addArrangedSubview(box) }
    func note(_ stack: NSStackView, _ text: String) { let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; stack.addArrangedSubview(label) }
    func actionButton(_ title: String, _ selector: Selector) -> NSButton { NSButton(title: title, target: self, action: selector) }

    let (_, general) = page(tr("General"), icon: "gearshape")
    heading(general, tr("General")); note(general, tr("Configure how Claude and Codex usage appears on this Mac.")); separator(general)
    let langCodes = ["auto"] + LANG_DISPLAY.map { $0.code }; let langTitles = [tr("System default")] + LANG_DISPLAY.map { $0.name }; let savedLang = UserDefaults.standard.string(forKey: "uiLang") ?? "auto"
    let generalGrid = NSGridView(views: [[NSTextField(labelWithString: tr("Language")), popup(langTitles, selected: langCodes.firstIndex(of: savedLang) ?? 0, action: #selector(settingsLanguageChanged(_:)))]]); generalGrid.rowSpacing = 12; generalGrid.columnSpacing = 24; general.addArrangedSubview(generalGrid)
    if #available(macOS 13.0, *) { let login = NSButton(checkboxWithTitle: tr("Start at login"), target: self, action: #selector(toggleLoginItem)); login.state = loginItemEnabled ? .on : .off; general.addArrangedSubview(login) }
    separator(general); general.addArrangedSubview(NSTextField(labelWithString: "v\(APP_VERSION) · Claude & Codex Usage Battery")); let generalLinks = NSStackView(); generalLinks.orientation = .horizontal; generalLinks.spacing = 10; generalLinks.addArrangedSubview(actionButton(tr("Open GitHub page"), #selector(openGitHubFromSettings))); general.addArrangedSubview(generalLinks)

    let (_, display) = page(tr("Display"), icon: "paintbrush")
    heading(display, tr("Appearance")); note(display, tr("Choose the visual style and optional companion shown in the menu bar.")); separator(display)
    let appearance = NSGridView(views: [
      [NSTextField(labelWithString: tr("Display style")), popup([tr("Modern batteries"), tr("Pixel batteries")], selected: currentDisplayMode() == "modern" ? 0 : 1, action: #selector(settingsDisplayChanged(_:)))],
      [NSTextField(labelWithString: tr("Battery size")), popup([tr("Big"), tr("Small")], selected: currentBattSize() == "big" ? 0 : 1, action: #selector(settingsSizeChanged(_:)))],
      [NSTextField(labelWithString: tr("Cat")), popup([tr("Off"), tr("Wide face"), tr("Slim face"), tr("Slime")], selected: [CatStyle.none, .nyan, .slim, .slime].firstIndex(of: currentCatStyle()) ?? 0, action: #selector(settingsCatChanged(_:)))],
    ]); appearance.rowSpacing = 14; appearance.columnSpacing = 24; display.addArrangedSubview(appearance)

    let (_, limits) = page(tr("Limits"), icon: "slider.horizontal.3")
    heading(limits, tr("Menu bar items")); note(limits, tr("Select the limits shown in the compact menu bar indicator. Detailed usage remains available in the dropdown.")); separator(limits)
    let choices: [(String, String)] = [("claude5", "Claude 5h"), ("claudeWeek", "Claude week"), ("claudeFable", "Claude Fable"), ("codex5", "Codex 5h"), ("codexWeek", "Codex week")]
    var metricButtons: [NSButton] = []
    for (key, title) in choices {
      let button = NSButton(checkboxWithTitle: tr(title), target: self, action: #selector(toggleMetric(_:))); button.identifier = NSUserInterfaceItemIdentifier("visible_\(key)"); button.state = isMetricVisible(key) ? .on : .off; metricButtons.append(button)
    }
    let metrics = NSGridView(views: [[metricButtons[0], metricButtons[1]], [metricButtons[2], metricButtons[3]], [metricButtons[4], NSView()]])
    metrics.rowSpacing = 12; metrics.columnSpacing = 55
    limits.addArrangedSubview(metrics)

    let (_, integration) = page(tr("Integration"), icon: "link")
    heading(integration, tr("Integrations")); note(integration, tr("Optional tools add cost breakdowns and provide quick access to the project.")); separator(integration)
    if lastSnap?.block != nil { integration.addArrangedSubview(actionButton(tr("Open ccusage dashboard"), #selector(openDashboard))) }
    integration.addArrangedSubview(actionButton(tr("Open GitHub page"), #selector(openGitHubFromSettings)))

    let (_, updates) = page(tr("Updates"), icon: "arrow.clockwise")
    heading(updates, tr("Updates")); note(updates, tr("The app checks for updates once a day. You can review the source and releases on GitHub.")); separator(updates)
    updates.addArrangedSubview(NSTextField(labelWithString: "Claude & Codex Usage Battery v\(APP_VERSION)")); updates.addArrangedSubview(actionButton(tr("Open GitHub page"), #selector(openGitHubFromSettings)))

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
    statusItem?.button?.image = nil
    statusItem?.button?.title = tr("⬇︎ Updating…")
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

private struct CoreSelfTestFailure: Error {
  let group: String
  let check: String
  let detail: String
}

private final class CoreSelfTestAssetResolver: ProviderAssetResolving {
  let apps: [Provider: URL]
  private(set) var installedLookups = 0
  private(set) var imageLookups = 0

  init(apps: [Provider: URL]) { self.apps = apps }

  func installedApp(for provider: Provider) -> URL? {
    installedLookups += 1
    return apps[provider]
  }

  func providerImage(for provider: Provider, installedApp: URL?) -> NSImage? {
    imageLookups += 1
    return NSImage(size: NSSize(width: 16, height: 16))
  }

  func applicationImage(for provider: Provider, installedApp: URL?) -> NSImage? {
    imageLookups += 1
    return NSImage(size: NSSize(width: 16, height: 16))
  }
}

private final class CoreSelfTestFlag {
  var value: Bool
  init(_ value: Bool) { self.value = value }
}

private final class CoreSelfTestBox<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

private final class CoreSelfTestVisualTimer: VisualTimerResource {
  let kind: VisualTimerKind
  private let callback: (VisualTimerResource) -> Void
  private(set) var isValid = true
  private(set) var callbackAttempts = 0
  private(set) var effectBegins = 0

  init(kind: VisualTimerKind, callback: @escaping (VisualTimerResource) -> Void) {
    self.kind = kind
    self.callback = callback
  }

  func invalidate() { isValid = false }
  func callbackEffectBegan() { effectBegins += 1 }
  func fireEvenIfInvalid() {
    callbackAttempts += 1
    callback(self)
  }
}

private final class CoreSelfTestVisualTimerFactory {
  private(set) var resources: [CoreSelfTestVisualTimer] = []

  func make(kind: VisualTimerKind, interval: TimeInterval, repeats: Bool,
            callback: @escaping (VisualTimerResource) -> Void) -> VisualTimerResource {
    let resource = CoreSelfTestVisualTimer(kind: kind, callback: callback)
    resources.append(resource)
    return resource
  }
}

private func runCoreSelfTest() throws {
  func require(_ value: @autoclosure () -> Bool, _ group: String, _ check: String,
               _ detail: String) throws {
    if !value() { throw CoreSelfTestFailure(group: group, check: check, detail: detail) }
  }
  let configuration = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "pixel" }, catStyle: { .nyan },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" })
  let now = 2_000_000_000
  let usage = ClaudeUsage(measuredAt: now, live: true,
                          fiveHour: UsageWindow(pct: 25, resetsAt: now + 4_000),
                          weekly: UsageWindow(pct: 50, resetsAt: nil), fable: nil)
  let codex = CodexUsage(measuredAt: now, live: true, limitId: nil, plan: "plus",
                         primary: CodexWindow(usedPercent: 25, resetsAt: now + 3_000),
                         secondary: nil, credits: nil)
  let snapshot = Snapshot(now: now, usage: usage, block: nil, models: nil, codex: codex,
                          update: (nil, false))

  let used = [-1.0, 0, 25, 50, 80, 100, 101]
  let expected = [100.0, 100, 75, 50, 20, 0, 0]
  try require(zip(used, expected).allSatisfy { normalizedRemaining(fromUsed: $0) == $1 },
              "conversion-bands-risk", "conversion-table", "used values did not normalize")
  try require(remainingBand(20) == .red && remainingBand(20.0001) == .amber
                && remainingBand(49.999) == .amber && remainingBand(50) == .green
                && remainingBand(.nan) == .red,
              "conversion-bands-risk", "band-boundaries", "remaining bands differ")
  try require(hasLowRemainingResetDistantRisk(remaining: 11.999, resetSeconds: 1_801)
                && !hasLowRemainingResetDistantRisk(remaining: 12, resetSeconds: 1_801)
                && !hasLowRemainingResetDistantRisk(remaining: 11, resetSeconds: 1_800),
              "conversion-bands-risk", "risk-boundaries", "risk threshold differs")
  try require(battItems(snapshot, configuration: configuration).first?.remain == 75
                && providerSummaries(snapshot, configuration: configuration).first?.remain == 50,
              "conversion-bands-risk", "cross-surface-25",
              "detail did not show 75 remaining or summary did not show the constrained 50")
  let modernConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "modern" }, catStyle: { .none },
    batterySize: { "small" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" })
  let conversionAssets = ProviderAssetContext(resolver: CoreSelfTestAssetResolver(apps: [:]))
  let pixelImage = renderBatteryImage(
    dark: false, items: battItems(snapshot, configuration: configuration),
    cat: catState(snapshot, configuration: configuration), configuration: configuration)
  let modernImage = renderModernSummaryImage(
    dark: false, summaries: providerSummaries(snapshot, configuration: modernConfiguration),
    assetContext: conversionAssets)
  try require(pixelImage != nil && modernImage != nil,
              "conversion-bands-risk", "fixed-render-modes", "pixel or modern output was absent")
  let nonFiniteUsage = ClaudeUsage(
    measuredAt: now, live: true, fiveHour: UsageWindow(pct: .nan, resetsAt: now + 4_000),
    weekly: UsageWindow(pct: .infinity, resetsAt: nil), fable: nil)
  let nonFiniteCodex = CodexUsage(
    measuredAt: now, live: true, limitId: nil, plan: nil,
    primary: CodexWindow(usedPercent: -.infinity, resetsAt: now + 3_000),
    secondary: nil, credits: nil)
  let nonFiniteSnapshot = Snapshot(
    now: now, usage: nonFiniteUsage, block: nil, models: nil, codex: nonFiniteCodex,
    update: (nil, false))
  let nonFiniteItems = battItems(nonFiniteSnapshot, configuration: configuration)
  let nonFiniteSummaries = providerSummaries(
    nonFiniteSnapshot, configuration: modernConfiguration)
  try require(nonFiniteItems.allSatisfy { $0.remain == 0 }
                && nonFiniteSummaries.allSatisfy { $0.remain == 0 }
                && renderBatteryImage(dark: false, items: nonFiniteItems,
                                      configuration: configuration) != nil
                && renderModernSummaryImage(dark: false, summaries: nonFiniteSummaries,
                                            assetContext: conversionAssets) != nil
                && !hasLowRemainingResetDistantRisk(remaining: .nan,
                                                     resetSeconds: .infinity),
              "conversion-bands-risk", "non-finite-surfaces",
              "non-finite values escaped defensive normalization/rendering")
  let noCatBig = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "pixel" }, catStyle: { .none },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" })
  let noCatSmall = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "pixel" }, catStyle: { .none },
    batterySize: { "small" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" })
  let fixedItems = battItems(snapshot, configuration: noCatBig)
  let bigImage = renderBatteryImage(dark: false, items: fixedItems, configuration: noCatBig)
  let smallImage = renderBatteryImage(dark: false, items: fixedItems, configuration: noCatSmall)
  try require(bigImage?.size == NSSize(width: 186, height: 24)
                && smallImage?.size == NSSize(width: 140, height: 18)
                && modernImage?.size == NSSize(width: 129, height: 24),
              "conversion-bands-risk", "fixed-dimensions",
              "big/small/modern geometry changed")
  let hiddenConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in false }, displayMode: { "pixel" }, catStyle: { .none },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "ja" })
  try require(battItems(snapshot, configuration: hiddenConfiguration).isEmpty
                && providerSummaries(snapshot, configuration: hiddenConfiguration).isEmpty
                && renderBatteryImage(dark: false, items: [],
                                      configuration: hiddenConfiguration)?.size
                  == NSSize(width: 16, height: 24),
              "conversion-bands-risk", "hidden-metrics", "hidden metrics leaked across surfaces")
  var productionReaderCalls = 0
  let countingConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in productionReaderCalls += 1; return true },
    displayMode: { productionReaderCalls += 1; return "modern" },
    catStyle: { productionReaderCalls += 1; return .none },
    batterySize: { productionReaderCalls += 1; return "small" },
    goldTestEnabled: { productionReaderCalls += 1; return false },
    forcedCatState: { productionReaderCalls += 1; return nil },
    language: { productionReaderCalls += 1; return "ja" })
  let countingDelegate = AppDelegate(
    presentationConfiguration: countingConfiguration, collector: { _ in },
    assetContextFactory: { conversionAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { true }, motionNotificationCenter: NotificationCenter())
  let counted = countingDelegate.preparePresentation(
    snapshot, dark: false, swiftBarDuplicate: false, assets: conversionAssets)
  try require(productionReaderCalls > 0 && counted.hasDisplayData
                && counted.menu.items.first?.title.contains("使用量") == true
                && counted.accessibilitySummary.contains("残り75%"),
              "conversion-bands-risk", "injected-reader-sentinel",
              "test configuration or injected language was bypassed")
  print("self-test-core: conversion-bands-risk PASS")

  let apps: [Provider: URL] = [
    .claude: URL(fileURLWithPath: "/in-memory/Claude.app"),
    .codex: URL(fileURLWithPath: "/in-memory/Codex.app")
  ]
  let resolver = CoreSelfTestAssetResolver(apps: apps)
  let assets = ProviderAssetContext(resolver: resolver)
  var opened: [URL] = []
  let menuDelegate = AppDelegate(
    presentationConfiguration: configuration, collector: { _ in },
    assetContextFactory: { assets }, duplicateReader: { false },
    opener: { opened.append($0) }, reduceMotionReader: { true },
    glintIntervalReader: { 30 }, motionNotificationCenter: NotificationCenter())
  let menu = buildMenu(snapshot, swiftBarDup: false, target: menuDelegate,
                       assets: assets, language: "en")
  let titles = menu.items.map(\.title)
  try require(titles.contains { $0.contains("75% remaining") }
                && !titles.contains { $0.contains("used") || $0.contains("left")
                  || $0.localizedCaseInsensitiveContains("projected")
                  || $0.localizedCaseInsensitiveContains("on pace") },
              "menu-actions-copy", "remaining-copy", "gauge copy is not remaining-only")
  try require(titles.filter { $0 == "live · updated just now" }.count == 2,
              "menu-actions-copy", "freshness-count", "expected one freshness row per provider")
  try require(titles.contains { $0.contains("remaining is low") } == false,
              "menu-actions-copy", "warning-boundary", "25 used incorrectly warned")
  let lowUsage = ClaudeUsage(measuredAt: now, live: true,
                             fiveHour: UsageWindow(pct: 89, resetsAt: now + 1_801),
                             weekly: nil, fable: nil)
  let lowSnapshot = Snapshot(now: now, usage: lowUsage, block: nil, models: nil, codex: nil,
                             update: (nil, false))
  let lowMenu = buildMenu(lowSnapshot, swiftBarDup: false, target: menuDelegate,
                          assets: assets, language: "en")
  try require(lowMenu.items.contains { $0.title == "⚠ 5h remaining is low and reset is still 30m away" },
              "menu-actions-copy", "factual-low-warning", "low/reset-distant warning missing")
  let pastUsage = ClaudeUsage(measuredAt: now, live: true,
                              fiveHour: UsageWindow(pct: 25, resetsAt: now), weekly: nil, fable: nil)
  let pastMenu = buildMenu(
    Snapshot(now: now, usage: pastUsage, block: nil, models: nil, codex: nil, update: (nil, false)),
    swiftBarDup: false, target: menuDelegate, assets: assets, language: "en")
  try require(pastMenu.items.contains { $0.title.contains("75% remaining  ·  reset") },
              "menu-actions-copy", "past-reset", "past reset was not marked reset")
  guard let claudeHeader = menu.items.first(where: { ($0.representedObject as? String) == CLAUDE_USAGE_URL }),
        let claudeApp = menu.items.first(where: { ($0.representedObject as? String) == apps[.claude]?.path })
  else { throw CoreSelfTestFailure(group: "menu-actions-copy", check: "actions", detail: "action rows missing") }
  menuDelegate.openLink(claudeHeader)
  menuDelegate.openProviderApp(claudeApp)
  try require(opened == [URL(string: CLAUDE_USAGE_URL)!, apps[.claude]!],
              "menu-actions-copy", "action-destinations", "HTTPS/file actions differ")
  try require(claudeHeader.title.contains("↗") && !claudeApp.title.contains("↗"),
              "menu-actions-copy", "action-distinction", "external/app affordances differ")
  try require(resolver.installedLookups == 2,
              "menu-actions-copy", "installed-lookup-once", "installed apps were re-resolved")
  let expectedMenuTitles = [
    "Claude Code · usage ↗",
    "5h    ▕\(gaugeBar(75, 20))▏ 75% remaining  ·  resets \(fmtDur(4_000))  ↗",
    "week  ▕\(gaugeBar(50, 20))▏ 50% remaining  ↗",
    "live · updated just now",
    "Open Claude app",
    "",
    "Codex · plus · usage ↗",
    "5h    ▕\(gaugeBar(75, 20))▏ 75% remaining  ·  resets \(fmtDur(3_000))  ↗",
    "live · updated just now",
    "Open Codex app",
    "",
    "Refresh",
    "Settings",
    "",
    "Quit"
  ]
  try require(titles == expectedMenuTitles,
              "menu-actions-copy", "exact-hierarchy-order", "menu hierarchy/order changed")
  let actionable = menu.items.filter { $0.action != nil }
  try require(actionable.filter { $0.action == #selector(AppDelegate.openLink(_:)) }.count == 5
                && actionable.filter { $0.action == #selector(AppDelegate.openProviderApp(_:)) }.count == 2
                && menu.items[11].action == #selector(AppDelegate.refresh)
                && menu.items[12].action == #selector(AppDelegate.showSettings)
                && actionable.filter { $0.action != #selector(NSApplication.terminate(_:)) }
                  .allSatisfy { $0.target === menuDelegate },
              "menu-actions-copy", "selectors-targets", "selector/target wiring changed")
  let providerActionRows = actionable.filter {
    $0.action == #selector(AppDelegate.openLink(_:))
      || $0.action == #selector(AppDelegate.openProviderApp(_:))
  }
  try require(providerActionRows.allSatisfy {
                  ($0.representedObject as? String)?.hasPrefix("https://") == true
                    || ($0.representedObject as? String)?.hasPrefix("/") == true
                }
                && providerActionRows.allSatisfy {
                  $0.toolTip?.isEmpty == false && $0.accessibilityLabel()?.isEmpty == false
                },
              "menu-actions-copy", "represented-tooltip-accessibility",
              "provider action metadata changed")
  let gaugeRows = menu.items.filter {
    ($0.representedObject as? String) == CLAUDE_USAGE_URL
      || ($0.representedObject as? String) == CODEX_USAGE_URL
  }.filter { $0.title.contains("▕") }
  try require(gaugeRows.count == 3 && gaugeRows.allSatisfy {
                  $0.accessibilityLabel()?.contains("75% remaining") == true
                    || $0.accessibilityLabel()?.contains("50% remaining") == true
                }
                && gaugeRows.allSatisfy {
                  $0.accessibilityLabel()?.contains("5h") == true
                    || $0.accessibilityLabel()?.contains("week") == true
                }
                && gaugeRows.filter { ($0.representedObject as? String) == CLAUDE_USAGE_URL }
                  .allSatisfy { $0.accessibilityHelp() == "Open Claude usage" }
                && gaugeRows.filter { ($0.representedObject as? String) == CODEX_USAGE_URL }
                  .allSatisfy { $0.accessibilityHelp() == "Open Codex usage" },
              "menu-actions-copy", "gauge-accessibility-semantics",
              "gauge metric/remaining label or provider-specific action help changed")
  guard let codexHeader = menu.items.first(where: {
          ($0.representedObject as? String) == CODEX_USAGE_URL
        }),
        let codexApp = menu.items.first(where: {
          ($0.representedObject as? String) == apps[.codex]?.path
        })
  else {
    throw CoreSelfTestFailure(group: "menu-actions-copy", check: "codex-actions",
                              detail: "Codex action rows missing")
  }
  menuDelegate.openLink(codexHeader)
  menuDelegate.openProviderApp(codexApp)
  try require(opened == [URL(string: CLAUDE_USAGE_URL)!, apps[.claude]!,
                         URL(string: CODEX_USAGE_URL)!, apps[.codex]!],
              "menu-actions-copy", "recorded-invocations", "recorded provider actions differ")
  let cachedSnapshot = Snapshot(
    now: now, usage: ClaudeUsage(measuredAt: now - 120, live: false,
                                 fiveHour: usage.fiveHour, weekly: nil, fable: nil),
    block: nil, models: nil,
    codex: CodexUsage(measuredAt: now - 120, live: false, limitId: nil, plan: nil,
                      primary: codex.primary, secondary: nil, credits: nil),
    update: (nil, false))
  let cachedMenu = buildMenu(cachedSnapshot, swiftBarDup: false, target: menuDelegate,
                             assets: assets, language: "en")
  try require(cachedMenu.items.filter { $0.title.contains("cached 2m ago") }.count == 2,
              "menu-actions-copy", "cached-providers", "cached rows missing")
  let block = ClaudeBlock(elapsedPct: 40, remainMin: 12, cost: 1.5,
                          tokens: 2_000, costPerHour: 3)
  let blockCreditsSnapshot = Snapshot(
    now: now, usage: nil, block: block, models: nil,
    codex: CodexUsage(measuredAt: now, live: true, limitId: nil, plan: nil,
                      primary: nil, secondary: nil,
                      credits: CodexCredits(hasCredits: false, unlimited: false, balance: nil)),
    update: (nil, false))
  let blockCreditsMenu = buildMenu(blockCreditsSnapshot, swiftBarDup: false,
                                   target: menuDelegate, assets: assets, language: "en")
  try require(blockCreditsMenu.items.contains { $0.title.contains("this block") }
                && blockCreditsMenu.items.contains { $0.title.contains("credits  exhausted") },
              "menu-actions-copy", "block-credits", "block/credits rows missing")
  let claudeOnly = buildMenu(
    Snapshot(now: now, usage: usage, block: nil, models: nil, codex: nil,
             update: (nil, false)),
    swiftBarDup: false, target: menuDelegate, assets: assets, language: "en")
  let noProvider = buildMenu(
    Snapshot(now: now, usage: nil, block: nil, models: nil, codex: nil,
             update: (nil, false)),
    swiftBarDup: false, target: menuDelegate, assets: assets, language: "en")
  try require(claudeOnly.items.first?.title.hasPrefix("Claude Code") == true
                && !claudeOnly.items.contains { $0.title.hasPrefix("Codex") }
                && noProvider.items.first?.title
                  == "Run Claude Code or Codex and usage will appear here",
              "menu-actions-copy", "one-no-provider", "one/no-provider hierarchy changed")
  print("self-test-core: menu-actions-copy PASS")

  var completions: [(Snapshot) -> Void] = []
  var menus: [NSMenu] = []
  var outputs: [StaticStatusOutput] = []
  var accessibilitySummaries: [String] = []
  let refreshResolver = CoreSelfTestAssetResolver(apps: [:])
  let refreshAssets = ProviderAssetContext(resolver: refreshResolver)
  let refreshDelegate = AppDelegate(
    presentationConfiguration: configuration,
    collector: { completions.append($0) },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { true }, glintIntervalReader: { 30 },
    motionNotificationCenter: NotificationCenter())
  refreshDelegate.menuSink = { menus.append($0) }
  refreshDelegate.staticOutputSink = { outputs.append($0) }
  refreshDelegate.accessibilitySummarySink = { accessibilitySummaries.append($0) }
  let retainedUsage = ClaudeUsage(
    measuredAt: now - 30, live: true,
    fiveHour: UsageWindow(pct: 11, resetsAt: now + 111),
    weekly: UsageWindow(pct: 22, resetsAt: now + 222),
    fable: FableWindow(pct: 33, resetsAt: now + 333, model: "prior-fable"))
  let retainedCodex = CodexUsage(
    measuredAt: now - 45, live: true, limitId: "prior-limit", plan: "prior-plan",
    primary: CodexWindow(usedPercent: 44, resetsAt: now + 444),
    secondary: CodexWindow(usedPercent: 55, resetsAt: now + 555),
    credits: CodexCredits(hasCredits: true, unlimited: false, balance: 12.5))
  let retainedPrior = Snapshot(
    now: now, usage: retainedUsage,
    block: ClaudeBlock(elapsedPct: 12, remainMin: 34, cost: 5.6, tokens: 789,
                       costPerHour: 1.2),
    models: (models: [ModelUse(name: "prior-model", cost: 3.4, tokens: 567)], total: 3.4),
    codex: retainedCodex, update: ("prior-version", false))
  refreshDelegate.requestRefresh(.timer)
  refreshDelegate.requestRefresh(.manual)
  refreshDelegate.requestRefresh(.timer)
  try require(completions.count == 1, "refresh-retention", "single-active", "more than one collection started")
  completions[0](snapshot)
  try require(completions.count == 2 && menus.isEmpty && outputs.isEmpty,
              "refresh-retention", "superseded", "superseded completion rendered")
  refreshDelegate.requestRefresh(.manual)
  refreshDelegate.requestRefresh(.timer)
  try require(completions.count == 2 && menus.isEmpty && outputs.isEmpty,
              "refresh-retention", "active-trailing-replacement",
              "request queued while trailing collection was active started early")
  completions[1](snapshot)
  try require(completions.count == 3 && menus.isEmpty && outputs.isEmpty
                && accessibilitySummaries.isEmpty,
              "refresh-retention", "active-trailing-superseded",
              "superseded trailing generation rendered or failed to start newest replacement")
  completions[2](retainedPrior)
  try require(refreshDelegate.acceptedRenderCount == 1 && menus.count == 1 && outputs.count == 1
                && accessibilitySummaries.count == 1
                && accessibilitySummaries[0].contains("Claude 5h, 89% remaining")
                && accessibilitySummaries[0].contains("Codex 5h, 56% remaining")
                && refreshDelegate.acceptedGenerations == [RefreshGeneration(value: 5)]
                && refreshDelegate.acceptedRefreshTriggers == [.timer],
              "refresh-retention", "accepted-newest-trailing",
              "newest replacement generation did not apply exactly once")
  completions[2](snapshot)
  try require(refreshDelegate.acceptedRenderCount == 1 && menus.count == 1 && outputs.count == 1
                && accessibilitySummaries.count == 1,
              "refresh-retention", "stale-duplicate", "duplicate completion rendered")
  refreshDelegate.requestRefresh(.manual)
  let incomingBlock = ClaudeBlock(elapsedPct: 67, remainMin: 89, cost: 10.1, tokens: 2_345,
                                  costPerHour: 6.7)
  let incomingModels = (
    models: [
      ModelUse(name: "incoming-alpha", cost: 7.8, tokens: 901),
      ModelUse(name: "incoming-beta", cost: 2.3, tokens: 456),
    ],
    total: 10.1
  )
  let missing = Snapshot(now: now + 120, usage: nil, block: incomingBlock,
                         models: incomingModels, codex: nil, update: ("9.9.9", true))
  completions[3](missing)
  let retained = refreshDelegate.lastSnap
  try require(retained?.now == now + 120
                && retained?.usage?.measuredAt == now - 30
                && retained?.usage?.live == false
                && retained?.usage?.fiveHour?.pct == 11
                && retained?.usage?.fiveHour?.resetsAt == now + 111
                && retained?.usage?.weekly?.pct == 22
                && retained?.usage?.weekly?.resetsAt == now + 222
                && retained?.usage?.fable?.pct == 33
                && retained?.usage?.fable?.resetsAt == now + 333
                && retained?.usage?.fable?.model == "prior-fable"
                && retained?.codex?.measuredAt == now - 45
                && retained?.codex?.live == false
                && retained?.codex?.limitId == "prior-limit"
                && retained?.codex?.plan == "prior-plan"
                && retained?.codex?.primary?.usedPercent == 44
                && retained?.codex?.primary?.resetsAt == now + 444
                && retained?.codex?.secondary?.usedPercent == 55
                && retained?.codex?.secondary?.resetsAt == now + 555
                && retained?.codex?.credits?.hasCredits == true
                && retained?.codex?.credits?.unlimited == false
                && retained?.codex?.credits?.balance == 12.5
                && retained?.block?.elapsedPct == 67
                && retained?.block?.remainMin == 89
                && retained?.block?.cost == 10.1
                && retained?.block?.tokens == 2_345
                && retained?.block?.costPerHour == 6.7
                && retained?.models?.models.map(\.name)
                  == ["incoming-alpha", "incoming-beta"]
                && retained?.models?.models.map(\.cost) == [7.8, 2.3]
                && retained?.models?.models.map(\.tokens) == [901, 456]
                && retained?.models?.total == 10.1
                && retained?.update.latest == "9.9.9"
                && retained?.update.hasUpdate == true
                && refreshDelegate.acceptedRenderCount == 2,
              "refresh-retention", "provider-retention",
              "retained provider or newest ancillary fields differed")
  try require(menus[1].items.filter { $0.title.contains("cached 2m ago") }.count == 2
                && refreshDelegate.acceptedGenerations.map(\.value) == [5, 6]
                && refreshDelegate.acceptedRefreshTriggers == [.timer, .manual],
              "refresh-retention", "accepted-sinks-generations",
              "accepted retained menu/generation trace differs")
  let countBeforeRerender = refreshDelegate.acceptedRenderCount
  refreshDelegate.rerender()
  try require(refreshDelegate.acceptedRenderCount == countBeforeRerender,
              "refresh-retention", "rerender-not-accept", "UI rerender incremented acceptance")
  if case .image(let image) = outputs[0] {
    try require(image.size.width > 0 && image.size.height > 0,
                "refresh-retention", "real-static-output", "static image is empty")
  } else {
    throw CoreSelfTestFailure(group: "refresh-retention", check: "real-static-output",
                              detail: "expected rendered image")
  }
  func exerciseRefreshOrder(_ first: RefreshTrigger, _ second: RefreshTrigger) throws {
    var orderCompletions: [(Snapshot) -> Void] = []
    var orderMenus: [NSMenu] = []
    var orderOutputs: [StaticStatusOutput] = []
    let delegate = AppDelegate(
      presentationConfiguration: configuration,
      collector: { orderCompletions.append($0) },
      assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
      reduceMotionReader: { true }, motionNotificationCenter: NotificationCenter())
    delegate.menuSink = { orderMenus.append($0) }
    delegate.staticOutputSink = { orderOutputs.append($0) }
    delegate.requestRefresh(first)
    delegate.requestRefresh(second)
    orderCompletions[0](snapshot)
    try require(orderCompletions.count == 2 && orderMenus.isEmpty && orderOutputs.isEmpty,
                "refresh-retention", "timer-manual-supersession",
                "superseded timer/manual completion reached a sink")
    orderCompletions[1](cachedSnapshot)
    try require(delegate.acceptedRefreshTriggers == [second]
                  && delegate.acceptedGenerations.map(\.value) == [2]
                  && orderMenus.count == 1 && orderOutputs.count == 1
                  && orderMenus[0].items.contains { $0.title.contains("cached 2m ago") },
                "refresh-retention", "timer-manual-order",
                "timer/manual newest accepted preparation or sinks differed")
  }
  try exerciseRefreshOrder(.timer, .manual)
  try exerciseRefreshOrder(.manual, .timer)

  let initialUnavailable = Snapshot(now: now + 120, usage: nil, block: nil, models: nil,
                                    codex: nil, update: (nil, false))

  var unavailableCompletion: ((Snapshot) -> Void)?
  var unavailableMenu: NSMenu?
  var unavailableOutput: StaticStatusOutput?
  var unavailableAccessibility: String?
  let unavailableDelegate = AppDelegate(
    presentationConfiguration: configuration,
    collector: { unavailableCompletion = $0 },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { true }, motionNotificationCenter: NotificationCenter())
  unavailableDelegate.menuSink = { unavailableMenu = $0 }
  unavailableDelegate.staticOutputSink = { unavailableOutput = $0 }
  unavailableDelegate.accessibilitySummarySink = { unavailableAccessibility = $0 }
  unavailableDelegate.requestRefresh(.initial)
  unavailableCompletion?(initialUnavailable)
  let unavailableIsFallback: Bool
  if case .fallback("🔋 —")? = unavailableOutput { unavailableIsFallback = true }
  else { unavailableIsFallback = false }
  try require(unavailableDelegate.acceptedRefreshTriggers == [.initial]
                && unavailableDelegate.acceptedGenerations == [RefreshGeneration(value: 1)]
                && unavailableMenu?.items.first?.title
                  == "Run Claude Code or Codex and usage will appear here"
                && unavailableAccessibility
                  == "Run Claude Code or Codex and usage will appear here"
                && unavailableIsFallback,
              "refresh-retention", "initial-unavailable",
              "initial unavailable accepted sinks differed")
  print("self-test-core: refresh-retention PASS")

  let motionFlag = CoreSelfTestFlag(false)
  let motionMode = CoreSelfTestBox("pixel")
  let motionCat = CoreSelfTestBox(CatStyle.nyan)
  let motionConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { motionMode.value },
    catStyle: { motionCat.value }, batterySize: { "big" },
    goldTestEnabled: { false }, forcedCatState: { nil }, language: { "en" })
  let center = NotificationCenter()
  let motionFactory = CoreSelfTestVisualTimerFactory()
  var motionMenus: [NSMenu] = []
  var motionOutputs: [StaticStatusOutput] = []
  var motionAccessibility: [String] = []
  var motionCompletions: [(Snapshot) -> Void] = []
  let inertMonitor = NSObject()
  let motionDelegate = AppDelegate(
    presentationConfiguration: motionConfiguration,
    collector: { motionCompletions.append($0) },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { motionFlag.value }, glintIntervalReader: { 30 },
    motionNotificationCenter: center, visualTimerFactory: motionFactory.make,
    allowsHeadlessVisualResources: true, providerMonitorIdentity: inertMonitor)
  motionDelegate.menuSink = { motionMenus.append($0) }
  motionDelegate.staticOutputSink = { motionOutputs.append($0) }
  motionDelegate.accessibilitySummarySink = { motionAccessibility.append($0) }
  let refreshTimer = Timer(timeInterval: 600, repeats: true) { _ in }
  motionDelegate.timer = refreshTimer
  motionDelegate.apiActiveProviders = [.claude, .codex]
  motionDelegate.updateActivityAnimation()
  motionDelegate.requestRefresh(.initial)
  motionCompletions[0](snapshot)
  let pixelResources = motionDelegate.visualResourceSnapshot()
  try require(pixelResources.animationTimer != nil && pixelResources.catTimer != nil
                && pixelResources.glintTimer != nil && pixelResources.activityLayers.isEmpty
                && pixelResources.activityTextLayers.isEmpty,
              "reduce-motion", "pixel-eligible-resources",
              "pixel presentation did not install only eligible resources")
  let initialAccessibility = motionDelegate.appliedAccessibilitySummary
  let initialAccessibilitySinkCount = motionAccessibility.count
  let initialOutputSinkCount = motionOutputs.count
  let liveTimers = motionFactory.resources.filter {
    $0.kind == .animation || $0.kind == .cat || $0.kind == .glint
  }
  try require([VisualTimerKind.animation, .cat, .glint].allSatisfy { kind in
                  liveTimers.filter { $0.kind == kind }.count == 1
                },
              "reduce-motion", "stale-callback-fixtures",
              "pixel presentation did not expose exactly one callback of every timer kind")
  liveTimers.forEach { $0.fireEvenIfInvalid() }
  try require(initialAccessibility?.contains("Claude 5h, 75% remaining") == true
                && motionDelegate.appliedAccessibilitySummary == initialAccessibility
                && motionAccessibility.count == initialAccessibilitySinkCount
                && motionOutputs.count == initialOutputSinkCount
                && liveTimers.allSatisfy {
                  $0.callbackAttempts == 1 && $0.effectBegins == 1
                },
              "reduce-motion", "animation-accessibility-continuity",
              "valid production timer callbacks did not cross the observable effect boundary")
  let staleTimers = liveTimers
  let acceptedCount = motionDelegate.acceptedRenderCount
  let outputCountBeforeEnable = motionOutputs.count
  let accessibilityCountBeforeEnable = motionAccessibility.count
  motionFlag.value = true
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  let reducedResources = motionDelegate.visualResourceSnapshot()
  try require(reducedResources.animationTimer == nil && reducedResources.catTimer == nil
                && reducedResources.glintTimer == nil && reducedResources.activityLayers.isEmpty
                && reducedResources.activityTextLayers.isEmpty
                && reducedResources.epoch > pixelResources.epoch
                && motionOutputs.count == outputCountBeforeEnable + 1
                && motionAccessibility.count == accessibilityCountBeforeEnable + 1
                && motionDelegate.appliedAccessibilitySummary == initialAccessibility,
              "reduce-motion", "mid-motion-cancellation",
              "enabling Reduce Motion did not cancel motion and reapply static output exactly once")
  let enabledOutputCount = motionOutputs.count
  let enabledAccessibilityCount = motionAccessibility.count
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  try require(motionDelegate.visualResourceSnapshot() == reducedResources
                && motionOutputs.count == enabledOutputCount
                && motionAccessibility.count == enabledAccessibilityCount
                && motionDelegate.acceptedRenderCount == acceptedCount,
              "reduce-motion", "enable-idempotent-identity",
              "same-value notification changed resource identity/count")

  motionMode.value = "modern"
  motionCat.value = .none
  motionDelegate.apiActiveProviders = [.claude]
  motionDelegate.updateActivityAnimation()
  motionDelegate.rerender()
  let reducedModernOne = motionDelegate.visualResourceSnapshot()
  motionCat.value = .nyan
  motionDelegate.apiActiveProviders = [.claude, .codex]
  motionDelegate.updateActivityAnimation()
  motionDelegate.rerender()
  let reducedModernTwo = motionDelegate.visualResourceSnapshot()
  try require(reducedModernOne.animationTimer == nil && reducedModernOne.catTimer == nil
                && reducedModernOne.glintTimer == nil && reducedModernOne.activityLayers.isEmpty
                && reducedModernOne.activityTextLayers.isEmpty
                && reducedModernTwo.animationTimer == nil && reducedModernTwo.catTimer == nil
                && reducedModernTwo.glintTimer == nil && reducedModernTwo.activityLayers.isEmpty
                && reducedModernTwo.activityTextLayers.isEmpty,
              "reduce-motion", "reduced-config-activity-suppression",
              "reduced config/cat/activity changes created visual resources")

  let menuCountBeforeRefresh = motionMenus.count
  let outputCountBeforeRefresh = motionOutputs.count
  let accessibilityCountBeforeRefresh = motionAccessibility.count
  motionDelegate.requestRefresh(.timer)
  motionCompletions[1](cachedSnapshot)
  let reducedAfterRefresh = motionDelegate.visualResourceSnapshot()
  try require(motionDelegate.reduceMotionEnabled
                && motionDelegate.acceptedRenderCount == acceptedCount + 1
                && motionDelegate.acceptedRefreshTriggers == [.initial, .timer]
                && motionMenus.count == menuCountBeforeRefresh + 1
                && (motionMenus.last?.items.contains {
                  $0.title.contains("cached 2m ago")
                }) == true
                && motionOutputs.count == outputCountBeforeRefresh + 1
                && motionAccessibility.count == accessibilityCountBeforeRefresh + 1
                && motionAccessibility.last == motionDelegate.appliedAccessibilitySummary
                && (motionDelegate.appliedAccessibilitySummary?
                  .contains("Claude, 75% remaining")) == true
                && reducedAfterRefresh.animationTimer == nil && reducedAfterRefresh.catTimer == nil
                && reducedAfterRefresh.glintTimer == nil
                && reducedAfterRefresh.activityLayers.isEmpty
                && reducedAfterRefresh.activityTextLayers.isEmpty
                && reducedAfterRefresh.refreshTimer == ObjectIdentifier(refreshTimer)
                && reducedAfterRefresh.refreshTimerActive
                && reducedAfterRefresh.providerMonitor == ObjectIdentifier(inertMonitor)
                && motionDelegate.providerMonitorIdentity === inertMonitor
                && motionDelegate.activeProviders == Set([.claude, .codex]),
              "reduce-motion", "reduced-refresh-nonvisual-continuation",
              "accepted reduced refresh or nonvisual identities/state changed")

  let stateBeforeStale = motionDelegate.visualResourceSnapshot()
  let catIndexBeforeStale = motionDelegate.catIdx
  let menusBeforeStale = motionMenus.count
  let outputsBeforeStale = motionOutputs.count
  let accessibilityBeforeStale = motionAccessibility.count
  staleTimers.forEach { $0.fireEvenIfInvalid() }
  try require(staleTimers.allSatisfy {
                  !$0.isValid && $0.callbackAttempts == 2 && $0.effectBegins == 1
                }
                && motionDelegate.visualResourceSnapshot() == stateBeforeStale
                && motionDelegate.catIdx == catIndexBeforeStale
                && motionMenus.count == menusBeforeStale
                && motionOutputs.count == outputsBeforeStale
                && motionAccessibility.count == accessibilityBeforeStale,
              "reduce-motion", "all-stale-callback-rejection",
              "invalidated callback crossed an old-epoch effect boundary or changed state")

  motionFlag.value = false
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  let restoredModern = motionDelegate.visualResourceSnapshot()
  try require(restoredModern.activityLayers.count == 2 && restoredModern.activityTextLayers.count == 2
                && restoredModern.animationTimer == nil && restoredModern.catTimer == nil
                && restoredModern.glintTimer == nil,
              "reduce-motion", "modern-eligible-restoration",
              "modern activity layers were not restored only after disabling Reduce Motion")
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  try require(motionDelegate.visualResourceSnapshot() == restoredModern,
              "reduce-motion", "modern-restoration-idempotence",
              "same-value disabled notification changed modern resource identity")

  motionFlag.value = true
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  let repeatedReduced = motionDelegate.visualResourceSnapshot()
  try require(repeatedReduced.activityLayers.isEmpty && repeatedReduced.activityTextLayers.isEmpty
                && repeatedReduced.animationTimer == nil
                && repeatedReduced.catTimer == nil && repeatedReduced.glintTimer == nil,
              "reduce-motion", "repeated-reduced-idempotence",
              "repeated reduced cycle retained visual resources")
  motionFlag.value = false
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  let repeatedModern = motionDelegate.visualResourceSnapshot()
  center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  try require(repeatedModern.activityLayers.count == 2 && repeatedModern.activityTextLayers.count == 2
                && motionDelegate.visualResourceSnapshot() == repeatedModern,
              "reduce-motion", "modern-repeat-restoration-idempotence",
              "repeated cycle restored ineligible resources or changed identity")

  motionMode.value = "pixel"
  motionDelegate.rerender()
  let finalPixel = motionDelegate.visualResourceSnapshot()
  try require(finalPixel.activityLayers.isEmpty && finalPixel.activityTextLayers.isEmpty
                && finalPixel.catTimer != nil
                && finalPixel.glintTimer != nil && finalPixel.animationTimer == nil,
              "reduce-motion", "representation-invalidation",
              "re-presentation retained resources from the prior mode")

  let launchReducedFactory = CoreSelfTestVisualTimerFactory()
  var launchReducedCompletion: ((Snapshot) -> Void)?
  let launchMonitor = NSObject()
  let launchReduced = AppDelegate(
    presentationConfiguration: motionConfiguration,
    collector: { launchReducedCompletion = $0 },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { true }, motionNotificationCenter: NotificationCenter(),
    visualTimerFactory: launchReducedFactory.make, allowsHeadlessVisualResources: true,
    providerMonitorIdentity: launchMonitor)
  launchReduced.menuSink = { _ in }
  launchReduced.staticOutputSink = { _ in }
  launchReduced.requestRefresh(.initial)
  launchReducedCompletion?(snapshot)
  let launchResources = launchReduced.visualResourceSnapshot()
  try require(launchReduced.reduceMotionEnabled && launchReducedFactory.resources.isEmpty
                && launchResources.animationTimer == nil && launchResources.catTimer == nil
                && launchResources.glintTimer == nil && launchResources.activityLayers.isEmpty
                && launchResources.activityTextLayers.isEmpty
                && launchResources.providerMonitor == ObjectIdentifier(launchMonitor)
                && launchReduced.providerMonitorIdentity === launchMonitor,
              "reduce-motion", "enabled-before-render",
              "launch-enabled Reduce Motion created resources or replaced inert monitor identity")
  print("self-test-core: reduce-motion PASS")

  // ── drain hatch: derived colors and shared modern geometry ──
  try require(activityHatchRGB(75, dark: true) == (9, 47, 18)
                && emptyHatchRGB(dark: true) == (95, 95, 95)
                && emptyHatchRGB(dark: false) == (190, 190, 190),
              "drain-hatch", "derived-colors",
              "hatch colors were not derived from the remaining color")
  try require(MODERN_ITEM_WIDTH == 59,
              "drain-hatch", "modern-item-width",
              "modern item width did not match the rendered layout")

  // ── drain hatch: modern mode layers ──
  // Note: local names prefixed hatchMode* (not modern*) — a `modernConfiguration` from
  // conversion-bands-risk above already occupies this flat function scope.
  let hatchModeFlag = CoreSelfTestFlag(false)
  let hatchModeConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "modern" },
    catStyle: { CatStyle.none }, batterySize: { "big" },
    goldTestEnabled: { false }, forcedCatState: { nil }, language: { "en" })
  var hatchModeCompletions: [(Snapshot) -> Void] = []
  let hatchModeCenter = NotificationCenter()
  let hatchModeDelegate = AppDelegate(
    presentationConfiguration: hatchModeConfiguration,
    collector: { hatchModeCompletions.append($0) },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { hatchModeFlag.value }, glintIntervalReader: { 30 },
    motionNotificationCenter: hatchModeCenter,
    visualTimerFactory: CoreSelfTestVisualTimerFactory().make,
    allowsHeadlessVisualResources: true, providerMonitorIdentity: NSObject())
  hatchModeDelegate.menuSink = { _ in }
  hatchModeDelegate.staticOutputSink = { _ in }
  hatchModeDelegate.accessibilitySummarySink = { _ in }
  hatchModeDelegate.requestRefresh(.initial)
  hatchModeCompletions[0](snapshot)
  hatchModeDelegate.apiActiveProviders = [.claude]
  hatchModeDelegate.updateActivityAnimation()
  let clip = hatchModeDelegate.activityLayers[.claude]
  let stripes = clip?.sublayers?.first
  try require(Set(hatchModeDelegate.activityLayers.keys) == [Provider.claude]
                && clip?.masksToBounds == true
                && stripes?.contents != nil
                && stripes?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-layer-installed",
              "active provider did not get a masked, animated hatch layer")
  try require((clip?.frame.width ?? 0) > 0 && (clip?.frame.height ?? 0) == 14
                && (stripes?.frame.width ?? 0) == (clip?.frame.width ?? 0) + HATCH_PITCH_PT,
              "drain-hatch", "modern-layer-geometry",
              "hatch layer geometry did not match the battery fill")
  // The clip layer covers the centered "NN%" in the button image, so the number is redrawn above it
  // at exactly the origin renderModernSummaryImage drew it from — glyph origin, not box center,
  // because the layer is sized to the rounded-up raster so .resize gravity can't squeeze it
  let label = hatchModeDelegate.activityTextLayers[.claude]
  func textImageHasInk(_ value: Double) -> Bool {
    guard let text = modernValueTextImage(value, dark: false),
          let pixels = text.image.dataProvider?.data else { return false }
    return (pixels as Data).contains { $0 != 0 }
  }
  let labelText = modernValueTextImage(50, dark: false)
  let labelOriginX = MODERN_IMAGE_PAD + MODERN_ICON_WIDTH + MODERN_ICON_GAP
    + (MODERN_BODY_WIDTH - (labelText?.size.width ?? 0)) / 2
  try require(label?.contents != nil && (label?.frame.width ?? 0) > 0 && textImageHasInk(50)
                && label?.frame.minY == clip?.frame.minY
                && labelText != nil
                && label?.frame.width == labelText?.rasterSize.width
                && label?.frame.height == labelText?.rasterSize.height
                && abs((label?.frame.minX ?? 0) - labelOriginX) < 0.001,
              "drain-hatch", "modern-text-layer-installed",
              "the percentage was not redrawn above the hatch at the image's own text rect")
  // Drain, not charge: the stripes travel exactly one pitch left per hatch period
  let drift = stripes?.animation(forKey: "drain") as? CABasicAnimation
  let driftFrom = (drift?.fromValue as? NSNumber)?.doubleValue
  let driftTo = (drift?.toValue as? NSNumber)?.doubleValue
  try require(driftFrom != nil && driftTo != nil
                && driftTo! == driftFrom! - Double(HATCH_PITCH_PT)
                && drift?.duration == HATCH_PERIOD && drift?.repeatCount == .infinity,
              "drain-hatch", "modern-drift-direction",
              "the drain animation did not drift one pitch left over one hatch period")
  // A second call with nothing changed must not restart the running "drain" animation
  hatchModeDelegate.updateActivityAnimation()
  let clipReused = hatchModeDelegate.activityLayers[.claude]
  let stripesReused = clipReused?.sublayers?.first
  let labelReused = hatchModeDelegate.activityTextLayers[.claude]
  try require(clip != nil && clipReused != nil
                && ObjectIdentifier(clip!) == ObjectIdentifier(clipReused!)
                && stripes != nil && stripesReused != nil
                && ObjectIdentifier(stripes!) == ObjectIdentifier(stripesReused!)
                && label != nil && labelReused != nil
                && ObjectIdentifier(label!) == ObjectIdentifier(labelReused!)
                && stripesReused?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-layer-reused",
              "unchanged hatch geometry/color rebuilt the layer instead of reusing it")
  hatchModeDelegate.apiActiveProviders = []
  hatchModeDelegate.updateActivityAnimation()
  try require(hatchModeDelegate.activityLayers.isEmpty && hatchModeDelegate.activityTextLayers.isEmpty,
              "drain-hatch", "modern-layer-removed",
              "hatch layer survived the provider going idle")
  // Becoming active again after idle is a real change — the old layer identity must not resurface
  hatchModeDelegate.apiActiveProviders = [.claude]
  hatchModeDelegate.updateActivityAnimation()
  let clipRecreated = hatchModeDelegate.activityLayers[.claude]
  try require(clip != nil && clipRecreated != nil
                && ObjectIdentifier(clip!) != ObjectIdentifier(clipRecreated!)
                && clipRecreated?.sublayers?.first?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-layer-recreated-on-activate",
              "hatch layer identity survived an idle/active cycle instead of rebuilding")
  // A full refresh cycle (prepareAndApplyCurrent → applyEligibleMotion) on an unchanged modern
  // presentation is the real regression site — stopVisualMotion() used to wipe layers here on
  // every refresh regardless of the reuse check above.
  hatchModeDelegate.requestRefresh(.timer)
  hatchModeCompletions[1](snapshot)
  let clipAfterRefresh = hatchModeDelegate.activityLayers[.claude]
  let stripesAfterRefresh = clipAfterRefresh?.sublayers?.first
  try require(clipRecreated != nil && clipAfterRefresh != nil
                && ObjectIdentifier(clipRecreated!) == ObjectIdentifier(clipAfterRefresh!)
                && stripesAfterRefresh?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-layer-survives-refresh",
              "a full refresh cycle on an unchanged presentation reset the running drain animation")
  // Low-fill fallback: above the threshold the layer tracks the fill in the derived tone,
  // below it the whole body is hatched in the flat empty tone
  func hatchModeSnapshot(remaining: Double) -> Snapshot {
    let usage = ClaudeUsage(measuredAt: now, live: true,
                            fiveHour: UsageWindow(pct: 100 - remaining, resetsAt: now + 4_000),
                            weekly: UsageWindow(pct: 100 - remaining, resetsAt: nil), fable: nil)
    return Snapshot(now: now, usage: usage, block: nil, models: nil, codex: nil,
                    update: (nil, false))
  }
  hatchModeDelegate.requestRefresh(.manual)
  hatchModeCompletions[2](hatchModeSnapshot(remaining: 20))
  let clipRedBand = hatchModeDelegate.activityLayers[.claude]
  try require(clipRedBand?.frame.width == (MODERN_BODY_WIDTH - 4) * 20 / 100
                && clipRedBand?.name?.contains("\(activityHatchRGB(20, dark: false))") == true,
              "drain-hatch", "derived-hatch-red-band-modern",
              "a red-band battery fell back to the flat empty tone instead of a derived hatch")
  hatchModeDelegate.requestRefresh(.manual)
  hatchModeCompletions[3](hatchModeSnapshot(remaining: 0))
  let clipEmpty = hatchModeDelegate.activityLayers[.claude]
  try require(clipEmpty?.frame.width == MODERN_BODY_WIDTH - 4
                && clipEmpty?.name?.contains("\(emptyHatchRGB(dark: false))") == true,
              "drain-hatch", "low-fill-fallback-modern",
              "an empty battery did not hatch the whole body in the empty tone")
  // Below the threshold the signature is value-independent, so the reuse path is what a draining
  // provider actually takes — the label has to be refreshed in place there, without the layer
  // teardown that a widened signature would cause (that would reset the drift to t=0).
  func hatchLabelProbe() -> (width: CGFloat, pixels: Int)? {
    // CFTypeID rather than `as?` — a conditional downcast to a CF type always succeeds, so a
    // non-image `contents` would crash the probe instead of failing the assertion below
    guard let label = hatchModeDelegate.activityTextLayers[.claude],
          let contents = label.contents,
          CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
    return (label.frame.width, (contents as! CGImage).width)
  }
  hatchModeDelegate.requestRefresh(.manual)
  hatchModeCompletions[4](hatchModeSnapshot(remaining: 15))
  let labelFifteen = hatchModeDelegate.activityTextLayers[.claude]
  let probeFifteen = hatchLabelProbe()
  hatchModeDelegate.requestRefresh(.manual)
  hatchModeCompletions[5](hatchModeSnapshot(remaining: 5))
  let clipDraining = hatchModeDelegate.activityLayers[.claude]
  let probeFive = hatchLabelProbe()
  try require(probeFifteen != nil && probeFive != nil
                && probeFifteen! != probeFive!
                && labelFifteen != nil
                && ObjectIdentifier(labelFifteen!) == ObjectIdentifier(hatchModeDelegate.activityTextLayers[.claude]!)
                && clipEmpty != nil && clipDraining != nil
                && ObjectIdentifier(clipEmpty!) == ObjectIdentifier(clipDraining!)
                && clipDraining?.sublayers?.first?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-text-refreshed-on-reuse",
              "a provider draining below the threshold kept the stale percentage over the new image")
  // The case a draining session is actually in: the fill shrinks every refresh while the band — and
  // so the stripe color — holds. That must resize in place; rebuilding would restart the drift at
  // t=0 every REFRESH_SECONDS, exactly while the animation is on screen. Note this feeds two
  // *different* snapshots; modern-layer-survives-refresh feeds the same one twice and cannot see it.
  hatchModeDelegate.requestRefresh(.manual)
  hatchModeCompletions[6](hatchModeSnapshot(remaining: 75))
  let clipSeventyFive = hatchModeDelegate.activityLayers[.claude]
  hatchModeDelegate.requestRefresh(.manual)
  hatchModeCompletions[7](hatchModeSnapshot(remaining: 71))
  let clipSeventyOne = hatchModeDelegate.activityLayers[.claude]
  let stripesResized = clipSeventyOne?.sublayers?.first
  try require(clipSeventyFive != nil && clipSeventyOne != nil
                && ObjectIdentifier(clipSeventyFive!) == ObjectIdentifier(clipSeventyOne!)
                && clipSeventyOne?.frame.width == (MODERN_BODY_WIDTH - 4) * 71 / 100
                && stripesResized?.frame.width == (clipSeventyOne?.frame.width ?? 0) + HATCH_PITCH_PT
                && stripesResized?.position.x == 0   // left anchor keeps the drift's from/to valid
                && stripesResized?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-layer-resized-in-place",
              "a changed fill rebuilt the hatch layer instead of resizing it, resetting the drift")
  // Nothing else pins the signed vertical origin: the headless harness has no button, so
  // buttonHeight == imageHeight there and the -1 of a real 22pt menu bar button never appears
  try require(hatchOriginY(buttonHeight: 22, imageHeight: MODERN_IMAGE_HEIGHT) == -1
                && hatchOriginY(buttonHeight: MODERN_IMAGE_HEIGHT, imageHeight: MODERN_IMAGE_HEIGHT) == 0,
              "drain-hatch", "signed-origin-y",
              "a button shorter than the image did not push the hatch origin negative")
  hatchModeFlag.value = true
  // reduceMotionEnabled only updates off a notification post (see applyReduceMotionPreference) —
  // flipping the reader alone wouldn't move it, matching the "reduce-motion" group's own pattern.
  hatchModeCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  hatchModeDelegate.apiActiveProviders = [.claude, .codex]
  hatchModeDelegate.updateActivityAnimation()
  try require(hatchModeDelegate.activityLayers.isEmpty && hatchModeDelegate.activityTextLayers.isEmpty,
              "drain-hatch", "modern-reduce-motion",
              "hatch layers were created while Reduce Motion was on")

  print("self-test-core: drain-hatch PASS")

  // GUI clients launch `codex` with a private CODEX_HOME, so the live rollout jsonl is appended
  // there while ~/.codex/sessions stays untouched — the monitor has to watch both.
  try require(codexSessionsRoot(codexHome: "/tmp/orca/home") == "/tmp/orca/home/sessions"
                && codexSessionsRoot(codexHome: "/tmp/orca/home/") == "/tmp/orca/home/sessions",
              "activity-roots", "sessions-subtree",
              "a CODEX_HOME did not resolve to its sessions subtree")
  try require(activityWatchRoots(default: "/a", discovered: []) == ["/a"]
                && activityWatchRoots(default: "/a", discovered: ["/b"]) == ["/a", "/b"],
              "activity-roots", "discovered-appended",
              "a discovered root was dropped from the watch list")
  try require(activityWatchRoots(default: "/a", discovered: ["/b", "/a", "/b", ""]) == ["/a", "/b"],
              "activity-roots", "deduped",
              "duplicate or empty roots survived the merge")
  // Only a forward mtime is a write. A root appearing or vanishing swaps which file wins without
  // anything being appended, and that must not animate the widget.
  try require(activityAdvanced(previous: 100, current: 101)
                && activityAdvanced(previous: nil, current: 100)
                && !activityAdvanced(previous: 100, current: 100)
                && !activityAdvanced(previous: 100, current: 99)
                && !activityAdvanced(previous: 100, current: nil)
                && !activityAdvanced(previous: nil, current: nil),
              "activity-roots", "forward-mtime-only",
              "a fingerprint that did not move forward in time was reported as a write")
  // Exercises proc_listallpids + proc_name + sysctl on the real machine (~1-2ms); the roots it
  // returns depend on what is running, so only their shape can be asserted.
  let discoveredNow = discoverCodexSessionRoots()
  try require(discoveredNow.keys.allSatisfy { $0 == .codex }
                && discoveredNow.values.joined().allSatisfy { $0.hasSuffix("/sessions") },
              "activity-roots", "discovery-smoke",
              "discovery returned a non-codex provider or a root outside a sessions subtree")

  print("self-test-core: activity-roots PASS")

  print("self-test-core: PASS")
}

if CommandLine.arguments.contains("--self-test-core") {
  do {
    try runCoreSelfTest()
    exit(0)
  } catch let failure as CoreSelfTestFailure {
    FileHandle.standardError.write(
      Data("self-test-core: FAIL: \(failure.group)/\(failure.check): \(failure.detail)\n".utf8))
    exit(1)
  } catch {
    FileHandle.standardError.write(Data("self-test-core: FAIL: internal/unexpected: \(error)\n".utf8))
    exit(1)
  }
}
// ── --render-glint <path>: saves an intermediate glint frame as PNG (for render verification) ──
if let idx = CommandLine.arguments.firstIndex(of: "--render-glint"), CommandLine.arguments.count > idx + 1 {
  let items = [BattItem(label: "C5", provider: .claude, remain: 100), BattItem(label: "CW", provider: .claude, remain: 100),
               BattItem(label: "X5", provider: .codex, remain: 100)]
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

// Discovery runs on the monitor's utility queue while the scenario mutates it from the main
// thread, so the fake result needs a lock of its own.
private final class ActivityTestDiscovery {
  private let lock = NSLock()
  private var roots: [Provider: [String]]
  init(_ roots: [Provider: [String]] = [:]) { self.roots = roots }
  var value: [Provider: [String]] {
    get { lock.lock(); defer { lock.unlock() }; return roots }
    set { lock.lock(); roots = newValue; lock.unlock() }
  }
}

// ── --test-activity-monitor: verifies file append → active → idle without touching user sessions ──
if CommandLine.arguments.contains("--test-activity-monitor") {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("ccb-activity-\(UUID().uuidString)", isDirectory: true)
  func makeRoot(_ name: String) throws -> URL {
    let url = base.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func seedSession(_ root: URL) throws -> URL {
    let file = root.appendingPathComponent("session.jsonl")
    try Data("{}\n".utf8).write(to: file)
    return file
  }
  func appendSession(_ file: URL) {
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data("{\"delta\":1}\n".utf8))
    try? handle.close()
  }
  // Runs a monitor over temp roots, performs `work` mid-flight, and returns the events it emitted.
  func observe(_ name: String, roots: [Provider: String], discovery: ActivityTestDiscovery,
               seconds: TimeInterval, work: @escaping () -> Void) -> [String] {
    var events: [String] = []
    let monitor = ProviderActivityMonitor(roots: roots, discovery: { discovery.value }) {
      provider, active in
      events.append("\(provider == .claude ? "claude" : "codex"):\(active ? "active" : "idle")")
    }
    monitor.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    monitor.stop()
    print("activity-monitor: \(name) events \(events)")
    return events
  }
  var failures: [String] = []
  func check(_ name: String, _ passed: Bool) {
    print("activity-monitor: \(name) \(passed ? "PASS" : "FAIL")")
    if !passed { failures.append(name) }
  }

  // 1. The default root: an append there still drives active → idle, and Claude stays quiet.
  let claudeRoot = try makeRoot("claude")
  let codexRoot = try makeRoot("codex")
  let defaultSession = try seedSession(codexRoot)
  let defaultEvents = observe("default-root",
                              roots: [.claude: claudeRoot.path, .codex: codexRoot.path],
                              discovery: ActivityTestDiscovery(), seconds: 7.5) {
    appendSession(defaultSession)
  }
  check("default-root", defaultEvents.contains("codex:active")
          && defaultEvents.contains("codex:idle") && !defaultEvents.contains("claude:active"))

  // 2. The regression: the session lives only under a discovered root (a GUI client's CODEX_HOME),
  //    and the default root never changes.
  let emptyCodexRoot = try makeRoot("codex-empty")
  let orcaRoot = try makeRoot("orca/sessions")
  let orcaSession = try seedSession(orcaRoot)
  let orcaEvents = observe("discovered-root",
                           roots: [.claude: claudeRoot.path, .codex: emptyCodexRoot.path],
                           discovery: ActivityTestDiscovery([.codex: [orcaRoot.path]]),
                           seconds: 3.5) { appendSession(orcaSession) }
  check("discovered-root",
        orcaEvents.contains("codex:active") && !orcaEvents.contains("claude:active"))

  // 3. A codex process started after the monitor did: discovery has to re-run, not just run once.
  let lateCodexRoot = try makeRoot("codex-late-default")
  let lateRoot = try makeRoot("late/sessions")
  let lateDiscovery = ActivityTestDiscovery()
  let lateEvents = observe("late-discovery",
                           roots: [.claude: claudeRoot.path, .codex: lateCodexRoot.path],
                           discovery: lateDiscovery, seconds: 7.5) {
    _ = try? seedSession(lateRoot)
    lateDiscovery.value = [.codex: [lateRoot.path]]
  }
  check("late-discovery", lateEvents.contains("codex:active"))

  // 4. Discovery repeating the default root must not crash or double-report. A smoke test: scanning
  //    one root twice yields the same maximum, so it cannot fail on dedup alone — activity-roots
  //    /deduped is what pins the merge.
  let dupRoot = try makeRoot("codex-dup")
  let dupSession = try seedSession(dupRoot)
  let dupEvents = observe("duplicate-discovery",
                          roots: [.claude: claudeRoot.path, .codex: dupRoot.path],
                          discovery: ActivityTestDiscovery([.codex: [dupRoot.path]]),
                          seconds: 3.5) { appendSession(dupSession) }
  check("duplicate-discovery", dupEvents.filter { $0 == "codex:active" }.count == 1)

  // 5. A discovered root going away (Orca quits) is not a write: the newest jsonl falls back to an
  //    older one in the default root, and the widget must stay still.
  let vanishCodexRoot = try makeRoot("codex-vanish-default")
  let vanishRoot = try makeRoot("vanish/sessions")
  let staleSession = try seedSession(vanishCodexRoot)
  try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                        ofItemAtPath: staleSession.path)
  _ = try seedSession(vanishRoot)
  let vanishDiscovery = ActivityTestDiscovery([.codex: [vanishRoot.path]])
  let vanishEvents = observe("vanishing-root",
                             roots: [.claude: claudeRoot.path, .codex: vanishCodexRoot.path],
                             discovery: vanishDiscovery, seconds: 7.5) {
    vanishDiscovery.value = [:]
  }
  check("vanishing-root", vanishEvents.isEmpty)

  try? FileManager.default.removeItem(at: base)
  print(failures.isEmpty ? "activity-monitor: PASS"
          : "activity-monitor: FAIL (\(failures.joined(separator: ", ")))")
  exit(failures.isEmpty ? 0 : 1)
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
