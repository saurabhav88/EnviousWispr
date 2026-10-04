import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// #3385: the Microphone tab changed how the microphone choice LOOKS; these pin that
/// it did not change what the choice DOES. Read from the source with SwiftParser: the input
/// selection still writes both preferences, the page still asks the one resolver which device
/// it describes, the socket choice keeps its eligibility and per-device write, and the media
/// row still pairs its output listener with the page's appearance. A drift guard; the
/// rebuilt-app UAT proves a microphone switch reaches RAW ASR.
@Suite("Microphone settings wiring (#3385)", .tags(.driftGuard))
struct MicrophoneSettingsWiringTests {
  static let audioPath = "Sources/EnviousWisprAppKit/Views/Settings/AudioSettingsView.swift"
  static let mediaPath = "Sources/EnviousWisprAppKit/Views/Settings/OtherAudioSettingsPanel.swift"

  static func source(_ path: String) throws -> SourceFileSyntax {
    Parser.parse(
      source: try String(contentsOf: RepoRoot.url.appending(path: path), encoding: .utf8))
  }

  /// #3454: the two writes moved, unchanged, into `SettingsManager.chooseInputDevice(uid:)`,
  /// which the menu bar's Microphone submenu also calls; `SettingsManagerInputDeviceChoiceTests`
  /// proves it writes both preferences, override first. This pins that the page still goes through it.
  @Test("choosing a microphone still writes both preferences, through the shared owner")
  func selectionWritesBothPreferences() throws {
    let writes = Self.setterAssignments(binding: "inputDeviceSelection", in: try Self.source(Self.audioPath))
    #expect(
      writes == ["settingsManager.chooseInputDevice(uid: $0)"], "setter writes: \(writes)")
  }

  @Test("the page describes the device from the one shared resolver")
  func oneResolver() throws {
    let calls = Self.calls(named: "InputSocket.socketDevice", in: try Self.source(Self.audioPath))
    #expect(calls.count == 1, "resolver calls: \(calls)")
    let call = try #require(calls.first)
    #expect(call.labels == ["preferredInputDeviceIDOverride", "devices", "resolvedAutoInputDeviceID"])
    #expect(call.bindings == ["socketDevice", "body"])
    #expect(
      call.arguments == [
        "settingsManager.preferredInputDeviceIDOverride",
        "audioDeviceList.availableInputDevices",
        "AudioDeviceEnumerator.resolvedAutoInputDeviceID",
      ])
  }

  @Test("a different resolver, or the right call in the wrong place, is seen")
  func resolverExtractorControls() {
    let fixture = Parser.parse(
      source: """
        var body: some View {
          let socketDevice = InputSocket.socketDevice(
            preferredInputDeviceIDOverride: settingsManager.preferredInputDeviceIDOverride,
            devices: audioDeviceList.availableInputDevices,
            resolvedAutoInputDeviceID: { AudioDeviceEnumerator.defaultInputDeviceID })
        }
        var other: Int {
          let elsewhere = InputSocket.socketDevice(
            preferredInputDeviceIDOverride: x, devices: y,
            resolvedAutoInputDeviceID: AudioDeviceEnumerator.resolvedAutoInputDeviceID)
        }
        """)
    let calls = Self.calls(named: "InputSocket.socketDevice", in: fixture)
    #expect(calls.count == 2)
    #expect(calls.first?.bindings == ["socketDevice", "body"])
    #expect(
      calls.first?.arguments.last == "{ AudioDeviceEnumerator.defaultInputDeviceID }",
      "a substituted resolver is visible to the guard")
    #expect(calls.last?.bindings == ["elsewhere", "other"])
  }

  @Test("the socket choice keeps its eligibility and its per-device write")
  func socketConditionsAndWrite() throws {
    let tree = try Self.source(Self.audioPath)
    let text = Self.codeOnly(tree)
    #expect(text.contains("device.inputChannelCount>1&&!device.uid.isEmpty"))
    #expect(text.contains("ifdevice.inputChannelCount<=6"))
    let writes = Self.setterAssignments(binding: "socketSelection", in: tree)
    #expect(writes == ["settingsManager.inputChannelByDeviceUID[device.uid] = newValue"], "\(writes)")
  }

  @Test("the media row starts its output listener on appear and stops it on disappear")
  func mediaListenerIsPaired() throws {
    let tree = try Self.source(Self.mediaPath)
    let appear = Self.modifierBodies(named: "onAppear", in: tree)
    let disappear = Self.modifierBodies(named: "onDisappear", in: tree)
    #expect(appear == ["startOutputListener()"], "onAppear bodies: \(appear)")
    #expect(disappear == ["stopOutputListener()"], "onDisappear bodies: \(disappear)")
  }

  // MARK: - Extractor controls

  @Test("a setter elsewhere does not count, and a missing write is seen")
  func extractorControls() {
    let fixture = Parser.parse(
      source: """
        let other = Binding<String>(get: { "" }, set: { v in settingsManager.preferredInputDeviceIDOverride = v })
        let inputDeviceSelection = Binding<String>(
          get: { "" },
          set: { newValue in settingsManager.preferredInputDeviceIDOverride = newValue })
        """)
    #expect(
      Self.setterAssignments(binding: "inputDeviceSelection", in: fixture)
        == ["settingsManager.preferredInputDeviceIDOverride = newValue"])
  }

  @Test("an onAppear without the listener start is seen")
  func modifierControl() {
    let fixture = Parser.parse(source: "var body: some View { Text(\"x\").onAppear { refresh() } }")
    #expect(Self.modifierBodies(named: "onAppear", in: fixture) == ["refresh()"])
  }

  // MARK: - Extractor

  /// The assignment statements inside the `set:` closure of `let <binding> = Binding(...)`.
  static func setterAssignments(binding: String, in tree: SourceFileSyntax) -> [String] {
    final class Finder: SyntaxVisitor {
      let name: String
      var result: [String] = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name,
          let call = node.initializer?.value.as(FunctionCallExprSyntax.self),
          let setter = call.arguments.first(where: { $0.label?.text == "set" })?
            .expression.as(ClosureExprSyntax.self)
        else { return .visitChildren }
        result = setter.statements.map { $0.item.trimmedDescription }
        return .skipChildren
      }
    }
    let finder = Finder(name: binding)
    finder.walk(tree)
    return finder.result
  }

  struct Call: CustomStringConvertible {
    let labels: [String]
    let arguments: [String]
    let bindings: [String]
    var description: String { "\(bindings): \(zip(labels, arguments).map { "\($0): \($1)" })" }
  }

  /// The bindings enclosing `node`, innermost first (`let x = ...`, `var body { ... }`).
  static func ownerBindings(of node: Syntax) -> [String] {
    var names: [String] = []
    var current = node.parent
    while let parent = current {
      if let binding = parent.as(PatternBindingSyntax.self),
        let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
      {
        names.append(identifier.identifier.text)
      }
      current = parent.parent
    }
    return names
  }

  static func calls(named name: String, in tree: SourceFileSyntax) -> [Call] {
    final class Finder: SyntaxVisitor {
      let name: String
      var result: [Call] = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if node.calledExpression.trimmedDescription == name {
          result.append(
            Call(
              labels: node.arguments.map { $0.label?.text ?? "_" },
              arguments: node.arguments.map { $0.expression.trimmedDescription },
              bindings: MicrophoneSettingsWiringTests.ownerBindings(of: Syntax(node))))
        }
        return .visitChildren
      }
    }
    let finder = Finder(name: name)
    finder.walk(tree)
    return finder.result
  }

  /// The single-statement bodies of every `.<name> { ... }` modifier.
  static func modifierBodies(named name: String, in tree: SourceFileSyntax) -> [String] {
    final class Finder: SyntaxVisitor {
      let name: String
      var result: [String] = []
      init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
          member.declName.baseName.text == name,
          let closure = node.trailingClosure
        {
          result.append(closure.statements.map { $0.item.trimmedDescription }.joined(separator: "; "))
        }
        return .visitChildren
      }
    }
    let finder = Finder(name: name)
    finder.walk(tree)
    return finder.result
  }

  /// The source's tokens with trivia (comments, whitespace) dropped, for checks on a
  /// condition's exact spelling.
  static func codeOnly(_ tree: SourceFileSyntax) -> String {
    tree.tokens(viewMode: .sourceAccurate).map(\.text).joined()
  }
}
