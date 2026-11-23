import EnviousWisprCore
import EnviousWisprEG1Engine
import EnviousWisprLlamaEngine
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprLocalPolish

/// #3853: the "Unload polish model after" choice becomes one launch flag on both bundled engines.
///
/// When this fails, a user who picked a time keeps a helper that never sleeps, or a user who
/// kept Never gets a helper that frees its model and makes the next dictation wait, or a changed
/// choice is not seen as a different launch so the running helper keeps its old idle time.
@Suite("Polish helper idle time reaches both engines' launch (#3853)", .tags(.productOutcome))
struct LocalPolishSleepIdleTests {
  static let expectedSeconds: [(ModelUnloadPolicy, Int?)] = [
    (.never, nil), (.immediately, 10), (.twoMinutes, 120), (.fiveMinutes, 300),
    (.tenMinutes, 600), (.fifteenMinutes, 900), (.sixtyMinutes, 3600),
  ]

  static let identity = ModelIdentity(
    family: .egOne, name: "fixture", revision: "r1", variant: "fixture", runtimeABI: "fixture")
  static let binary = URL(fileURLWithPath: "/tmp/ew-sleep/server")
  static let model = URL(fileURLWithPath: "/tmp/ew-sleep/model")
  static let draft = URL(fileURLWithPath: "/tmp/ew-sleep/draft")

  static func egOneSpec(_ seconds: @escaping @Sendable () -> Int?) -> LocalPolishLaunchSpec {
    EnviousDecodeEngine(
      draftModelURL: draft, draftArtifactIdentity: identity, cacheLimitBytes: 1024,
      sleepIdleSeconds: seconds
    ).makeLaunchConfiguration(.egOne(.mini), identity, binary, model, 8192, nil).spec
  }

  static func s1Spec(_ seconds: @escaping @Sendable () -> Int?) -> LocalPolishLaunchSpec {
    LlamaServerEngine(sleepIdleSeconds: seconds).makeLaunchConfiguration(
      .singleModel(for: .s1Mini), identity, binary, model, 16384, nil
    ).spec
  }

  @Test("each of the seven choices maps to its own idle seconds; Never has none")
  func secondsPerChoice() {
    #expect(ModelUnloadPolicy.allCases.count == Self.expectedSeconds.count)
    for (policy, seconds) in Self.expectedSeconds {
      #expect(LocalPolishSleepIdle.seconds(for: policy) == seconds, "\(policy)")
    }
  }

  @Test("the flag is rendered only for a positive idle time")
  func flagRendering() {
    #expect(LocalPolishSleepIdle.arguments(seconds: nil).isEmpty)
    #expect(LocalPolishSleepIdle.arguments(seconds: 0).isEmpty)
    #expect(LocalPolishSleepIdle.arguments(seconds: -3).isEmpty)
    #expect(LocalPolishSleepIdle.arguments(seconds: 120) == ["--sleep-idle-seconds", "120"])
  }

  @Test("EG-1 and S1-mini launch with the flag for every choice, and with none for Never")
  func matrix() {
    for (policy, seconds) in Self.expectedSeconds {
      let value = LocalPolishSleepIdle.seconds(for: policy)
      let egOne = Self.egOneSpec { value }.extraArguments
      let s1 = Self.s1Spec { value }.extraArguments
      if let seconds {
        #expect(egOne.suffix(2) == ["--sleep-idle-seconds", String(seconds)], "EG-1 \(policy)")
        #expect(s1.suffix(2) == ["--sleep-idle-seconds", String(seconds)], "S1-mini \(policy)")
      } else {
        #expect(!egOne.contains("--sleep-idle-seconds"), "EG-1 \(policy)")
        #expect(!s1.contains("--sleep-idle-seconds"), "S1-mini \(policy)")
      }
    }
  }

  @Test("the default launch has no flag and the other flags are untouched")
  func defaultsKeepOldLaunch() {
    #expect(Self.egOneSpec({ nil }).extraArguments == ["--cache-limit-bytes", "1024"])
    #expect(
      Self.s1Spec({ nil }).extraArguments
        == LlamaServerLaunchBuilder.engineArguments(for: .s1Mini))
  }

  @Test("a different choice is a different spec on both engines, the same choice is equal")
  func specEquality() {
    #expect(Self.egOneSpec({ 120 }) != Self.egOneSpec({ nil }))
    #expect(Self.egOneSpec({ 120 }) != Self.egOneSpec({ 300 }))
    #expect(Self.egOneSpec({ 120 }) == Self.egOneSpec({ 120 }))
    #expect(Self.s1Spec({ 120 }) != Self.s1Spec({ nil }))
    #expect(Self.s1Spec({ 120 }) != Self.s1Spec({ 300 }))
    #expect(Self.s1Spec({ 120 }) == Self.s1Spec({ 120 }))
  }

  @Test("the engine reads the setting at each launch, not once at construction")
  func readAtEachLaunch() {
    let setting = LocalPolishSleepIdleSetting(seconds: nil)
    let egOne = EnviousDecodeEngine(
      draftModelURL: Self.draft, draftArtifactIdentity: Self.identity, cacheLimitBytes: 1024,
      sleepIdleSeconds: setting.reader)
    let s1 = LlamaServerEngine(sleepIdleSeconds: setting.reader)
    func specs() -> (LocalPolishLaunchSpec, LocalPolishLaunchSpec) {
      (
        egOne.makeLaunchConfiguration(
          .egOne(.mini), Self.identity, Self.binary, Self.model, 8192, nil
        ).spec,
        s1.makeLaunchConfiguration(
          .singleModel(for: .s1Mini), Self.identity, Self.binary, Self.model, 16384, nil
        ).spec
      )
    }
    let before = specs()
    setting.seconds = 600
    let after = specs()
    #expect(before.0 != after.0 && before.1 != after.1)
    #expect(after.0.extraArguments.suffix(2) == ["--sleep-idle-seconds", "600"])
    #expect(after.1.extraArguments.suffix(2) == ["--sleep-idle-seconds", "600"])
    setting.seconds = nil
    let back = specs()
    #expect(back.0 == before.0 && back.1 == before.1)
  }

  @Test("the flag reaches the process command line of both engines")
  func commandLine() {
    let inputs = LocalPolishLaunchConnection.Inputs(
      socketPath: "/l/s.sock", keyFileURL: URL(fileURLWithPath: "/l/k"), secret: "b")
    for spec in [Self.egOneSpec({ 300 }), Self.s1Spec({ 300 })] {
      let configuration =
        spec.engineKind == .enviousDecode
        ? EnviousDecodeEngine(
          draftModelURL: Self.draft, draftArtifactIdentity: Self.identity, cacheLimitBytes: 1024,
          sleepIdleSeconds: { 300 }
        ).makeLaunchConfiguration(.egOne(.mini), Self.identity, Self.binary, Self.model, 8192, nil)
        : LlamaServerEngine(sleepIdleSeconds: { 300 }).makeLaunchConfiguration(
          .singleModel(for: .s1Mini), Self.identity, Self.binary, Self.model, 16384, nil)
      let arguments = configuration.makeLaunch(configuration.spec, inputs).arguments
      #expect(arguments.contains("--sleep-idle-seconds"))
      #expect(
        arguments[arguments.firstIndex(of: "--sleep-idle-seconds")! + 1] == "300")
    }
  }
}

/// #3853: the recording-start wake is a courtesy that can never hurt a dictation.
@Suite("Polish helper wake request (#3853)", .tags(.productOutcome))
struct LocalPolishWakeTests {
  static let endpoint = LocalPolishEndpoint(
    socketPath: "/l/s.sock", authToken: "t", contextTokens: 8192)

  final class Seen: @unchecked Sendable {
    let lock = NSLock()
    var requests: [LocalPolishHelperRequest] = []
  }

  @Test("it sends one authenticated POST /wake with an empty JSON object and reports a 200")
  func sendsTheWake() async {
    let seen = Seen()
    let ok = await LocalPolishWake.send(to: Self.endpoint) { request, endpoint in
      seen.lock.withLock { seen.requests.append(request) }
      #expect(endpoint == Self.endpoint)
      return LocalPolishHelperResponse(status: 200, body: Data("{\"status\":\"awake\"}".utf8))
    }
    #expect(ok)
    let requests = seen.lock.withLock { seen.requests }
    #expect(requests.count == 1)
    #expect(requests.first?.method == .post)
    #expect(requests.first?.path == "/wake")
    #expect(requests.first?.body == Data("{}".utf8))
  }

  @Test("an older helper (404), a refusal, a lost connection and a cancelled caller are all silent")
  func failuresAreSilent() async {
    for status in [401, 404, 405, 503] {
      let ok = await LocalPolishWake.send(to: Self.endpoint) { _, _ in
        LocalPolishHelperResponse(status: status, body: Data())
      }
      #expect(!ok, "status \(status)")
    }
    for error in [
      LocalPolishHelperClientError.notConnectable, .connectionLost, .timedOut, .failed,
    ] {
      let ok = await LocalPolishWake.send(to: Self.endpoint) { _, _ in throw error }
      #expect(!ok, "\(error)")
    }
    let cancelled = await LocalPolishWake.send(to: Self.endpoint) { _, _ in
      throw CancellationError()
    }
    #expect(!cancelled)
  }
}
