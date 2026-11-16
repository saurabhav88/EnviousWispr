import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Drift guard (#4601 §3a): in the two files that start, check and release the microphone, every
/// call that talks to the audio driver runs off the main thread, inside a job handed to the
/// audio-unit lane or inside the native half that only lane jobs reach; `AudioUnitRender` runs
/// only in the real-time render callback. When this fails, someone added a direct driver call on
/// the main actor, and a stuck driver can freeze the app at record start or release again.
///
/// Structural evidence only: it reads where calls are written, not what runs at runtime, and it
/// does not prove the render callback is real-time safe.
@Suite("Audio-unit lane call sites — #4601", .tags(.driftGuard))
struct AudioUnitLaneCallSiteTests {

  /// Calls that reach the audio driver. Pure value constructors (`AudioObjectPropertyAddress`,
  /// `AudioComponentDescription`, `AudioObjectID`, `AudioUnit`) and pure helpers
  /// (`AudioDeviceEnumerator.transportLabel`, `builtInInputKind`) are not listed: a name starting
  /// with Audio is not a hardware call by itself. Matching is by prefix; the property write is
  /// listed by its `AudioObjectSet` stem because scripts/check-dependency-direction.sh reads the
  /// full name as a live desktop call even inside a string.
  static func isHardwareCall(_ callee: String) -> Bool {
    let prefixes = [
      "AudioUnitGetProperty", "AudioUnitSetProperty", "AudioUnitInitialize",
      "AudioUnitUninitialize", "AudioUnitRender", "AudioOutputUnitStart", "AudioOutputUnitStop",
      "AudioComponentFindNext", "AudioComponentInstanceNew", "AudioComponentInstanceDispose",
      "AudioObjectGetPropertyData", "AudioObjectSet", "AudioObjectHasProperty",
      "AudioObjectAddPropertyListener", "AudioObjectRemovePropertyListener",
    ]
    if prefixes.contains(where: { callee == $0 || callee.hasPrefix($0) }) { return true }
    let readers = [
      "AudioDeviceEnumerator.defaultInputDeviceUID", "AudioDeviceEnumerator.defaultInputDeviceID",
      "AudioDeviceEnumerator.inputChannelCount", "AudioDeviceEnumerator.inputDeviceUID",
      "AudioDeviceEnumerator.inputDeviceSnapshot", "AudioDeviceEnumerator.transportTypeRaw",
      "CoreAudioDeviceLiveness.classify",
    ]
    if readers.contains(callee) { return true }
    // The device-selection and route reads (each reads the driver through its injected calls).
    let selection = ["resolver.resolve", "routeResolver.resolve", "request.resolver.resolve"]
    return selection.contains(callee) || callee.hasSuffix("isWarmBindCompatible")
  }

  /// Calls INTO the native half from outside it. The native half's own driver calls are allowed
  /// only because lane jobs alone reach it, so each way in is held to the same placement: a
  /// `HALUnitNative` function (a capitalized member is a value type's initializer, not a call
  /// in), the injected open and running-probe aliases, a unit owner's `retire()`, and the
  /// failed-open cleanup helper that retires one.
  static func isNativeEntry(_ callee: String) -> Bool {
    if callee == "openWork" || callee == "probe" { return true }
    if callee.hasSuffix("failedOpenError") { return true }
    if callee.hasSuffix(".retire") { return callee != "lane.retire" && callee != "self.lane.retire" }
    let native = "HALUnitNative."
    guard callee.hasPrefix(native), let first = callee.dropFirst(native.count).first else {
      return false
    }
    return first.isLowercase
  }

  /// Where a call may run. `lane`: inside a closure handed to the audio-unit lane. `native`:
  /// inside the native half only lane jobs call. `render`: the real-time render callback.
  enum Context: Equatable, CustomStringConvertible {
    case lane, native, render
    case other(String)
    var description: String {
      switch self {
      case .lane: "lane"
      case .native: "native"
      case .render: "render"
      case .other(let where_): "main: \(where_)"
      }
    }
  }

  static let nativeTypes: Set<String> = ["HALUnitNative", "HALUnitResources", "HALNativeCalls"]
  static let laneEntryPoints: Set<String> = ["run", "open", "retire", "retireAndWait"]
  /// The closure arguments the lane runs on its worker: the unlabelled job and `disposeLate`.
  /// `onTerminal` is excluded: it can run synchronously in the caller when an attempt is
  /// cancelled, off the worker.
  static let laneWorkerLabels: Set<String> = ["", "disposeLate"]

  struct Site: CustomStringConvertible {
    let callee: String
    let line: Int
    let context: Context
    var description: String { "\(callee) line \(line) (\(context))" }
  }

  final class Visitor: SyntaxVisitor {
    var sites: [Site] = []
    let converter: SourceLocationConverter

    init(_ tree: SourceFileSyntax, file: String) {
      converter = SourceLocationConverter(fileName: file, tree: tree)
      super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      let callee = node.calledExpression.trimmedDescription
      if AudioUnitLaneCallSiteTests.isHardwareCall(callee)
        || AudioUnitLaneCallSiteTests.isNativeEntry(callee)
      {
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        sites.append(
          Site(callee: callee, line: line, context: AudioUnitLaneCallSiteTests.context(of: node)))
      }
      return .visitChildren
    }
  }

  /// The nearest enclosing boundary, walking outward from the call.
  static func context(of node: some SyntaxProtocol) -> Context {
    var current = Syntax(node)
    var enclosingFunction = "top level"
    var sawFunction = false
    while let parent = current.parent {
      if let closure = current.as(ClosureExprSyntax.self), isLaneArgument(closure) {
        return .lane
      }
      if let function = parent.as(FunctionDeclSyntax.self) {
        if function.name.text == "halRenderProc" { return .render }
        if !sawFunction {
          enclosingFunction = function.name.text
          sawFunction = true
        }
      }
      // A computed property or a stored property's initializer is named by its property. Walking
      // outward, an outer property overwrites a local `let` inside it; a function, once seen,
      // wins over both.
      if !sawFunction, let binding = parent.as(PatternBindingSyntax.self) {
        enclosingFunction = binding.pattern.trimmedDescription
      }
      if let name = typeName(of: parent), nativeTypes.contains(name) { return .native }
      current = parent
    }
    return .other(enclosingFunction)
  }

  /// Whether `closure` is a worker argument (the unlabelled job or `disposeLate`, written inline
  /// or trailing) of `lane.<entry>(...)`.
  static func isLaneArgument(_ closure: ClosureExprSyntax) -> Bool {
    var node = Syntax(closure)
    var label = ""
    for _ in 0..<3 {
      guard let parent = node.parent else { return false }
      if let argument = parent.as(LabeledExprSyntax.self) {
        label = argument.label?.text ?? ""
      } else if let trailing = parent.as(MultipleTrailingClosureElementSyntax.self) {
        label = trailing.label.text
      }
      if let call = parent.as(FunctionCallExprSyntax.self) {
        guard laneWorkerLabels.contains(label) else { return false }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
          laneEntryPoints.contains(member.declName.baseName.text),
          let base = member.base?.trimmedDescription
        else { return false }
        return base == "lane" || base == "self.lane"
      }
      node = parent
    }
    return false
  }

  static func typeName(of node: Syntax) -> String? {
    if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
    if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
    if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
    return nil
  }

  static func sites(source: String, file: String = "fixture.swift") -> [Site] {
    let tree = CachedSwiftParser.parse(source: source)
    let visitor = Visitor(tree, file: file)
    visitor.walk(tree)
    return visitor.sites
  }

  static func sites(of path: String) throws -> [Site] {
    let snapshot = try CachedSwiftParser.snapshot(at: RepoRoot.url.appending(path: path))
    let visitor = Visitor(snapshot.tree, file: path)
    visitor.walk(snapshot.tree)
    return visitor.sites
  }

  /// Driver calls written outside a lane job, each with the reason it is not a main-actor read.
  /// Keyed by "callee in function" (function "top level" = a stored-property initializer).
  /// Adding a row is a design decision: name the reason, never just silence the guard.
  static let exemptions: [String: String] = [
    // The injectable liveness reader's DEFAULT. Defining it reads nothing; it is CALLED only
    // inside a lane job (`readerCallsRunOnTheLane` below checks every call).
    "CoreAudioDeviceLiveness.classify in livenessReader":
      "default of livenessReader, called on the lane",
    // The same for the native-rate reader's default.
    "HALUnitNative.queryNativeStreamFormat in nativeRateReader":
      "default of nativeRateReader, called on the lane",
    // The failed-open cleanup lives in a HALDeviceInputSource extension but is a nonisolated
    // helper of the native open; its callers are held to the native half as native entries.
    "resources.retire in failedOpenError": "failed-open cleanup, called only by the native open",
  ]

  static let guardedFiles = [
    "Sources/EnviousWisprAudio/HALDeviceInputSource.swift",
    "Sources/EnviousWisprAudio/AudioCaptureManager.swift",
  ]

  @Test(
    "every driver call in the microphone files runs on the lane, in the native half or in render")
  func driverCallsStayOffTheMainActor() throws {
    var all: [Site] = []
    for file in Self.guardedFiles {
      let sites = try Self.sites(of: file)
      all += sites
      let misplaced = sites.filter {
        guard case .other(let function) = $0.context else { return false }
        return Self.exemptions["\($0.callee) in \(function)"] == nil
      }
      #expect(misplaced.isEmpty, "\(file): driver calls outside the lane: \(misplaced)")
    }
    // The inventory is not empty: a scan that found nothing would pass vacuously.
    #expect(all.count >= 30, "too few driver calls found: \(all.count)")
    #expect(all.contains { $0.context == .lane }, "no lane-wrapped calls were found")
  }

  @Test("every exemption still matches a real call site (no stale rows)")
  func exemptionsAreLive() throws {
    var keys: Set<String> = []
    for file in Self.guardedFiles {
      for site in try Self.sites(of: file) {
        if case .other(let function) = site.context { keys.insert("\(site.callee) in \(function)") }
      }
    }
    #expect(Set(Self.exemptions.keys).subtracting(keys).isEmpty, "stale exemption rows")
  }

  /// The injectable readers whose defaults read the driver are only ever called in lane jobs.
  @Test("the injected liveness and native-rate readers are called only inside lane jobs")
  func readerCallsRunOnTheLane() throws {
    let snapshot = try CachedSwiftParser.snapshot(
      at: RepoRoot.url.appending(path: Self.guardedFiles[0]))
    final class ReaderCalls: SyntaxVisitor {
      var contexts: [Context] = []
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        if callee.hasSuffix("livenessReader") || callee.hasSuffix("nativeRateReader")
          || callee == "reader" || callee == "rateReader"
        {
          contexts.append(AudioUnitLaneCallSiteTests.context(of: node))
        }
        return .visitChildren
      }
    }
    let visitor = ReaderCalls(viewMode: .sourceAccurate)
    visitor.walk(snapshot.tree)
    #expect(!visitor.contexts.isEmpty, "no reader calls found")
    #expect(visitor.contexts.allSatisfy { $0 == .lane }, "\(visitor.contexts)")
  }

  @Test("AudioUnitRender appears only in the real-time render callback")
  func renderStaysInTheCallback() throws {
    let sites = try Self.sites(of: Self.guardedFiles[0]).filter { $0.callee == "AudioUnitRender" }
    #expect(sites.count == 1)
    #expect(sites.allSatisfy { $0.context == .render })
  }

  @Test("the guard flags a driver call placed on the main actor, and accepts it inside a lane job")
  func guardRejectsAMainActorPlacement() {
    let fixture = """
      @MainActor final class Source {
        var lane: AudioUnitLane
        func badProbe(_ unit: AudioUnit) -> Bool {
          var running: UInt32 = 0
          var size = UInt32(4)
          return AudioUnitGetProperty(unit, 0, 0, 0, &running, &size) == noErr
        }
        func goodProbe(_ unit: AudioUnit) async {
          _ = await lane.run("running_probe") {
            var running: UInt32 = 0
            var size = UInt32(4)
            return AudioUnitGetProperty(unit, 0, 0, 0, &running, &size)
          }
        }
        func badDefault() -> String? { AudioDeviceEnumerator.defaultInputDeviceUID() }
        func pureHelpers() {
          _ = AudioObjectPropertyAddress(mSelector: 0, mScope: 0, mElement: 0)
          _ = AudioDeviceEnumerator.transportLabel(forTransportType: nil)
          _ = HALUnitNative.Progress()
        }
      }
      """
    let sites = Self.sites(source: fixture)
    #expect(
      sites.map(\.callee) == [
        "AudioUnitGetProperty", "AudioUnitGetProperty",
        "AudioDeviceEnumerator.defaultInputDeviceUID",
      ])
    #expect(sites.map(\.context) == [.other("badProbe"), .lane, .other("badDefault")])
  }

  @Test("the open moved out of its lane job, or a driver call in onTerminal, is flagged")
  func guardRejectsNativeEntryAndTerminalPlacements() {
    let fixture = """
      @MainActor final class Source {
        var lane: AudioUnitLane
        func movedOpen(_ snapshot: OpenRequest, _ unit: AudioUnit) async {
          let openWork = HALUnitNative.open
          let early = openWork(snapshot)
          _ = await lane.open(
            "microphone_start", attempt: nil, deadline: nil,
            onTerminal: { _ = AudioOutputUnitStop(unit) },
            { openWork(snapshot) },
            disposeLate: { _ in handoff.take()?.retire() })
          lane.retire { resources.retire() }
          resources.retire()
        }
      }
      """
    let sites = Self.sites(source: fixture).map { "\($0.callee) \($0.context)" }
    #expect(
      sites == [
        "openWork main: movedOpen",
        "AudioOutputUnitStop main: movedOpen",
        "openWork lane",
        "handoff.take()?.retire lane",
        "resources.retire lane",
        "resources.retire main: movedOpen",
      ])
  }
}
