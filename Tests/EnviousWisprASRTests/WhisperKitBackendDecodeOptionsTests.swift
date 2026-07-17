import EnviousWisprCore
import Testing

@testable import EnviousWisprASR

@Suite("WhisperKitBackend decode options")
struct WhisperKitBackendDecodeOptionsTests {

  @Test("detectLanguage true when language nil for auto-mode LID-abstain path")
  func test_detectLanguage_true_when_language_nil_for_auto_mode_LID_abstain_path() async {
    let sut = WhisperKitBackend(admittedModelFolder: { nil })
    let options = TranscriptionOptions(language: nil)

    let decodeOptions = await sut.makeDecodeOptions(from: options, sampleCount: 0)

    #expect(decodeOptions.detectLanguage == true)
  }

  @Test(
    "detectLanguage false when language locked to explicit code",
    arguments: ["es", "en", "ja", "de"])
  func test_detectLanguage_false_when_language_locked_to_explicit_code(_ language: String) async {
    let sut = WhisperKitBackend(admittedModelFolder: { nil })
    let options = TranscriptionOptions(language: language)

    let decodeOptions = await sut.makeDecodeOptions(from: options, sampleCount: 0)

    #expect(decodeOptions.detectLanguage == false)
  }

  // Documents WhisperKit's own contract: only `nil` triggers auto-detect.
  // Empty / whitespace strings are non-nil so detectLanguage stays false; the
  // string is then forwarded to WhisperKit which (per TextDecoder.swift:183-184)
  // builds "<||>", fails the tokenizer lookup, and falls back to the english
  // token. Safe but does not auto-detect. We do NOT defensively normalize
  // empty to nil, because that would diverge from WhisperKit's own gate at
  // TranscribeTask.swift:341 which uses `options.language == nil` exactly.
  @Test(
    "detectLanguage false when language is empty or whitespace (matches WhisperKit's nil-only auto-detect contract)",
    arguments: ["", " ", "   "])
  func test_detectLanguage_false_when_language_empty_or_whitespace(_ language: String) async {
    let sut = WhisperKitBackend(admittedModelFolder: { nil })
    let options = TranscriptionOptions(language: language)

    let decodeOptions = await sut.makeDecodeOptions(from: options, sampleCount: 0)

    #expect(decodeOptions.detectLanguage == false)
  }
}
