import Foundation
import Testing

@testable import EnviousWisprCore

// TranscriptPolishService lives in EnviousWisprPipeline which has heavy transitive
// dependencies (WhisperKit C modules) that the test target cannot link.
// Service behavior is validated via rebuild-relaunch + wispr-eyes UAT.
//
// This file tests the supporting types that live in Core.

@Suite("EnhancementError")
struct EnhancementErrorTests {

  @Test("error is scoped to transcript ID")
  func errorScoping() {
    let id = UUID()
    let error = EnhancementError(transcriptID: id, message: "test error")
    #expect(error.transcriptID == id)
    #expect(error.message == "test error")
  }

  @Test("different transcript IDs are distinct")
  func distinctTranscripts() {
    // #881 TO-5: pin that each error carries EXACTLY the id + message it was
    // constructed with. The old test asserted only `id1 != id2`, where the
    // distinctness came from stdlib UUID() uniqueness, not from any
    // EnhancementError behavior — it passed even if the init hard-coded a
    // constant id, swapped fields, or dropped the message. These per-instance
    // assertions catch all of those; distinctness then follows from our
    // faithful per-instance storage.
    let id1 = UUID()
    let id2 = UUID()
    let error1 = EnhancementError(transcriptID: id1, message: "error 1")
    let error2 = EnhancementError(transcriptID: id2, message: "error 2")
    #expect(error1.transcriptID == id1)
    #expect(error1.message == "error 1")
    #expect(error2.transcriptID == id2)
    #expect(error2.message == "error 2")
    #expect(error1.transcriptID != error2.transcriptID)
  }
}
