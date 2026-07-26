# Drain Hatch Activity Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 세션 사용중 표시를 아이콘 주위 orbit 점에서 배터리 잔량 위를 흐르는 45° 소모 빗금으로 교체한다.

**Architecture:** 모던 모드는 이미지 재렌더 없이 `CALayer` 두 겹(클리핑 레이어 + 빗금 레이어)으로 처리하고, 픽셀 모드는 캔버스에 픽셀 빗금을 직접 찍은 뒤 고양이 프레임 타이머와 통합된 단일 10fps 틱으로 phase를 돌린다. 빗금 색은 잔량 색에서 파생(RGB ×0.35)해 초록/앰버/빨강 어디서든 대비가 일정하다.

**Tech Stack:** Swift 5 / AppKit / QuartzCore, 빌드는 `swiftc` 단일 호출(`app/build.sh`), 테스트는 바이너리 내장 자체 검증(`--self-test-core`)

## Global Constraints

- 스펙: `docs/superpowers/specs/2026-07-26-drain-hatch-animation-design.md`
- 빗금 사양: 45° · 굵기 3pt(모던) / 1px(픽셀 논리 좌표) · 피치 9pt(모던) / 3px(픽셀) · 오른쪽→왼쪽 · 주기 0.60s
- 빗금 색: 잔량 색(`heatRemain`)의 각 채널 × 0.35 (반올림), 모던 모드는 알파 0.85
- 잔량이 극소일 때(모던 fill < 8pt, 픽셀 fw < 6px)는 배터리 내부 전체에 흐린 톤(`dark ? (95,95,95) : (190,190,190)`) 빗금
- `reduceMotion`이 켜진 상태에서는 어떤 애니메이션 리소스도 생성되지 않아야 한다 (기존 `stopVisualMotion` 정책)
- 새 서드파티 의존성 금지 (이 저장소는 무의존성이 핵심 특징)
- 빌드 명령: `cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o <출력경로> -framework Cocoa -framework QuartzCore -framework ServiceManagement`
- 테스트 명령: `<출력경로> --self-test-core` — 모든 그룹이 PASS를 출력하고 종료 코드 0
- 작업용 바이너리 경로는 저장소를 더럽히지 않도록 `/tmp/ccb-test`를 쓴다

---

### Task 1: 렌더러 — 지오메트리 상수 · 빗금 색 · 픽셀 캡슐 빗금

**Files:**
- Modify: `app/BatteryRenderer.swift` (상수 추가, `drawCapsule`, `renderBatteryImage`, `renderModernSummaryImage`)
- Test: `app/main.swift` (`runCoreSelfTest()` 안에 `drain-hatch` 그룹 추가)

**Interfaces:**
- Consumes: 기존 `heatRemain(_:dark:)`(private), `normalizedRemaining(_:)`, `remainingBand(_:)`, `Canvas.set(_:_:_:)`
- Produces:
  - `MODERN_ICON_WIDTH / MODERN_ICON_GAP / MODERN_BODY_WIDTH / MODERN_BODY_HEIGHT / MODERN_ITEM_GAP / MODERN_IMAGE_PAD / MODERN_IMAGE_HEIGHT / MODERN_ITEM_WIDTH: CGFloat`
  - `HATCH_PITCH_PT: CGFloat = 9`, `HATCH_STRIPE_PT: CGFloat = 3`, `HATCH_PERIOD: CFTimeInterval = 0.6`
  - `HATCH_PITCH_PX: Int = 3`, `HATCH_STRIPE_PX: Int = 1`, `HATCH_TICK_INTERVAL: TimeInterval = 0.2`
  - `func activityHatchRGB(_ remain: Double?, dark: Bool) -> RGB`
  - `func emptyHatchRGB(dark: Bool) -> RGB`
  - `func renderBatteryImage(dark:items:glintX:cat:catFrameIndex:hatchPhase:hatchProviders:configuration:) -> NSImage?`
    — 새 파라미터는 `hatchPhase: Int? = nil`, `hatchProviders: Set<Provider> = []`

- [ ] **Step 1: 자체 검증 테스트를 먼저 추가한다 (실패해야 함)**

`app/main.swift`의 `runCoreSelfTest()` 안, `print("self-test-core: reduce-motion PASS")` **바로 앞**에 아래 블록을 삽입한다.

```swift
  // ── drain hatch: 픽셀 캡슐 빗금 ──
  let hatchItems = [BattItem(label: "C5", provider: .claude, remain: 75),
                    BattItem(label: "X5", provider: .codex, remain: 40)]
  func hatchPixels(_ image: NSImage?) -> Data? { image?.tiffRepresentation }
  let hatchPlain = hatchPixels(renderBatteryImage(dark: true, items: hatchItems))
  let hatchOff = hatchPixels(renderBatteryImage(dark: true, items: hatchItems,
                                                hatchPhase: 0, hatchProviders: []))
  let hatchZero = hatchPixels(renderBatteryImage(dark: true, items: hatchItems,
                                                 hatchPhase: 0, hatchProviders: [.claude]))
  let hatchOne = hatchPixels(renderBatteryImage(dark: true, items: hatchItems,
                                                hatchPhase: 1, hatchProviders: [.claude]))
  try require(hatchPlain != nil && hatchPlain == hatchOff,
              "drain-hatch", "inactive-render-unchanged",
              "hatch parameters with no active provider changed the rendered image")
  try require(hatchZero != nil && hatchZero != hatchPlain && hatchZero != hatchOne,
              "drain-hatch", "phase-advances-pixels",
              "hatch phase did not change the rendered pixels")
  try require(activityHatchRGB(75, dark: true) == (32, 62, 39)
                && emptyHatchRGB(dark: true) == (95, 95, 95)
                && emptyHatchRGB(dark: false) == (190, 190, 190),
              "drain-hatch", "derived-colors",
              "hatch colors were not derived from the remaining color")
  try require(MODERN_ITEM_WIDTH == 59,
              "drain-hatch", "modern-item-width",
              "modern item width did not match the rendered layout")
  print("self-test-core: drain-hatch PASS")
```

- [ ] **Step 2: 컴파일이 실패하는지 확인한다**

```bash
cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o /tmp/ccb-test \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement
```
Expected: FAIL — `cannot find 'activityHatchRGB' in scope`, `extra arguments 'hatchPhase', 'hatchProviders'`, `cannot find 'MODERN_ITEM_WIDTH' in scope`

- [ ] **Step 3: 상수와 색 헬퍼를 추가한다**

`app/BatteryRenderer.swift`의 `heatRemain` 정의(현재 231행) **바로 아래**에 추가한다.

```swift
// Modern layout geometry — shared by the renderer and the activity layers so the two can't drift
let MODERN_ICON_WIDTH: CGFloat = 13
let MODERN_ICON_GAP: CGFloat = 5
let MODERN_BODY_WIDTH: CGFloat = 38
let MODERN_BODY_HEIGHT: CGFloat = 18
let MODERN_ITEM_GAP: CGFloat = 7
let MODERN_IMAGE_PAD: CGFloat = 2
let MODERN_IMAGE_HEIGHT: CGFloat = 24
let MODERN_ITEM_WIDTH = MODERN_ICON_WIDTH + MODERN_ICON_GAP + MODERN_BODY_WIDTH + 3

// Drain hatch — 45° stripes drifting right→left over the remaining fill ("this is being used up")
let HATCH_PITCH_PT: CGFloat = 9
let HATCH_STRIPE_PT: CGFloat = 3
let HATCH_PERIOD: CFTimeInterval = 0.6
let HATCH_PITCH_PX = 3            // pixel canvas is in logical px (Canvas.SCALE doubles it)
let HATCH_STRIPE_PX = 1
let HATCH_TICK_INTERVAL: TimeInterval = 0.2   // one logical px per tick → a full pitch in HATCH_PERIOD

// Hatch color = the remaining color, darkened. Keeps the same contrast on green, amber and red.
func activityHatchRGB(_ remain: Double?, dark: Bool) -> RGB {
  let base = heatRemain(remainingBand(normalizedRemaining(remain ?? 0)), dark: dark)
  let scale = 0.35
  return (UInt8((Double(base.r) * scale).rounded()),
          UInt8((Double(base.g) * scale).rounded()),
          UInt8((Double(base.b) * scale).rounded()))
}

// Used when the fill is too small to carry the hatch — the stripes run over the empty body instead
func emptyHatchRGB(dark: Bool) -> RGB { dark ? (95, 95, 95) : (190, 190, 190) }
```

- [ ] **Step 4: `drawCapsule`에 픽셀 빗금을 그린다**

`drawCapsule` 시그니처(현재 277행)의 마지막 파라미터 뒤에 `_ hatchPhase: Int?`를 추가한다.

```swift
private func drawCapsule(_ cv: Canvas, _ p: Preset, _ x: Int, _ midY: Int,
                         _ remain: Double?, _ ink: RGB, _ dark: Bool, _ glintX: Int?,
                         _ hatchPhase: Int?) {
```

골드 글린트 블록(`if golden, let g = glintX { … }`)과 숫자 그리기(`let s = String(Int(value.rounded()))`) **사이**에 삽입한다. 숫자보다 먼저 그려야 숫자가 빗금에 덮이지 않는다.

```swift
  // Drain hatch — skipped while the golden glint sweep owns the capsule
  if let phase = hatchPhase, !(golden && glintX != nil) {
    let wide = fw >= 6
    let hatchW = wide ? fw : p.bw - 4
    let col = wide ? activityHatchRGB(remain, dark: dark) : emptyHatchRGB(dark: dark)
    for j in 0 ..< (p.bh - 4) {
      for i in 0 ..< hatchW {
        let px = x + 2 + i, py = by + 2 + j
        let d = (((px - py + phase) % HATCH_PITCH_PX) + HATCH_PITCH_PX) % HATCH_PITCH_PX
        if d < HATCH_STRIPE_PX { cv.set(px, py, col) }
      }
    }
  }
```

- [ ] **Step 5: `renderBatteryImage`에 파라미터를 흘려보낸다**

시그니처(현재 330행)를 바꾼다.

```swift
func renderBatteryImage(dark: Bool, items: [BattItem], glintX: Int? = nil,
                        cat: CatState? = nil, catFrameIndex: Int = 0,
                        hatchPhase: Int? = nil, hatchProviders: Set<Provider> = [],
                        configuration: PresentationConfiguration = .production) -> NSImage? {
```

캡슐 그리는 줄(현재 365행)을 바꾼다.

```swift
    drawCapsule(cv, p, x, midY, item.remain, ink, dark, glintX,
                hatchProviders.contains(item.provider) ? hatchPhase : nil)
```

- [ ] **Step 6: 모던 렌더러가 새 지오메트리 상수를 쓰게 한다**

`renderModernSummaryImage`(현재 380행)의 지역 상수 선언 줄을 교체한다. 값은 동일하므로 렌더 결과는 바뀌지 않고, 활동 레이어와 상수를 공유하게 된다.

```swift
  let iconWidth = MODERN_ICON_WIDTH, iconGap = MODERN_ICON_GAP
  let bodyW = MODERN_BODY_WIDTH, bodyH = MODERN_BODY_HEIGHT, itemGap = MODERN_ITEM_GAP
  let itemW = MODERN_ITEM_WIDTH
  let image = NSImage(size: NSSize(width: ceil(MODERN_IMAGE_PAD * 2 + CGFloat(summaries.count) * itemW
                                               + CGFloat(summaries.count - 1) * itemGap),
                                   height: MODERN_IMAGE_HEIGHT))
```

같은 함수의 `var x: CGFloat = 2`도 `var x: CGFloat = MODERN_IMAGE_PAD`로 바꾼다.

- [ ] **Step 7: 빌드하고 테스트가 통과하는지 확인한다**

```bash
cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o /tmp/ccb-test \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement && /tmp/ccb-test --self-test-core
```
Expected: PASS — 출력에 `self-test-core: drain-hatch PASS`와 `self-test-core: PASS`가 모두 있어야 하고, 기존 그룹(`reduce-motion` 등)도 그대로 PASS

- [ ] **Step 8: 커밋**

```bash
git add app/BatteryRenderer.swift app/main.swift
git commit -m "feat: draw drain hatch on pixel-mode capsules"
```

---

### Task 2: 픽셀 모드 — 고양이·빗금 통합 모션 틱

**Files:**
- Modify: `app/main.swift` (`AppDelegate` 상태, `catTick` → `pixelMotionTick`, `restartCatTimer` → `restartPixelMotionTimer`, `updateActivityAnimation`, `preparePresentation`, `playGoldenGlint`, `applyEligibleMotion`, `restoreEligibleMotion`)
- Test: `app/main.swift` (`runCoreSelfTest()`의 `drain-hatch` 그룹 확장)

**Interfaces:**
- Consumes: Task 1의 `HATCH_PITCH_PX`, `HATCH_TICK_INTERVAL`, `renderBatteryImage(… hatchPhase:hatchProviders:…)`
- Produces:
  - `AppDelegate.hatchPhase: Int` (0 ..< 3)
  - `AppDelegate.pixelMotionTick()` — 고양이 프레임과 빗금 phase를 함께 진행시키고 아이콘을 한 번만 다시 그린다
  - `AppDelegate.restartPixelMotionTimer(_ state: CatState)` — 기존 `catTimer` 슬롯을 그대로 사용
  - `AppDelegate.pixelTickInterval(_ state: CatState) -> TimeInterval`

- [ ] **Step 1: 실패하는 테스트를 추가한다**

Task 1에서 삽입한 `drain-hatch` 블록의 `print("self-test-core: drain-hatch PASS")` **바로 앞**에 이어 붙인다. (`motionDelegate`는 pixel 모드 · cat `.nyan` · `apiActiveProviders = [.claude, .codex]` 상태로 이미 만들어져 있으나 이 시점엔 reduceMotion이 켜져 있으므로, 검증용 델리게이트를 새로 만든다.)

```swift
  // ── drain hatch: 픽셀 모션 틱 ──
  let tickFlag = CoreSelfTestFlag(false)
  let tickMode = CoreSelfTestBox("pixel")
  let tickCat = CoreSelfTestBox(CatStyle.none)
  let tickConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { tickMode.value },
    catStyle: { tickCat.value }, batterySize: { "big" },
    goldTestEnabled: { false }, forcedCatState: { nil }, language: { "en" })
  let tickFactory = CoreSelfTestVisualTimerFactory()
  var tickCompletions: [(Snapshot) -> Void] = []
  let tickDelegate = AppDelegate(
    presentationConfiguration: tickConfiguration,
    collector: { tickCompletions.append($0) },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { tickFlag.value }, glintIntervalReader: { 30 },
    motionNotificationCenter: NotificationCenter(), visualTimerFactory: tickFactory.make,
    allowsHeadlessVisualResources: true, providerMonitorIdentity: NSObject())
  tickDelegate.menuSink = { _ in }
  tickDelegate.staticOutputSink = { _ in }
  tickDelegate.accessibilitySummarySink = { _ in }
  tickDelegate.requestRefresh(.initial)
  tickCompletions[0](snapshot)
  try require(tickDelegate.visualResourceSnapshot().catTimer == nil,
              "drain-hatch", "idle-pixel-timer-absent",
              "pixel motion timer ran with no cat and no active provider")
  tickDelegate.apiActiveProviders = [.claude]
  tickDelegate.updateActivityAnimation()
  let hatchTimer = tickDelegate.visualResourceSnapshot().catTimer
  try require(hatchTimer != nil && tickDelegate.pixelTickInterval(.walk) == HATCH_TICK_INTERVAL,
              "drain-hatch", "activity-starts-pixel-timer",
              "activating a provider did not start the pixel motion timer at the hatch interval")
  tickCat.value = .nyan
  try require(tickDelegate.pixelTickInterval(.sleep) == HATCH_TICK_INTERVAL
                && tickDelegate.pixelTickInterval(.dash) == 0.12,
              "drain-hatch", "tick-interval-is-fastest",
              "pixel tick interval was not the faster of the cat and hatch cadences")
  // 최초 리프레시가 인트로 프레임 타이머를 켜 두므로, 틱 가드를 통과하도록 먼저 무효화한다
  tickFactory.resources.filter { $0.kind == .animation }.forEach { $0.invalidate() }
  let phaseBefore = tickDelegate.hatchPhase
  tickDelegate.pixelMotionTick()
  tickDelegate.pixelMotionTick()
  try require(tickDelegate.hatchPhase == (phaseBefore + 2) % HATCH_PITCH_PX,
              "drain-hatch", "tick-advances-phase",
              "pixel motion tick did not advance the hatch phase")
  tickDelegate.apiActiveProviders = []
  tickCat.value = CatStyle.none
  tickDelegate.updateActivityAnimation()
  try require(tickDelegate.visualResourceSnapshot().catTimer == nil,
              "drain-hatch", "deactivation-stops-pixel-timer",
              "pixel motion timer survived losing both the cat and every active provider")
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o /tmp/ccb-test \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement
```
Expected: FAIL — `value of type 'AppDelegate' has no member 'pixelTickInterval'`, `… has no member 'hatchPhase'`, `… has no member 'pixelMotionTick'`

- [ ] **Step 3: 상태와 틱 함수를 추가한다**

`app/main.swift`의 `var catIdx = 0`(현재 256행) 아래에 추가한다.

```swift
  var hatchPhase = 0
  private var pixelTickCount = 0
```

`catTick()`(현재 470~484행) 전체를 아래로 교체한다.

```swift
  // Advance one pixel-mode motion frame (cat sprite + drain hatch) and redraw the icon only
  @objc func pixelMotionTick() {
    guard !reduceMotionEnabled, presentationConfiguration.displayMode() != "modern",
          animTimer?.isValid != true, let snap = lastSnap else { return }
    let catStyle = presentationConfiguration.catStyle()
    let hatching = !activeProviders.isEmpty
    guard catStyle != .none || hatching else { return }
    let state = catState(snap, configuration: presentationConfiguration)
    if catStyle != .none {
      let ticksPerCatFrame = max(1, Int((catTickInterval(state) / pixelTickInterval(state)).rounded()))
      if pixelTickCount % ticksPerCatFrame == 0 { catIdx += 1 }
    }
    if hatching { hatchPhase = (hatchPhase + 1) % HATCH_PITCH_PX }
    pixelTickCount += 1
    // 프레임 상태를 먼저 진행시키고, 그릴 버튼이 있을 때만 다시 그린다 (헤드리스 검증 가능)
    guard let button = statusItem?.button else { return }
    let items = battItems(snap, configuration: presentationConfiguration)
    guard !items.isEmpty else { return }
    let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if let image = renderBatteryImage(dark: dark, items: items,
                                      cat: catStyle == .none ? nil : state,
                                      catFrameIndex: catIdx,
                                      hatchPhase: hatching ? hatchPhase : nil,
                                      hatchProviders: activeProviders,
                                      configuration: presentationConfiguration) {
      setButtonImage(image)
    }
  }

  // The tick runs at the faster of the two cadences; the cat only advances every Nth tick
  func pixelTickInterval(_ state: CatState) -> TimeInterval {
    let catActive = presentationConfiguration.catStyle() != .none
    let hatchActive = !activeProviders.isEmpty
    if catActive && hatchActive { return min(catTickInterval(state), HATCH_TICK_INTERVAL) }
    if hatchActive { return HATCH_TICK_INTERVAL }
    return catTickInterval(state)
  }
```

- [ ] **Step 4: 타이머를 픽셀 모션 타이머로 바꾼다**

`restartCatTimer`(현재 494~509행) 전체를 교체한다.

```swift
  // (Re)start the pixel-mode motion cycle — runs when the cat or the drain hatch needs frames
  func restartPixelMotionTimer(_ state: CatState) {
    guard (statusItem != nil || allowsHeadlessVisualResources), !reduceMotionEnabled,
          presentationConfiguration.displayMode() != "modern",
          presentationConfiguration.catStyle() != .none || !activeProviders.isEmpty else {
      catTimer?.invalidate(); catTimer = nil
      return
    }
    catTimer?.invalidate()
    let epoch = motionEpoch
    catTimer = visualTimerFactory(.cat, pixelTickInterval(state), true) { [weak self] timer in
      guard let self, self.motionEpoch == epoch, !self.reduceMotionEnabled,
            self.presentationConfiguration.displayMode() != "modern" else { return }
      timer.callbackEffectBegan()
      self.pixelMotionTick()
    }
  }
```

호출부 두 곳을 새 이름으로 바꾼다.
- `restoreEligibleMotion()`(현재 409행): `restartCatTimer(catState(…))` → `restartPixelMotionTimer(catState(…))`
  이때 감싸고 있는 `if presentationConfiguration.catStyle() != .none { … }` 조건은 삭제하고, `restartPixelMotionTimer(catState(snapshot, configuration: presentationConfiguration))`를 무조건 호출한다 (고양이가 꺼져 있어도 빗금 때문에 타이머가 필요하고, 필요 없으면 함수 안 guard가 정리한다).
- `applyEligibleMotion(_:dark:)`(현재 730행): `restartCatTimer(output.catState)` → `restartPixelMotionTimer(output.catState)`

- [ ] **Step 5: 활동 상태 변경이 픽셀 타이머를 갱신하게 한다**

`updateActivityAnimation()`(현재 414~417행)을 교체한다.

```swift
  func updateActivityAnimation() {
    activeProviders = apiActiveProviders.union(sessionActiveProviders)
    updateActivityLayers()
    if presentationConfiguration.displayMode() != "modern", let snap = lastSnap {
      restartPixelMotionTimer(catState(snap, configuration: presentationConfiguration))
    }
  }
```

- [ ] **Step 6: 정적 렌더 경로에도 현재 빗금 상태를 반영한다**

리프레시 때 이미지가 다시 그려질 때 빗금이 한 틱 동안 사라지지 않도록, 픽셀 이미지를 만드는 두 곳에 현재 phase를 넘긴다.

`preparePresentation(_:dark:swiftBarDuplicate:assets:)`(현재 661~664행)의 pixel 분기:

```swift
      : renderBatteryImage(dark: dark, items: items, cat: state, catFrameIndex: catIdx,
                           hatchPhase: (reduceMotionEnabled || activeProviders.isEmpty) ? nil : hatchPhase,
                           hatchProviders: activeProviders,
                           configuration: presentationConfiguration)
```

`playGoldenGlint()`(현재 521~523행)의 최종 프레임:

```swift
          let final = renderBatteryImage(dark: dark, items: items, cat: state,
                                         catFrameIndex: catIdx,
                                         hatchPhase: activeProviders.isEmpty ? nil : hatchPhase,
                                         hatchProviders: activeProviders,
                                         configuration: presentationConfiguration) else { return }
```

- [ ] **Step 7: 빌드하고 테스트가 통과하는지 확인한다**

```bash
cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o /tmp/ccb-test \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement && /tmp/ccb-test --self-test-core
```
Expected: PASS — `self-test-core: drain-hatch PASS`, `self-test-core: reduce-motion PASS`, `self-test-core: PASS`

- [ ] **Step 8: 커밋**

```bash
git add app/main.swift
git commit -m "feat: unify cat and drain hatch into one pixel motion tick"
```

---

### Task 3: 모던 모드 — orbit 점을 빗금 레이어로 교체

**Files:**
- Modify: `app/BatteryRenderer.swift` (`hatchStripeImage` 추가)
- Modify: `app/main.swift` (`activityLayers` 타입, `updateActivityLayers`)
- Test: `app/main.swift` (`runCoreSelfTest()`의 `drain-hatch` 그룹 확장)

**Interfaces:**
- Consumes: Task 1의 `MODERN_*` 상수, `HATCH_PITCH_PT`, `HATCH_STRIPE_PT`, `HATCH_PERIOD`, `activityHatchRGB`, `emptyHatchRGB`
- Produces:
  - `func hatchStripeImage(width: CGFloat, height: CGFloat, color: NSColor) -> CGImage?`
  - `AppDelegate.activityLayers: [Provider: CALayer]` — 값이 클리핑 레이어이고, 첫 서브레이어가 `"drain"` 키 애니메이션을 가진다

- [ ] **Step 1: 실패하는 테스트를 추가한다**

Task 2에서 넣은 블록 뒤, `print("self-test-core: drain-hatch PASS")` 앞에 이어 붙인다.

```swift
  // ── drain hatch: 모던 모드 레이어 ──
  let modernFlag = CoreSelfTestFlag(false)
  let modernConfiguration = PresentationConfiguration(
    isMetricVisible: { _ in true }, displayMode: { "modern" },
    catStyle: { CatStyle.none }, batterySize: { "big" },
    goldTestEnabled: { false }, forcedCatState: { nil }, language: { "en" })
  var modernCompletions: [(Snapshot) -> Void] = []
  let modernDelegate = AppDelegate(
    presentationConfiguration: modernConfiguration,
    collector: { modernCompletions.append($0) },
    assetContextFactory: { refreshAssets }, duplicateReader: { false }, opener: { _ in },
    reduceMotionReader: { modernFlag.value }, glintIntervalReader: { 30 },
    motionNotificationCenter: NotificationCenter(),
    visualTimerFactory: CoreSelfTestVisualTimerFactory().make,
    allowsHeadlessVisualResources: true, providerMonitorIdentity: NSObject())
  modernDelegate.menuSink = { _ in }
  modernDelegate.staticOutputSink = { _ in }
  modernDelegate.accessibilitySummarySink = { _ in }
  modernDelegate.requestRefresh(.initial)
  modernCompletions[0](snapshot)
  modernDelegate.apiActiveProviders = [.claude]
  modernDelegate.updateActivityAnimation()
  let clip = modernDelegate.activityLayers[.claude]
  let stripes = clip?.sublayers?.first
  try require(Set(modernDelegate.activityLayers.keys) == [Provider.claude]
                && clip?.masksToBounds == true
                && stripes?.contents != nil
                && stripes?.animation(forKey: "drain") != nil,
              "drain-hatch", "modern-layer-installed",
              "active provider did not get a masked, animated hatch layer")
  try require((clip?.frame.width ?? 0) > 0 && (clip?.frame.height ?? 0) == 14
                && (stripes?.frame.width ?? 0) == (clip?.frame.width ?? 0) + HATCH_PITCH_PT,
              "drain-hatch", "modern-layer-geometry",
              "hatch layer geometry did not match the battery fill")
  modernDelegate.apiActiveProviders = []
  modernDelegate.updateActivityAnimation()
  try require(modernDelegate.activityLayers.isEmpty,
              "drain-hatch", "modern-layer-removed",
              "hatch layer survived the provider going idle")
  modernFlag.value = true
  modernDelegate.apiActiveProviders = [.claude, .codex]
  modernDelegate.updateActivityAnimation()
  try require(modernDelegate.activityLayers.isEmpty,
              "drain-hatch", "modern-reduce-motion",
              "hatch layers were created while Reduce Motion was on")
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o /tmp/ccb-test \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement && /tmp/ccb-test --self-test-core
```
Expected: FAIL — `self-test-core: FAIL: drain-hatch/modern-layer-installed: active provider did not get a masked, animated hatch layer` (현재는 orbit용 `CAShapeLayer`라 `masksToBounds`도 `"drain"` 애니메이션도 없다)

- [ ] **Step 3: 빗금 타일 이미지 생성 함수를 추가한다**

`app/BatteryRenderer.swift`의 `emptyHatchRGB` 아래에 추가한다.

```swift
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

func hatchNSColor(_ rgb: RGB, alpha: CGFloat) -> NSColor {
  NSColor(calibratedRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
          blue: CGFloat(rgb.b) / 255, alpha: alpha)
}
```

- [ ] **Step 4: `activityLayers`를 `CALayer`로 바꾸고 `updateActivityLayers`를 교체한다**

`app/main.swift`의 선언(현재 255행)을 바꾼다.

```swift
  var activityLayers: [Provider: CALayer] = [:]
```

`updateActivityLayers()`(현재 419~467행) 전체를 교체한다.

```swift
  func updateActivityLayers() {
    guard !reduceMotionEnabled, presentationConfiguration.displayMode() == "modern",
          let snap = lastSnap, statusItem?.button != nil || allowsHeadlessVisualResources else {
      activityLayers.values.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
      activityLayers.removeAll()
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
    let originY = max(0, (buttonHeight - imageHeight) / 2)
    let dark = button.map { $0.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua } ?? true

    for provider in [Provider.claude, .codex] {
      if let stale = activityLayers.removeValue(forKey: provider) {
        stale.removeAllAnimations()
        stale.removeFromSuperlayer()
      }
      guard activeProviders.contains(provider),
            let index = summaries.firstIndex(where: { $0.provider == provider }) else { continue }
      let summary = summaries[index]
      let itemX = originX + MODERN_IMAGE_PAD + CGFloat(index) * (MODERN_ITEM_WIDTH + MODERN_ITEM_GAP)
      let bodyX = itemX + MODERN_ICON_WIDTH + MODERN_ICON_GAP
      let fillW = max(0, (MODERN_BODY_WIDTH - 4) * normalizedRemaining(summary.remain) / 100)
      // Too little fill to carry the stripes → run them over the whole body so activity stays visible
      let wide = fillW >= 8
      let rect = CGRect(x: bodyX + 2, y: originY + 5,
                        width: wide ? fillW : MODERN_BODY_WIDTH - 4, height: 14)
      let color = wide ? hatchNSColor(activityHatchRGB(summary.remain, dark: dark), alpha: 0.85)
                       : hatchNSColor(emptyHatchRGB(dark: dark), alpha: 0.55)

      let clip = CALayer()
      clip.frame = rect
      clip.masksToBounds = true
      clip.cornerRadius = 2.5
      let stripes = CALayer()
      stripes.frame = CGRect(x: 0, y: 0, width: rect.width + HATCH_PITCH_PT, height: rect.height)
      stripes.contentsScale = 2
      stripes.contents = hatchStripeImage(width: rect.width + HATCH_PITCH_PT,
                                          height: rect.height, color: color)
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
    }
  }
```

- [ ] **Step 5: 빌드하고 테스트가 통과하는지 확인한다**

```bash
cd app && swiftc -O -target arm64-apple-macos12.0 *.swift -o /tmp/ccb-test \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement && /tmp/ccb-test --self-test-core
```
Expected: PASS — `self-test-core: drain-hatch PASS`와 `self-test-core: PASS`, 기존 그룹 전부 PASS

- [ ] **Step 6: 커밋**

```bash
git add app/BatteryRenderer.swift app/main.swift
git commit -m "feat: replace orbit dot with drain hatch in modern mode"
```

---

### Task 4: 실제 앱 육안 확인

**Files:**
- Modify: 없음 (확인만; 문제가 보이면 해당 Task로 돌아가 수정)

**Interfaces:**
- Consumes: Task 1~3의 최종 바이너리

- [ ] **Step 1: 앱을 빌드한다**

```bash
cd /Users/redpug/Dev/claude-codex-battery && app/build.sh
```
Expected: `✅ ad-hoc signing complete` 또는 서명 생략 메시지로 끝나고 `app/ClaudeCodexBattery.app`이 갱신됨

- [ ] **Step 2: 픽셀 모드 정지 프레임을 PNG로 뽑아 빗금을 확인한다**

```bash
/tmp/ccb-test --render-glint /tmp/ccb-glint.png && echo "glint ok"
```
Expected: `saved` 출력 — 기존 골드 글린트 경로가 깨지지 않았는지 확인 (빗금 없이 이전과 동일해야 함)

- [ ] **Step 3: 앱을 실행하고 메뉴바를 눈으로 확인한다**

```bash
open /Users/redpug/Dev/claude-codex-battery/app/ClaudeCodexBattery.app
```
확인 항목 — Claude Code 세션이 도는 동안:
1. 모던 모드에서 잔량 초록 영역 위로 45° 빗금이 오른쪽→왼쪽으로 흐르는가
2. 아이콘 주위 orbit 점이 더 이상 없는가
3. 두 번째 배터리(Codex)의 빗금이 잔량 영역에 정확히 겹치는가 (2px 어긋남이 없어야 함)
4. 설정에서 픽셀 모드로 바꿨을 때 캡슐 위 빗금이 흐르고, 고양이 애니메이션 속도가 이전과 같은가
5. 세션이 끝나면 두 모드 모두 빗금이 멈추는가

- [ ] **Step 4: 문제가 없으면 사용자에게 스크린샷으로 보고한다**

```bash
screencapture -R 0,0,1600,60 /tmp/ccb-menubar.png
```
스크린샷을 사용자에게 보여주고, 속도·굵기·색 미세조정 요청이 있으면 해당 상수(`HATCH_PERIOD`, `HATCH_STRIPE_PT`, `activityHatchRGB`의 `scale`)만 고친 뒤 Task 1~3의 테스트를 다시 돌린다.

---

## 참고

- 픽셀 캔버스 좌표는 논리 좌표다 (`Canvas.set`이 내부에서 2배로 확대). 그래서 픽셀 모드 빗금 굵기 1 / 피치 3이 실제로는 2px / 6px로 찍힌다.
- `activityLayers`라는 이름은 그대로 둔다. `VisualResourceSnapshot`과 기존 `reduce-motion` 검증들이 이 이름을 쓰고 있고, 의미(활동 표시 레이어)도 그대로다.
- `catTimer` 슬롯도 이름을 유지한다. 이제 고양이와 빗금을 함께 돌리는 픽셀 모션 타이머지만, 기존 검증이 이 슬롯의 존재/부재를 확인한다.
