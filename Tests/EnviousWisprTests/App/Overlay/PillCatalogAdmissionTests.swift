import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// **Table 2 — admission, through the reducer** (#2375 Phase 3, chunk C2).
///
/// Admission is a function of `OverlayState`, never of a catalog entry, so it
/// cannot be observed from `PillCatalog` at all. This suite drives real events
/// through a real reducer.
///
/// **The cross-product is GENERATED, not hand-picked.** Hand-written rows cover
/// the cells the author thought of, which is the same blind spot the table exists
/// to cover for. Every request is run against every starting state.
///
/// **The clause a naive admission test omits is the third one**: a refusal must
/// leave the incumbent UNTOUCHED. Without it, a feature stealing another
/// feature's slot passes — the refusal is reported, and the slot has already
/// changed hands.
@Suite(.tags(.productOutcome))
struct PillCatalogAdmissionTests {

  // MARK: - Axes

  private enum StartingState: String, CaseIterable {
    /// Nothing on screen, pipeline idle.
    case emptySlot
    /// A dictation is running, so the pipeline owns the slot.
    case pipelineBusy
    /// A feature card already holds the slot while the pipeline is idle.
    case featureHoldsSlot
  }

  private static func reducer(in state: StartingState) -> OverlayReducer {
    var reducer = OverlayReducer()
    switch state {
    case .emptySlot:
      break
    case .pipelineBusy:
      _ = reducer.reduce(.pipeline(.recording(audioLevel: 0)))
    case .featureHoldsSlot:
      _ = reducer.reduce(.bluetoothAwareness)
    }
    return reducer
  }

  private static let chip = LanguageChipPayload(
    lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)

  /// Every request a caller can make of the slot, feature routes included.
  private static let events: [(label: String, event: OverlayEvent)] = [
    ("hidden", .pipeline(.hidden)),
    ("recording", .pipeline(.recording(audioLevel: 0))),
    ("processing", .pipeline(.processing(phase: .transcribing))),
    ("clipboardFallback", .pipeline(.clipboardFallback)),
    ("accessibilityToast", .pipeline(.accessibilityToast)),
    ("warning", .pipeline(.warning(reason: .polishFailed))),
    ("error", .pipeline(.error(reason: .asrFailed))),
    ("advisory", .pipeline(.advisory(reason: .zeroSignal))),
    ("interruption", .pipeline(.interruption(reason: .deviceRemoved))),
    ("passiveChip", .pipeline(.passiveChip(payload: chip))),
    ("cachingModel", .pipeline(.cachingModel(engineLabel: "Parakeet"))),
    ("engineReady", .pipeline(.engineReady)),
    ("recoveringLastRecording", .pipeline(.recoveringLastRecording)),
    ("recoverySucceeded", .pipeline(.recoverySucceeded)),
    ("bluetoothAwareness.pipelineRoute", .pipeline(.bluetoothAwareness)),
    ("escapeRecovery", .pipeline(.escapeRecovery(transcriptID: UUID()))),
    ("bluetoothAwareness.featureRoute", .bluetoothAwareness),
    ("importStatus.featureRoute", .importStatus(message: "Imported 12 words")),
  ]

  // MARK: - The sweep

  /// **A pipeline request is never refused; a feature request is refused unless
  /// the slot is free.** That is the shipped arbitration rule, and running every
  /// request against every state is what proves the rule rather than a sample of
  /// it.
  @Test("every request against every starting state obeys the arbitration rule")
  func admissionCrossProduct() {
    var refused = 0
    var admitted = 0
    var emptied = 0

    for state in StartingState.allCases {
      for (label, event) in Self.events {
        var reducer = Self.reducer(in: state)
        let before = reducer.state.current
        let plan = reducer.reduce(event)

        let isFeatureRoute = Self.isFeatureRoute(event)
        let shouldBeRefused = isFeatureRoute && state != .emptySlot

        if shouldBeRefused {
          refused += 1
          #expect(
            plan.didChange == false,
            "\(label) in \(state.rawValue) was admitted and should have been refused")
          // The clause that catches a feature stealing another feature's slot.
          #expect(
            reducer.state.current == before,
            "\(label) in \(state.rawValue) was refused and still disturbed the incumbent")
          #expect(
            plan.presentation == nil,
            "\(label) in \(state.rawValue) was refused and still produced a presentation")
          #expect(
            plan.announcement == nil,
            "\(label) in \(state.rawValue) was refused and still spoke")
        } else if Self.isEmptying(event) {
          emptied += 1
          // `.hidden` empties the slot. From an EMPTY slot that is a genuine
          // no-op with its own accounting; from an occupied one it is a change,
          // and it evicts a feature card as well as a pipeline pill.
          #expect(
            plan.presentation == nil,
            "\(label) in \(state.rawValue) emptied the slot and still produced a pill")
          #expect(
            reducer.state.current == nil,
            "\(label) in \(state.rawValue) did not empty the slot")
          #expect(
            plan.didChange == (before != nil),
            "\(label) in \(state.rawValue) mis-reported whether emptying changed anything")
        } else {
          admitted += 1
          // **Acceptance is `didChange`, NOT "the value differs".** An earlier
          // draft asserted the occupant changed, which fails on a repeated
          // recording push: the same audio level rebuilds an EQUAL definition, so
          // a correctly admitted request looks like a no-op to an equality check.
          // The sweep caught it, which is the argument for generating the
          // cross-product rather than picking rows.
          #expect(
            plan.didChange,
            "\(label) in \(state.rawValue) was refused and should have been admitted")
          #expect(
            plan.presentation != nil,
            "\(label) in \(state.rawValue) was admitted with nothing to show")
          // **The binding clause: the plan's occupant is the one that landed.**
          // `didChange` plus a non-nil plan plus a non-nil incumbent can all be
          // true of a reducer that reports a presentation and commits something
          // else (review r1 finding 2).
          #expect(
            reducer.state.current == plan.presentation,
            "\(label) in \(state.rawValue) reported a presentation without committing it")
          if state == .pipelineBusy, case .pipeline(.recording) = event {
            // The one legitimate no-change admission: a repeated recording push
            // at the same audio level rebuilds an EQUAL definition and must keep
            // its identity, or every metering tick would look like a new pill.
            #expect(
              reducer.state.current == before,
              "the repeated recording morph lost its identity")
          } else {
            #expect(
              reducer.state.current != before,
              "\(label) in \(state.rawValue) reported admission without replacing the prior occupant")
          }
        }
      }
    }

    // **The sweep must prove it generated something.** Every branch above is a
    // conditional, so a mis-specified axis — one state, one event, a predicate
    // that never fires — leaves this test green while asserting nothing. The
    // three counts are arithmetic over the axes: 18 requests x 3 states = 54
    // cells, of which the 2 feature routes are refused in the 2 non-empty states
    // (4), `.hidden` empties in all 3, and the remaining 47 are admitted.
    #expect(refused == 4, "the refusal half of this sweep is not being exercised")
    #expect(emptied == 3, "the emptying half of this sweep is not being exercised")
    #expect(admitted == 47, "the admission half of this sweep is not being exercised")
    #expect(refused + emptied + admitted == StartingState.allCases.count * Self.events.count)
  }

  /// The sweep above would still pass against a reducer that refused EVERYTHING,
  /// because a refusal is easy to satisfy. This pins the other direction: from an
  /// empty slot, both feature routes are admitted and occupy it.
  @Test("both feature routes are admitted from an empty slot")
  func featuresAreAdmittedWhenTheSlotIsFree() {
    for (label, event) in Self.events where Self.isFeatureRoute(event) {
      var reducer = Self.reducer(in: .emptySlot)
      let plan = reducer.reduce(event)
      #expect(plan.didChange, "\(label) was refused from an empty slot")
      #expect(plan.presentation != nil, "\(label) was admitted with nothing to show")
      #expect(reducer.state.current != nil, "\(label) did not take the slot")
    }
  }

  /// The one feature that may replace itself, which is the shipped rule and is
  /// narrower than "the slot is free".
  @Test("import status may replace itself and nothing else")
  func importStatusReplacesOnlyItself() {
    var reducer = OverlayReducer()
    #expect(reducer.reduce(.importStatus(message: "Imported 12 words")).didChange)
    let first = reducer.state.current

    let second = reducer.reduce(.importStatus(message: "Imported 40 words"))
    #expect(second.didChange, "a status pill must be replaceable by the next status")
    #expect(reducer.state.current != first, "the message did not update")

    // ...but it may not take the slot from another feature.
    var other = OverlayReducer()
    _ = other.reduce(.bluetoothAwareness)
    let held = other.state.current
    let refused = other.reduce(.importStatus(message: "Imported 12 words"))
    #expect(refused.didChange == false, "import status took the Bluetooth card's slot")
    #expect(other.state.current == held, "the Bluetooth card was disturbed by a refusal")
  }

  /// The Bluetooth card reaches the slot by two routes and both must produce the
  /// same occupant, now that one catalog arm serves them.
  @Test("both Bluetooth routes install the same occupant")
  func bothBluetoothRoutesAgree() {
    var viaPipeline = OverlayReducer()
    var viaFeature = OverlayReducer()
    let a = viaPipeline.reduce(.pipeline(.bluetoothAwareness))
    let b = viaFeature.reduce(.bluetoothAwareness)

    #expect(a.presentation?.content == b.presentation?.content)
    #expect(a.presentation?.requestedWidth == b.presentation?.requestedWidth)
    #expect(a.presentation?.reservesFixedHeight == b.presentation?.reservesFixedHeight)
    #expect(a.presentation?.expiry == b.presentation?.expiry)
    #expect(a.announcement == b.announcement)
  }

  /// The same class one suite over: the sweep's axes are hand-written lists, and
  /// the coverage floor above counts CELLS. Fifty-four cells is equally true of
  /// eighteen distinct requests and of seventeen with one duplicated, so the
  /// floor cannot tell a complete axis from a short one. Name the axis.
  @Test("the request axis is the whole set, not merely eighteen entries")
  func requestAxisIsComplete() {
    let labels = Self.events.map(\.label)
    let expected: Set<String> = [
      "hidden", "recording", "processing", "clipboardFallback", "accessibilityToast",
      "warning", "error", "advisory", "interruption", "passiveChip", "cachingModel",
      "engineReady", "recoveringLastRecording", "recoverySucceeded",
      "bluetoothAwareness.pipelineRoute", "escapeRecovery",
      "bluetoothAwareness.featureRoute", "importStatus.featureRoute",
    ]
    #expect(Set(labels) == expected, "a request is missing from the sweep's axis")
    #expect(labels.count == expected.count, "the sweep's axis contains a duplicate")
    #expect(
      Self.events.filter { Self.isFeatureRoute($0.event) }.count == 2,
      "both feature routes must be on the axis — they are where a refusal is observable")

    // **A LABEL IS NOT AN EVENT, and the set check above only proves the labels.**
    // A row labelled "warning" carrying `.error` satisfies every assertion in this
    // suite: the label set matches, the cell counts match, and both requests are
    // admitted identically — so the sweep would report full coverage of an axis
    // that never exercises one of its members. Pin each label to its request.
    for (label, event) in Self.events {
      switch (label, event) {
      case ("hidden", .pipeline(.hidden)),
        ("recording", .pipeline(.recording(audioLevel: _))),
        ("processing", .pipeline(.processing(phase: _))),
        ("clipboardFallback", .pipeline(.clipboardFallback)),
        ("accessibilityToast", .pipeline(.accessibilityToast)),
        ("warning", .pipeline(.warning(reason: _))),
        ("error", .pipeline(.error(reason: _))),
        ("advisory", .pipeline(.advisory(reason: _))),
        ("interruption", .pipeline(.interruption(reason: _))),
        ("passiveChip", .pipeline(.passiveChip(payload: _))),
        ("cachingModel", .pipeline(.cachingModel(engineLabel: _))),
        ("engineReady", .pipeline(.engineReady)),
        ("recoveringLastRecording", .pipeline(.recoveringLastRecording)),
        ("recoverySucceeded", .pipeline(.recoverySucceeded)),
        ("bluetoothAwareness.pipelineRoute", .pipeline(.bluetoothAwareness)),
        ("escapeRecovery", .pipeline(.escapeRecovery(transcriptID: _))),
        ("bluetoothAwareness.featureRoute", .bluetoothAwareness),
        ("importStatus.featureRoute", .importStatus(message: _)):
        break
      default:
        Issue.record("\(label) is paired with the wrong request")
      }
    }
  }

  private static func isFeatureRoute(_ event: OverlayEvent) -> Bool {
    switch event {
    case .importStatus, .bluetoothAwareness: return true
    default: return false
    }
  }

  /// `.hidden` from an empty slot is a genuine no-op, so "admitted and changed
  /// nothing" is the correct outcome there rather than a failure.
  private static func isEmptying(_ event: OverlayEvent) -> Bool {
    if case .pipeline(.hidden) = event { return true }
    return false
  }
}
