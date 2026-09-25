import Testing

@testable import EnviousWisprAppKit

/// #3142: the on-screen preview's status and mode words are localized where they
/// are authored. Each keeps its English bytes, checked against independent literals.
@Suite("Live Preview copy", .tags(.productOutcome))
struct LivePreviewCopyTests {
  @Test("every preview status and mode word reads exactly as before")
  func englishIsUnchanged() {
    #expect(LivePreviewCopy.needsNewerMacOS == "On-screen preview needs macOS 26.")
    #expect(
      LivePreviewCopy.languageUnsupported == "On-screen preview does not support this language yet."
    )
    #expect(LivePreviewCopy.notReady == "On-screen preview is not ready yet.")
    #expect(LivePreviewCopy.preparing == "Getting the preview ready...")
    #expect(LivePreviewCopy.listening == "Listening...")
    #expect(LivePreviewCopy.listeningMode == "Listening")
    #expect(LivePreviewCopy.handsFreeMode == "Hands-free")
    #expect(
      LivePreviewCopy.previewModelNotInstalled
        == "Download the preview model in Settings to see words appear.")
    #expect(
      LivePreviewCopy.heartIsStreaming
        == "On-screen preview pauses while Faster Transcription is on.")
    #expect(
      LivePreviewCopy.engineUnavailableInThisBuild
        == "This version of EnviousWispr cannot run that preview engine.")
  }
}
