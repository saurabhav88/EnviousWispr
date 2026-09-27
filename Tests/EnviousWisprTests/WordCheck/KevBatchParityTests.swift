import Foundation
import Testing

@testable import EnviousWisprWordCheck

/// The real word-check model on this Mac (#3242). A take's questions are answered in ONE
/// right-padded batch; the Swift/Python parity spike answered one question per pass, so this is
/// the check that padding changes no answer. When this fails, a take with several learned-word
/// spots gets different decisions than the same spots asked alone. Runs where the model has been
/// downloaded (`~/Library/Application Support/EnviousWispr/Models/word-check`); skipped elsewhere,
/// including CI, which has no model.
@Suite("Kev word check: batched answers equal single answers (#3242)", .tags(.productOutcome))
struct KevBatchParityTests {
  static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("EnviousWispr/Models/word-check", isDirectory: true)
  static var modelPresent: Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent("kev-contract.json").path)
  }

  /// Lengths deliberately uneven so every row but the longest is padded.
  static let states = [
    KevEncoding.stateText(
      listedWord: "Tuist", asWritten: "Twist builds our Xcode project from Swift manifests.",
      withListedWord: "Tuist builds our Xcode project from Swift manifests.", changedFrom: "Twist"),
    KevEncoding.stateText(
      listedWord: "Tuist", asWritten: "Add a twist of lime.",
      withListedWord: "Add a Tuist of lime.", changedFrom: "twist"),
    KevEncoding.stateText(
      listedWord: "Qwen", asWritten: "We benchmarked quen against the older checkpoint last night before the demo.",
      withListedWord: "We benchmarked Qwen against the older checkpoint last night before the demo.",
      changedFrom: "quen"),
    KevEncoding.stateText(
      listedWord: "Saurabh", asWritten: "Ask Sarab.", withListedWord: "Ask Saurabh.", changedFrom: "Sarab"),
    KevEncoding.stateText(
      listedWord: "Sol", asWritten: "Saul Bellow wrote the novel.",
      withListedWord: "Sol Bellow wrote the novel.", changedFrom: "Saul"),
  ]

  @Test("five uneven questions in one batch answer as they do alone, same side of the cutoff",
    .enabled(if: modelPresent))
  func batchedEqualsSingle() async throws {
    let model = try await KevWordCheckModel(folder: Self.folder)
    try await model.warmUp()
    let batched = try await model.probabilities(forStates: Self.states)
    let cutoff = await model.contract.threshold
    #expect(batched.count == Self.states.count)
    for (index, state) in Self.states.enumerated() {
      let single = try await model.probabilities(forStates: [state])[0]
      #expect(
        abs(single - batched[index]) < 0.02,
        "question \(index): alone \(single), batched \(batched[index])")
      #expect(
        (single >= cutoff) == (batched[index] >= cutoff),
        "question \(index) crosses the cutoff \(cutoff) when batched: alone \(single), batched \(batched[index])")
    }
    // The obvious fix is approved and the everyday use is kept (live UAT, 2026-09-27).
    #expect(batched[0] >= cutoff)
    #expect(batched[1] < cutoff)
  }
}
