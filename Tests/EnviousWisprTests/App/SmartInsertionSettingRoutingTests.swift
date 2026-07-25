import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

// Routing for the Smart insertion setting (#1785 Chunk 5).
//
// A setting is only real if it reaches the user AND stops at the right layer.
// Two properties are pinned here:
//
// 1. Exactly ONE visible toggle, bound to the setting. The plan deliberately
//    ships one switch rather than spacing/capitalisation/punctuation
//    sub-toggles, so a second surface appearing is a regression.
// 2. It is FROZEN per recording. Changing it mid-dictation must not touch the
//    dictation in flight, so live settings sync must do nothing for this key.
@MainActor
@Suite("Smart insertion setting routing")
struct SmartInsertionSettingRoutingTests {

  private static let clipboardViewPath =
    "Sources/EnviousWisprAppKit/Views/Settings/ClipboardSettingsView.swift"
  private static let syncPath = "Sources/EnviousWisprAppKit/App/PipelineSettingsSync.swift"

  @Test("the Clipboard page exposes exactly one Smart insertion toggle")
  func exactlyOneVisibleToggle() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.clipboardViewPath), encoding: .utf8)

    let labels = source.components(separatedBy: "Text(\"Smart insertion\")").count - 1
    #expect(labels == 1, "expected exactly one Smart insertion label, found \(labels)")

    let bindings = source.components(separatedBy: "$settings.smartInsertion").count - 1
    #expect(bindings == 1, "expected exactly one binding, found \(bindings)")

    // The plan ships ONE switch at first release. Any of these would be a
    // sub-toggle surface the founder explicitly ruled out.
    for banned in [
      "smartInsertionSpacing", "smartInsertionCapitalization", "smartInsertionPunctuation",
    ] {
      #expect(source.contains(banned) == false, "sub-toggle surface leaked: \(banned)")
    }
  }

  @Test("live settings sync treats Smart insertion as frozen per recording")
  func frozenPerRecording() throws {
    let source = try String(contentsOf: RepoRoot.sourceURL(Self.syncPath), encoding: .utf8)

    // It must appear in the frozen no-op group, beside the analogue the plan
    // names, and nowhere else in the sync file.
    let occurrences = source.components(separatedBy: ".smartInsertion").count - 1
    #expect(occurrences == 1, "expected one mention in the sync file, found \(occurrences)")

    guard let caseRange = source.range(of: "case .autoCopyToClipboard") else {
      Issue.record("frozen-per-recording case group not found")
      return
    }
    // Bound the group at its no-op terminator rather than a character count, so
    // the assertion cannot drift as neighbouring cases change.
    guard
      let breakRange = source.range(
        of: "break  // Frozen per recording",
        range: caseRange.upperBound..<source.endIndex)
    else {
      Issue.record("frozen-per-recording no-op terminator not found")
      return
    }

    let group = source[caseRange.lowerBound..<breakRange.upperBound]
    #expect(
      group.contains(".smartInsertion"),
      "Smart insertion must sit in the frozen group beside .restoreClipboardAfterPaste")
    #expect(group.contains(".restoreClipboardAfterPaste"))

    // Nothing in this case may touch live state. Naming the known mutation
    // owners makes a future live-sync addition fail here rather than silently
    // altering an in-flight dictation.
    for forbidden in [
      "settings.smartInsertion", "kernelDriver", "whisperKitKernelDriver", "audioCapture",
      "hotkeyService",
    ] {
      #expect(
        group.contains(forbidden) == false, "live mutation leaked into frozen group: \(forbidden)")
    }
  }

  @Test("the factory source threads Smart insertion into the session config")
  func factoryThreadsSettingIntoConfig() throws {
    let factory = try String(
      contentsOf: RepoRoot.sourceURL(
        "Sources/EnviousWisprAppKit/App/DictationSessionConfigFactory.swift"),
      encoding: .utf8)
    #expect(factory.contains("smartInsertion: settings.smartInsertion"))
  }

  @Test("the test helper defaults OFF so existing suites keep legacy behaviour")
  func testHelperDefaultsOff() {
    #expect(DictationSessionConfig.testDefault().smartInsertion == false)
  }
}
