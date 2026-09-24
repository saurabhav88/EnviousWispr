import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #913 PR2 — proves the `EnviousWisprPostProcessing` resource bundle (the
/// spoken-emoji dictionary) is carried with the module under the Xcode/Tuist
/// build and that the production `Bundle.module` accessor resolves it at
/// runtime. The "does the SIGNED app ship it under Contents/Resources" claim is
/// proven separately by inspecting the built signed app in the PR2 build script
/// (a non-hosted unit test resolves `Bundle.module` to its own test bundle, not
/// the app, so that containment claim cannot be asserted here without hosting
/// the whole suite inside the menu-bar app — which we avoid).
///
/// Not tautological: it asserts three independent facts — the `Bundle.module`
/// lookup returns a URL, a real file exists there, and the production loader +
/// formatter turn known phrases into the expected glyphs through that resource.
@Suite("PostProcessing resource bundle runtime")
struct PostProcessingResourceBundleRuntimeTests {
  @Test("Bundle.module resolves the emoji dictionary and EmojiFormatter loads it")
  func bundleModuleResolvesEmojiDictionary() throws {
    let dictionaryURL = try #require(
      EmojiFormatter.bundledDictionaryURLForDiagnostics,
      "Bundle.module did not resolve emoji-dictionary.json — the resource bundle did not ship with the module."
    )

    #expect(dictionaryURL.lastPathComponent == "emoji-dictionary.json")
    #expect(
      FileManager.default.fileExists(atPath: dictionaryURL.path),
      "emoji-dictionary.json missing at the Bundle.module URL: \(dictionaryURL.path)"
    )

    let moduleBundleURL = EmojiFormatter.moduleBundleURLForDiagnostics
    #expect(
      dictionaryURL.path.hasPrefix(moduleBundleURL.standardizedFileURL.path),
      "Dictionary resolved outside the module bundle: \(dictionaryURL.path)"
    )

    let formatter = try EmojiFormatter.load()
    #expect(formatter.format("thumbs up emoji") == "👍")
    #expect(formatter.format("happy birthday Emma red heart emoji") == "happy birthday Emma ❤️")
  }

  /// #3124: the English (UK) spelling table ships in the same bundle. A missing table silently
  /// disables British spelling for every UK user, so the shipped lookup is asserted directly.
  @Test("Bundle.module resolves the British spelling table and the converter loads it")
  func bundleModuleResolvesBritishSpellingTable() throws {
    let tableURL = try #require(
      BritishSpellingConverter.bundledTableURLForDiagnostics,
      "Bundle.module did not resolve british-spelling.json"
    )
    #expect(tableURL.lastPathComponent == "british-spelling.json")
    #expect(
      tableURL.path.hasPrefix(EmojiFormatter.moduleBundleURLForDiagnostics.standardizedFileURL.path),
      "Table resolved outside the module bundle: \(tableURL.path)"
    )
    let converter = try BritishSpellingConverter.load()
    #expect(converter.convert("the color of the center").text == "the colour of the centre")
  }
}
