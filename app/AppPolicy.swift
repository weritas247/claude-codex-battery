import Foundation

func normalizedRemaining(fromUsed used: Double) -> Double {
  normalizedRemaining(100 - used)
}

func normalizedRemaining(_ remaining: Double) -> Double {
  guard remaining.isFinite else { return 0 }
  return min(100, max(0, remaining))
}

enum RemainingBand: Equatable {
  case red
  case amber
  case green
}

func remainingBand(_ remaining: Double) -> RemainingBand {
  let value = normalizedRemaining(remaining)
  if value <= 20 { return .red }
  if value < 50 { return .amber }
  return .green
}

func hasLowRemainingResetDistantRisk(remaining: Double, resetSeconds: TimeInterval) -> Bool {
  guard resetSeconds.isFinite else { return false }
  return normalizedRemaining(remaining) < 12 && resetSeconds > 1_800
}

struct RefreshGeneration: Equatable, Hashable {
  let value: Int
}

enum RefreshRequestTransition: Equatable {
  case start(RefreshGeneration)
  case queueNewest(RefreshGeneration, replacing: RefreshGeneration?)
}

enum RefreshCompletionTransition: Equatable {
  case accept(RefreshGeneration)
  case discardAndStart(discarded: RefreshGeneration, next: RefreshGeneration)
  case stale(RefreshGeneration)
}

struct RefreshGate {
  private(set) var active: RefreshGeneration?
  private(set) var newestTrailing: RefreshGeneration?
  private var lastGeneration = 0

  mutating func request() -> RefreshRequestTransition {
    lastGeneration += 1
    let generation = RefreshGeneration(value: lastGeneration)
    guard active != nil else {
      active = generation
      return .start(generation)
    }
    let replaced = newestTrailing
    newestTrailing = generation
    return .queueNewest(generation, replacing: replaced)
  }

  mutating func complete(_ generation: RefreshGeneration) -> RefreshCompletionTransition {
    guard generation == active else { return .stale(generation) }
    if let next = newestTrailing {
      active = next
      newestTrailing = nil
      return .discardAndStart(discarded: generation, next: next)
    }
    active = nil
    return .accept(generation)
  }
}

private func productionMetricVisibility(_ metric: String) -> Bool {
  isMetricVisible(metric)
}

struct PresentationConfiguration {
  let isMetricVisible: (String) -> Bool
  let displayMode: () -> String
  let catStyle: () -> CatStyle
  let batterySize: () -> String
  let goldTestEnabled: () -> Bool
  let forcedCatState: () -> CatState?
  let language: () -> String

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
    language: { UI_LANG }
  )
}
