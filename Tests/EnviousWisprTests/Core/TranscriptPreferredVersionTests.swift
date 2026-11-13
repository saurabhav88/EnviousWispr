import EnviousWisprCore
import Foundation
import Testing

/// A dictation's History preference (#3147 §3.4): which stored text History shows and delivers.
/// Older rows have no preference and read as polished; imports and meetings keep `displayText`.
/// Class: `.productOutcome` — the text a person sees and copies from a History card.
@Suite("Transcript preferred version (#3147)", .tags(.productOutcome))
struct TranscriptPreferredVersionTests {

  @Test("a row saved before preferences decodes as polished and shows its polished text")
  func legacyRowDecodesAsPolished() throws {
    let legacy = Transcript(text: "um raw", polishedText: "Raw.")
    var json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
    json.removeValue(forKey: "preferredVersion")
    let decoded = try JSONDecoder().decode(
      Transcript.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.preferredVersion == nil)
    #expect(decoded.effectivePreferredVersion == .polished)
    #expect(decoded.historyText == "Raw.")
  }

  @Test("original gives the words before AI polish; polished falls back like displayText")
  func resolverPicksStoredText() {
    let polished = Transcript(text: "um raw", polishedText: "Raw.")
    #expect(polished.preferring(.original).historyText == "um raw")
    #expect(polished.preferring(.polished).historyText == "Raw.")
    let processedOnly = Transcript(text: "um raw", processedText: "Processed.")
    #expect(processedOnly.historyText == "Processed.")
    let rawOnly = Transcript(text: "just raw")
    #expect(rawOnly.historyText == "just raw")
  }

  @Test("imports and meetings keep displayText whatever the preference")
  func importsAndMeetingsKeepDisplayText() {
    let imported = Transcript(text: "raw", polishedText: "Doc.", importedFileName: "a.m4a")
    #expect(imported.preferring(.original).historyText == "Doc.")
    let meeting = Transcript(text: "raw", polishedText: "Notes.", meetingID: UUID())
    #expect(meeting.preferring(.original).historyText == "Notes.")
  }

  @Test("the preference survives a save and reload and changes nothing else")
  func preferencePersistsAlone() throws {
    let row = Transcript(text: "um raw", polishedText: "Raw.", llmProvider: "openai")
    let preferred = row.preferring(.original)
    let decoded = try JSONDecoder().decode(
      Transcript.self, from: JSONEncoder().encode(preferred))
    #expect(decoded.preferredVersion == .original)
    #expect(decoded.text == row.text)
    #expect(decoded.polishedText == row.polishedText)
    #expect(decoded.llmProvider == row.llmProvider)
    #expect(decoded.displayText == row.displayText)
  }
}
