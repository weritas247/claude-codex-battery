# 배터리 채움 색 개인화 + 설정창 불일치 수정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바 배터리의 초록 채움 색을 사용자가 녹색 계열 안에서 고를 수 있게 하고, 설정창이 앱의 실제 동작과 어긋나는 4건을 바로잡는다.

**Architecture:** 색은 `UserDefaults`에 `"#RRGGBB"` 문자열로 저장하고, 이미 존재하는 DI seam인 `PresentationConfiguration`을 통해 렌더러로 주입한다. 색을 실제로 고르는 단일 지점은 `heatRemain`이며, green 밴드일 때만 사용자 색으로 교체한다. 앰버·빨강과 100% 골드는 손대지 않는다. 설정 UI는 Display 탭에 프리셋 스와치 행 하나를 추가하고, 세밀 조정은 색조가 녹색으로 제한된 시트에서 한다.

**Tech Stack:** Swift 5 / AppKit (Cocoa) / `swiftc -O` 단일 모듈 빌드 (Xcode 프로젝트 없음)

## Global Constraints

- **배포 타깃 macOS 12.0** (`app/build.sh:9`). macOS 13.0+ API는 `if #available(macOS 13.0, *)` 가드 없이 쓰지 않는다. `NSColorWell.colorWellStyle`은 13.0+ 이므로 **쓰지 않는다**.
- **`NSColorPanel` / `NSColorWell` 을 쓰지 않는다.** 녹색 제한을 걸 수 없어 "고른 색과 그려진 색이 다른" 문제가 생긴다.
- 새 `.swift` 파일은 `app/` 에 두면 `build.sh`가 자동 포함한다. `import` 불필요. 링크된 프레임워크는 `Cocoa`, `QuartzCore`, `ServiceManagement` 뿐이다.
- **사용자 색 미설정 시 모든 색이 현행과 바이트 단위로 동일해야 한다.** 기존 self-test(특히 `activityHatchRGB(75, dark: true) == (9, 47, 18)`)가 수정 없이 통과해야 한다.
- 모든 UI 문자열은 `tr()` / `trf()` 를 거치고, `TR` 딕셔너리(`app/Localization.swift`)에 **6개 언어**(`ko`/`ja`/`zh-Hans`/`zh-Hant`/`es`, 영어는 키 자체)를 모두 채운다.
- 설정 변경은 **즉시 적용**(`rerender()`). OK/Cancel 없음.
- 소스 스타일: 한 줄에 여러 statement를 `;` 로 잇는 압축 스타일(`app/main.swift` 설정 UI 영역). 주석은 영어.
- 빌드: `cd app && ./build.sh` — 테스트: `cd app && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core` (성공 시 마지막 줄 `self-test-core: PASS`, exit 0)
- 커밋은 태스크마다. 커밋 메시지 말미에 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

## File Structure

| 파일 | 역할 | 변경 |
|---|---|---|
| `app/Util.swift` | hex → RGB 바이트 파싱, 드롭다운 게이지 색 | 수정 |
| `app/BatteryRenderer.swift` | 저장 getter, `heatRemain` 색 결정, 두 모드 렌더 | 수정 |
| `app/AppPolicy.swift` | `PresentationConfiguration` DI seam | 수정 |
| `app/MenuBuilder.swift` | 드롭다운 게이지 행 | 수정 |
| `app/main.swift` | 해치 레이어, 설정창 UI·핸들러, self-test | 수정 |
| `app/Localization.swift` | `TR` 번역 딕셔너리 | 수정 |

새 파일은 만들지 않는다. 색 결정 로직이 `heatRemain` 한 곳에 모여 있어 분리할 이유가 없다.

---

## Task 1: hex 파싱과 저장 getter

**Files:**
- Modify: `app/Util.swift:91` (`hexColor` 바로 뒤)
- Modify: `app/BatteryRenderer.swift:183` (`isMetricVisible` 바로 뒤)
- Test: `app/main.swift:2056` (`print("self-test-core: procargs PASS")` 바로 뒤)

**Interfaces:**
- Produces: `rgbFromHex(_ s: String) -> (r: UInt8, g: UInt8, b: UInt8)?`,
  `validatedBatteryGreen(_ raw: String?) -> String?`,
  `currentBatteryGreen() -> String?`, `let BATTERY_GREEN_KEY = "batteryGreen"`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`app/main.swift`의 `print("self-test-core: procargs PASS")` 줄 **바로 아래**, `print("self-test-core: PASS")` **위**에 삽입:

```swift
  let parsedGreen = rgbFromHex("#198532")
  let parsedWhite = rgbFromHex("#FFFFFF")
  let parsedBlack = rgbFromHex("#000000")
  try require(parsedGreen?.r == 25 && parsedGreen?.g == 133 && parsedGreen?.b == 50
                && parsedWhite?.r == 255 && parsedWhite?.g == 255 && parsedWhite?.b == 255
                && parsedBlack?.r == 0 && parsedBlack?.g == 0 && parsedBlack?.b == 0,
              "battery-color", "hex-parse", "rgbFromHex mis-parsed a valid color")
  try require(rgbFromHex("198532") == nil && rgbFromHex("#1985") == nil
                && rgbFromHex("#GGGGGG") == nil && rgbFromHex("") == nil
                && rgbFromHex("#1985327") == nil,
              "battery-color", "hex-reject", "rgbFromHex accepted a malformed value")
  try require(validatedBatteryGreen("#00A878") == "#00A878"
                && validatedBatteryGreen("not-a-color") == nil
                && validatedBatteryGreen(nil) == nil,
              "battery-color", "validate", "a malformed saved color was not rejected")
  print("self-test-core: battery-color PASS")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh`
Expected: FAIL — `error: cannot find 'rgbFromHex' in scope` (그리고 `validatedBatteryGreen`도 동일)

- [ ] **Step 3: 최소 구현을 쓴다**

`app/Util.swift` — `hexColor` 함수 끝(`}`) 바로 뒤에 추가:

```swift
// Hex → raw RGB bytes. Deliberately not routed through hexColor(): that builds an sRGB NSColor
// while the battery renderer works in calibrated RGB, and round-tripping the two shifts the color.
func rgbFromHex(_ s: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
  var h = s
  guard h.hasPrefix("#") else { return nil }
  h.removeFirst()
  guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
  return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
}
```

`app/BatteryRenderer.swift` — `isMetricVisible` 함수 끝(`}`) 바로 뒤에 추가:

```swift
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
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: `self-test-core: battery-color PASS` 가 출력되고 마지막 줄이 `self-test-core: PASS`, exit 0

- [ ] **Step 5: 커밋**

```bash
git add app/Util.swift app/BatteryRenderer.swift app/main.swift
git commit -m "feat(color): parse and validate a user-picked battery green

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 사용자 색을 렌더러로 주입

**Files:**
- Modify: `app/AppPolicy.swift:78-99` (`PresentationConfiguration`)
- Modify: `app/BatteryRenderer.swift:231-238` (`heatRemain`), `:267-273` (`activityHatchRGB`), `:376-408` (`drawCapsule`), `:429-475` (`renderBatteryImage`), `:479-518` (`renderModernSummaryImage`)
- Modify: `app/main.swift:471` (해치 색), `:740-743` (모던 렌더 호출)
- Test: `app/main.swift` — Task 1이 만든 `battery-color` 그룹에 이어 붙임

**Interfaces:**
- Consumes: `rgbFromHex`, `currentBatteryGreen` (Task 1)
- Produces: `PresentationConfiguration.batteryGreen: () -> String?`,
  `heatRemain(_:dark:custom:)` (private),
  `activityHatchRGB(_ remain: Double?, dark: Bool, custom: String? = nil) -> (UInt8, UInt8, UInt8)`,
  `renderModernSummaryImage(dark:summaries:assetContext:configuration:) -> NSImage?`

**중요:** `batteryGreen`은 **`var` + 기본값**으로 선언한다. Swift의 memberwise init이 기본값 있는 `var`를 선택 파라미터로 넣어주므로, 기존 생성 지점 8곳(`app/AppPolicy.swift:87`, `app/main.swift:1082`·`1112`·`1148`·`1152`·`1164`·`1175`·`1548`·`1774`)이 **수정 없이 컴파일**된다. 테스트 fake들이 자동으로 "커스텀 없음"이 되어 회귀 보호가 공짜로 따라온다. (`let` 으로 선언하면 memberwise init에서 아예 빠져 컴파일이 깨진다.)

- [ ] **Step 1: 실패하는 테스트를 쓴다**

Task 1이 추가한 `print("self-test-core: battery-color PASS")` **바로 위**에 삽입:

```swift
  // Green band takes the custom color; amber and red keep the system warning colors.
  let customHatchGreen = activityHatchRGB(75, dark: true, custom: "#00A878")
  let customHatchAmber = activityHatchRGB(35, dark: true, custom: "#00A878")
  let customHatchRed = activityHatchRGB(15, dark: true, custom: "#00A878")
  try require(customHatchGreen == (0, 59, 42),
              "battery-color", "custom-green-band", "the custom green did not reach the green band")
  try require(customHatchAmber == (89, 75, 4) && customHatchRed == (89, 24, 20),
              "battery-color", "warning-bands-untouched",
              "a custom green leaked into the amber or red band")
  try require(activityHatchRGB(75, dark: true) == (9, 47, 18)
                && activityHatchRGB(75, dark: false) == (15, 62, 25),
              "battery-color", "default-unchanged",
              "the built-in green changed when no custom color is set")
  // Wiring check: the same summaries must render differently once a custom green is injected,
  // and identically when only the warning bands are on screen.
  let greenSummaries = [ProviderSummary(provider: .claude, remain: 75, active: false)]
  let redSummaries = [ProviderSummary(provider: .claude, remain: 15, active: false)]
  let plainConfig = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "modern" }, catStyle: { .none },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" })
  let customConfig = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "modern" }, catStyle: { .none },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" }, batteryGreen: { "#00A878" })
  func modernBytes(_ summaries: [ProviderSummary], _ configuration: PresentationConfiguration) -> Data? {
    guard let image = renderModernSummaryImage(dark: true, summaries: summaries,
                                               assetContext: conversionAssets,
                                               configuration: configuration),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data else { return nil }
    return data as Data
  }
  try require(modernBytes(greenSummaries, plainConfig) != nil
                && modernBytes(greenSummaries, plainConfig) != modernBytes(greenSummaries, customConfig),
              "battery-color", "modern-wiring",
              "renderModernSummaryImage ignored the injected custom green")
  try require(modernBytes(redSummaries, plainConfig) == modernBytes(redSummaries, customConfig),
              "battery-color", "modern-red-identical",
              "a custom green changed the red band in the modern renderer")
  // Pixel mode writes exact bytes into its canvas, so the fill color can be scanned for directly.
  func pixelImageContains(_ image: NSImage?, _ rgb: (UInt8, UInt8, UInt8)) -> Bool {
    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let data = cg.dataProvider?.data else { return false }
    let length = CFDataGetLength(data)
    guard let ptr = CFDataGetBytePtr(data) else { return false }
    var offset = 0
    while offset + 3 < length {
      if ptr[offset] == rgb.0, ptr[offset + 1] == rgb.1, ptr[offset + 2] == rgb.2 { return true }
      offset += 4
    }
    return false
  }
  let pixelPlain = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "pixel" }, catStyle: { .none },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" })
  let pixelCustom = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "pixel" }, catStyle: { .none },
    batterySize: { "big" }, goldTestEnabled: { false }, forcedCatState: { nil },
    language: { "en" }, batteryGreen: { "#00A878" })
  let pixelItems = battItems(snapshot, configuration: pixelPlain)
  let pixelPlainImage = renderBatteryImage(dark: true, items: pixelItems, configuration: pixelPlain)
  let pixelCustomImage = renderBatteryImage(dark: true, items: pixelItems, configuration: pixelCustom)
  try require(pixelImageContains(pixelPlainImage, (25, 133, 50))
                && !pixelImageContains(pixelPlainImage, (0, 168, 120)),
              "battery-color", "pixel-default-fill", "the default pixel fill is no longer the built-in green")
  try require(pixelImageContains(pixelCustomImage, (0, 168, 120))
                && !pixelImageContains(pixelCustomImage, (25, 133, 50)),
              "battery-color", "pixel-custom-fill", "the custom green did not reach the pixel capsule")
```

> `snapshot` 과 `conversionAssets` 는 `conversion-bands-risk` 그룹이 같은 함수 스코프에 이미 만들어 둔 값이다(`app/main.swift:1082` 부근). 이름이 다르면 그 그룹에서 쓰는 이름을 그대로 따른다.

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh`
Expected: FAIL — `error: extra argument 'custom' in call` (`activityHatchRGB`), `error: extra argument 'batteryGreen' in call`, `error: extra argument 'configuration' in call`

- [ ] **Step 3: 최소 구현을 쓴다**

**(a) `app/AppPolicy.swift`** — `language` 필드 뒤에 추가하고 `production`을 잇는다:

```swift
struct PresentationConfiguration {
  let isMetricVisible: (String) -> Bool
  let displayMode: () -> String
  let catStyle: () -> CatStyle
  let batterySize: () -> String
  let goldTestEnabled: () -> Bool
  let forcedCatState: () -> CatState?
  let language: () -> String
  // var with a default so the memberwise init keeps it optional: every existing construction
  // site compiles untouched and defaults to "no custom color", which is what the colour
  // regression checks need. A `let` here would drop it from the memberwise init entirely.
  var batteryGreen: () -> String? = { nil }

  static let production = PresentationConfiguration(
    isMetricVisible: { productionMetricVisibility($0) },
    displayMode: { currentDisplayMode() },
    catStyle: { currentCatStyle() },
    batterySize: { currentBattSize() },
    goldTestEnabled: { ProcessInfo.processInfo.environment["CCB_GOLD_TEST"] != nil },
    forcedCatState: {
      guard let raw = ProcessInfo.processInfo.environment["CCB_CAT_TEST"] else { return nil }
      return CatState(rawValue: raw)
    },
    language: { UI_LANG },
    batteryGreen: { currentBatteryGreen() }
  )
}
```

**(b) `app/BatteryRenderer.swift:231-238`** — `heatRemain` 교체:

```swift
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
```

**(c) `app/BatteryRenderer.swift:267-273`** — `activityHatchRGB` 에 `custom` 전달:

```swift
func activityHatchRGB(_ remain: Double?, dark: Bool, custom: String? = nil) -> (UInt8, UInt8, UInt8) {
  let base = heatRemain(remainingBand(normalizedRemaining(remain ?? 0)), dark: dark, custom: custom)
  let scale = 0.35
  return (UInt8((Double(base.r) * scale).rounded()),
          UInt8((Double(base.g) * scale).rounded()),
          UInt8((Double(base.b) * scale).rounded()))
}
```

**(d) `app/BatteryRenderer.swift:376-408`** — `drawCapsule` 시그니처 끝에 파라미터를 더하고 채움 색에 전달:

```swift
private func drawCapsule(_ cv: Canvas, _ p: Preset, _ x: Int, _ midY: Int,
                         _ remain: Double?, _ ink: RGB, _ dark: Bool, _ glintX: Int?,
                         _ customGreen: String?) {
```

같은 함수 안 `:392` 한 줄만 바꾼다:

```swift
      cv.rect(x + 2, by + 2, fw, p.bh - 4, heatRemain(band, dark: dark, custom: customGreen))
```

**(e) `app/BatteryRenderer.swift:432` 부근** — `renderBatteryImage` 안, `let p = ...` 다음 줄에 추가:

```swift
  let customGreen = configuration.batteryGreen()
```

그리고 `:464` 의 호출을 바꾼다:

```swift
    drawCapsule(cv, p, x, midY, item.remain, ink, dark, glintX, customGreen)
```

**(f) `app/BatteryRenderer.swift:479-480`** — `renderModernSummaryImage` 에 기본값 있는 파라미터 추가:

```swift
func renderModernSummaryImage(dark: Bool, summaries: [ProviderSummary],
                              assetContext: ProviderAssetContext = .production(),
                              configuration: PresentationConfiguration = .production) -> NSImage? {
```

`image.lockFocus()` 다음 줄(`let ink = ...` 위)에 추가:

```swift
  let customGreen = configuration.batteryGreen()
```

`:501` 한 줄을 바꾼다:

```swift
    let c = heatRemain(band, dark: dark, custom: customGreen)
```

**(g) `app/main.swift:741`** — 모던 렌더 호출에 configuration 전달:

```swift
      ? renderModernSummaryImage(dark: dark, summaries: summaries, assetContext: assets,
                                 configuration: presentationConfiguration)
```

**(h) `app/main.swift:471`** — 해치 색이 사용자 색을 따르게 한다:

```swift
      let colorRGB = wide ? activityHatchRGB(summary.remain, dark: dark,
                                             custom: presentationConfiguration.batteryGreen())
                          : emptyHatchRGB(dark: dark)
```

> `rebuildKey`(`app/main.swift:477`)가 `colorRGB` 문자열로 만들어지므로 색이 바뀌면 레이어가 자동으로 재생성된다. 추가 작업 없음.

- [ ] **Step 4: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: `self-test-core: drain-hatch PASS` (기존 테스트가 수정 없이 통과) 와 `self-test-core: battery-color PASS` 가 모두 출력, 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 5: 커밋**

```bash
git add app/AppPolicy.swift app/BatteryRenderer.swift app/main.swift
git commit -m "feat(color): let a custom green replace the healthy band fill

Warning bands and the 100% gold are untouched; the drain hatch follows
automatically because it derives from the same fill color.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 드롭다운 게이지 색 동기화

**Files:**
- Modify: `app/Util.swift:76-82` (`usageColor`)
- Modify: `app/MenuBuilder.swift:34-50` (`gaugeRow`), `:58` (`buildMenu`), 호출부 `:83`·`:93`·`:98`·`:160`·`:164`
- Modify: `app/main.swift:752-753` (`buildMenu` 호출)
- Test: `app/main.swift` — `battery-color` 그룹에 이어 붙임

**Interfaces:**
- Consumes: `rgbFromHex` (Task 1), `PresentationConfiguration.batteryGreen` (Task 2)
- Produces: `usageColor(forRemaining:custom:) -> UsageColor`, `buildMenu(..., batteryGreen: String?)`

드롭다운 초록(`#348A45`)은 메뉴바 초록과 지금도 값이 다르다. 사용자 색을 메뉴바에만 적용하면 새 불일치를 만드는 셈이므로 같이 따르게 한다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`print("self-test-core: battery-color PASS")` **바로 위**에 삽입:

```swift
  try require(usageColor(forRemaining: 75).hex == "#348A45"
                && usageColor(forRemaining: 35).hex == "#FFB340"
                && usageColor(forRemaining: 15).hex == "#FF6961",
              "battery-color", "gauge-default", "the default dropdown gauge colors changed")
  try require(usageColor(forRemaining: 75, custom: "#00A878").hex == "#00A878"
                && usageColor(forRemaining: 35, custom: "#00A878").hex == "#FFB340"
                && usageColor(forRemaining: 15, custom: "#00A878").hex == "#FF6961",
              "battery-color", "gauge-custom",
              "the dropdown gauge ignored the custom green or leaked it into a warning band")
  try require(usageColor(forRemaining: 75, custom: "bogus").hex == "#348A45",
              "battery-color", "gauge-malformed", "a malformed custom color was not ignored")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh`
Expected: FAIL — `error: extra argument 'custom' in call`

- [ ] **Step 3: 최소 구현을 쓴다**

**(a) `app/Util.swift:75-82`** 교체:

```swift
// Single source of truth for both the menu-bar capsule and dropdown gauge.
func usageColor(forRemaining remaining: Double, custom: String? = nil) -> UsageColor {
  switch remainingBand(remaining) {
  case .red: return UsageColor(r: 255, g: 105, b: 97)
  case .amber: return UsageColor(r: 255, g: 179, b: 64)
  case .green:
    if let custom, let rgb = rgbFromHex(custom) { return UsageColor(r: rgb.r, g: rgb.g, b: rgb.b) }
    return UsageColor(r: 52, g: 138, b: 69)
  }
}
```

**(b) `app/MenuBuilder.swift:34-35`** — `gaugeRow` 에 파라미터 추가:

```swift
private func gaugeRow(_ menu: NSMenu, _ label: String, remaining: Double, resetText: String?,
                      usageURL: String, usageTitle: String, target: AppDelegate, language: String,
                      batteryGreen: String?) {
```

같은 함수 `:45` 를 바꾼다:

```swift
  let item = row(menu, text, mono: true, color: usageColor(forRemaining: value, custom: batteryGreen).hex,
```

**(c) `app/MenuBuilder.swift:58`** — `buildMenu` 시그니처 마지막에 기본값 있는 파라미터를 더한다:

```swift
func buildMenu(_ snap: Snapshot, swiftBarDup: Bool, target: AppDelegate,
```
로 시작하는 파라미터 목록 끝에 `, batteryGreen: String? = nil` 을 추가한다.

**(d)** `gaugeRow` 호출 5곳(`app/MenuBuilder.swift:83`, `:93`, `:98`, `:160`, `:164`)의 인자 목록 끝에 각각 `, batteryGreen: batteryGreen` 을 추가한다.

**(e) `app/main.swift:752-753`** — `buildMenu` 호출에 전달:

```swift
    let menu = buildMenu(snapshot, swiftBarDup: swiftBarDuplicate, target: self,
                         assets: assets, language: language,
                         batteryGreen: presentationConfiguration.batteryGreen())
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: `self-test-core: menu-actions-copy PASS` 와 `self-test-core: battery-color PASS` 모두 출력, 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 5: 커밋**

```bash
git add app/Util.swift app/MenuBuilder.swift app/main.swift
git commit -m "feat(color): follow the custom green in the dropdown gauges

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 설정 Display 탭에 프리셋 스와치 행

**Files:**
- Modify: `app/BatteryRenderer.swift` (Task 1이 추가한 `currentBatteryGreen` 뒤) — 프리셋 목록
- Modify: `app/main.swift:915-921` (로컬 헬퍼), `:932-936` (그리드), `:961-965` (핸들러), `:261` 부근 (저장 프로퍼티)
- Modify: `app/Localization.swift`
- Test: `app/main.swift` — `battery-color` 그룹에 이어 붙임

**Interfaces:**
- Consumes: `BATTERY_GREEN_KEY`, `validatedBatteryGreen` (Task 1)
- Produces: `let BATTERY_GREEN_PRESETS: [String]`, `@objc func settingsBatteryColorChanged(_ sender: NSButton)`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`print("self-test-core: battery-color PASS")` **바로 위**에 삽입:

```swift
  try require(BATTERY_GREEN_PRESETS.count == 5
                && BATTERY_GREEN_PRESETS.allSatisfy { rgbFromHex($0) != nil },
              "battery-color", "presets-parse", "a preset swatch is not a valid hex color")
  // Every preset must sit inside the green hue window the custom sheet also enforces.
  try require(BATTERY_GREEN_PRESETS.allSatisfy { hex in
                guard let rgb = rgbFromHex(hex) else { return false }
                let hue = NSColor(calibratedRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                                  blue: CGFloat(rgb.b) / 255, alpha: 1).hueComponent
                return hue >= BATTERY_GREEN_HUE_MIN && hue <= BATTERY_GREEN_HUE_MAX
              },
              "battery-color", "presets-in-gamut", "a preset swatch falls outside the green hue range")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh`
Expected: FAIL — `error: cannot find 'BATTERY_GREEN_PRESETS' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

**(a) `app/BatteryRenderer.swift`** — Task 1이 추가한 `currentBatteryGreen()` 뒤에 붙인다:

```swift
// Green hue window (NSColor hue is 0…1). The settings UI cannot produce anything outside it.
let BATTERY_GREEN_HUE_MIN: CGFloat = 85.0 / 360.0
let BATTERY_GREEN_HUE_MAX: CGFloat = 170.0 / 360.0

// Preset swatches, all inside the hue window above. The row also carries a "default" chip
// ahead of these, which clears the key and restores the built-in dark/light pair.
let BATTERY_GREEN_PRESETS = ["#0F5132", "#198532", "#34C759", "#00A878", "#6FBF4A"]
```

**(b) `app/main.swift`** — `var settingsWindow: NSWindow?`(`:261` 부근) 옆에 저장 프로퍼티를 더한다:

```swift
  var settingsColorSwatches: [NSButton] = []
```

**(c) `app/main.swift:921`** — `actionButton` 헬퍼 **바로 뒤**에 스와치 헬퍼를 더한다:

```swift
    func colorSwatch(_ hex: String?) -> NSButton {
      let b = NSButton(title: "", target: self, action: #selector(settingsBatteryColorChanged(_:)))
      b.isBordered = false; b.wantsLayer = true; b.setButtonType(.momentaryChange)
      b.identifier = NSUserInterfaceItemIdentifier(hex ?? "default")
      b.toolTip = hex ?? tr("Default — follows light and dark")
      b.translatesAutoresizingMaskIntoConstraints = false
      b.widthAnchor.constraint(equalToConstant: 22).isActive = true
      b.heightAnchor.constraint(equalToConstant: 22).isActive = true
      b.layer?.cornerRadius = 5
      b.layer?.backgroundColor = (hex.flatMap(hexColor) ?? NSColor(calibratedRed: 42 / 255.0, green: 176 / 255.0, blue: 70 / 255.0, alpha: 1)).cgColor
      return b
    }
    func colorRow() -> NSStackView {
      let saved = currentBatteryGreen()
      settingsColorSwatches = ([nil] + BATTERY_GREEN_PRESETS.map { Optional($0) }).map { colorSwatch($0) }
      let stack = NSStackView(views: settingsColorSwatches)
      stack.orientation = .horizontal; stack.spacing = 6
      let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
      divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
      stack.addArrangedSubview(divider)
      stack.addArrangedSubview(actionButton(tr("Custom…"), #selector(showBatteryColorSheet)))
      highlightColorSwatches(saved)
      return stack
    }
```

**(d) `app/main.swift:932-936`** — `appearance` 그리드에 행을 하나 더한다. 배열의 마지막 행(`Cat`) 뒤에 추가:

```swift
      [NSTextField(labelWithString: tr("Battery color")), colorRow()],
```

**(e) `app/main.swift:961-965` 부근** — 핸들러와 선택 표시 헬퍼를 더한다:

```swift
  func highlightColorSwatches(_ selected: String?) {
    for b in settingsColorSwatches {
      let id = b.identifier?.rawValue
      let isOn = (selected == nil && id == "default") || (selected != nil && id == selected)
      b.layer?.borderWidth = isOn ? 2.5 : 0
      b.layer?.borderColor = isOn ? NSColor.controlAccentColor.cgColor : nil
    }
  }
  @objc func settingsBatteryColorChanged(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    if id == "default" { UserDefaults.standard.removeObject(forKey: BATTERY_GREEN_KEY) }
    else { UserDefaults.standard.set(id, forKey: BATTERY_GREEN_KEY) }
    highlightColorSwatches(currentBatteryGreen()); rerender()
  }
```

**(f) `app/Localization.swift`** — `TR` 딕셔너리에 추가:

```swift
  "Battery color": ["ko": "배터리 색상", "ja": "バッテリーの色", "zh-Hans": "电池颜色", "zh-Hant": "電池顏色", "es": "Color de la batería"],
  "Custom…": ["ko": "사용자 지정…", "ja": "カスタム…", "zh-Hans": "自定…", "zh-Hant": "自訂…", "es": "Personalizado…"],
  "Default — follows light and dark": [
    "ko": "기본 — 다크/라이트에 맞춰 자동", "ja": "デフォルト — ライト/ダークに追従",
    "zh-Hans": "默认 — 跟随浅色/深色", "zh-Hant": "預設 — 跟隨淺色/深色",
    "es": "Predeterminado — sigue claro y oscuro",
  ],
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: `self-test-core: battery-color PASS`, 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 5: 육안 확인**

Run: `pkill -f ClaudeCodexBattery; cd app && open ClaudeCodexBattery.app`
그다음 메뉴바 아이콘 → Settings → Display 탭. `Battery color` 행에 스와치 6개(기본 + 프리셋 5)와 `Custom…` 버튼이 보이고, 스와치를 누르면 **메뉴바 배터리 색이 즉시 바뀌고** 선택 링이 옮겨가야 한다. `기본`을 누르면 원래 색으로 돌아가야 한다.

- [ ] **Step 6: 커밋**

```bash
git add app/BatteryRenderer.swift app/main.swift app/Localization.swift
git commit -m "feat(settings): add a battery color swatch row to the Display tab

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 사용자 지정 시트 (슬라이더 3개 + 미리보기)

**Files:**
- Modify: `app/BatteryRenderer.swift` (Task 4가 추가한 상수 뒤) — HSB 변환 헬퍼
- Modify: `app/main.swift` (`:261` 부근 프로퍼티, 핸들러 영역)
- Modify: `app/Localization.swift`
- Test: `app/main.swift` — `battery-color` 그룹에 이어 붙임

**Interfaces:**
- Consumes: `rgbFromHex` (Task 1), `BATTERY_GREEN_HUE_MIN/MAX` (Task 4), `highlightColorSwatches` (Task 4)
- Produces: `hexFromHSB(hue:saturation:brightness:) -> String`, `hsbFromHex(_:) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)?`, `@objc func showBatteryColorSheet()`

색조만 묶으면 채도·밝기를 열어도 녹색을 벗어나지 않는다. 채도를 고정하지 않는 이유: 프리셋 5색의 채도가 서로 달라, 고정하면 시트를 열었을 때 현재 색을 표현하지 못하고 슬라이더를 건드리지 않아도 색이 튄다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`print("self-test-core: battery-color PASS")` **바로 위**에 삽입:

```swift
  // HSB round-trip must land back on the same hex for every preset.
  try require(BATTERY_GREEN_PRESETS.allSatisfy { hex in
                guard let hsb = hsbFromHex(hex) else { return false }
                return hexFromHSB(hue: hsb.hue, saturation: hsb.saturation,
                                  brightness: hsb.brightness) == hex
              },
              "battery-color", "hsb-roundtrip", "an HSB round-trip changed a preset color")
  // Anything the sheet can produce stays inside the green window.
  try require([BATTERY_GREEN_HUE_MIN, (BATTERY_GREEN_HUE_MIN + BATTERY_GREEN_HUE_MAX) / 2, BATTERY_GREEN_HUE_MAX]
                .allSatisfy { hue in
                  guard let rgb = rgbFromHex(hexFromHSB(hue: hue, saturation: 1.0, brightness: 0.95)) else { return false }
                  return rgb.g > rgb.r && rgb.g > rgb.b
                },
              "battery-color", "sheet-gamut", "the hue window let through a non-green color")
  try require(hsbFromHex("nope") == nil,
              "battery-color", "hsb-reject", "hsbFromHex accepted a malformed color")
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh`
Expected: FAIL — `error: cannot find 'hsbFromHex' in scope`

- [ ] **Step 3: 최소 구현을 쓴다**

**(a) `app/BatteryRenderer.swift`** — Task 4의 `BATTERY_GREEN_PRESETS` 뒤에 붙인다:

```swift
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
```

**(b) `app/main.swift`** — `settingsColorSwatches` 옆에 프로퍼티를 더한다:

```swift
  var colorSheet: NSWindow?
  var colorSheetPreview: NSView?
  var colorSheetSliders: (hue: NSSlider, saturation: NSSlider, brightness: NSSlider)?
```

핸들러 영역(`settingsBatteryColorChanged` 뒤)에 추가:

```swift
  @objc func showBatteryColorSheet() {
    guard let parent = settingsWindow else { return }
    let start = hsbFromHex(currentBatteryGreen() ?? "#198532") ?? (hue: 0.35, saturation: 0.8, brightness: 0.55)
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                         styleMask: [.titled], backing: .buffered, defer: false)
    sheet.title = tr("Battery color")
    func slider(_ min: Double, _ max: Double, _ value: Double) -> NSSlider {
      let s = NSSlider(value: value, minValue: min, maxValue: max, target: self,
                       action: #selector(colorSheetSliderChanged))
      s.translatesAutoresizingMaskIntoConstraints = false
      s.widthAnchor.constraint(equalToConstant: 240).isActive = true
      return s
    }
    let hue = slider(Double(BATTERY_GREEN_HUE_MIN), Double(BATTERY_GREEN_HUE_MAX), Double(start.hue))
    let sat = slider(0.35, 1.0, Double(max(0.35, min(1.0, start.saturation))))
    let bri = slider(0.25, 0.95, Double(max(0.25, min(0.95, start.brightness))))
    colorSheetSliders = (hue, sat, bri)
    let preview = NSView(); preview.wantsLayer = true; preview.translatesAutoresizingMaskIntoConstraints = false
    preview.layer?.cornerRadius = 6
    preview.widthAnchor.constraint(equalToConstant: 90).isActive = true
    preview.heightAnchor.constraint(equalToConstant: 34).isActive = true
    colorSheetPreview = preview
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: tr("Hue")), hue],
      [NSTextField(labelWithString: tr("Saturation")), sat],
      [NSTextField(labelWithString: tr("Brightness")), bri],
      [NSTextField(labelWithString: tr("Preview")), preview],
    ])
    grid.rowSpacing = 14; grid.columnSpacing = 18; grid.translatesAutoresizingMaskIntoConstraints = false
    let done = NSButton(title: tr("Done"), target: self, action: #selector(closeBatteryColorSheet))
    done.keyEquivalent = "\r"; done.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView(); content.addSubview(grid); content.addSubview(done); sheet.contentView = content
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
      done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
    ])
    colorSheet = sheet
    colorSheetSliderChanged() // seed the preview and persist the starting color
    parent.beginSheet(sheet, completionHandler: nil)
  }

  @objc func colorSheetSliderChanged() {
    guard let s = colorSheetSliders else { return }
    let hex = hexFromHSB(hue: CGFloat(s.hue.doubleValue), saturation: CGFloat(s.saturation.doubleValue),
                         brightness: CGFloat(s.brightness.doubleValue))
    colorSheetPreview?.layer?.backgroundColor = hexColor(hex)?.cgColor
    UserDefaults.standard.set(hex, forKey: BATTERY_GREEN_KEY)
    highlightColorSwatches(currentBatteryGreen()); rerender()
  }

  @objc func closeBatteryColorSheet() {
    guard let sheet = colorSheet else { return }
    settingsWindow?.endSheet(sheet); colorSheet = nil
    colorSheetSliders = nil; colorSheetPreview = nil
  }
```

**(c) `app/Localization.swift`** — `TR` 에 추가:

```swift
  "Hue": ["ko": "색조", "ja": "色相", "zh-Hans": "色相", "zh-Hant": "色相", "es": "Tono"],
  "Saturation": ["ko": "채도", "ja": "彩度", "zh-Hans": "饱和度", "zh-Hant": "飽和度", "es": "Saturación"],
  "Brightness": ["ko": "밝기", "ja": "明るさ", "zh-Hans": "亮度", "zh-Hant": "亮度", "es": "Brillo"],
  "Preview": ["ko": "미리보기", "ja": "プレビュー", "zh-Hans": "预览", "zh-Hant": "預覽", "es": "Vista previa"],
  "Done": ["ko": "완료", "ja": "完了", "zh-Hans": "完成", "zh-Hant": "完成", "es": "Listo"],
```

- [ ] **Step 4: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: `self-test-core: battery-color PASS`, 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 5: 육안 확인**

Run: `pkill -f ClaudeCodexBattery; cd app && open ClaudeCodexBattery.app`
Settings → Display → `Custom…`. 슬라이더 3개를 끝에서 끝까지 움직여도 **미리보기와 메뉴바가 항상 녹색 계열**이어야 하고, 슬라이더를 놓을 때마다 메뉴바가 즉시 따라와야 한다. `Done`으로 닫으면 스와치 행의 선택 링이 프리셋에서 벗어나 있어야 한다(사용자 지정 색이므로).

- [ ] **Step 6: 커밋**

```bash
git add app/BatteryRenderer.swift app/main.swift app/Localization.swift
git commit -m "feat(settings): add a green-only custom color sheet

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 모던 모드에서 무효한 설정을 비활성화

**Files:**
- Modify: `app/main.swift:261` 부근 (프로퍼티), `:932-936` (그리드), `:961` (`settingsDisplayChanged`)
- Modify: `app/Localization.swift`

**Interfaces:**
- Produces: `func applyPixelOnlyAvailability()`

기본 표시 모드는 `modern`인데(`currentDisplayMode()`, `app/BatteryRenderer.swift:174-176`) 모던 렌더러는 `batterySize`·`catStyle`에 도달하지 않고, 고양이는 `app/main.swift:548`에서 `displayMode() != "modern"` 가드로 막혀 있다. 두 컨트롤을 골라도 아무 일이 일어나지 않는다. 렌더러는 건드리지 않고 UI만 정직하게 만든다.

- [ ] **Step 1: 프로퍼티와 헬퍼를 추가한다**

`app/main.swift` — `settingsColorSwatches` 옆에:

```swift
  var settingsSizePopup: NSPopUpButton?
  var settingsCatPopup: NSPopUpButton?
  var settingsPixelOnlyNote: NSTextField?
```

핸들러 영역에:

```swift
  // Modern mode never reads batterySize or catStyle, so the two controls would silently do nothing.
  func applyPixelOnlyAvailability() {
    let pixel = currentDisplayMode() == "pixel"
    settingsSizePopup?.isEnabled = pixel
    settingsCatPopup?.isEnabled = pixel
    settingsPixelOnlyNote?.isHidden = pixel
  }
```

- [ ] **Step 2: 그리드가 컨트롤 참조를 남기게 한다**

`app/main.swift:932-936` — 팝업을 인라인으로 만들지 말고 먼저 변수에 담는다. `let appearance = NSGridView(views: [` **위**에:

```swift
    let sizePopup = popup([tr("Big"), tr("Small")], selected: currentBattSize() == "big" ? 0 : 1, action: #selector(settingsSizeChanged(_:)))
    let catPopup = popup([tr("Off"), tr("Wide face"), tr("Slim face"), tr("Slime")], selected: [CatStyle.none, .nyan, .slim, .slime].firstIndex(of: currentCatStyle()) ?? 0, action: #selector(settingsCatChanged(_:)))
    settingsSizePopup = sizePopup; settingsCatPopup = catPopup
```

그리드 배열의 `Battery size` / `Cat` 행을 각각 `sizePopup` / `catPopup` 을 쓰도록 바꾼다:

```swift
      [NSTextField(labelWithString: tr("Battery size")), sizePopup],
      [NSTextField(labelWithString: tr("Cat")), catPopup],
```

그리드를 스택에 넣은 줄(`display.addArrangedSubview(appearance)`) **바로 뒤**에:

```swift
    let pixelNote = NSTextField(wrappingLabelWithString: tr("Battery size and Cat apply to pixel batteries only."))
    pixelNote.textColor = .secondaryLabelColor; pixelNote.font = .systemFont(ofSize: 12); pixelNote.maximumNumberOfLines = 2
    settingsPixelOnlyNote = pixelNote; display.addArrangedSubview(pixelNote)
    applyPixelOnlyAvailability()
```

- [ ] **Step 3: 표시 모드를 바꾸면 즉시 반영되게 한다**

`app/main.swift:961` 을 바꾼다:

```swift
  @objc func settingsDisplayChanged(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.indexOfSelectedItem == 0 ? "modern" : "pixel", forKey: DISPLAY_MODE_KEY); applyPixelOnlyAvailability(); rerender() }
```

- [ ] **Step 4: 번역을 추가한다**

`app/Localization.swift` — `TR` 에:

```swift
  "Battery size and Cat apply to pixel batteries only.": [
    "ko": "배터리 크기와 고양이는 픽셀 배터리에서만 적용됩니다.",
    "ja": "バッテリーサイズと猫はピクセルバッテリーのみに適用されます。",
    "zh-Hans": "电池大小和猫仅适用于像素电池。",
    "zh-Hant": "電池大小與貓僅適用於像素電池。",
    "es": "El tamaño de la batería y el gato solo se aplican a las baterías pixel.",
  ],
```

- [ ] **Step 5: 빌드와 육안 확인**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: 마지막 줄 `self-test-core: PASS`, exit 0

Run: `pkill -f ClaudeCodexBattery; cd app && open ClaudeCodexBattery.app`
Settings → Display. 기본(Modern) 상태에서 `Battery size`·`Cat` 팝업이 **흐리게 비활성**이고 안내문이 보여야 한다. `Display style`을 `Pixel batteries`로 바꾸면 **즉시** 둘 다 활성화되고 안내문이 사라져야 한다. 다시 Modern으로 되돌리면 원상복귀.

- [ ] **Step 6: 커밋**

```bash
git add app/main.swift app/Localization.swift
git commit -m "fix(settings): disable the pixel-only controls in modern mode

Battery size and Cat never reach the modern renderer, so presenting them
as active made the app look broken.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 설정창 번역 채우기와 죽은 항목 제거

**Files:**
- Modify: `app/Localization.swift:147-152` (죽은 항목), `TR` 딕셔너리 전반
- Test: `app/main.swift` — `battery-color` 그룹에 이어 붙임

설정창 문자열 13개 중 12개가 `TR` 에 **키 자체가 없어** 전 언어에서 영어로 폴백된다(`tr()` 은 `TR[en]?[language] ?? en`, `app/Localization.swift:232-235`). 드롭다운은 100% 번역돼 있어 한 화면에 언어가 섞인다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`print("self-test-core: battery-color PASS")` **바로 위**에 삽입:

```swift
  // Every settings-window string must exist in all six languages — a missing key silently
  // falls back to English and produces a half-translated window.
  let settingsStrings = [
    "General", "Configure how Claude and Codex usage appears on this Mac.",
    "Display", "Appearance", "Choose the visual style and optional companion shown in the menu bar.",
    "Limits", "Integration", "Integrations",
    "Optional tools add cost breakdowns and provide quick access to the project.",
    "Updates", "The app checks for updates once a day. You can review the source and releases on GitHub.",
    "Menu bar items", "Claude 5h", "Claude week", "Claude Fable", "Codex 5h", "Codex week",
    "Battery color", "Custom…", "Settings",
  ]
  let missingTranslations = settingsStrings.flatMap { key in
    SUPPORTED_LANGS.filter { $0 != "en" && tr(key, language: $0) == key }.map { "\(key)/\($0)" }
  }
  try require(missingTranslations.isEmpty,
              "battery-color", "settings-i18n", "untranslated settings strings: \(missingTranslations.joined(separator: ", "))")
```

> 어떤 언어에서 번역문이 영어 원문과 우연히 같다면(예: 고유명사) 이 검사가 오탐한다. 그런 경우에만 해당 문자열을 `settingsStrings`에서 빼고, 뺀 이유를 주석으로 남긴다.

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: FAIL — `self-test-core: FAIL: battery-color/settings-i18n: untranslated settings strings: General/ko, General/ja, …`

- [ ] **Step 3: 번역을 채운다**

`app/Localization.swift` 의 `TR` 에 추가:

```swift
  "Settings": ["ko": "설정", "ja": "設定", "zh-Hans": "设置", "zh-Hant": "設定", "es": "Ajustes"],
  "General": ["ko": "일반", "ja": "一般", "zh-Hans": "通用", "zh-Hant": "一般", "es": "General "],
  "Configure how Claude and Codex usage appears on this Mac.": [
    "ko": "이 Mac에서 Claude와 Codex 사용량을 어떻게 표시할지 설정합니다.",
    "ja": "このMacでClaudeとCodexの使用量をどう表示するか設定します。",
    "zh-Hans": "配置 Claude 和 Codex 用量在这台 Mac 上的显示方式。",
    "zh-Hant": "設定 Claude 與 Codex 用量在這台 Mac 上的顯示方式。",
    "es": "Configura cómo se muestra el uso de Claude y Codex en este Mac.",
  ],
  "Display": ["ko": "표시", "ja": "表示", "zh-Hans": "显示", "zh-Hant": "顯示", "es": "Pantalla"],
  "Appearance": ["ko": "모양", "ja": "外観", "zh-Hans": "外观", "zh-Hant": "外觀", "es": "Apariencia"],
  "Choose the visual style and optional companion shown in the menu bar.": [
    "ko": "메뉴 막대에 표시할 시각 스타일과 동행 캐릭터를 고릅니다.",
    "ja": "メニューバーに表示するビジュアルスタイルと相棒を選びます。",
    "zh-Hans": "选择菜单栏中显示的视觉样式与可选伙伴。",
    "zh-Hant": "選擇選單列中顯示的視覺樣式與可選夥伴。",
    "es": "Elige el estilo visual y el acompañante que aparecen en la barra de menús.",
  ],
  "Limits": ["ko": "한도", "ja": "上限", "zh-Hans": "限额", "zh-Hant": "額度", "es": "Límites"],
  "Integration": ["ko": "연동", "ja": "連携", "zh-Hans": "集成", "zh-Hant": "整合", "es": "Integración"],
  "Integrations": ["ko": "연동", "ja": "連携", "zh-Hans": "集成", "zh-Hant": "整合", "es": "Integraciones"],
  "Optional tools add cost breakdowns and provide quick access to the project.": [
    "ko": "선택 도구를 붙이면 비용 내역을 볼 수 있고 프로젝트로 바로 이동할 수 있습니다.",
    "ja": "オプションのツールを使うとコスト内訳の表示とプロジェクトへの素早いアクセスができます。",
    "zh-Hans": "可选工具可显示费用明细，并快速访问项目。",
    "zh-Hant": "選用工具可顯示費用明細，並快速前往專案。",
    "es": "Las herramientas opcionales añaden desglose de costes y acceso rápido al proyecto.",
  ],
  "Updates": ["ko": "업데이트", "ja": "アップデート", "zh-Hans": "更新", "zh-Hant": "更新", "es": "Actualizaciones"],
  "The app checks for updates once a day. You can review the source and releases on GitHub.": [
    "ko": "앱은 하루에 한 번 업데이트를 확인합니다. 소스와 릴리즈는 GitHub에서 볼 수 있습니다.",
    "ja": "アプリは1日1回アップデートを確認します。ソースとリリースはGitHubで確認できます。",
    "zh-Hans": "应用每天检查一次更新。你可以在 GitHub 上查看源代码与发行版。",
    "zh-Hant": "應用程式每天檢查一次更新。你可以在 GitHub 上查看原始碼與發行版。",
    "es": "La app busca actualizaciones una vez al día. Puedes ver el código y las versiones en GitHub.",
  ],
```

`"General "` 의 스페인어에 붙은 뒤쪽 공백은 오타다 — `"General"` 로 고쳐 쓰되, 그러면 `es` 번역이 영어 원문과 같아져 Step 1의 검사가 오탐한다. `settingsStrings` 배열에서 `"General"` 을 빼고 다음 주석을 남긴다:

```swift
  // "General" is spelled the same in English and Spanish, so the missing-translation scan
  // can't distinguish a real translation from a fallback. Verified by hand instead.
```

- [ ] **Step 4: `ko` 만 있는 항목을 마저 채운다**

`app/Localization.swift:150-151` 을 교체:

```swift
  "Claude 5h": ["ko": "Claude 5시간", "ja": "Claude 5時間", "zh-Hans": "Claude 5 小时", "zh-Hant": "Claude 5 小時", "es": "Claude 5 h"],
  "Claude week": ["ko": "Claude 주간", "ja": "Claude 週間", "zh-Hans": "Claude 每周", "zh-Hant": "Claude 每週", "es": "Claude semanal"],
  "Claude Fable": ["ko": "Claude Fable", "ja": "Claude Fable", "zh-Hans": "Claude Fable", "zh-Hant": "Claude Fable", "es": "Claude Fable"],
  "Codex 5h": ["ko": "Codex 5시간", "ja": "Codex 5時間", "zh-Hans": "Codex 5 小时", "zh-Hant": "Codex 5 小時", "es": "Codex 5 h"],
  "Codex week": ["ko": "Codex 주간", "ja": "Codex 주간", "zh-Hans": "Codex 每周", "zh-Hant": "Codex 每週", "es": "Codex semanal"],
```

`"Claude Fable"` 은 전 언어가 동일한 고유명사다. Step 1의 `settingsStrings` 배열에서 빼고 이유를 주석으로 남긴다.
`"Codex week"` 의 `ja` 값은 오타다 — `"Codex 週間"` 으로 고친다.

- [ ] **Step 5: 죽은 번역 항목을 지운다**

`app/Localization.swift` 에서 아래 세 줄을 **삭제**한다. 어느 것도 코드에서 참조되지 않는다(설정창에 OK/Cancel 버튼이 없고, 말줄임표 버전과 옛 설명문은 현재 문구와 다르다).

```swift
  "Menu bar items…": [...],
  "Choose which limits appear in the menu bar. Detailed menu information stays available.": [...],
  "OK": ["ko": "확인"], "Cancel": ["ko": "취소"],
```

Run: `cd app && grep -rn "Menu bar items…\|\"OK\"\|\"Cancel\"\|Choose which limits appear" *.swift`
Expected: 출력 없음 (삭제 후 참조가 남아 있지 않음)

- [ ] **Step 6: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: `self-test-core: battery-color PASS`, 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 7: 커밋**

```bash
git add app/Localization.swift app/main.swift
git commit -m "fix(i18n): translate the settings window and drop dead entries

The tab titles, headings and notes were wrapped in tr() but absent from
the table, so every language fell back to English mid-window.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Limits 설명문을 실제 동작에 맞게 고쳐 쓴다

**Files:**
- Modify: `app/main.swift:939`
- Modify: `app/Localization.swift`
- Test: Task 7의 `settings-i18n` 검사에 새 문자열을 추가

현재 문구는 "메뉴바에 표시할 한도를 고르세요"인데, 모던 모드의 메뉴바는 프로바이더당 배터리 1개이고 **체크된 한도들의 최솟값**을 보여준다(`providerSummaries`, `app/main.swift:82-83`). 체크를 풀면 항목이 사라지는 게 아니라 숫자가 조용히 올라간다. 1:1 대응은 픽셀 모드에서만 성립한다(`battItems`, `app/main.swift:33-48`).

- [ ] **Step 1: 테스트에 새 문자열을 등록한다**

Task 7이 만든 `settingsStrings` 배열에 추가:

```swift
    "Modern batteries show the tightest of the selected limits; pixel batteries show one per limit. Claude Fable is off by default.",
```

- [ ] **Step 2: 실패를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: FAIL — `self-test-core: FAIL: battery-color/settings-i18n: untranslated settings strings: Modern batteries show…/ko, …`

- [ ] **Step 3: 문구를 바꾸고 번역을 추가한다**

`app/main.swift:939` 의 `note(limits, tr(...))` 인자를 교체:

```swift
    heading(limits, tr("Menu bar items")); note(limits, tr("Modern batteries show the tightest of the selected limits; pixel batteries show one per limit. Claude Fable is off by default.")); separator(limits)
```

`app/Localization.swift` 의 `TR` 에 추가:

```swift
  "Modern batteries show the tightest of the selected limits; pixel batteries show one per limit. Claude Fable is off by default.": [
    "ko": "일반 배터리는 선택한 한도 중 가장 빠듯한 값을 보여주고, 픽셀 배터리는 한도마다 하나씩 그립니다. Claude Fable은 기본으로 꺼져 있습니다.",
    "ja": "標準バッテリーは選択した上限のうち最も厳しい値を表示し、ピクセルバッテリーは上限ごとに1つ表示します。Claude Fableは既定でオフです。",
    "zh-Hans": "标准电池显示所选限额中最紧张的一项；像素电池为每个限额各显示一个。Claude Fable 默认关闭。",
    "zh-Hant": "標準電池顯示所選額度中最吃緊的一項；像素電池為每個額度各顯示一個。Claude Fable 預設關閉。",
    "es": "Las baterías modernas muestran el límite más ajustado de los seleccionados; las pixel muestran uno por límite. Claude Fable está desactivado por defecto.",
  ],
```

`note()` 는 `maximumNumberOfLines = 2` 다(`app/main.swift:920`). 새 문구가 2줄을 넘어 잘리면 그 호출의 값을 `3` 으로 올린다.

- [ ] **Step 4: 통과를 확인한다**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 5: 육안 확인**

Run: `pkill -f ClaudeCodexBattery; cd app && open ClaudeCodexBattery.app`
Settings → Limits. 설명문이 **잘리지 않고** 전부 보여야 한다.

- [ ] **Step 6: 커밋**

```bash
git add app/main.swift app/Localization.swift
git commit -m "fix(settings): describe what the Limits checkboxes actually do

Modern mode aggregates the selected limits into one battery per provider,
so 'select the limits shown' promised behavior that only pixel mode has.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: 언어를 바꾸면 설정창도 다시 그린다

**Files:**
- Modify: `app/main.swift:261` 부근 (프로퍼티), `:866-877` (`setLang`), `:893-959` (`showSettings` 분해)

`rerender()`(`app/main.swift:683-685`)는 메뉴와 상태 아이콘만 재생성한다. 설정창 라벨은 `showSettings()` 에서 한 번 만들어진 뒤 재구축되지 않아, 언어를 바꾼 직후 **사용자가 보고 있는 화면만** 이전 언어로 남는다.

- [ ] **Step 1: 탭 구축부를 분리한다**

`app/main.swift` — `settingsWindow` 옆에 프로퍼티를 더한다:

```swift
  var settingsTabView: NSTabView?
```

`showSettings()` 를 분해한다. `let tabs = NSTabView()`(`:900`)부터 Updates 페이지 구성이 끝나는 줄(`:956`)까지를 **그대로** 새 메서드로 옮긴다:

```swift
  private func buildSettingsTabs() -> NSTabView {
    let tabs = NSTabView(); tabs.tabViewType = .topTabsBezelBorder; tabs.translatesAutoresizingMaskIntoConstraints = false
    // …기존 page/popup/heading/separator/note/actionButton 중첩 헬퍼와 5개 페이지 구성을 그대로 옮긴다…
    return tabs
  }

  private func installSettingsContent(in window: NSWindow, selectedTab: Int) {
    let tabs = buildSettingsTabs()
    let content = NSView(); content.addSubview(tabs); window.contentView = content
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
    ])
    if selectedTab >= 0, selectedTab < tabs.numberOfTabViewItems { tabs.selectTabViewItem(at: selectedTab) }
    settingsTabView = tabs
  }
```

`showSettings()` 는 이렇게 남는다:

```swift
  @objc func showSettings() {
    if let window = settingsWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = tr("Settings")
    window.isReleasedWhenClosed = false
    window.delegate = self
    installSettingsContent(in: window, selectedTab: 0)
    settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
```

- [ ] **Step 2: 언어 변경 시 재구축하게 한다**

`app/main.swift` — 핸들러 영역에 추가:

```swift
  // rerender() only rebuilds the menu and the status image, so an open settings window would
  // keep the old language — the one surface the user is looking at when they change it.
  func rebuildSettingsWindowForLanguage() {
    guard let window = settingsWindow else { return }
    var index = 0
    if let tabs = settingsTabView, let selected = tabs.selectedTabViewItem {
      let found = tabs.indexOfTabViewItem(selected)
      if found != NSNotFound { index = found }
    }
    window.title = tr("Settings")
    installSettingsContent(in: window, selectedTab: index)
  }
```

`setLang`(`app/main.swift:875-876`)에서 `rerender()` **앞에** 호출을 넣는다:

```swift
    UI_LANG = resolveLang()
    rebuildSettingsWindowForLanguage()
    rerender()
```

`windowWillClose`(`app/main.swift:968`)에서 참조도 정리한다:

```swift
  func windowWillClose(_ notification: Notification) { settingsWindow = nil; settingsTabView = nil }
```

- [ ] **Step 3: 빌드와 테스트**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 4: 육안 확인**

Run: `pkill -f ClaudeCodexBattery; cd app && open ClaudeCodexBattery.app`
Settings → Display 탭을 선택 → General 탭으로 가서 언어를 `한국어`로 바꾼다. **창을 닫지 않은 채로** 탭 제목·헤딩·설명문이 즉시 한국어로 바뀌어야 하고, 언어를 바꾸기 전 선택했던 탭(General)이 그대로 선택돼 있어야 한다. Display 탭을 선택한 뒤 언어를 `English`로 되돌리면 Display 탭이 유지돼야 한다.

- [ ] **Step 5: 커밋**

```bash
git add app/main.swift
git commit -m "fix(settings): rebuild the settings window when the language changes

The window the user is looking at when they switch languages was the one
surface that kept the old strings.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: 최종 통합 확인

**Files:** 없음 (검증만)

- [ ] **Step 1: 전체 빌드와 테스트**

Run: `cd app && ./build.sh && ./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core`
Expected: 모든 그룹이 PASS — `conversion-bands-risk`, `menu-actions-copy`, `refresh-retention`, `reduce-motion`, `drain-hatch`, `activity-roots`, `procargs`, `battery-color`, 마지막 줄 `self-test-core: PASS`, exit 0

- [ ] **Step 2: 기본값 회귀 확인**

Run:
```bash
cd app
defaults delete com.dennykim.claude-codex-battery-app batteryGreen 2>/dev/null
./ClaudeCodexBattery.app/Contents/MacOS/ClaudeCodexBattery --self-test-core | tail -3
```
Expected: `self-test-core: PASS` — 사용자 색이 없을 때 기존 동작이 그대로임을 확인

- [ ] **Step 3: 실사용 확인**

Run: `pkill -f ClaudeCodexBattery; cd app && open ClaudeCodexBattery.app`

확인 항목:
1. 프리셋 스와치를 누르면 메뉴바 배터리와 **드롭다운 게이지 색이 함께** 바뀐다
2. Claude/Codex 세션이 활성일 때 **소모 빗금이 새 색을 따라간다** (색만 바뀌고 애니메이션이 끊기지 않는다)
3. 다크/라이트 모드를 전환해도 고른 색이 유지된다
4. `기본` 스와치로 되돌리면 다크/라이트에 따라 색이 다시 자동 분기한다
5. Display 탭에서 Modern일 때 Battery size·Cat이 비활성, Pixel일 때 활성
6. 언어를 바꾸면 설정창이 즉시 따라 바뀌고 탭 선택이 유지된다

- [ ] **Step 4: 커밋 (필요한 경우)**

3단계에서 문제를 고쳤다면 커밋한다. 없으면 이 태스크는 커밋 없이 끝난다.

---

## Self-Review

**1. 스펙 커버리지**

| 스펙 요구 | 태스크 |
|---|---|
| `UserDefaults "batteryGreen"` = `"#RRGGBB"`, 미설정 = 현행 | Task 1 |
| `CCB_BATTERY_GREEN` 환경변수 | Task 1 |
| 문법만 검증, hue 보정 안 함 | Task 1 |
| `rgbFromHex` 로 색공간 우회 | Task 1 |
| `PresentationConfiguration.batteryGreen` | Task 2 |
| `heatRemain` green 밴드만 교체 | Task 2 |
| 픽셀·모던 두 모드 적용 | Task 2 |
| 모던 렌더러 시그니처에 configuration | Task 2 |
| 빗금이 따라옴 + `rebuildKey` 무효화 | Task 2 |
| 100% 골드 대상 아님 | Task 2 (`drain-hatch` 기존 테스트 + 골드 경로 미변경) |
| 드롭다운 게이지 동기화 | Task 3 |
| 프리셋 5색 + "기본" 칸 | Task 4 |
| 사용자 지정 시트, 슬라이더 3개, 색조 85–170° | Task 5 |
| 즉시 적용, OK/Cancel 없음 | Task 4·5 (`rerender()`) |
| macOS 12 호환, `NSColorWell`/`NSColorPanel` 미사용 | Global Constraints, Task 5 |
| 모던에서 죽은 설정 비활성화 + 즉시 토글 | Task 6 |
| 번역 12개 × 6언어, ko-only 5개 보완, 죽은 항목 제거 | Task 7 |
| Limits 설명문 정정 + Fable 기본 꺼짐 안내 | Task 8 |
| 언어 변경 시 설정창 재구축 + 탭 유지 | Task 9 |
| 회귀: 미설정 시 바이트 동일 | Task 2 Step 1 (`default-unchanged`), Task 10 Step 2 |

빠진 스펙 요구 없음.

**2. 플레이스홀더 스캔**

`buildSettingsTabs()` 본문에 "기존 …을 그대로 옮긴다"는 이동 지시가 있다(Task 9 Step 1). 이는 새로 작성할 코드가 아니라 **기존 57줄을 위치만 바꾸는** 작업이라 원문을 다시 싣지 않았다. 옮길 범위(`app/main.swift:900`–`:956`)를 줄 번호로 못 박아 모호성을 없앴다. 그 외 TBD/TODO/"적절히 처리" 류 없음.

**3. 타입 일관성**

- `rgbFromHex` 반환 `(r: UInt8, g: UInt8, b: UInt8)?` — `BatteryRenderer.swift` 의 `private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)` 와 라벨까지 동일해 `heatRemain` 에서 그대로 반환 가능 (Task 2)
- `activityHatchRGB` 반환은 기존대로 라벨 없는 `(UInt8, UInt8, UInt8)` — 테스트의 `== (0, 59, 42)` 튜플 비교와 맞음
- `batteryGreen: () -> String?` 을 Task 2·3·4·5 가 모두 같은 이름·타입으로 참조
- `highlightColorSwatches(_:)` 는 Task 4가 정의하고 Task 5가 호출 — 시그니처 동일
- `BATTERY_GREEN_HUE_MIN/MAX` 는 Task 4가 정의하고 Task 4 테스트·Task 5가 사용
- `applyPixelOnlyAvailability()` 는 Task 6 안에서만 정의·호출

---

## 예상 검증 값 (참고)

테스트에 쓰인 상수의 근거. 채널마다 `(값 × 0.35).rounded()`.

| 입력 | 밴드 | 기준 색 | 해치 결과 |
|---|---|---|---|
| `activityHatchRGB(75, dark: true)` | green | `(25,133,50)` | `(9, 47, 18)` — 기존 테스트와 동일 |
| `activityHatchRGB(75, dark: false)` | green | `(42,176,70)` | `(15, 62, 25)` |
| `activityHatchRGB(75, dark: true, custom: "#00A878")` | green | `(0,168,120)` | `(0, 59, 42)` |
| `activityHatchRGB(35, dark: true, custom: "#00A878")` | amber | `(255,214,10)` | `(89, 75, 4)` |
| `activityHatchRGB(15, dark: true, custom: "#00A878")` | red | `(255,69,58)` | `(89, 24, 20)` |

값이 어긋나면 **테스트가 아니라 계산을 먼저 의심한다** — `rounded()` 는 0.5에서 반올림(away from zero)이다.
