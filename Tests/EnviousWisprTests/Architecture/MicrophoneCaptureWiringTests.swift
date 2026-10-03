import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// A drift guard: only the microphone picker may observe capture changes, and the cue
/// reads actual capture evidence, never the selected preference. These syntax checks
/// establish where reads execute, not a measured recording-latency improvement.
@Suite("Microphone capture wiring (#3385)", .tags(.driftGuard))
struct MicrophoneCaptureWiringTests {
  @Test("main window defers every capture read to the injected reader")
  func mainWindowProjectsCaptureEvidence() throws {
    let tree = try MicrophoneSettingsWiringTests.source(
      "Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift")
    let root = try #require(Self.structure(named: "MainWindowRoot", in: tree))
    let facts = Self.captureReadFacts(in: Syntax(root))
    #expect(facts.readers == 1)
    #expect(facts.deferred == ["isCapturing", "zeroSignalDiscriminatorDevice"])
    #expect(facts.immediate == [], "root-level observation: \(facts.immediate)")
    let calls = MicrophoneSettingsWiringTests.calls(named: "MicrophoneCapturePresentation", in: tree)
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.labels == ["isCapturing", "boundDeviceUID"])
    #expect(call.arguments == [
      "b.liveRecordingState.audioCapture.isCapturing",
      "b.liveRecordingState.audioCapture.zeroSignalDiscriminatorDevice?.deviceUID",
    ])
  }

  @Test("only the picker invokes the reader in its body, with a snapshot override")
  func viewUsesDisplayedIdentity() throws {
    let page = MicrophoneSettingsWiringTests.codeOnly(try MicrophoneSettingsWiringTests.source(
      MicrophoneSettingsWiringTests.audioPath))
    #expect(page.contains("microphoneCapturePresentation") == false)
    #expect(page.contains("capturePresentation:") == false)
    #expect(page.contains("AudioCaptureManager") == false)
    let tree = try MicrophoneSettingsWiringTests.source(
      "Sources/EnviousWisprAppKit/Views/Settings/MicrophoneDevicePicker.swift")
    let calls = MicrophoneSettingsWiringTests.calls(named: "readCapturePresentation", in: tree)
    #expect(calls.count == 1)
    #expect(calls.first?.bindings == ["capturePresentation", "body"])
    let picker = MicrophoneSettingsWiringTests.codeOnly(tree)
    #expect(picker.contains("@Environment(\\.microphoneCapturePresentation)privatevarreadCapturePresentation"))
    #expect(picker.contains("varcapturePresentation:MicrophoneCapturePresentation?=nil"))
    #expect(picker.contains("letcapturePresentation=capturePresentation??readCapturePresentation()"))
    #expect(picker.contains("capturePresentation.isInUse(displayedUID:presentation.deviceUID)"))
    #expect(picker.contains(".accessibilityLabel(String(localized:DictationSettingsCopy.Microphone.inputDeviceTitle))"))
    #expect(picker.contains(".accessibilityValue([presentation.deviceName??placeholder,detail].compactMap{$0}.joined(separator:\", \"))"))
    #expect(picker.contains(".pickerStyle(.inline)"))
    #expect(picker.contains(".tag(\"\")"))
    #expect(picker.contains(".tag(device.uid)"))
    #expect(picker.contains("Text(MicrophoneChoiceCopy.autoExplanation).disabled(true)"))
  }

  @Test("the structural scan distinguishes deferred, eager and precomputed reads")
  func observationPlacementExtractorControls() {
    let read = "b.liveRecordingState.audioCapture.isCapturing"
    let deferred = Self.captureReadFacts(in: Syntax(Parser.parse(source:
      "var body: some View { view.environment(\\.microphoneCapturePresentation, { Snapshot(active: \(read)) }) }")))
    #expect(deferred.readers == 1)
    #expect(deferred.deferred == ["isCapturing"])
    #expect(deferred.immediate == [])
    let eager = Self.captureReadFacts(in: Syntax(Parser.parse(source:
      "var body: some View { view.environment(\\.microphoneCapturePresentation, Snapshot(active: \(read))) }")))
    #expect(eager.readers == 0)
    #expect(eager.deferred == [])
    #expect(eager.immediate == ["isCapturing"])
    let precomputed = Self.captureReadFacts(in: Syntax(Parser.parse(source:
      "var body: some View { let snapshot = Snapshot(active: \(read)); return view.environment(\\.microphoneCapturePresentation, { snapshot }) }")))
    #expect(precomputed.readers == 1)
    #expect(precomputed.deferred == [])
    #expect(precomputed.immediate == ["isCapturing"])
    let captured = Self.captureReadFacts(in: Syntax(Parser.parse(source:
      "var body: some View { view.environment(\\.microphoneCapturePresentation, { [active = \(read)] in Snapshot(active: active) }) }")))
    #expect(captured.readers == 1)
    #expect(captured.deferred == [])
    #expect(captured.immediate == ["isCapturing"])
  }

  private static func structure(named name: String, in tree: SourceFileSyntax) -> StructDeclSyntax? {
    final class Finder: SyntaxVisitor {
      let name: String
      var found: StructDeclSyntax?
      init(_ name: String) { self.name = name; super.init(viewMode: .sourceAccurate) }
      override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == name { found = node; return .skipChildren }
        return .visitChildren
      }
    }
    let finder = Finder(name)
    finder.walk(tree)
    return finder.found
  }

  struct CaptureReadFacts {
    let readers: Int
    let deferred: [String]
    let immediate: [String]
  }

  /// Classifies each capture member access by its syntax ancestry. A closure anywhere
  /// is insufficient: it must be inside the uninvoked environment reader's body.
  /// Capture-list expressions execute when the closure is created, so they are eager.
  static func captureReadFacts(in tree: Syntax) -> CaptureReadFacts {
    final class Finder: SyntaxVisitor {
      var readers: [ClosureExprSyntax] = []
      var accesses: [MemberAccessExprSyntax] = []
      init() { super.init(viewMode: .sourceAccurate) }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "environment",
          node.arguments.first?.expression.trimmedDescription == "\\.microphoneCapturePresentation",
          node.arguments.count == 2,
          let reader = node.arguments.last?.expression.as(ClosureExprSyntax.self) {
          readers.append(reader)
        }
        return .visitChildren
      }
      override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.base?.trimmedDescription == "b.liveRecordingState.audioCapture" {
          accesses.append(node)
        }
        return .visitChildren
      }
    }
    let finder = Finder()
    finder.walk(tree)
    let readerBodyIDs = Set(finder.readers.map { $0.statements.id })
    var deferred: [String] = []
    var immediate: [String] = []
    for access in finder.accesses {
      var parent = Syntax(access).parent
      var isDeferred = false
      while let ancestor = parent {
        if readerBodyIDs.contains(ancestor.id) { isDeferred = true; break }
        parent = ancestor.parent
      }
      if isDeferred { deferred.append(access.declName.baseName.text) }
      else { immediate.append(access.declName.baseName.text) }
    }
    return CaptureReadFacts(readers: finder.readers.count, deferred: deferred.sorted(), immediate: immediate.sorted())
  }
}
