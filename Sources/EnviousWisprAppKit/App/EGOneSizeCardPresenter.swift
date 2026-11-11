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

  struct Memory: Equatable, Sendable {
    let bytes: Int64
    let macBytes: UInt64
    /// The size needs more than half of this Mac's memory.
    let isTight: Bool
    var fraction: Double { macBytes == 0 ? 0 : min(1, Double(bytes) / Double(macBytes)) }
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
            isTight: UInt64(max(0, $0.value)) * 2 > inputs.physicalMemoryBytes)
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
