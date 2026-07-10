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
    #expect(transcript.inputDeviceWasRemoved == nil)
  }

  // MARK: - #1408 `inputDeviceWasRemoved`

  /// The additive-optional pattern again. Rollback safety depends on this: a
  /// reverted build must decode forward-written JSON by ignoring the unknown key,
  /// and a pre-#1408 file must decode with `inputDeviceWasRemoved` nil.
  @Test("a pre-#1408 JSON decodes with inputDeviceWasRemoved nil")
  func preInterruptedJSONDecodes() throws {
    let id = UUID().uuidString
    let legacy = """
      {"id":"\(id)","text":"hello world","duration":1.5,"processingTime":0.2,\
      "backendType":"parakeet","createdAt":12345.0,"isRecovered":false}
      """
    let transcript = try JSONDecoder().decode(Transcript.self, from: Data(legacy.utf8))
    #expect(transcript.text == "hello world")
    #expect(transcript.isRecovered == false)
    #expect(transcript.inputDeviceWasRemoved == nil)
  }

  @Test("inputDeviceWasRemoved round-trips through Codable")
  func interruptedRoundTrips() throws {
    let original = Transcript(text: "cut short", isRecovered: false, inputDeviceWasRemoved: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)
    #expect(decoded.inputDeviceWasRemoved == true)
    #expect(decoded.isRecovered == false)
  }

  /// `nil` and `false` are different answers and the History badge must not
  /// conflate them: a spool-recovered transcript genuinely does not know whether
  /// the input device was removed, so it carries nil, and the badge (which tests
  /// `== true`) stays hidden without ever claiming the recording was clean.
  @Test("nil is unknown, not false")
  func nilIsUnknownNotFalse() throws {
    let unknown = Transcript(text: "replayed from a spool", isRecovered: true)
    let data = try JSONEncoder().encode(unknown)
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)
    #expect(decoded.inputDeviceWasRemoved == nil)
    #expect(decoded.inputDeviceWasRemoved != false)
    #expect((decoded.inputDeviceWasRemoved == true) == false, "the badge must not render")
  }
}
