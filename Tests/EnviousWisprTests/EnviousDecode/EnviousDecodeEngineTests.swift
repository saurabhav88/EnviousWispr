import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLlamaEngine
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousDecodeKit
@testable import EnviousWisprEG1Engine

/// #4473 P2: the app side of the EnviousDecode engine: what the app launches for an EG-1 size,
/// how it asks the helper for a polish, and how it reads the answer.
///
/// When this is wrong the user loses local polish without a message, or gets it from the wrong
/// model: the helper is started with a command line it refuses, so EG-1 never becomes ready; a
/// new draft model is installed and the old process keeps answering; the health check reads
/// green for a helper that cannot polish; a polish cut off at the token cap is pasted as if it
/// were whole; or the helper stays alive after the app stopped it. Encounter: every start of
/// EG-1, every model update, every dictation. Owner: plan #4473 P2 (EnviousDecodeEngine).
/// Rigs: the lifecycle fixture's fake server for the process rules, and the helper the build
/// embeds in the Dev app with the local candidate models for the real launch.
@Suite(
  "The app launches the EnviousDecode helper for EG-1 and reads its answers (#4473)",
  .serialized, .tags(.productOutcome))
struct EnviousDecodeEngineTests {
  typealias Connector = EnviousWisprEG1Engine.EGOneConnector
  typealias Integration = EnviousDecodeHelperIntegrationTests
  typealias Fixture = EGOneAdapterLifecycleTests.Fixture

  static let cacheLimit = 256 * 1024 * 1024

  static func identity(_ name: String, _ revision: String) -> ModelIdentity {
    ModelIdentity(
      family: .egOne, name: name, revision: revision, variant: "fixture", runtimeABI: "fixture")
  }

  // MARK: - Requests, built the way the app builds them

  struct PolishRequest {
    let envelope: PromptEnvelope
    let config: LLMProviderConfig
    /// The body the connector sends for this request.
    let body: Data
  }

  static func request(transcript: String, cap: Int, family: PromptFamily) throws -> PolishRequest {
    let input = PromptBuildInput(
      transcript: transcript, provider: .egOne, modelID: LLMProvider.egOneModelName,
      appName: nil, language: nil, polishVocabulary: PolishVocabulary(terms: [], generation: 0))
    let envelope = DefaultPromptPlanner.builder(for: family).build(input: input, mode: .message)
    let config = LLMProviderConfig(
      model: LLMProvider.egOneModelName, apiKeyKeychainId: nil, outputTokens: .capped(cap),
      temperature: 0, thinking: nil, detectedLanguage: nil)
    let pair = try #require(envelope.asSingleTurn())
    let body = try JSONSerialization.data(
      withJSONObject: try Connector.makeRequestBody(
        system: pair.system ?? "", user: pair.user, config: config))
    return PolishRequest(envelope: envelope, config: config, body: body)
  }

  /// Why a polish through the connector did not give text, or nil when it did.
  static func skipReason(
    _ connector: Connector, _ request: PolishRequest
  ) async -> String? {
    do {
      _ = try await connector.polish(
        envelope: request.envelope, config: request.config, onToken: nil)
      return nil
    } catch LLMError.egOneSkipped(.crashed) {
      return "crashed"
    } catch LLMError.egOneSkipped(.outputTruncated) {
      return "outputTruncated"
    } catch {
      return "other: \(error)"
    }
  }

  struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
  }

  /// Looks for a signal of a child process (its exit, its port going quiet) until it is there,
  /// and throws `TimedOut` when `seconds` pass first.
  static func signal(
    _ what: String, within seconds: Double, _ present: @Sendable () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !(await present()) {
      guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
      try await Task.sleep(for: .milliseconds(50))  // deadline-fallback: the child is another process; its exit is read until the deadline
    }
  }

  static func answersHealth(_ endpoint: LocalPolishEndpoint) async -> Bool {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/health")!)
    request.timeoutInterval = 2
    request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
    let response = (try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse
    return response?.statusCode == 200
  }

  // MARK: - 1. What is launched

  @Test(
    "the launch of an EG-1 size on the helper is exactly this spec and this command line, another draft model is another launch, and a llama launch is what it was"
  )
  func theLaunchSpecAndCommandLineAreExact() throws {
    let helper = URL(fileURLWithPath: "/Applications/EW.app/Contents/MacOS/envious-decode")
    let model = URL(fileURLWithPath: "/models/eg1-mini", isDirectory: true)
    let draft = URL(fileURLWithPath: "/models/eg1-mini-draft", isDirectory: true)
    let modelIdentity = Self.identity("eg1-mini", "m1")
    let draftIdentity = Self.identity("eg1-mini-draft", "d1")
    let adapter = URL(fileURLWithPath: "/models/eg1-mini-checker/adapters.safetensors")
    func configuration(
      draft: URL = draft, draftIdentity: ModelIdentity = draftIdentity,
      cacheLimit: Int = 268_435_456, adapter: URL? = nil
    ) -> LocalPolishProcessManager.Configuration {
      EnviousDecodeEngine(
        draftModelURL: draft, draftArtifactIdentity: draftIdentity, cacheLimitBytes: cacheLimit
      ).makeLaunchConfiguration(.egOne(.mini), modelIdentity, helper, model, 8192, adapter)
    }

    // The spec, field by field.
    let launch = configuration()
    let expected = LocalPolishLaunchSpec(
      engineKind: .enviousDecode, modelID: .egOne(.mini), artifactIdentity: modelIdentity,
      serverBinaryURL: helper, modelURL: model, contextTokens: 8192, learnedWordAdapterURL: nil,
      extraArguments: ["--cache-limit-bytes", "268435456"], learnedWordAdapterArguments: [],
      draftModelURL: draft, draftArtifactIdentity: draftIdentity)
    #expect(launch.spec == expected)
    #expect(launch.spec.learnedWordAdapterURL == nil)
    // The helper's seven arguments, with the port and bearer of one spawn.
    #expect(
      launch.makeArguments(launch.spec, 49152, "bearer-1") == [
        "--model", "/models/eg1-mini", "--draft-model", "/models/eg1-mini-draft",
        "--model-name", "eg-1", "--port", "49152", "--token", "bearer-1",
        "--ctx-size", "8192", "--cache-limit-bytes", "268435456",
      ])
    // The same values again are the same launch; the fallback copy keeps the draft model.
    #expect(configuration().spec == launch.spec)
    #expect(launch.spec.withoutLearnedWordAdapter() == launch.spec)

    // With the checker adapter's weights file offered (#4473 P3): the spec carries that file,
    // the helper is told its folder after its seven arguments, and it is another launch. The
    // fallback copy is the launch without the adapter, argument included.
    let adapted = configuration(adapter: adapter)
    #expect(
      adapted.spec
        == LocalPolishLaunchSpec(
          engineKind: .enviousDecode, modelID: .egOne(.mini), artifactIdentity: modelIdentity,
          serverBinaryURL: helper, modelURL: model, contextTokens: 8192,
          learnedWordAdapterURL: adapter, extraArguments: ["--cache-limit-bytes", "268435456"],
          learnedWordAdapterArguments: ["--word-check-adapter", "/models/eg1-mini-checker"],
          draftModelURL: draft, draftArtifactIdentity: draftIdentity))
    #expect(
      adapted.makeArguments(adapted.spec, 49152, "bearer-1") == [
        "--model", "/models/eg1-mini", "--draft-model", "/models/eg1-mini-draft",
        "--model-name", "eg-1", "--port", "49152", "--token", "bearer-1",
        "--ctx-size", "8192", "--cache-limit-bytes", "268435456",
        "--word-check-adapter", "/models/eg1-mini-checker",
      ])
    #expect(adapted.spec != launch.spec)
    #expect(adapted.spec.withoutLearnedWordAdapter() == launch.spec)

    // Another draft revision, another draft folder, another cache limit: each another launch.
    let otherRevision = configuration(draftIdentity: Self.identity("eg1-mini-draft", "d2")).spec
    #expect(otherRevision != launch.spec)
    #expect(otherRevision.draftModelURL == draft)
    let otherFolder = configuration(
      draft: URL(fileURLWithPath: "/models/eg1-mini-draft-2", isDirectory: true))
    #expect(otherFolder.spec != launch.spec)
    #expect(
      otherFolder.makeArguments(otherFolder.spec, 1, "t")[3] == "/models/eg1-mini-draft-2")
    #expect(configuration(cacheLimit: 134_217_728).spec != launch.spec)
    #expect(
      configuration(cacheLimit: 134_217_728).spec.extraArguments
        == ["--cache-limit-bytes", "134217728"])

    // The request the connector sends holds only fields the helper serves.
    let body = try Connector.makeRequestBody(
      system: "s", user: "u",
      config: LLMProviderConfig(
        model: LLMProvider.egOneModelName, apiKeyKeychainId: nil, outputTokens: .capped(64),
        temperature: 0, thinking: nil, detectedLanguage: nil))
    #expect(Set(body.keys) == ["model", "messages", "max_tokens", "temperature"])
    #expect(Set(body.keys).isSubset(of: EnviousDecodeRequestMapper.knownFields))
    #expect(body["model"] as? String == "eg-1" && body["max_tokens"] as? Int == 64)

    // The llama engine, built with the constructor call it always had: same spec, same
    // command line, and no draft model.
    let llamaBinary = URL(fileURLWithPath: "/Applications/EW.app/Contents/Resources/llama-server")
    let gguf = URL(fileURLWithPath: "/models/eg1.gguf")
    let llamaIdentity = Self.identity("eg1", "g1")
    let llama = LlamaServerEngine().makeLaunchConfiguration(
      .singleModel(for: .egOne), llamaIdentity, llamaBinary, gguf, 16384, nil)
    let llamaFlags = [
      "-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--spec-type",
      "ngram-simple",
    ]
    #expect(
      llama.spec
        == LocalPolishLaunchSpec(
          engineKind: .llamaServer, modelID: .singleModel(for: .egOne),
          artifactIdentity: llamaIdentity, serverBinaryURL: llamaBinary, modelURL: gguf,
          contextTokens: 16384, learnedWordAdapterURL: nil, extraArguments: llamaFlags,
          learnedWordAdapterArguments: []))
    #expect(llama.spec.draftModelURL == nil && llama.spec.draftArtifactIdentity == nil)
    #expect(
      llama.makeArguments(llama.spec, 49152, "bearer-1")
        == [
          "-m", "/models/eg1.gguf", "--host", "127.0.0.1", "--port", "49152", "-c", "16384",
          "--api-key", "bearer-1",
        ] + llamaFlags)
    // The engine kind alone makes two launches different.
    let sameButLlama = LocalPolishLaunchSpec(
      engineKind: .llamaServer, modelID: expected.modelID,
      artifactIdentity: expected.artifactIdentity, serverBinaryURL: helper, modelURL: model,
      contextTokens: 8192, learnedWordAdapterURL: nil, extraArguments: expected.extraArguments,
      learnedWordAdapterArguments: [], draftModelURL: draft, draftArtifactIdentity: draftIdentity)
    #expect(sameButLlama != expected)
  }

  // MARK: - 2. The real helper, started by the process manager

  /// About 10 seconds with the Mini candidate: the process manager starts the real helper
  /// (model load), the probe and three requests run on it, and the same folders are loaded in
  /// this process for the expected answers.
  @Test(
    "the process manager starts the embedded helper, the health check polishes for real, the connector gets the engine's own answer, and a prompt of more than 1024 tokens is served",
    .enabled(if: EnviousDecodeHelperIntegrationTests.canRun))
  func theProcessManagerStartsTheRealHelper() async throws {
    // The helper inherits this process's environment: the attention opt-out of the research
    // build is not set, so the long prompt below runs on the ordinary attention path.
    #expect(ProcessInfo.processInfo.environment["EW_SDPA_NO_NAX_DSPLIT"] == nil)
    let family = PromptFamily.egOneEnvelopeNamedLanguage
    let folders = Integration.Fixtures.self
    let engine = EnviousDecodeEngine(
      draftModelURL: URL(
        fileURLWithPath: try #require(folders.helperFolders["mini"] ?? nil), isDirectory: true),
      draftArtifactIdentity: Self.identity("eg1-mini-draft", "candidate"),
      cacheLimitBytes: Self.cacheLimit)
    var configuration = engine.makeLaunchConfiguration(
      .egOne(.mini), Self.identity("eg1-mini", "candidate"),
      try #require(Integration.helperCandidates.first),
      URL(fileURLWithPath: try #require(folders.targetFolders["mini"] ?? nil), isDirectory: true),
      8192, nil)
    configuration.readinessBudgetSeconds = 180

    let manager = LocalPolishProcessManager()
    defer { manager.terminateImmediately() }
    await manager.start(configuration: configuration)
    let state = await manager.currentLifecycle().state
    let endpoint = try #require(await manager.activeEndpoint(), "the helper is \(state)")
    #expect(endpoint.contextTokens == 8192 && !endpoint.hasLearnedWordAdapter)

    // The health check is a real polish through the connector; it is the helper's first
    // request, so it also pays the helper's one-time first-request work. The verdict read here
    // is the transformation. `probe_slow` is the same transformation taking over 5 seconds,
    // which a loaded test machine can cause; speed is measured at the P2 speed gate.
    let health = await manager.probeHealth(
      operation: engine.makeHealthProbe(.egOne(.mini), family))
    #expect(health == .green || health == .yellow(reason: "probe_slow"), "\(health)")

    // The connector's answer is the engine's own answer for the same request.
    let reference = try await Integration.Reference.load(size: "mini")
    let connector = Connector(endpoint: endpoint)
    let short = try Self.request(
      transcript: "um so i think we should uh meet on friday no wait thursday", cap: 128,
      family: family)
    let expectedShort = try reference.expected(short.body)
    #expect(expectedShort.finish == "stop")
    #expect(!expectedShort.content.lowercased().contains("transcript>"))
    let answer = try await connector.polish(
      envelope: short.envelope, config: short.config, onToken: nil)
    #expect(
      answer.polishedText
        == expectedShort.content.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(!answer.polishedText.isEmpty)

    // A long dictation: the prompt alone is more than 1024 tokens. The cap is small, so the
    // helper stops at it: the helper's answer is the engine's own, and the connector reads a
    // capped answer as truncated and skips it whole.
    let sentence =
      "so the next thing on the list is the quarterly planning review and i think we should "
      + "move the budget discussion to the second half because finance still needs to confirm "
      + "the numbers for the new hires and the travel requests before we can decide anything "
    let long = try Self.request(
      transcript: String(repeating: sentence, count: 24), cap: 48, family: family)
    let prepared = try EnviousDecodeRequestMapper.prepare(
      body: long.body, configuration: reference.configuration, tokenizer: reference.tokenizer)
    #expect(prepared.promptTokenIDs.count >= 1024, "\(prepared.promptTokenIDs.count) tokens")
    let expectedLong = try reference.expected(long.body)
    #expect(expectedLong.finish == "length" && !expectedLong.content.isEmpty)
    let served = try Integration.fields(
      try await LocalPolishTransport.send(endpoint: endpoint, body: long.body))
    #expect(served.content == expectedLong.content)
    #expect(served.finish == "length")
    #expect(await Self.skipReason(connector, long) == "outputTruncated")
    // The helper still serves after the long prompt.
    #expect(await Self.skipReason(connector, short) == nil)

    // Stopped by the process manager, the helper goes away.
    await manager.stop()
    #expect(await manager.activeEndpoint() == nil)
    // deadline-fallback: the signal is the helper's port going quiet after SIGTERM; its stated bound is 2 s
    try await Self.signal("the stopped helper to leave its port", within: 6) {
      !(await Self.answersHealth(endpoint))
    }
  }

  // MARK: - 3. The process rules and the edges of the adapter

  /// About 3 seconds: four real launches of the lifecycle fixture's fake server as a child
  /// process, the fixture's half-second floor each.
  @Test(
    "the neutral lifecycle starts, stops and restarts the engine's launch, another draft model replaces the process, and refused, empty and capped answers are skipped"
  )
  func theLifecycleRunsTheLaunchAndTheConnectorSkipsBadAnswers() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let draft = fixture.root.appendingPathComponent("draft", isDirectory: true)
    let otherDraft = fixture.root.appendingPathComponent("draft-2", isDirectory: true)
    for folder in [draft, otherDraft] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func engine(_ draft: URL, revision: String) -> EnviousDecodeEngine {
      EnviousDecodeEngine(
        draftModelURL: draft, draftArtifactIdentity: Self.identity("draft", revision),
        cacheLimitBytes: Self.cacheLimit)
    }
    func target(_ engine: EnviousDecodeEngine) -> LocalPolishTarget {
      // No checker adapter is offered here; the launch with one is in the word checker's suite.
      var configuration = engine.makeLaunchConfiguration(
        .singleModel(for: .egOne), Self.identity("model", "m1"), fixture.binary, fixture.model,
        4096, nil)
      configuration.readinessBudgetSeconds = 4
      return LocalPolishTarget(configuration: configuration)
    }
    func arguments(_ draft: URL, _ endpoint: LocalPolishEndpoint) -> [String] {
      [
        "--model", fixture.model.path, "--draft-model", draft.path, "--model-name", "eg-1",
        "--port", String(endpoint.port), "--token", endpoint.authToken, "--ctx-size", "4096",
        "--cache-limit-bytes", "268435456",
      ]
    }
    let first = engine(draft, revision: "d1")
    let coordinator = LocalPolishServerCoordinator()

    // Start: the child was started with the engine's command line, and no checker rides it.
    await coordinator.transition(to: .run(target(first)), intent: coordinator.claimIntent())
    let endpoint = try #require(await coordinator.endpoint(for: .egOne))
    #expect(!endpoint.hasLearnedWordAdapter)
    #expect(try fixture.launches() == [arguments(draft, endpoint)])
    let firstPID = try fixture.lastPID()

    // The health check sends one real polish request with only the fields the helper serves.
    let probe = first.makeHealthProbe(.singleModel(for: .egOne), .egOneFixed)
    #expect(await coordinator.probeHealth(.egOne, operation: probe) == .green)
    let posts = try String(
      contentsOf: fixture.root.appendingPathComponent("posts.jsonl"), encoding: .utf8
    ).split(separator: "\n")
    #expect(posts.count == 1)
    let postLine = try #require(posts.last)
    let post = try #require(
      try JSONSerialization.jsonObject(with: Data(postLine.utf8)) as? [String: String])
    #expect(post["path"] == "/v1/chat/completions")
    let postBody = try #require(post["body"])
    let sent = try #require(
      try JSONSerialization.jsonObject(with: Data(postBody.utf8)) as? [String: Any])
    #expect(Set(sent.keys) == ["model", "messages", "max_tokens", "temperature"])
    #expect(sent["model"] as? String == "eg-1" && sent["max_tokens"] as? Int == 128)
    #expect(sent["temperature"] as? Double == 0)
    let turns = try #require(sent["messages"] as? [[String: String]])
    #expect(turns.map { $0["role"] } == ["system", "user"])
    #expect(turns.last?["content"]?.contains("move the meeting to thursday no wait friday") == true)

    // What the connector makes of the helper's answers.
    let connector = Connector(endpoint: endpoint)
    let request = try Self.request(transcript: "um send it friday", cap: 64, family: .egOneFixed)
    func script(_ name: String, _ value: String?) throws {
      let file = fixture.root.appendingPathComponent(name)
      try? FileManager.default.removeItem(at: file)
      if let value { try Data(value.utf8).write(to: file) }
    }
    // An echoed transcript wrapper is removed.
    try script("post_content", "<TRANSCRIPT>\nSend it Friday.\n</TRANSCRIPT>")
    let cleaned = try await connector.polish(
      envelope: request.envelope, config: request.config, onToken: nil)
    #expect(cleaned.polishedText == "Send it Friday.")
    // An answer that is not the transformation reads yellow, never green.
    try script("post_content", "So um move the meeting to Thursday, no wait, Friday.")
    #expect(
      await coordinator.probeHealth(.egOne, operation: probe)
        == .yellow(reason: "probe_output_unexpected"))
    // Only a wrapper, or only spaces: nothing to paste, so the polish is skipped silently.
    try script("post_content", "<TRANSCRIPT></TRANSCRIPT>")
    #expect(await Self.skipReason(connector, request) == "crashed")
    try script("post_content", "  \n ")
    #expect(await Self.skipReason(connector, request) == "crashed")
    // A request the helper refuses (HTTP 400) is skipped silently, and the health check is red.
    try script("post_content", nil)
    try script("post_status", "400")
    #expect(await Self.skipReason(connector, request) == "crashed")
    #expect(
      await coordinator.probeHealth(.egOne, operation: probe) == .red(reason: "probe_failed"))
    try script("post_status", nil)
    // An answer that stopped at the cap is a partial rewrite: skipped whole, never pasted.
    let capped = try JSONSerialization.data(withJSONObject: [
      "choices": [
        [
          "index": 0, "finish_reason": "length",
          "message": ["role": "assistant", "content": "Send it"],
        ] as [String: Any]
      ]
    ])
    #expect {
      try Connector.parseSuccess(data: capped)
    } throws: { error in
      if case LLMError.egOneSkipped(.outputTruncated) = error { return true }
      return false
    }
    #if DEBUG
      // The helper has no slots; the engine says so without a request.
      #expect(try await first.inspectSlots(endpoint, 1) == .unsupported)
    #endif

    // The same launch asked again leaves the process alone.
    await coordinator.transition(
      to: .run(target(engine(draft, revision: "d1"))), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 1)

    // Stop, then start: the old child is gone and a new one serves.
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) == nil)
    // deadline-fallback: the signal is the stopped child's exit, read from its process ID
    try await Self.signal("the stopped child to exit", within: 5) { kill(firstPID, 0) != 0 }
    await coordinator.transition(to: .run(target(first)), intent: coordinator.claimIntent())
    let restarted = try #require(await coordinator.endpoint(for: .egOne))
    #expect(try fixture.launches().count == 2)
    #expect(try fixture.launches().last == arguments(draft, restarted))
    let secondPID = try fixture.lastPID()
    #expect(secondPID != firstPID)

    // Another revision of the draft model in the same folder: the command line is the same,
    // and the process is still replaced, because the bytes it loaded are not the new ones.
    await coordinator.transition(
      to: .run(target(engine(draft, revision: "d2"))), intent: coordinator.claimIntent())
    let revised = try #require(await coordinator.endpoint(for: .egOne))
    #expect(try fixture.launches().count == 3)
    #expect(try fixture.launches().last == arguments(draft, revised))
    #expect(try fixture.lastPID() != secondPID)

    // Another draft folder: replaced again, started with the new folder.
    await coordinator.transition(
      to: .run(target(engine(otherDraft, revision: "d2"))), intent: coordinator.claimIntent())
    let moved = try #require(await coordinator.endpoint(for: .egOne))
    #expect(try fixture.launches().count == 4)
    #expect(try fixture.launches().last == arguments(otherDraft, moved))
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }
}
