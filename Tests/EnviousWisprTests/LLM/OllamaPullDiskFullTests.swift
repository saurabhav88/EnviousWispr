import Foundation
import Testing

@testable import EnviousWisprLLM

/// When this fails, a user whose disk filled during a local model download is told the
/// download failed instead of that the disk is full, or the reverse.
///
/// The check reads the error's code or Ollama's own message, never `localizedDescription`,
/// which follows the app's language (#3142).
@Suite(.tags(.productOutcome))
struct OllamaPullDiskFullTests {

  @Test("Ollama's own out-of-space message is a full disk")
  func ollamaMessageIsDiskFull() {
    #expect(
      OllamaSetupService.isDiskFull(
        LLMError.requestFailed("Ollama pull error: write /models/blob: no space left on device")))
    #expect(OllamaSetupService.isDiskFull(LLMError.requestFailed("Ollama pull error: errno 28")))
  }

  @Test("the system's out-of-space codes are a full disk, whatever their description says")
  func systemCodesAreDiskFull() {
    let posix = NSError(
      domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
      userInfo: [NSLocalizedDescriptionKey: "Kein Speicherplatz auf dem Gerät"])
    let cocoa = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
      userInfo: [NSLocalizedDescriptionKey: "Nicht genügend Speicherplatz"])
    #expect(OllamaSetupService.isDiskFull(posix))
    #expect(OllamaSetupService.isDiskFull(cocoa))
  }

  @Test("other failures are not a full disk, even when their description mentions space")
  func otherFailuresAreNotDiskFull() {
    #expect(!OllamaSetupService.isDiskFull(LLMError.requestFailed("Ollama pull request failed")))
    let described = NSError(
      domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no space left on device"])
    #expect(!OllamaSetupService.isDiskFull(described))
    #expect(!OllamaSetupService.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
  }
}
