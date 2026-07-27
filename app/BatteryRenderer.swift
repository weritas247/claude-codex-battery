// Menu bar battery icon renderer — ports the widget JS's pixel canvas, font, and geometry as-is
// (Builds CGImage directly instead of PNG encoding. Pixel placement matches the JS 1:1)
import Cocoa

enum Provider: Hashable, CaseIterable {
  case claude, codex
  var symbolName: String { self == .claude ? "sparkles" : "terminal" }
}

protocol ProviderAssetResolving {
  func installedApp(for provider: Provider) -> URL?
  func providerImage(for provider: Provider, installedApp: URL?) -> NSImage?
  func applicationImage(for provider: Provider, installedApp: URL?) -> NSImage?
}

struct ProductionProviderAssetResolver: ProviderAssetResolving {
  func installedApp(for provider: Provider) -> URL? {
    installedProviderApp(provider)
  }

  func providerImage(for provider: Provider, installedApp: URL?) -> NSImage? {
    if provider == .codex, let installedApp {
      let image = NSWorkspace.shared.icon(forFile: installedApp.path)
      image.size = NSSize(width: 16, height: 16)
      return image
    }
    return bundledProviderImage(provider)
  }

  func applicationImage(for provider: Provider, installedApp: URL?) -> NSImage? {
    if provider == .claude { return bundledProviderImage(provider) }
    guard let installedApp else { return nil }
    let image = NSWorkspace.shared.icon(forFile: installedApp.path)
    image.size = NSSize(width: 16, height: 16)
    return image
  }

  private func bundledProviderImage(_ provider: Provider) -> NSImage? {
    let name = provider == .claude ? "ClaudeProvider" : "CodexProvider"
    guard let path = Bundle.main.path(forResource: name, ofType: "svg"),
          let image = NSImage(contentsOfFile: path) else { return nil }
    image.size = NSSize(width: 16, height: 16)
    image.isTemplate = true
    return image
  }
}

struct ProviderAssetContext {
  let resolver: ProviderAssetResolving
  private let installedApps: [Provider: URL]

  init(resolver: ProviderAssetResolving) {
    self.resolver = resolver
    var installedApps: [Provider: URL] = [:]
    for provider in Provider.allCases {
      installedApps[provider] = resolver.installedApp(for: provider)
    }
    self.installedApps = installedApps
  }

  static func production() -> ProviderAssetContext {
    ProviderAssetContext(resolver: ProductionProviderAssetResolver())
  }

  func installedApp(for provider: Provider) -> URL? {
    installedApps[provider]
  }

  func providerImage(for provider: Provider) -> NSImage? {
    resolver.providerImage(for: provider, installedApp: installedApp(for: provider))
  }

  func applicationImage(for provider: Provider) -> NSImage? {
    resolver.applicationImage(for: provider, installedApp: installedApp(for: provider))
  }
}

struct BattItem {
  let label: String // internal period key: C5/CW/CF/X5/XW/X
  let provider: Provider
  let remain: Double? // remaining % (nil means an empty capsule)
}

struct ProviderSummary {
  let provider: Provider
  let remain: Double
}

private func drawProviderGlyph(_ provider: Provider, at point: NSPoint) {
  let providerColor = provider == .claude
    ? NSColor(calibratedRed: 0.88, green: 0.42, blue: 0.25, alpha: 1)
    : NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.78, alpha: 1)
  providerColor.setStroke(); providerColor.setFill()
  if provider == .claude {
    // Six-petal rosette: an original provider mark that remains legible at menu-bar size.
    for i in 0..<6 {
      let angle = CGFloat(i) * .pi / 3
      let cx = point.x + 7 + cos(angle) * 3.2
      let cy = point.y + 7 + sin(angle) * 3.2
      NSBezierPath(ovalIn: NSRect(x: cx - 2.2, y: cy - 2.2, width: 4.4, height: 4.4)).fill()
    }
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x + 5.2, y: point.y + 5.2, width: 3.6, height: 3.6)).fill()
  } else {
    // Four linked loops: a geometric Codex-style mark, distinct from a terminal icon.
    let p = NSBezierPath(); p.lineWidth = 1.8
    p.appendOval(in: NSRect(x: point.x + 1, y: point.y + 5, width: 8, height: 5))
    p.appendOval(in: NSRect(x: point.x + 5, y: point.y + 1, width: 5, height: 8))
    p.appendOval(in: NSRect(x: point.x + 5, y: point.y + 5, width: 8, height: 5))
    p.appendOval(in: NSRect(x: point.x + 1, y: point.y + 5, width: 5, height: 8))
    p.stroke()
  }
}

private func providerAsset(_ provider: Provider, context: ProviderAssetContext) -> NSImage? {
  context.providerImage(for: provider)
}

// 4x6 pixel font (big preset)
private let FONT46: [Character: [String]] = [
  "0": ["0110", "1001", "1001", "1001", "1001", "0110"],
  "1": ["0010", "0110", "0010", "0010", "0010", "0111"],
  "2": ["0110", "1001", "0010", "0100", "1000", "1111"],
  "3": ["1110", "0001", "0110", "0001", "1001", "0110"],
  "4": ["0010", "0110", "1010", "1111", "0010", "0010"],
  "5": ["1111", "1000", "1110", "0001", "1001", "0110"],
  "6": ["0110", "1000", "1110", "1001", "1001", "0110"],
  "7": ["1111", "0001", "0010", "0100", "0100", "0100"],
  "8": ["0110", "1001", "0110", "1001", "1001", "0110"],
  "9": ["0110", "1001", "1001", "0111", "0001", "0110"],
  "C": ["0110", "1001", "1000", "1000", "1001", "0110"],
  "X": ["1001", "1001", "0110", "0110", "1001", "1001"],
]
// 3x5 classic pixel font (small preset)
private let FONT35: [Character: [String]] = [
  "0": ["111", "101", "101", "101", "111"],
  "1": ["010", "110", "010", "010", "111"],
  "2": ["111", "001", "111", "100", "111"],
  "3": ["111", "001", "111", "001", "111"],
  "4": ["101", "101", "111", "001", "001"],
  "5": ["111", "100", "111", "001", "111"],
  "6": ["111", "100", "111", "101", "111"],
  "7": ["111", "001", "001", "001", "001"],
  "8": ["111", "101", "111", "101", "111"],
  "9": ["111", "101", "111", "001", "111"],
  "C": ["111", "100", "100", "100", "111"],
  "X": ["101", "101", "010", "101", "101"],
]

// Per-preset geometry (same values as the JS PRESET)
private struct Preset {
  let font: [Character: [String]]
  let adv: (Character) -> Int // letter spacing (in big, only '1' gets 4px kerning)
  let bw, bh, capw, gap, ggap, pad, lblgap, H, dy: Int
}

private let PRESET_BIG = Preset(font: FONT46, adv: { $0 == "1" ? 4 : 5 },
                                bw: 18, bh: 10, capw: 20, gap: 5, ggap: 10, pad: 2, lblgap: 3, H: 12, dy: 3)
private let PRESET_SMALL = Preset(font: FONT35, adv: { _ in 4 },
                                  bw: 14, bh: 9, capw: 16, gap: 3, ggap: 7, pad: 1, lblgap: 2, H: 9, dy: 2)

let SIZE_FILE = "\(STATE_DIR)/.batt-size"
let DISPLAY_MODE_KEY = "displayMode"
private let METRIC_VISIBILITY_DEFAULTS: [String: Bool] = [
  "claude5": true, "claudeWeek": true, "claudeFable": false,
  "codex5": true, "codexWeek": true,
]
func currentBattSize() -> String {
  let s = (try? String(contentsOfFile: SIZE_FILE, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return s == "small" ? "small" : "big"
}

func currentDisplayMode() -> String {
  UserDefaults.standard.string(forKey: DISPLAY_MODE_KEY) == "pixel" ? "pixel" : "modern"
}

func isMetricVisible(_ key: String) -> Bool {
  if UserDefaults.standard.object(forKey: "visible_\(key)") == nil {
    return METRIC_VISIBILITY_DEFAULTS[key] ?? true
  }
  return UserDefaults.standard.bool(forKey: "visible_\(key)")
}

let BATTERY_GREEN_KEY = "batteryGreen"

// Only the syntax is validated. The settings UI cannot produce a non-green, and silently
// correcting a hand-edited value would make the picked color differ from the drawn one.
func validatedBatteryGreen(_ raw: String?) -> String? {
  guard let raw, rgbFromHex(raw) != nil else { return nil }
  return raw
}

// User's green for the healthy band; nil = the built-in dark/light pair.
func currentBatteryGreen() -> String? {
  validatedBatteryGreen(ProcessInfo.processInfo.environment["CCB_BATTERY_GREEN"]
                          ?? UserDefaults.standard.string(forKey: BATTERY_GREEN_KEY))
}

// Green hue window (NSColor hue is 0…1). The settings UI cannot produce anything outside it.
let BATTERY_GREEN_HUE_MIN: CGFloat = 85.0 / 360.0
let BATTERY_GREEN_HUE_MAX: CGFloat = 170.0 / 360.0

// Preset swatches, all inside the hue window above. The row also carries a "default" chip
// ahead of these, which clears the key and restores the built-in dark/light pair.
let BATTERY_GREEN_PRESETS = ["#0F5132", "#198532", "#34C759", "#00A878", "#6FBF4A"]

// HSB <-> hex helpers for the custom color sheet. Hue is bounded by the caller
// (BATTERY_GREEN_HUE_MIN/MAX), so these two are otherwise unconstrained conversions.
func hexFromHSB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> String {
  let c = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
  return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}

func hsbFromHex(_ hex: String) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
  guard let rgb = rgbFromHex(hex) else { return nil }
  let c = NSColor(calibratedRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                  blue: CGFloat(rgb.b) / 255, alpha: 1)
  return (c.hueComponent, c.saturationComponent, c.brightnessComponent)
}

private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

// Logical pixel canvas (SCALE=2 — draws at 2x pixels for Retina)
private final class Canvas {
  static let SCALE = 2
  let wl: Int, hl: Int, w: Int, h: Int
  var buf: [UInt8]
  init(_ wl: Int, _ hl: Int) {
    self.wl = wl
    self.hl = hl
    w = wl * Canvas.SCALE
    h = hl * Canvas.SCALE
    buf = [UInt8](repeating: 0, count: w * h * 4)
  }

  func set(_ x: Int, _ y: Int, _ col: RGB) {
    if x < 0 || y < 0 || x >= wl || y >= hl { return }
    for dy in 0 ..< Canvas.SCALE {
      for dx in 0 ..< Canvas.SCALE {
        let px = ((y * Canvas.SCALE + dy) * w + (x * Canvas.SCALE + dx)) * 4
        buf[px] = col.r
        buf[px + 1] = col.g
        buf[px + 2] = col.b
        buf[px + 3] = 255
      }
    }
  }

  func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: RGB) {
    for j in 0 ..< rh { for i in 0 ..< rw { set(x + i, y + j, col) } }
  }

  // Rounded border leaving 1px open at the corners
  func stroke(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: RGB) {
    for i in 1 ..< max(1, rw - 1) {
      set(x + i, y, col)
      set(x + i, y + rh - 1, col)
    }
    for j in 1 ..< max(1, rh - 1) {
      set(x, y + j, col)
      set(x + rw - 1, y + j, col)
    }
  }
}

// Actual macOS battery indicator colors (Apple HIG system colors)
private func heatRemain(_ band: RemainingBand, dark: Bool, custom: String? = nil) -> RGB {
  switch band {
  case .red: return dark ? (255, 69, 58) : (255, 59, 48) // systemRed
  case .amber: return dark ? (255, 214, 10) : (255, 204, 0) // systemYellow
  case .green:
    // One picked color covers both appearances — the user chose it explicitly, so honor it as-is
    if let custom, let rgb = rgbFromHex(custom) { return rgb }
    // Dark menu bar draws the value in white, so the fill goes deeper for contrast; light keeps it bright
    return dark ? (25, 133, 50) : (42, 176, 70) // vivid green
  }
}

// Modern layout geometry — shared by the renderer and the activity layers so the two can't drift
let MODERN_ICON_WIDTH: CGFloat = 13
let MODERN_ICON_GAP: CGFloat = 5
let MODERN_BODY_WIDTH: CGFloat = 38
let MODERN_BODY_HEIGHT: CGFloat = 18
let MODERN_ITEM_GAP: CGFloat = 7
let MODERN_IMAGE_PAD: CGFloat = 2
let MODERN_IMAGE_HEIGHT: CGFloat = 24
let MODERN_ITEM_WIDTH = MODERN_ICON_WIDTH + MODERN_ICON_GAP + MODERN_BODY_WIDTH + 3

// Drain hatch — 45° stripes drifting right→left over the remaining fill ("this is being used up").
// Modern mode only; the pixel capsule interior is too small to carry stripes legibly.
let HATCH_PITCH_PT: CGFloat = 9
let HATCH_STRIPE_PT: CGFloat = 3
let HATCH_PERIOD: CFTimeInterval = 0.6

// Below this the fill is too narrow to carry the stripes — they run over the whole body instead.
// Points of the 34pt modern capsule interior.
let HATCH_MIN_FILL_PT: CGFloat = 6

// Signed on purpose: a 22pt menu bar button is shorter than the 24pt image, and clamping that -1
// to 0 would lift the stripes a point off the fill they sit inside
func hatchOriginY(buttonHeight: CGFloat, imageHeight: CGFloat) -> CGFloat {
  (buttonHeight - imageHeight) / 2
}

// Hatch color = the remaining color, darkened. Keeps the same contrast on green, amber and red.
func activityHatchRGB(_ remain: Double?, dark: Bool, custom: String? = nil) -> (UInt8, UInt8, UInt8) {
  let base = heatRemain(remainingBand(normalizedRemaining(remain ?? 0)), dark: dark, custom: custom)
  let scale = 0.35
  return (UInt8((Double(base.r) * scale).rounded()),
          UInt8((Double(base.g) * scale).rounded()),
          UInt8((Double(base.b) * scale).rounded()))
}

// Used when the fill is too small to carry the hatch — the stripes run over the empty body instead
func emptyHatchRGB(dark: Bool) -> (UInt8, UInt8, UInt8) { dark ? (95, 95, 95) : (190, 190, 190) }

// One period-aligned strip of 45° stripes: translating it left by exactly HATCH_PITCH_PT looks seamless
func hatchStripeImage(width: CGFloat, height: CGFloat, color: NSColor) -> CGImage? {
  let scale: CGFloat = 2
  let pw = Int((width * scale).rounded()), ph = Int((height * scale).rounded())
  guard pw > 0, ph > 0,
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  ctx.scaleBy(x: scale, y: scale)
  ctx.setFillColor(color.cgColor)
  var x = -height - HATCH_PITCH_PT
  while x < width + HATCH_PITCH_PT {
    ctx.move(to: CGPoint(x: x, y: 0))
    ctx.addLine(to: CGPoint(x: x + HATCH_STRIPE_PT, y: 0))
    ctx.addLine(to: CGPoint(x: x + HATCH_STRIPE_PT + height, y: height))
    ctx.addLine(to: CGPoint(x: x + height, y: height))
    ctx.closePath()
    ctx.fillPath()
    x += HATCH_PITCH_PT
  }
  return ctx.makeImage()
}

// The percentage drawn inside a modern capsule — shared so the activity layer can redraw it above
// the hatch with exactly the font and color the button image already used.
func modernValueAttributes(dark: Bool) -> [NSAttributedString.Key: Any] {
  let ink = dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.2, alpha: 1)
  return [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink]
}

// Just the "NN%" glyphs on transparency, plus the size the caller needs to center them and the
// size the raster actually covers — the pixel grid rounds up, and a layer sized to `size` instead
// of `rasterSize` squeezes the glyphs under the default `.resize` contents gravity.
func modernValueTextImage(_ value: Double, dark: Bool)
  -> (image: CGImage, size: CGSize, rasterSize: CGSize)? {
  let text = "\(Int(value.rounded()))%" as NSString
  let attrs = modernValueAttributes(dark: dark)
  let size = text.size(withAttributes: attrs)
  let scale: CGFloat = 2   // pairs with contentsScale on the layer that shows this image
  let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
  guard pw > 0, ph > 0,
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  ctx.scaleBy(x: scale, y: scale)
  let previous = NSGraphicsContext.current
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  text.draw(at: .zero, withAttributes: attrs)
  NSGraphicsContext.current = previous
  let rasterSize = CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
  return ctx.makeImage().map { ($0, size, rasterSize) }
}

func hatchNSColor(_ rgb: (UInt8, UInt8, UInt8), alpha: CGFloat) -> NSColor {
  NSColor(calibratedRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
          blue: CGFloat(rgb.2) / 255, alpha: alpha)
}

// 100% remaining = golden battery (a two-tone gold distinct from the warning yellow)
func isGolden(_ remain: Double?) -> Bool {
  guard let remain, remain.isFinite else { return false }
  return normalizedRemaining(remain) >= 99.5
}
private func goldBase(_ dark: Bool) -> RGB { dark ? (255, 184, 0) : (255, 170, 0) }
private func goldHi(_ dark: Bool) -> RGB { dark ? (255, 226, 110) : (255, 214, 90) }

// Full span of the glint sweep — the length needed for the diagonal to fully cross the capsule
func batteryGlintSpan(configuration: PresentationConfiguration = .production) -> Int {
  let p = configuration.batterySize() == "small" ? PRESET_SMALL : PRESET_BIG
  return p.bw + p.bh
}

// When altCol/boundaryX is set: if pixel x is left of the fill boundary, use altCol (contrast over the bright fill); if right, use col
@discardableResult
private func drawNum(_ cv: Canvas, _ p: Preset, _ x: Int, _ y: Int, _ str: String,
                     _ col: RGB, _ altCol: RGB? = nil, _ boundaryX: Int = 0) -> Int {
  var cx = x
  for ch in str {
    if let g = p.font[ch] {
      for (r, rowStr) in g.enumerated() {
        for (c, bit) in rowStr.enumerated() where bit == "1" {
          let px = cx + c
          if let alt = altCol, px < boundaryX { cv.set(px, y + r, alt) }
          else { cv.set(px, y + r, col) }
        }
      }
    }
    cx += p.adv(ch)
  }
  return cx
}

private func numW(_ p: Preset, _ s: String) -> Int { s.reduce(0) { $0 + p.adv($1) } - 1 }

// One capsule: border + remaining-fill + remaining number inside (100 included, always shown)
// 100% is two-tone gold; when glintX is set, a diagonal glint sweep passes over the gold capsule
private func drawCapsule(_ cv: Canvas, _ p: Preset, _ x: Int, _ midY: Int,
                         _ remain: Double?, _ ink: RGB, _ dark: Bool, _ glintX: Int?,
                         _ customGreen: String?) {
  let by = midY - p.bh / 2
  cv.stroke(x, by, p.bw, p.bh, ink)
  cv.rect(x + p.bw, by + 3, 2, p.bh - 6, ink) // terminal
  guard let remain = remain else { return }
  let value = normalizedRemaining(remain)
  let band = remainingBand(value)
  let innerW = p.bw - 4
  let fw = Int((value / 100 * Double(innerW)).rounded())
  let golden = isGolden(value)
  if fw > 0 {
    if golden {
      cv.rect(x + 2, by + 2, fw, p.bh - 4, goldBase(dark))
      cv.rect(x + 2, by + 2, fw, 2, goldHi(dark)) // top highlight
    } else {
      cv.rect(x + 2, by + 2, fw, p.bh - 4, heatRemain(band, dark: dark, custom: customGreen))
    }
  }
  if golden, let g = glintX {
    for j in 0 ..< (p.bh - 4) {
      let gx = x + 2 + g - j // diagonal (down-left)
      if gx >= x + 2, gx < x + 2 + fw {
        cv.set(gx, by + 2 + j, (255, 255, 240))
        if gx + 1 < x + 2 + fw { cv.set(gx + 1, by + 2 + j, (255, 240, 170)) }
      }
    }
  }
  let s = String(Int(value.rounded()))
  let tx = x + (p.bw - numW(p, s)) / 2
  // Pixels over the fill (bright system color) get a dark number, over the empty background get ink → contrast is guaranteed everywhere
  drawNum(cv, p, tx, midY - p.dy, s, ink, (30, 30, 30), x + 2 + fw)
}

// Draw one cat frame into the canvas (shares ink with the batteries; accents fixed)
private func drawCat(_ cv: Canvas, _ x: Int, _ y: Int, _ style: CatStyle, _ state: CatState, _ frame: Int, _ ink: RGB) {
  let grid = catFrame(style, state, frame)
  for (r, rowStr) in grid.enumerated() {
    for (c, ch) in rowStr.enumerated() {
      switch ch {
      case "A", "z": cv.set(x + c, y + r, ink)
      case "o": cv.set(x + c, y + r, (255, 150, 50))
      case "r": cv.set(x + c, y + r, (255, 70, 60))
      case "b": cv.set(x + c, y + r, (90, 180, 255))
      case "p": cv.set(x + c, y + r, (255, 150, 170)) // Nyan-style pink blush
      default: break
      }
    }
  }
}

// N capsules + group label (C/X) → NSImage (2x pixels; the caller scales down to the display size)
// With `cat`, a pixel cat runs at the left edge, facing its battery "finish line".
func renderBatteryImage(dark: Bool, items: [BattItem], glintX: Int? = nil,
                        cat: CatState? = nil, catFrameIndex: Int = 0,
                        configuration: PresentationConfiguration = .production) -> NSImage? {
  let p = configuration.batterySize() == "small" ? PRESET_SMALL : PRESET_BIG
  let customGreen = configuration.batteryGreen()
  let ink: RGB = dark ? (235, 235, 235) : (45, 45, 45)
  let catStyle = configuration.catStyle()
  let catSpan = (cat != nil && catStyle != .none) ? CAT_W + 3 : 0
  // Compute width (including group label)
  var W = p.pad * 2 + catSpan
  var pg: Character? = nil
  for item in items {
    let g = item.label.first!
    if g != pg {
      if pg != nil { W += p.ggap }
      W += numW(p, String(g)) + p.lblgap
      pg = g
    } else { W += p.gap }
    W += p.capw
  }
  let cv = Canvas(max(W, 8), p.H)
  let midY = p.H / 2
  var x = p.pad
  if let c = cat, catStyle != .none {
    drawCat(cv, x, max(0, (p.H - CAT_H) / 2), catStyle, c, catFrameIndex, ink)
    x += catSpan
  }
  pg = nil
  for item in items {
    let g = item.label.first!
    if g != pg {
      if pg != nil { x += p.ggap }
      drawNum(cv, p, x, midY - p.dy, String(g), ink) // group label C or X
      x += numW(p, String(g)) + p.lblgap
      pg = g
    } else { x += p.gap }
    drawCapsule(cv, p, x, midY, item.remain, ink, dark, glintX, customGreen)
    x += p.capw
  }
  guard let provider = CGDataProvider(data: Data(cv.buf) as CFData),
        let cg = CGImage(width: cv.w, height: cv.h, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: cv.w * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent)
  else { return nil }
  return NSImage(cgImage: cg, size: NSSize(width: cv.w, height: cv.h))
}


// Provider-first menu bar layout: one compact battery per provider, with detailed windows in the menu.
func renderModernSummaryImage(dark: Bool, summaries: [ProviderSummary],
                              assetContext: ProviderAssetContext = .production(),
                              configuration: PresentationConfiguration = .production) -> NSImage? {
  guard !summaries.isEmpty else { return nil }
  let iconWidth = MODERN_ICON_WIDTH, iconGap = MODERN_ICON_GAP
  let bodyW = MODERN_BODY_WIDTH, bodyH = MODERN_BODY_HEIGHT, itemGap = MODERN_ITEM_GAP
  let itemW = MODERN_ITEM_WIDTH
  let image = NSImage(size: NSSize(width: ceil(MODERN_IMAGE_PAD * 2 + CGFloat(summaries.count) * itemW
                                               + CGFloat(summaries.count - 1) * itemGap),
                                   height: MODERN_IMAGE_HEIGHT))
  image.lockFocus()
  let customGreen = configuration.batteryGreen()
  let ink = dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.2, alpha: 1)
  var x: CGFloat = MODERN_IMAGE_PAD
  for (index, summary) in summaries.enumerated() {
    let bodyX = x + iconWidth + iconGap
    let rect = NSRect(x: bodyX, y: 3, width: bodyW, height: bodyH)
    let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
    ink.setStroke(); outline.lineWidth = 1.0; outline.stroke()
    let terminal = NSBezierPath(roundedRect: NSRect(x: bodyX + bodyW, y: 8, width: 3, height: 8), xRadius: 1.5, yRadius: 1.5)
    ink.setFill(); terminal.fill()
    let value = normalizedRemaining(summary.remain)
    let band = remainingBand(value)
    let fill = NSRect(x: bodyX + 2, y: 5, width: max(0, (bodyW - 4) * value / 100), height: bodyH - 4)
    let c = heatRemain(band, dark: dark, custom: customGreen)
    NSColor(calibratedRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    if let icon = providerAsset(summary.provider, context: assetContext) {
      icon.draw(in: NSRect(x: x, y: 5, width: iconWidth, height: iconWidth), from: .zero, operation: .sourceOver, fraction: 1)
    } else {
      drawProviderGlyph(summary.provider, at: NSPoint(x: x, y: 5))
    }
    let valueText = "\(Int(value.rounded()))%"
    let attrs = modernValueAttributes(dark: dark)
    let size = (valueText as NSString).size(withAttributes: attrs)
    (valueText as NSString).draw(at: NSPoint(x: bodyX + (bodyW - size.width) / 2, y: 5), withAttributes: attrs)
    x += itemW
    if index < summaries.count - 1 { x += itemGap }
  }
  image.unlockFocus()
  return image
}
