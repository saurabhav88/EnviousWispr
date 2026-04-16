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
    let error1 = EnhancementError(transcriptID: UUID(), message: "error 1")
    let error2 = EnhancementError(transcriptID: UUID(), message: "error 2")
    #expect(error1.transcriptID != error2.transcriptID)
  }
}
