import CoreGraphics
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// **Table 1 — definition parity, read from the catalog and checked against the
/// FROZEN oracle** (#2375 Phase 3, chunk C2).
///
/// Every expectation here comes from `FrozenPillParity.rows`, captured by running
/// the shipped reducer at `main` `da103706` before any catalog code existed.
/// Nothing is derived from `PillCatalog`, and that is the whole point: a table
/// that reads its expectations from the code under test proves only
/// self-consistency.
///
/// **Recording is absent, deliberately.** The catalog has no `.recording` case
/// until C3a supplies a resolved design, so its two frozen geometry rows are
/// C3a's and C3b's receipt rather than this chunk's. This suite covers the
/// sixteen non-recording requests.
@Suite(.tags(.productOutcome))
struct PillCatalogParityTests {

  // MARK: - Projection

  /// Project a catalog entry into the fixture's rename-neutral schema.
  ///
  /// **The projection is the risky part of this suite and it fails CLOSED.**
  /// A projection that quietly reported "no notice" for a notice-backed pill
  /// would make several rows pass while asserting nothing, so every enum it
  /// crosses is switched exhaustively and every unknown is a distinct string a
  /// comparison cannot match by accident.
  private static func project(_ entry: PillCatalogEntry, label: String) -> FrozenRow {
    guard let definition = entry.definition else {
      return FrozenRow(
        label: label, hasDefinition: false, contentTag: "none", notice: nil,
        width: nil, fixedHeight: nil, expiry: nil,
        announcement: entry.announcement.map(frozen))
    }
    return FrozenRow(
      label: label, hasDefinition: true,
      contentTag: tag(definition.content),
      notice: frozenNotice(definition.content),
      width: frozen(definition.requestedWidth),
      fixedHeight: definition.reservesFixedHeight,
      expiry: frozen(definition.expiry),
      announcement: entry.announcement.map(frozen))
  }

  private static func tag(_ content: OverlayContent) -> String {
    switch content {
    case .recording: return "recording"
    case .notice: return "notice"
    case .languageChip: return "languageChip"
    case .bluetoothAwareness: return "bluetoothAwareness"
    case .escapeRecovery: return "escapeRecovery"
    }
  }

  private static func frozenNotice(_ content: OverlayContent) -> FrozenNotice? {
    guard case .notice(let notice) = content else { return nil }
    return FrozenNotice(
      kind: name(notice.kind), text: notice.text, secondary: notice.secondaryText,
      severity: name(notice.severity), isMultiline: notice.isMultiline,
      actionLabel: notice.action?.label, actionCase: notice.action.map { name($0.action) })
  }

  private static func name(_ kind: NoticeModel.Kind) -> String {
    switch kind {
    case .processing: return "processing"
    case .notification: return "notification"
    case .accessibilityToast: return "accessibilityToast"
    case .warmingUp: return "warmingUp"
    case .ready: return "ready"
    case .recovery: return "recovery"
    case .importStatus: return "importStatus"
    }
  }

  private static func name(_ severity: NoticeModel.Severity) -> String {
    switch severity {
    case .neutral: return "neutral"
    case .warning: return "warning"
    case .error: return "error"
    case .advisory: return "advisory"
    case .distress: return "distress"
    }
  }

  private static func name(_ action: PillAction) -> String {
    switch action {
    case .grantAccessibility: return "grantAccessibility"
    case .openMicrophoneSettings: return "openMicrophoneSettings"
    case .discardRecovery: return "discardRecovery"
    case .pasteEscapeRecovery: return "pasteEscapeRecovery"
    case .lockLanguage: return "lockLanguage"
    case .dismissChip: return "dismissChip"
    case .acknowledgeBluetoothAwareness: return "acknowledgeBluetoothAwareness"
    case .closeBluetoothAwareness: return "closeBluetoothAwareness"
    case .openBluetoothSettings: return "openBluetoothSettings"
    }
  }

  private static func frozen(_ width: OverlayWidth) -> FrozenWidth {
    switch width {
    case .fixed(let value): return .fixed(value)
    case .measured: return .measured
    }
  }

  private static func frozen(_ expiry: OverlayExpiry) -> FrozenExpiry {
    switch expiry {
    case .untilReplaced: return .untilReplaced
    case .after(let seconds, let pausesOnHover):
      return .after(seconds: seconds, pausesOnHover: pausesOnHover)
    }
  }

  private static func frozen(_ announcement: OverlayAnnouncement) -> FrozenAnnouncement {
    FrozenAnnouncement(text: announcement.text, isHighPriority: announcement.isHighPriority)
  }

  // MARK: - The requests, and the inputs each frozen row was captured with

  /// The sixteen non-recording requests, paired with the frozen row each must
  /// reproduce.
  ///
  /// **The payloads are RECONSTRUCTED from the row labels, and a wrong
  /// reconstruction cannot pass quietly.** The capture recorded which reason it
  /// drove each row with in the label — `warning.polishFailed`,
  /// `interruption.deviceRemoved` — and every reason produces different copy, so
  /// a mis-picked payload fails on the notice text and the announcement rather
  /// than silently matching.
  private static let cases: [(label: String, request: PillCatalogRequest)] = [
    ("hidden", .hidden),
    ("processing.transcribing", .processing(phase: .transcribing)),
    ("clipboardFallback", .clipboardFallback),
    ("accessibilityToast", .accessibilityToast),
    ("warning.polishFailed", .warning(reason: .polishFailed)),
    ("error.asrFailed", .error(reason: .asrFailed)),
    ("advisory.zeroSignal", .advisory(reason: .zeroSignal)),
    ("interruption.deviceRemoved", .interruption(reason: .deviceRemoved)),
    ("passiveChip", .passiveChip(payload: spanishChip)),
    ("cachingModel", .cachingModel(engineLabel: "Parakeet")),
    ("engineReady", .engineReady),
    ("recoveringLastRecording", .recoveringLastRecording),
    ("recoverySucceeded", .recoverySucceeded),
    ("bluetoothAwareness.pipelineRoute", .bluetoothAwareness),
    ("escapeRecovery", .escapeRecovery(transcriptID: UUID())),
    ("importStatus.featureRoute", .importStatus(message: "Imported 12 words")),
  ]

  /// The inputs the accessibility composition check drives, and the row label the
  /// Bluetooth duplicate check reads.
  ///
  /// **These exist so the accounting test and the checks consume the SAME data.**
  /// Round 4's finding: a partition built from its own string literals is a copy
  /// of the check's inputs rather than a reference to them, so the two can drift
  /// and the accounting would still report a clean partition over rows nothing
  /// reads. I had recorded that as unclosable without a runtime registry or
  /// source parsing. It is closable with a shared constant.
  private static let accessibilityCompositionCases: [(label: String, showsToast: Bool)] = [
    ("accessibilityNotice.toastShown", true),
    ("accessibilityNotice.toastRefused", false),
  ]

  private static let bluetoothFeatureRowLabel = "bluetoothAwareness.featureRoute"

  // MARK: - Table 1

  @Test("every non-recording request reproduces its frozen definition and announcement")
  func nonRecordingParity() throws {
    for (label, request) in Self.cases {
      guard let expected = FrozenPillParity.rows.first(where: { $0.label == label }) else {
        Issue.record("no frozen row labelled \(label) — the oracle and this table disagree")
        continue
      }
      let observed = Self.project(
        PillCatalog.entry(for: request, id: PresentationID()), label: label)
      #expect(observed == expected, "\(label) drifted from the frozen capture")
    }
  }

  /// **Every row in `FrozenPillParity.rows` is accounted for exactly once: either
  /// covered by this suite or explicitly deferred to C3a.**
  ///
  /// "Spent" was the earlier wording and it over-claimed — `recording` is
  /// deferred, not covered, and a partition that calls a deferral a check is the
  /// same defect one level up from the ones this suite exists to catch.
  ///
  /// This is the strongest completeness claim available here, and it replaces a
  /// bare `rows.count == 20`. A count cannot tell a complete oracle from one with
  /// a duplicate row and a missing one, and — worse — it says nothing at all about
  /// whether this suite USES what C0 froze. Twenty rows could sit in the fixture
  /// with four of them asserted nowhere, which is exactly what round 1 found for
  /// the two accessibility rows.
  ///
  /// Read the partition as the suite's own map: sixteen non-recording requests in
  /// the parity sweep, the second Bluetooth route in the duplicate check, both
  /// composition outcomes in the accessibility check, and recording deferred to
  /// C3a because the catalog cannot answer it yet.
  @Test("every table row is either covered exactly once or explicitly deferred")
  func theOracleIsFullyAccountedFor() {
    let frozen = Set(FrozenPillParity.rows.map(\.label))
    #expect(
      frozen.count == FrozenPillParity.rows.count,
      "the oracle has a duplicate label, so a row is unaddressable")

    let sweep = Set(Self.cases.map(\.label))
    #expect(sweep.count == Self.cases.count, "this suite's request list has a duplicate label")

    let duplicateCheck: Set<String> = [Self.bluetoothFeatureRowLabel]
    let compositionCheck = Set(Self.accessibilityCompositionCases.map(\.label))
    // Deferred, with its reason: the catalog has no `.recording` case until C3a
    // supplies a resolved design, so its row is C3a's receipt.
    let deferredToC3a: Set<String> = ["recording"]

    let partitions = [sweep, duplicateCheck, compositionCheck, deferredToC3a]
    let accounted = partitions.reduce(into: Set<String>()) { $0.formUnion($1) }

    // ONE literal, never a concatenation: a `Comment` is built from a string
    // literal, so `"a" + "b"` does not type-check as an expectation message.
    #expect(
      accounted == frozen,
      "orphaned frozen rows: \(frozen.subtracting(accounted).sorted()) — claims with no frozen row: \(accounted.subtracting(frozen).sorted())"
    )
    // **Disjointness over ALL FOUR, not just `sweep` against each other one.**
    // Comparing one partition to the rest leaves the rest free to overlap, which
    // is how the earlier version let the Bluetooth pipeline route be counted by
    // two checks while reading as a partition. Summing counts and comparing to
    // the union tests every pair at once.
    #expect(
      partitions.reduce(0) { $0 + $1.count } == accounted.count,
      "a frozen row is assigned to more than one partition")
  }

  /// The two frozen rows an entry-by-entry table cannot reach (review r1 finding 1).
  ///
  /// **`reduceAccessibilityNotice` is a COMPOSITION of two catalog requests, and
  /// its whole point is that the halves come from different ones.** When
  /// eligibility refuses the toast it draws the CLIPBOARD definition and retains
  /// the ACCESSIBILITY announcement — the only place in the system where that is
  /// legitimate. Asserting the toast entry and the clipboard entry separately
  /// proves each is right and says nothing about the substitution, so C0 froze
  /// the composed outcome in both eligibility states and this is where those two
  /// rows are spent.
  @Test("both accessibility outcomes reproduce their frozen rows")
  func accessibilityCompositionParity() throws {
    for (label, showsToast) in Self.accessibilityCompositionCases {
      var reducer = OverlayReducer()
      let plan = reducer.reduceAccessibilityNotice(showingToast: { showsToast })
      let expected = try #require(
        FrozenPillParity.rows.first { $0.label == label },
        "no frozen row labelled \(label)")
      let observed = Self.project(
        PillCatalogEntry(definition: plan.presentation, announcement: plan.announcement),
        label: label)
      #expect(observed == expected, "\(label) drifted from the frozen capture")
    }
  }

  /// The duplicate G2 removes, asserted as an OUTCOME rather than as an absence.
  ///
  /// C0 froze the Bluetooth card twice because the base revision minted it twice —
  /// once through the pipeline switch and once inline in the feature reducer.
  /// After C2 there is one arm, so the single catalog request must reproduce both
  /// frozen rows. A test asserting only that the inline mint is gone would pass
  /// against an arm that returns the wrong card.
  ///
  /// **This test covers the FEATURE route only, and that is not a weakening.**
  /// The pipeline route is already covered by the parity sweep, which issues the
  /// same `.bluetoothAwareness` request. Checking both here made the row covered
  /// twice, so the accounting above could call itself a partition while it was
  /// not one. Both frozen rows are still reproduced by the single arm; the claim
  /// is distributed across two checks instead of overlapping in one.
  @Test("the single catalog arm reproduces the frozen feature Bluetooth route")
  func bluetoothDuplicateIsGone() throws {
    let row = try #require(
      FrozenPillParity.rows.first { $0.label == Self.bluetoothFeatureRowLabel },
      "the oracle lost the second base-revision route, which is where the duplicate was visible")
    let observed = Self.project(
      PillCatalog.entry(for: .bluetoothAwareness, id: PresentationID()), label: row.label)
    #expect(observed == row, "the feature route is not what the single catalog arm produces")
  }

  /// `.hidden` is the shape a definition-only return could not have carried.
  @Test("hidden empties the slot and still announces")
  func hiddenAnnouncesWithoutDefinition() {
    let entry = PillCatalog.entry(for: .hidden, id: PresentationID())
    #expect(entry.definition == nil, "hidden must empty the slot")
    #expect(entry.announcement?.text == "Recording complete")
    #expect(entry.announcement?.isHighPriority == false)
  }

  /// Import status is the one silent request, and the fixture asserts nil rather
  /// than omitting the row.
  @Test("import status has a definition and says nothing")
  func importStatusIsSilent() {
    let entry = PillCatalog.entry(
      for: .importStatus(message: "Imported 12 words"), id: PresentationID())
    #expect(entry.definition != nil, "import status must occupy the slot")
    #expect(entry.announcement == nil, "import status announces nothing")
  }

  /// The id travels onto the definition rather than being looked up afterwards.
  @Test("the catalog stamps the identity it was given")
  func identityTravels() {
    let id = PresentationID(rawValue: UUID())
    let entry = PillCatalog.entry(for: .engineReady, id: id)
    #expect(entry.definition?.id == id)
  }

  private static let spanishChip = LanguageChipPayload(
    lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)
}
