import Foundation
import Testing

@testable import EnviousWisprCore

/// `Transcript` gains optional `recoverySessionID` / `isRecovered` (#1063 PR0).
/// Both must be decode-safe: a pre-#1063 JSON file on disk (no such keys) must
/// still decode, with the fields defaulting to nil — otherwise every existing
/// transcript in a user's History would fail to load.
@Suite("Transcript recovery fields (#1063)")
struct TranscriptRecoveryFieldsTests {

  @Test("a pre-#1063 JSON decodes with the new fields nil")
  func legacyJSONDecodes() throws {
    let id = UUID().uuidString
    let legacy = """
      {"id":"\(id)","text":"hello world","duration":1.5,"processingTime":0.2,\
      "backendType":"parakeet","createdAt":12345.0}
      """
    let transcript = try JSONDecoder().decode(Transcript.self, from: Data(legacy.utf8))
    #expect(transcript.text == "hello world")
    #expect(transcript.recoverySessionID == nil)
    #expect(transcript.isRecovered == nil)
  }

  @Test("the new fields round-trip through Codable")
  func newFieldsRoundTrip() throws {
    let original = Transcript(
      text: "recovered take", recoverySessionID: "session-42", isRecovered: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)
    #expect(decoded.recoverySessionID == "session-42")
    #expect(decoded.isRecovered == true)
  }

  @Test("a default transcript has nil recovery fields")
  func defaultsAreNil() {
    let transcript = Transcript(text: "x")
    #expect(transcript.recoverySessionID == nil)
    #expect(transcript.isRecovered == nil)
  }
}
