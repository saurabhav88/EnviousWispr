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
  /// with Audio is not a hardware call by itself.
  static func isHardwareCall(_ callee: String) -> Bool {
    let prefixes = [
      "AudioUnitGetProperty", "AudioUnitSetProperty", "AudioUnitInitialize",
      "AudioUnitUninitialize", "AudioUnitRender", "AudioOutputUnitStart", "AudioOutputUnitStop",
      "AudioComponentFindNext", "AudioComponentInstanceNew", "AudioComponentInstanceDispose",
      "AudioObjectGetPropertyData", "AudioObjectSetPropertyData", "AudioObjectHasProperty",
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
      if AudioUnitLaneCallSiteTests.isHardwareCall(callee) {
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

  /// Whether `closure` is an argument (labelled or trailing) of `lane.<entry>(...)`.
  static func isLaneArgument(_ closure: ClosureExprSyntax) -> Bool {
    var node = Syntax(closure)
    for _ in 0..<3 {
      guard let parent = node.parent else { return false }
      if let call = parent.as(FunctionCallExprSyntax.self) {
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
    // No production caller (manager reads `isRunningOnLane`, #4601 C5D); kept as the protocol's
    // synchronous property for test fakes. Reported for removal in the C8B review.
    "AudioUnitGetProperty in isRunning": "HALDeviceInputSource.isRunning: no production caller",
    // No production caller (manager uses `warmBindCompatibleOnLane`, #4601 C5D); kept for the
    // conformance tests. Reported for removal in the C8B review.
    "inputDeviceResolver.isWarmBindCompatible in boundDeviceMatchesResolvedTargetForReuse":
      "sync warm-bind predicate: no production caller",
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
}
