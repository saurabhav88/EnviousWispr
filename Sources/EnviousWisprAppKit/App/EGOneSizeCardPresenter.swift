import EnviousWisprCore
import EnviousWisprLocalPolish
import Foundation

/// #4473: one EG-1 size card, as plain values. The view draws it; nothing here draws, reads
/// a runtime or holds state.
struct EGOneSizeCard: Equatable, Identifiable, Sendable {
  enum State: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double)
    case verifying
    case paused
    case updatePaused(resumable: Bool)
    case failed(EGOneDownloadFailure)
    case installed
  }

  enum Action: Equatable, Sendable {
    case download, resume, resumeUpgrade, finishUpgrade, tryAgain, cancel
    /// Choose this size: a click anywhere on its card. Never one of a card's buttons.
    case use
    case testLive
    case remove
  }

  /// #4525: the memory row and its bar. Gray is the Mac's memory in use now (live); purple is
  /// the size's measured peak, stacked after gray for a size that is not running. A size that is
  /// starting or running adds no purple: its memory is already part of gray. With no live
  /// figure the bar is today's: purple from the left, warned by the more-than-half rule.
  struct Memory: Equatable, Sendable {
    enum Warning: Equatable, Sendable {
      /// No live figure: the size needs more than half of this Mac's memory.
      case tight
      /// Live: memory in use now plus this size passes 90% of this Mac's memory (founder
      /// 2026-11-11, plan #4525 §14 Q1).
      case wontFitNow
    }

    /// The size's measured peak.
    let bytes: Int64
    let macBytes: UInt64
    /// The Mac's memory in use now; nil when the live read is unavailable.
    let systemUsedBytes: UInt64?
    let activity: LocalPolishRuntime.ServerActivity

    var warning: Warning? {
      // A starting or running size is already using its memory: never warned, live or not.
      guard activity == .inactive else { return nil }
      let peak = UInt64(max(0, bytes))
      guard let used = systemUsedBytes else { return peak * 2 > macBytes ? .tight : nil }
      // Whole numbers, so exactly 90% is not a warning and nothing rounds across the line.
      let (projected, o1) = used.addingReportingOverflow(peak)
      let (scaled, o2) = projected.multipliedReportingOverflow(by: 10)
      let (limit, o3) = macBytes.multipliedReportingOverflow(by: 9)
      if o1 || o2 || o3 { return .wontFitNow }
      return scaled > limit ? .wontFitNow : nil
    }

    /// Gray: memory in use now, as a share of the Mac's memory; 0 with no live figure.
    var usedFraction: Double { Self.share(systemUsedBytes ?? 0, of: macBytes) }
    /// Where purple starts: after gray when live, else at the left edge.
    var peakStart: Double { usedFraction }
    /// Purple's width; never past the end of the track, and 0 for a starting or running size
    /// with a live figure.
    var peakFraction: Double {
      if systemUsedBytes != nil, activity != .inactive { return 0 }
      return min(1 - peakStart, Self.share(UInt64(max(0, bytes)), of: macBytes))
    }

    private static func share(_ part: UInt64, of whole: UInt64) -> Double {
      whole == 0 ? 0 : min(1, Double(part) / Double(whole))
    }

    // Kept for the view until #4525 chunk 3 redraws the bar; removed there.
    var isTight: Bool { warning != nil }
    var fraction: Double { peakFraction }
  }

  let size: EGOneSize
  var id: EGOneSize { size }
  /// "Best for this Mac". Advice only: every card stays usable on every Mac.
  let isRecommended: Bool
  /// The size the app uses for new work (the preference): the highlighted card.
  let isSelected: Bool
  let state: State
  /// Selected, installed, and EG-1 is this surface's polish engine.
  let isInUse: Bool
  let actions: [Action]
  /// "1.3"; nil renders no version.
  let displayVersion: String?
  /// The download's size; nil when the build has no manifest for the size.
  let downloadBytes: Int64?
  let englishPercent: Int?
  let internationalPercent: Int?
  let polishMilliseconds: Int?
  let isFastest: Bool
  let memory: Memory?
  let isLightest: Bool
}

/// Projects install states, the preference, the recommendation and the measured facts into
/// the three cards (plan #4473 P5). Pure: the same inputs always give the same cards.
enum EGOneSizeCardPresenter {
  struct Inputs {
    var preferred: EGOneSize
    /// EG-1 is the polish engine of the surface showing the cards.
    var surfaceUsesEGOne: Bool
    /// The surface may start the engine (see `ProviderSetupSurface.mayActivateEGOne`).
    var allowsRuntimeActivation: Bool
    var recommendation: EGOneSize
    /// nil for a size this build has no runtime for: it reads as not downloaded.
    var installStates: [EGOneSize: EGOneInstallState]
    var displayVersions: [EGOneSize: String]
    var downloadBytes: [EGOneSize: Int64]
    var facts: EGOneSizeFacts
    var physicalMemoryBytes: UInt64
    /// #4525: the Mac's memory in use now; nil when unread or unavailable.
    var systemUsedBytes: UInt64? = nil
    /// #4525: each size's helper process, from `LocalPolishRuntime.serverActivity`; a size
    /// missing here is not running.
    var activity: [EGOneSize: LocalPolishRuntime.ServerActivity] = [:]
  }

  /// Largest first, as the cards read left to right.
  static let order: [EGOneSize] = [.full, .mini, .micro]

  static func cards(_ inputs: Inputs) -> [EGOneSizeCard] {
    let speeds = order.compactMap { size in
      inputs.facts.facts(for: size).polishMilliseconds.map { (size, $0.value) }
    }
    let memories = order.compactMap { size in
      inputs.facts.facts(for: size).memoryBytes.map { (size, $0.value) }
    }
    // A "fastest" or "lightest" mark compares sizes, so it needs every size measured.
    let fastest = speeds.count == order.count ? speeds.min { $0.1 < $1.1 }?.0 : nil
    let lightest = memories.count == order.count ? memories.min { $0.1 < $1.1 }?.0 : nil

    return order.map { size in
      let state = Self.state(inputs.installStates[size] ?? .notInstalled)
      let isSelected = size == inputs.preferred
      let facts = inputs.facts.facts(for: size)
      return EGOneSizeCard(
        size: size,
        isRecommended: size == inputs.recommendation,
        isSelected: isSelected,
        state: state,
        isInUse: isSelected && state == .installed && inputs.surfaceUsesEGOne,
        actions: actions(
          state, isSelected: isSelected, allowsRuntimeActivation: inputs.allowsRuntimeActivation),
        displayVersion: inputs.displayVersions[size].flatMap { $0.isEmpty ? nil : $0 },
        downloadBytes: inputs.downloadBytes[size],
        englishPercent: facts.englishPercent.map { Int($0.value) },
        internationalPercent: facts.internationalPercent.map { Int($0.value) },
        polishMilliseconds: facts.polishMilliseconds.map { Int($0.value) },
        isFastest: size == fastest,
        memory: facts.memoryBytes.map {
          EGOneSizeCard.Memory(
            bytes: $0.value, macBytes: inputs.physicalMemoryBytes,
            systemUsedBytes: inputs.systemUsedBytes,
            activity: inputs.activity[size] ?? .inactive)
        },
        isLightest: size == lightest)
    }
  }

  static func state(_ install: EGOneInstallState) -> EGOneSizeCard.State {
    switch install {
    case .notInstalled: .notDownloaded
    case .downloading(let fraction, _): .downloading(fraction: fraction)
    case .verifying: .verifying
    case .installed: .installed
    case .paused: .paused
    case .updatePaused(let resumable, _): .updatePaused(resumable: resumable)
    case .failed(let failure): .failed(failure)
    }
  }

  /// The buttons a card offers, in reading order. Exhaustive on the state, so a new state
  /// cannot render a card with no way forward.
  static func actions(
    _ state: EGOneSizeCard.State, isSelected: Bool, allowsRuntimeActivation: Bool
  ) -> [EGOneSizeCard.Action] {
    switch state {
    case .notDownloaded: [.download]
    case .downloading: [.cancel]
    case .verifying: []
    case .paused: [.resume]
    case .updatePaused(let resumable): [resumable ? .resumeUpgrade : .finishUpgrade]
    case .failed: [.tryAgain]
    case .installed:
      // No Use button: a click on the card chooses the size (founder 2026-11-11).
      isSelected && allowsRuntimeActivation ? [.testLive, .remove] : [.remove]
    }
  }
}
