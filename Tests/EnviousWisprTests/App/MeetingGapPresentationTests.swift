import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #3972 C5: when these fail, a German user sees English "[Could not transcribe ...]" markers in
/// a meeting, a translated marker shifts the words the turns point at, or ordinary words that
/// merely resemble a marker are rewritten.
@MainActor
@Suite("Meeting gap markers in the interface language", .tags(.productOutcome))
struct MeetingGapPresentationTests {
  /// Stand-in German forms. The real German lives in the catalog (checked below); these prove
  /// the recognition and the substitution.
  static let german = MeetingGapPresentation.Forms(
    bounded: { "[DE \($0) bis \($1)]" }, from: { "[DE ab \($0)]" })

  @Test("both marker forms the pass writes are recognised, beside ordinary speech")
  func bothFormsBesideSpeech() {
    let bounded = MeetingTranscriptionJob.missingAudioMarker(.init(startMs: 60_000, endMs: 90_000))
    let from = MeetingTranscriptionJob.missingAudioMarker(.init(startMs: 3_725_000, endMs: nil))
    let failedPiece = MeetingTranscriptionJob.gapMarker(startSample: 0, endSample: 16_000 * 5)
    #expect(bounded.text == "[Could not transcribe 1:00 to 1:30]")
    #expect(from.text == "[Could not transcribe from 1:02:05]")
    let text = "Hello there. \(bounded.text) and then \(from.text) \(failedPiece.text). Thanks."
    #expect(
      MeetingGapPresentation.localized(text, forms: Self.german)
        == "Hello there. [DE 1:00 bis 1:30] and then [DE ab 1:02:05] [DE 0:00 bis 0:05]. Thanks.")
  }

  @Test("words that only resemble a marker are left alone")
  func lookalikesUnchanged() {
    let lookalikes = [
      "Could not transcribe 1:00 to 1:30",
      "[Could not transcribe the call]",
      "[could not transcribe 1:00 to 1:30]",
      "[Could not transcribe 1:00 until 1:30]",
      "[Could not transcribe from soon]",
      "[Could not transcribe 1:0 to 1:30]",
      "[Could not transcribe from 2:00",
    ]
    for text in lookalikes {
      #expect(MeetingGapPresentation.localized(text, forms: Self.german) == text)
    }
  }

  @Test("English stays exactly as stored")
  func englishUnchanged() {
    let text = "[Could not transcribe 1:00 to 1:30] [Could not transcribe from 2:00]"
    #expect(MeetingGapPresentation.localized(text) == text)
  }

  @Test("History's preview, search text and delivery all show the localized markers")
  func historyReadersLocalize() throws {
    let text = "Hi. [Could not transcribe 1:00 to 1:30] Bye. [Could not transcribe from 2:00]"
    let turns = [
      Turn(
        id: "m0-0", speakerId: "mic:you", startMs: 0, endMs: 90_000,
        originalTextRange: 0..<39, wasPolished: true),
      Turn(
        id: "m1-120000", speakerId: "mic:you", startMs: 120_000, endMs: 120_000,
        originalTextRange: 40..<text.utf16.count, wasPolished: true),
    ]
    let row = Transcript(
      text: text, backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
      speakerNames: ["mic:you": "You"], turns: turns, meetingID: UUID())
    let projection = MeetingHistoryPresentation.project(
      row, info: MeetingHistoryInfo(echoTurnIDs: []), showEcho: false, gapForms: Self.german)
    let preview = MeetingHistoryPresentation.previewText(projection)
    #expect(preview == "You: Hi. [DE 1:00 bis 1:30]\n\nYou: Bye. [DE ab 2:00]")
    let delivered = try #require(
      MeetingHistoryPresentation.deliveryText(
        row, projection: projection, timesOn: false, gapForms: Self.german))
    #expect(delivered.contains("[DE 1:00 bis 1:30]"))
    #expect(delivered.contains("[DE ab 2:00]"))
    #expect(!delivered.contains("Could not transcribe"))
    // The stored row and its ranges are untouched.
    #expect(row.text == text)
  }

  @Test("a speaker name shaped like a marker is never rewritten; the turn's own marker is")
  func speakerNamesUntouched() throws {
    let marker = "[Could not transcribe from 2:00]"
    let text = "Hi. \(marker)"
    let turns = [
      Turn(
        id: "m0-0", speakerId: "sys:1", startMs: 0, endMs: 1_000,
        originalTextRange: 0..<text.utf16.count, wasPolished: true)
    ]
    let row = Transcript(
      text: text, backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
      speakerNames: ["sys:1": marker], turns: turns, meetingID: UUID())
    let projection = MeetingHistoryPresentation.project(
      row, info: MeetingHistoryInfo(echoTurnIDs: []), showEcho: false, gapForms: Self.german)
    #expect(MeetingHistoryPresentation.previewText(projection) == "\(marker): Hi. [DE ab 2:00]")
    let delivered = try #require(
      MeetingHistoryPresentation.deliveryText(
        row, projection: projection, timesOn: false, gapForms: Self.german))
    #expect(delivered == "\(marker)\nHi. [DE ab 2:00]")
  }

  @Test("History's rendered meeting turns localize only plain text")
  func renderedTurns() throws {
    let rendered = [
      TranscriptDocumentPresenter.RenderedTurn(
        speakerId: "mic:you", speakerName: "You", timeLabel: "1:00",
        content: .plain("Hi [Could not transcribe from 2:00]"), isUncleaned: false,
        startMs: 60_000)
    ]
    let localized = try #require(MeetingGapPresentation.localized(rendered, forms: Self.german))
    #expect(localized.first?.content == .plain("Hi [DE ab 2:00]"))
    #expect(localized.first?.speakerName == "You")
    #expect(localized.first?.timeLabel == "1:00")
    #expect(localized.first?.startMs == 60_000, "play from here keeps the turn's time")
  }

  @Test("the catalog carries reviewed German for both markers and the echo switch")
  func catalogGerman() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/EnviousWispr/Resources/Localizable.xcstrings")
    let catalog = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    func german(_ key: String) -> (value: String?, state: String?) {
      let unit =
        (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["de"]
        as? [String: Any])?["stringUnit"] as? [String: Any]
      return (unit?["value"] as? String, unit?["state"] as? String)
    }
    // The hidden-everything message names this switch: its German must match exactly.
    #expect(german("Show probable echo").value == "Wahrscheinliches Echo anzeigen")
    for key in ["[Could not transcribe %@ to %@]", "[Could not transcribe from %@]"] {
      let entry = german(key)
      #expect(entry.state == "translated", "\(key)")
      #expect(entry.value?.hasPrefix("[") == true && entry.value?.hasSuffix("]") == true, "\(key)")
      // Every time the English carries reaches the German (`%@`, or numbered `%1$@`).
      let placeholder = /%(?:\d+\$)?@/
      #expect(
        entry.value.map { $0.matches(of: placeholder).count } == key.matches(of: placeholder).count,
        "\(key)")
    }
  }
}
