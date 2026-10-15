import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A: the two engine cards and the selected-engine summary have one owner that the
/// Settings Map will reuse. Expected text, keys and icons are typed from the cards as they
/// shipped before #3482 (SpeechEngineSettingsView at cdd03bf9), not read from the code under
/// test.
@Suite("Engine choice presentation (#3482)", .tags(.driftGuard))
struct EngineChoicePresentationTests {
  typealias Presentation = EngineChoicePresentation

  @Test("engines are Fast then All Languages, and every backend has a card")
  func orderAndLookup() {
    #expect(Presentation.choices.map(\.backend) == [.parakeet, .whisper])
    #expect(Presentation.choice(for: .parakeet, parakeetModel: "Parakeet v3").backend == .parakeet)
    #expect(Presentation.choice(for: .whisper, parakeetModel: "Parakeet v3").backend == .whisper)
    #expect(Presentation.choices.map(\.icon) == ["bolt.fill", "globe"])
  }

  @Test("each card keeps its shipped English, spec table included")
  func shippedEnglish() {
    func card(_ c: Presentation.Choice) -> [[UInt8]] {
      ([String(localized: c.title), String(localized: c.tagline)]
        + c.specs.flatMap { [String(localized: $0.label), $0.value.resolved] }).map {
          Array($0.utf8)
        }
    }
    // #3792: Download size joins the table and the times leave it for their own row.
    let fast = [
      "Fast", "Pick this for everyday English and European dictation.",
      "Model", "Parakeet v3", "Download size", "483 MB", "Languages", "25 European languages",
      "Runs on", "Apple Neural Engine",
    ].map { Array($0.utf8) }
    let all = [
      "All Languages", "Pick this for other languages or the toughest audio.",
      "Model", "Whisper Large v3 Turbo", "Download size", "886 MB", "Languages", "99+ languages",
      "Runs on", "Apple GPU",
    ].map { Array($0.utf8) }
    #expect(card(Presentation.choice(for: .parakeet, parakeetModel: "Parakeet v3")) == fast)
    #expect(card(Presentation.choice(for: .whisper, parakeetModel: "Parakeet v3")) == all)
  }

  @Test("titles and taglines keep their catalog keys; model names stay verbatim")
  func keysAndModelNames() {
    #expect(Presentation.choices.map(\.title.key) == ["Fast", "All Languages"])
    #expect(
      Presentation.choices.map(\.tagline.key) == [
        "Pick this for everyday English and European dictation.",
        "Pick this for other languages or the toughest audio.",
      ])
    // #3546: the canonical list the Settings Map reads names the shipped model; screens pass
    // the model this Mac presents.
    #expect(Presentation.choices.map(\.model) == ["Parakeet Ultra", "Whisper Large v3 Turbo"])
    for choice in Presentation.choices {
      guard case .verbatim(let model) = choice.specs.first?.value else {
        Issue.record("the Model row of \(choice.model) is not a verbatim product name")
        continue
      }
      #expect(model == choice.model)
    }
  }

  @Test("the Fast card and summary name the Parakeet model the Mac presents", arguments: [
    "Parakeet v3", "Parakeet Ultra",
  ])
  func fastNamesThePresentedModel(model: String) {
    let fast = Presentation.choice(for: .parakeet, parakeetModel: model)
    #expect(fast.model == model)
    guard case .verbatim(let row) = fast.specs.first?.value else {
      Issue.record("the Model row is not a verbatim product name")
      return
    }
    #expect(row == model)
    #expect(Presentation.choices(parakeetModel: model).first?.model == model)
  }

  @Test("the selected-engine summary reads the same choice and its existing short line")
  func summaryCorrespondence() {
    let fast = Presentation.choice(for: .parakeet, parakeetModel: "Parakeet v3")
    let all = Presentation.choice(for: .whisper, parakeetModel: "Parakeet v3")
    #expect(String(localized: fast.summary) == "For everyday English and European dictation")
    #expect(String(localized: all.summary) == "For other languages or the toughest audio")
    #expect(fast.summary.key == "For everyday English and European dictation")
    #expect(all.summary.key == "For other languages or the toughest audio")
  }

  /// #3792: what the times row says. Expected text is typed from the founder-approved plan,
  /// not read from the code under test. The number format follows the test host's region, which
  /// is English (US) here.
  @Test("each card shows its three transcribe times, the captions and the help")
  func transcribeTimesRow() {
    let fast = Presentation.choice(for: .parakeet, parakeetModel: "Parakeet Ultra")
    let all = Presentation.choice(for: .whisper, parakeetModel: "Parakeet Ultra")
    #expect(fast.times.values == ["0.1 s", "0.3 s", "1 s"])
    #expect(Array(all.times.values.prefix(2)) == ["0.6 s", "0.8 s"])
    #expect(Presentation.timeCaptions.map { String(localized: $0) } == ["short", "medium", "long"])
    #expect(String(localized: Presentation.transcribeTimeLabel) == "Transcribe time")
    let intro =
      "Typical transcription time after you stop speaking. This does not include AI polish or pasting. Short means under 5 seconds of speech, medium about 30 seconds, long about 5 minutes."
    #expect(
      fast.times.help
        == intro
        + " Typical times for people using EnviousWispr. On the oldest supported Macs (M1), about 0.2 s, 0.4 s and 2 s."
    )
    #expect(
      all.times.help == intro + " Measured on a MacBook Pro with M5 Max. Older Macs take longer.")
  }

  /// #3792: a model update that changes a download changes its manifest; the card must follow.
  /// Each size is read from the bundled delivery manifest, an independent source.
  @Test("each card's download size is its delivery manifest's total", arguments: [
    ("Parakeet Ultra", "parakeet-delivery-manifest.json", "632 MB"),
    ("Parakeet v3", "parakeet-v3-retired-manifest.json", "483 MB"),
  ])
  func fastDownloadSizeFollowsTheManifest(model: String, manifest: String, shown: String) throws {
    #expect(Presentation.fastDownloadBytes(parakeetModel: model) == (try Self.totalBytes(manifest)))
    let fast = Presentation.choice(for: .parakeet, parakeetModel: model)
    #expect(fast.specs[1].value.resolved == shown)
  }

  @Test("the All Languages download size is the Whisper manifest's total")
  func whisperDownloadSizeFollowsTheManifest() throws {
    #expect(Presentation.whisperDownloadBytes == (try Self.totalBytes("whisper-delivery-manifest.json")))
    #expect(Presentation.allLanguages.specs[1].value.resolved == "886 MB")
  }

  static func totalBytes(_ manifest: String) throws -> Int64 {
    let data = try Data(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWispr/Resources/\(manifest)"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require((object["totalBytes"] as? NSNumber)?.int64Value)
  }
}
