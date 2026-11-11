import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4473 (plan §3.1.1 S6, S7): a file import and a saved recording carry the exact polish
/// model they were started with.
///
/// When this fails, a file import or a recovered recording is polished by a model chosen
/// later in Settings, or a recording that names a size this build does not know is run on
/// some other size. Encounter: every import and every crash recovery. Owner: plan #4473 P5.
@MainActor
@Suite("An import and a saved recording keep the polish model they were started with (#4473)", .tags(.productOutcome))
struct EGOneFrozenModelTests {
  private static func settings() -> SettingsManager {
    let name = "ew.eg1.frozen.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return SettingsManager(defaults: defaults)
  }

  @Test("an import freezes its provider and its EG-1 size; a later settings change does not reach it")
  func theImportKeepsItsModel() {
    let settings = Self.settings()
    settings.fileImportLLMProvider = .egOne
    let snapshot = FileImportSettingsFreeze.snapshot(settings: settings)
    #expect(snapshot.llmProvider == LLMProvider.egOne.rawValue && snapshot.egOneSize == "full")
    let run = FileImportSettingsFreeze.configuration(for: snapshot, ollamaModelIsRemote: nil)
    #expect(run.localPolishModel == .egOne(.full))

    settings.fileImportLLMProvider = .s1Mini
    settings.selectEGOneSize(.micro)
    #expect(snapshot.polishModelID == .egOne(.full))
    #expect(run.localPolishModel == .egOne(.full))
    let next = FileImportSettingsFreeze.snapshot(settings: settings)
    #expect(next.egOneSize == nil && next.polishModelID == .singleModel(for: .s1Mini))
    #expect(
      FileImportSettingsFreeze.configuration(for: next, ollamaModelIsRemote: nil).localPolishModel
        == .singleModel(for: .s1Mini))

    // A cloud engine has no bundled server to hold.
    settings.fileImportLLMProvider = .claude
    #expect(
      FileImportSettingsFreeze.configuration(
        for: FileImportSettingsFreeze.snapshot(settings: settings), ollamaModelIsRemote: nil
      ).localPolishModel == nil)
  }

  @Test("a saved recording that names an EG-1 size this build does not know holds no server and names no model")
  func anUnknownSizeNamesNoModel() {
    let unknown = LocalPolishExactModelTests.snapshot(provider: .egOne, size: "giant")
    let run = FileImportSettingsFreeze.configuration(for: unknown, ollamaModelIsRemote: nil)
    #expect(run.localPolishModel == nil)
    #expect(run.polishProvider == .egOne, "the provider is kept, for the History row")
    let mini = LocalPolishExactModelTests.snapshot(provider: .egOne, size: "mini")
    #expect(
      FileImportSettingsFreeze.configuration(for: mini, ollamaModelIsRemote: nil).localPolishModel
        == .egOne(.mini))
  }

  @Test("new work freezes EG-1 at the size the user prefers; other providers have their one model")
  func newWorkFreezesThePreferredSize() {
    let settings = Self.settings()
    // Before the first resolution there is no preference: the one EG-1 before sizes.
    #expect(settings.egOneSize == nil && settings.polishModelID(for: .egOne) == .egOne(.full))
    for size in EGOneSize.allCases {
      settings.selectEGOneSize(size)
      #expect(settings.polishModelID(for: .egOne) == .egOne(size))
      settings.fileImportLLMProvider = .egOne
      let snapshot = FileImportSettingsFreeze.snapshot(settings: settings)
      #expect(snapshot.egOneSize == size.rawValue && snapshot.polishModelID == .egOne(size))
    }
    #expect(settings.polishModelID(for: .s1Mini) == .singleModel(for: .s1Mini))
    #expect(settings.polishModelID(for: .claude) == .singleModel(for: .claude))
  }
}
