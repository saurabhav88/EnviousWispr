import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// The bijection between `OverlayIntent` and `PillCatalogRequest`, checked
/// rather than intended (#2375 Phase 3, chunk C2).
///
/// **Two mappings exist and they must agree.** `PillCatalogRequest(nonRecording:)`
/// converts an intent into a request; `matchingIntent` converts it back so the
/// catalog can ask `DictationNarrator` — still the sole author of announcement
/// TEXT — for the sentence. Written twice, they are a duplicate-authority risk of
/// exactly the kind this phase exists to remove, so the agreement is a test
/// rather than a comment.
///
/// **Drift Guard, not Product Outcome.** A failure here means our own two
/// mappings disagree, which is a fact about the code and not about what a user
/// sees. The user-facing consequence — the wrong pill, or the wrong sentence — is
/// `PillCatalogParityTests`.
@Suite(.tags(.driftGuard))
struct PillCatalogRoundTripTests {

  /// Every `OverlayIntent` arm, with a payload where it takes one.
  ///
  /// **Hand-written and therefore checked for completeness below.** `OverlayIntent`
  /// is not `CaseIterable` — several arms carry payloads that have no canonical
  /// value — so this list cannot be derived. An array literal is not exhaustive
  /// over an enum, and a new arm silently missing from it would leave the whole
  /// suite passing while covering nothing, so `everyIntentArmIsListed` counts.
  private static let intents: [OverlayIntent] = [
    .hidden,
    .recording(audioLevel: 0),
    .processing(phase: .transcribing),
    .clipboardFallback,
    .accessibilityToast,
    .warning(reason: .polishFailed),
    .error(reason: .asrFailed),
    .advisory(reason: .zeroSignal),
    .interruption(reason: .deviceRemoved),
    .passiveChip(
      payload: LanguageChipPayload(
        lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)),
    .cachingModel(engineLabel: "Parakeet"),
    .engineReady,
    .recoveringLastRecording,
    .recoverySucceeded,
    .bluetoothAwareness,
    .escapeRecovery(transcriptID: UUID()),
  ]

  @Test("every intent except recording round-trips through a catalog request")
  func intentRoundTrip() {
    for intent in Self.intents {
      guard let request = PillCatalogRequest(nonRecording: intent) else {
        // The ONE legal refusal: recording is permanently outside this
        // initialiser's domain, because a recording request needs a resolved
        // design and an intent alone has not resolved one.
        #expect(
          Self.isRecording(intent),
          "PillCatalogRequest(nonRecording:) refused a non-recording intent")
        continue
      }
      #expect(
        request.matchingIntent == intent,
        "the two mappings disagree about this intent")
    }
  }

  @Test("import status is the only request with no matching intent")
  func onlyImportStatusHasNoIntent() {
    #expect(PillCatalogRequest.importStatus(message: "x").matchingIntent == nil)
    for intent in Self.intents where !Self.isRecording(intent) {
      let request = PillCatalogRequest(nonRecording: intent)
      #expect(request?.matchingIntent != nil, "a pipeline-derived request lost its intent")
    }
  }

  /// The completeness floor for the hand-written list above.
  ///
  /// **Sixteen is a measured count, not a guess**: `PipelineVocabulary.swift`
  /// declares sixteen `OverlayIntent` arms. Fifteen of them convert to a request;
  /// the sixteenth is `.recording`, staged out until C3a. Adding an arm to the
  /// enum without adding it here leaves this red.
  @Test("all sixteen intent arms are exercised, and fifteen convert")
  func everyIntentArmIsListed() {
    // **A COUNT IS NOT A SET, and a count was what this asserted.** Sixteen
    // entries can contain a duplicate while omitting another arm, so the list
    // would read complete while covering fifteen. Name them.
    let names = Self.intents.map(Self.caseName)
    let expected: Set<String> = [
      "hidden", "recording", "processing", "clipboardFallback",
      "accessibilityToast", "warning", "error", "advisory", "interruption",
      "passiveChip", "cachingModel", "engineReady", "recoveringLastRecording",
      "recoverySucceeded", "bluetoothAwareness", "escapeRecovery",
    ]
    #expect(Set(names) == expected, "an OverlayIntent arm is missing or duplicated")
    #expect(names.count == expected.count, "the intent list contains a duplicate")

    let converted = Self.intents.compactMap { PillCatalogRequest(nonRecording: $0) }
    #expect(converted.count == 15, "exactly one arm — recording — may refuse conversion")
    #expect(Self.intents.filter(Self.isRecording).count == 1)
  }

  /// Exhaustive over `OverlayIntent`, so a new arm fails to compile here as well
  /// as in the catalog.
  private static func caseName(_ intent: OverlayIntent) -> String {
    switch intent {
    case .hidden: return "hidden"
    case .recording: return "recording"
    case .processing: return "processing"
    case .clipboardFallback: return "clipboardFallback"
    case .accessibilityToast: return "accessibilityToast"
    case .warning: return "warning"
    case .error: return "error"
    case .advisory: return "advisory"
    case .interruption: return "interruption"
    case .passiveChip: return "passiveChip"
    case .cachingModel: return "cachingModel"
    case .engineReady: return "engineReady"
    case .recoveringLastRecording: return "recoveringLastRecording"
    case .recoverySucceeded: return "recoverySucceeded"
    case .bluetoothAwareness: return "bluetoothAwareness"
    case .escapeRecovery: return "escapeRecovery"
    }
  }

  /// The catalog's own case count, asserted through a value each case produces
  /// rather than through a comment claiming a number.
  ///
  /// **Sixteen non-recording cases, not seventeen.** `bluetoothAwareness` is a
  /// pipeline intent AND was minted a second time by the feature reducer; those
  /// are two routes to one value, and C0 froze both and found them identical. A
  /// seventeenth non-recording case could only be a second Bluetooth arm, which
  /// is the duplicate this chunk deletes.
  @Test("the staged catalog covers sixteen non-recording requests")
  func stagedCaseCount() {
    let requests: [PillCatalogRequest] =
      Self.intents.compactMap { PillCatalogRequest(nonRecording: $0) } + [.importStatus(message: "x")]
    #expect(requests.count == 16)

    // Every one of them resolves, and only `.hidden` empties the slot.
    let withoutDefinition = requests.filter {
      PillCatalog.entry(for: $0, id: PresentationID()).definition == nil
    }
    #expect(withoutDefinition.count == 1, "only hidden may resolve to no definition")
    #expect(withoutDefinition.first == .hidden)
  }

  /// What `stagedCaseCount` cannot see (review r1 finding 3).
  ///
  /// **That test counts a list this file builds, so it is a claim about the list
  /// and not about the enum.** A seventeenth case could be declared in
  /// `PillCatalogRequest` and every other test here would stay green: nothing in
  /// the round-trip reaches a case no intent maps to, and the count would still
  /// read sixteen. Reading the declaration is the only way to ask the enum
  /// itself.
  ///
  /// **Update this set DELIBERATELY.** C3a adds `recording` and this test must go
  /// red first — that is the point of a freeze. It is a lexical read of a small
  /// enum this phase owns, and it fails LOUDLY on a mis-parse (an empty or short
  /// name set cannot equal the expected one), so it has no silent direction.
  @Test("the staged enum declares exactly the expected cases")
  func stagedDeclarationSetIsFrozen() throws {
    let path = "Sources/EnviousWisprAppKit/App/Overlay/PillCatalog.swift"
    let source = try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8)
    let start = try #require(
      source.range(of: "enum PillCatalogRequest: Equatable, Sendable {"),
      "the request enum was renamed or reshaped")
    let tail = source[start.upperBound...]
    let end = try #require(tail.range(of: "\n}"), "the request enum has no closing brace")
    let names = tail[..<end.lowerBound].split(separator: "\n").compactMap { line -> String? in
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("case ") else { return nil }
      return String(text.dropFirst(5).prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }
    // **Updated DELIBERATELY by C3a, which is what this guard is for.** It went
    // red the moment `.recording` was added, which is the designed behaviour: the
    // set is frozen so a case cannot arrive unnoticed, and unfreezing it is an
    // edit someone has to make on purpose.
    let expected: Set<String> = [
      "recording",
      "hidden", "processing", "clipboardFallback", "accessibilityToast", "warning",
      "error", "advisory", "interruption", "passiveChip", "cachingModel",
      "engineReady", "recoveringLastRecording", "recoverySucceeded",
      "bluetoothAwareness", "escapeRecovery", "importStatus",
    ]
    #expect(Set(names) == expected, "the catalog case set changed")
    #expect(names.count == expected.count, "a catalog case is duplicated")
  }

  private static func isRecording(_ intent: OverlayIntent) -> Bool {
    if case .recording = intent { return true }
    return false
  }
}
