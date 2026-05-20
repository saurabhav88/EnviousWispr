import Foundation
import Testing

@testable import EnviousWispr

/// Unit tests for `LastRecordingResult` (PR7 of epic #763).
///
/// Trivial coverage by design: this home is a single-field observable
/// storage; the former root state's existing state-change closures push to
/// `polishError`, and `toggleRecording` resets it on a new recording
/// start. The full reset/cancel/failure matrix is exercised by Live UAT,
/// not unit tests — pushing the former root state's state-change closures from a unit
/// test would require constructing it (which pulls in real audio capture,
/// ASR, and pipelines).
@MainActor
@Suite("LastRecordingResult")
struct LastRecordingResultTests {

  @Test("init leaves polishError nil")
  func initialStateIsNil() {
    let result = LastRecordingResult()
    #expect(result.polishError == nil)
  }

  @Test("setting polishError reads back verbatim")
  func setAndReadPolishError() {
    let result = LastRecordingResult()
    result.polishError = "polish timeout"
    #expect(result.polishError == "polish timeout")
  }

  @Test("clearing polishError resets to nil")
  func clearPolishError() {
    let result = LastRecordingResult()
    result.polishError = "failure"
    result.polishError = nil
    #expect(result.polishError == nil)
  }
}
