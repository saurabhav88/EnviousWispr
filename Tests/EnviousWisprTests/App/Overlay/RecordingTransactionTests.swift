import CoreGraphics
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// **Table 3a and Table 3ab: the recording transaction** (#2375 Phase 3, chunk
/// C3a).
///
/// Two properties, and they pull in opposite directions. A prepared transition
/// must survive events that cannot conflict with it, or a rare reentrancy becomes
/// a dictation that shows nothing — and `CLAUDE.md` puts "dictation works 100% of
/// the time it physically can" above every other audio decision. It must be
/// discarded by events that CAN conflict, or an older pill overwrites a newer
/// one.
@Suite(.tags(.productOutcome))
struct RecordingTransactionTests {

  private static func reducerWithLiveRecording(
    design: RecordingPillDesign = .classic
  ) -> OverlayReducer {
    var r = OverlayReducer()
    r.startRecordingForTests(audioLevel: 0.3, design: design)
    return r
  }

  // MARK: - Table 3a — morph preservation

  /// **Every same-id morph preserves the resolved design.** Without this a
  /// hands-free lock could silently drop a live pill back to the other design's
  /// geometry mid-recording, which is a visible resize the user did not ask for.
  ///
  /// The design is part of the recording content case, so a morph that dropped it
  /// would not compile — this asserts the OUTCOME anyway, because "it compiles"
  /// is a claim about the code and this is a claim about the pill.
  @Test(
    "all five morphs preserve identity, design and geometry",
    arguments: RecordingPillDesign.allCases)
  func morphsPreserveDesign(design: RecordingPillDesign) throws {
    var r = Self.reducerWithLiveRecording(design: design)
    let original = try #require(r.state.current)

    func check(_ plan: OverlayPlan, _ what: String) throws {
      let after = try #require(plan.presentation, "\(what) produced no presentation")
      #expect(after.id == original.id, "\(what) changed the presentation id")
      #expect(after.recordingDesign == design, "\(what) dropped the resolved design")
      #expect(after.requestedWidth == original.requestedWidth, "\(what) changed the width")
      #expect(
        after.reservesFixedHeight == original.reservesFixedHeight,
        "\(what) changed the reserved height")
    }

    // 1. audio level
    try check(r.startRecordingForTests(audioLevel: 0.9, design: design), "an audio-level morph")
    // 2. hands-free lock on
    try check(r.reduce(.lockStateChanged(true)), "locking")
    // 3. lock off
    try check(r.reduce(.lockStateChanged(false)), "unlocking")
    // 4. in-panel notice arriving
    try check(
      r.reduce(.inPanelNotice(.approachingCap, dismissAfter: nil)), "an in-panel notice")
    // 5. that notice clearing
    let id = try #require(r.state.current?.id)
    try check(r.reduce(.inPanelNoticeExpiryFired(id)), "an in-panel notice clearing")
  }

  /// The morph path reads NOTHING: no capability, no selections, no position. It
  /// cannot, because it never reaches RESOLVE.
  @Test("a morph is reported as a morph, never as a fresh preparation")
  func morphSkipsPrepare() {
    var r = Self.reducerWithLiveRecording()
    switch r.prepareRecording(audioLevel: 0.7) {
    case .morphed(let plan):
      #expect(plan.presentation?.recordingDesign == .classic)
    case .prepared:
      Issue.record(
        "a live recording was treated as a fresh one, so its design would be re-resolved")
    case .refused:
      Issue.record("a live recording refused its own audio-level update")
    }
  }

  // MARK: - PREPARE mutates nothing

  /// **A caller that prepares and never commits leaves the reducer as it found
  /// it.** That is what makes a discard safe rather than merely tidy.
  @Test("preparing a fresh recording publishes nothing and mutates nothing")
  func prepareIsPure() throws {
    var r = OverlayReducer()
    _ = r.reduce(.pipeline(.engineReady))
    let before = r.state.current
    let revisionBefore = r.recordingReconciliationSnapshot.revision

    guard case .prepared(let token) = r.prepareRecording(audioLevel: 0.4) else {
      Issue.record("expected a fresh preparation")
      return
    }

    #expect(r.state.current == before, "PREPARE changed the slot")
    #expect(
      r.recordingReconciliationSnapshot.revision == revisionBefore,
      "PREPARE advanced the slot revision, so it would invalidate its own token")
    #expect(
      token.effects.contains(.recordingStateChanged(true)),
      "the bridge would never be told the recording started")
  }

  // MARK: - Table 3ab — the invalidated transition

  /// **Assert the OUTCOME — which definition is current — never a flag saying the
  /// token was invalidated.** A flag is satisfied by a token that was marked and
  /// committed anyway.
  @Test("a newer event between PREPARE and COMMIT discards the older transition")
  func reentrantEventDiscardsTheStaleTransition() throws {
    var r = OverlayReducer()
    guard case .prepared(let token) = r.prepareRecording(audioLevel: 0.4) else {
      Issue.record("expected a fresh preparation")
      return
    }

    // The reentrant winner: a terminal notice takes the slot while the recording
    // is still being resolved.
    let winner = r.reduce(.pipeline(.error(reason: .asrFailed)))
    let winningDefinition = try #require(winner.presentation)

    let entry = PillCatalog.entry(
      for: .recording(audioLevel: token.audioLevel, design: .classic), id: token.id)
    let committed = r.commitRecording(token, definition: try #require(entry.definition))

    #expect(committed == nil, "the stale transition was committed over a newer event")
    #expect(
      r.state.current == winningDefinition,
      "the newer event's pill is not the one on screen")
    #expect(r.state.current?.id != token.id, "the stale token's identity reached the slot")
  }

  /// **The narrowing, asserted from the surviving side.** A lock-only change
  /// cannot conflict with a fresh recording, so it may not discard one — the
  /// alternative is a recording pill that never appears.
  ///
  /// Hover is tested separately, against an incumbent retained during PREPARE.
  ///
  /// **An earlier version of this comment claimed hover could not occur in this
  /// window at all, on the reasoning that a PREPARED transition has published no
  /// presentation to hover over.** That is false and `prepareIsPure` above
  /// disproves it in the same file: PREPARE mutates nothing, so whatever occupied
  /// the slot is still there and still hoverable.
  @Test("a lock-only change does NOT invalidate a prepared recording")
  func lockOnlyChangeDoesNotInvalidate() throws {
    var r = OverlayReducer()
    guard case .prepared(let token) = r.prepareRecording(audioLevel: 0.4) else {
      Issue.record("expected a fresh preparation")
      return
    }
    _ = r.reduce(.lockStateChanged(true))

    let entry = PillCatalog.entry(
      for: .recording(audioLevel: token.audioLevel, design: .classic), id: token.id)
    let plan = r.commitRecording(token, definition: try #require(entry.definition))
    #expect(plan != nil, "a lock-only change discarded a recording it cannot conflict with")
    #expect(r.state.current?.id == token.id, "a lock-only change cost the user their pill")
  }

  /// The other half of the narrowing, against the incumbent PREPARE leaves in
  /// place.
  @Test("hovering the incumbent does not invalidate a prepared recording")
  func incumbentHoverDoesNotInvalidate() throws {
    var r = OverlayReducer()
    // **A HOVER-PAUSABLE incumbent, and that is the whole fixture.** `.engineReady`
    // has `pausesOnHover: false`, so `reduceHover` returns `.noChange` and the
    // hover never happens — this case passed with hover handling entirely broken.
    // Escape Recovery pauses on hover, so the event is genuinely accepted.
    let incumbent = try #require(
      r.reduce(.pipeline(.escapeRecovery(transcriptID: UUID()))).presentation)
    guard case .prepared(let token) = r.prepareRecording(audioLevel: 0.4) else {
      Issue.record("expected a fresh preparation")
      return
    }

    let hover = r.reduce(.hoverChanged(incumbent.id, true))
    #expect(r.state.isHovered, "the fixture never entered the hovered state")
    #expect(hover.expiryCommand == .cancel, "the hover event was not accepted")

    let definition = try #require(
      PillCatalog.entry(
        for: .recording(audioLevel: token.audioLevel, design: .classic), id: token.id
      ).definition)

    #expect(
      r.commitRecording(token, definition: definition) != nil,
      "a hover on the incumbent discarded a recording it cannot conflict with")
    #expect(r.state.current?.id == token.id, "the hover cost the user their recording pill")
  }

  /// **COMMIT reads the CURRENT lock, not one captured at PREPARE.** That is what
  /// makes the narrowing above safe rather than merely defensible: a lock arriving
  /// inside the window is preserved in the pill that commits.
  @Test("a lock arriving inside the window is applied to the committed pill")
  func lockInsideTheWindowIsPreserved() throws {
    var r = OverlayReducer()
    guard case .prepared(let token) = r.prepareRecording(audioLevel: 0.4) else {
      Issue.record("expected a fresh preparation")
      return
    }
    _ = r.reduce(.lockStateChanged(true))

    let entry = PillCatalog.entry(
      for: .recording(audioLevel: token.audioLevel, design: .classic), id: token.id)
    _ = r.commitRecording(token, definition: try #require(entry.definition))

    guard case .recording(_, let isLocked, _, _)? = r.state.current?.content else {
      Issue.record("no recording is current")
      return
    }
    #expect(isLocked, "hands-free lock was lost by the transaction that raced it")
  }

  /// A slot change DOES invalidate, and this is the paired half of the narrowing.
  @Test("a slot change between PREPARE and COMMIT does invalidate")
  func slotChangeInvalidates() throws {
    var r = OverlayReducer()
    guard case .prepared(let token) = r.prepareRecording(audioLevel: 0.4) else {
      Issue.record("expected a fresh preparation")
      return
    }
    _ = r.reduce(.pipeline(.engineReady))

    let entry = PillCatalog.entry(
      for: .recording(audioLevel: token.audioLevel, design: .classic), id: token.id)
    #expect(
      r.commitRecording(token, definition: try #require(entry.definition)) == nil,
      "a real slot conflict was committed over")
  }

  // MARK: - The reconciliation snapshot

  /// The snapshot is what the bounded loop reads, so it must actually track the
  /// two things the loop compares.
  @Test("the reconciliation snapshot tracks the slot and whether a recording is up")
  func snapshotTracksTheWorld() {
    var r = OverlayReducer()
    let idle = r.recordingReconciliationSnapshot
    #expect(idle.isRecording == false)

    r.startRecordingForTests(audioLevel: 0.2)
    let recording = r.recordingReconciliationSnapshot
    #expect(recording.isRecording, "a live recording is not reported as one")
    #expect(recording.revision != idle.revision, "taking the slot did not move the revision")

    _ = r.reduce(.pipeline(.hidden))
    let after = r.recordingReconciliationSnapshot
    #expect(after.isRecording == false, "an emptied slot still reports a recording")
    #expect(after.revision != recording.revision, "emptying the slot did not move the revision")
  }

  /// **The narrowing, at the level the loop reads it.** A hover must not move the
  /// slot revision, or every hover would invalidate a prepared recording.
  @Test("a hover does not move the slot revision")
  func hoverDoesNotMoveTheSlotRevision() throws {
    var r = Self.reducerWithLiveRecording()
    let id = try #require(r.state.current?.id)
    let before = r.recordingReconciliationSnapshot.revision

    _ = r.reduce(.hoverChanged(id, true))
    #expect(
      r.recordingReconciliationSnapshot.revision == before,
      "a hover advanced the slot revision, which would discard prepared recordings")

    _ = r.reduce(.hoverChanged(id, false))
    #expect(r.recordingReconciliationSnapshot.revision == before)
  }
}
