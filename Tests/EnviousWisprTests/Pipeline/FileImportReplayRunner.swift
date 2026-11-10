import CryptoKit
import EnviousWisprCore
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing
@testable import EnviousWisprServices

/// #4450: the processing stage of the international sealed polish exams. Not a product test: it
/// replays a manifest of recogniser texts through the shipped Transcribe a File engine and runs
/// only when one is named (`TEST_RUNNER_EW_REPLAY_MANIFEST`), so the ordinary lane reports it
/// skipped, like `WhisperFileTranscriptionRunner`.
///
/// Every case goes through the same calls `WisprBootstrapper.beginRun` makes:
/// `FileImportSettingsFreeze.snapshot`, `FileImportRunner.freeze` with the corrector vocabulary
/// the custom-words seed builds, the word-check preload, the bundled server's activation and
/// import hold, then `process(part:engineLanguage:)`. The engine's own objects are built the way
/// the composition root builds them, rooted in a temporary Application Support whose model
/// files are hard links to the installed ones, so the user's real install is never written.
///
/// What the polisher received is captured once, by wrapping the production polisher factories:
/// the real connector still answers. The prompt family comes from the planner the step really
/// used; the named-language decision is read from the step's own route line in this process's
/// log, never recomputed.
@MainActor
@Suite(
  "File import replay runner (#4450, international sealed exams)", .serialized,
  .tags(.harnessContract))
struct FileImportReplayRunner {

  nonisolated private static var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }
  nonisolated static var manifestIsNamed: Bool { environment["EW_REPLAY_MANIFEST"] != nil }

  nonisolated static var repoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  /// The arms the exam grades. Mini occupies the EG-1 slot: everything is production except the
  /// endpoint the EG-1 connector is pointed at.
  enum Arm: String {
    /// `canned` (#4450, founder 2026-11-08): answers written by another engine (EnviousDecode,
    /// #4446) fill the EG-1 slot; everything after the model is production.
    case egOne, appleIntelligence, none, mini, canned
    var provider: LLMProvider {
      switch self {
      case .egOne, .mini, .canned: .egOne
      case .appleIntelligence: .appleIntelligence
      case .none: .none
      }
    }
  }

  @Test(
    "replays every case the manifest names through the production file-import runner",
    .enabled(if: manifestIsNamed), .tags(.realBoundary), .realBoundaryRun)
  func runManifest() async throws {
    let env = Self.environment
    let manifest = try #require(env["EW_REPLAY_MANIFEST"])
    let outPath = try #require(env["EW_REPLAY_OUT"])
    try #require(
      !FileManager.default.fileExists(atPath: outPath), "refusing to overwrite \(outPath)")
    let arm = try #require(Arm(rawValue: env["EW_REPLAY_ARM"] ?? ""), "EW_REPLAY_ARM")
    let appBundle = URL(fileURLWithPath: try #require(env["EW_REPLAY_APP_BUNDLE"]))
    let modelsDir = URL(
      fileURLWithPath: env["EW_REPLAY_MODELS_DIR"]
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EnviousWispr/Models").path)

    // The route line (`polish_language_hint`) is an AppLogger line; this process's log goes to
    // the lane's own folder (`scripts/xcode-test.sh` sets it), never the dev app's.
    await AppLogger.shared.setDebugMode(true)
    let logURL = await AppLogger.shared.logDirectoryURL().appendingPathComponent("app.log")

    let rig = try await ReplayRig.make(
      arm: arm, appBundle: appBundle, modelsDir: modelsDir,
      settingsPlist: env["EW_REPLAY_SETTINGS_PLIST"], wordsFile: env["EW_REPLAY_WORDS_JSON"],
      mini: try Self.miniEndpoint(arm: arm, env: env), miniSHA256: env["EW_REPLAY_MINI_SHA256"])
    defer { rig.tearDown() }

    var out = Data()
    func emit(_ object: [String: Any]) throws {
      out.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      out.append(0x0A)
    }
    try emit(["header": true, "arm": arm.rawValue, "identity": rig.identity])

    var rowCount = 0
    let lines = try String(contentsOfFile: manifest, encoding: .utf8).split(separator: "\n")
    for line in lines where !line.isEmpty {
      let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let id = try #require(row["id"] as? String)
      let text = try #require(row["text"] as? String)
      let backendName = try #require(row["backend"] as? String)
      let backend = try #require(ASRBackendType(rawValue: backendName))
      let engineLanguage = row["engine_language"] as? String
      let logStart = Self.fileSize(logURL)
      do {
        let result = try await rig.process(
          id: id, text: text, backend: backend, engineLanguage: engineLanguage)
        let marker = "EW_REPLAY_CASE_END \(UUID().uuidString)"
        await AppLogger.shared.log(marker, level: .info, category: "Replay")
        let route = Self.routeLines(logURL, from: logStart, until: marker)
        try emit(
          [
            "id": id, "arm": arm.rawValue, "delivered": result.outcome.displayText,
            "pre_polish": result.outcome.text,
            "polished": result.outcome.polishedText ?? NSNull(),
            "polish_attempted": result.outcome.wasPolishAttempted,
            "polisher_calls": result.calls.map(\.json),
            "plans": result.plans,
            "route_lines": route.lines,
            "route_observed": route.markerFound,
            "polish_skip_lines": route.skips,
            "checker_selection": result.checker,
            "frozen_settings": result.snapshotJSON,
            "engine_language": engineLanguage ?? NSNull(), "backend": backend.rawValue,
          ])
      } catch {
        try emit(["id": id, "arm": arm.rawValue, "error": String(describing: error)])
      }
      rowCount += 1
    }
    #expect(rowCount > 0, "the manifest named no cases")
    try out.write(to: URL(filePath: outPath), options: .withoutOverwriting)
  }

  /// The route reader: lines up to this case's own marker, and "not observed" when the marker
  /// is missing, so an unread log is never reported as "no route".
  @Test("route lines are read up to the case marker and a missing marker is not observed")
  func routeLinesStopAtMarker() throws {
    let url = TestTemporaryDirectory.url.appendingPathComponent("route-\(UUID().uuidString).log")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let before = "[t] [INFO] [LLM] LLM prompt route: provider=egOne, prompt_family=a\n"
    try Data(before.utf8).write(to: url)
    let offset = Self.fileSize(url)
    let body =
      "[t] [INFO] [LLM] LLM prompt route: provider=egOne, prompt_family=b\n"
      + "[t] [INFO] [TextProcessing] LLM Polish timed out after 9.0ms — skipping\n"
      + "[t] [INFO] [LLM] LLM polish skipped: transcript too short (2 words, minimum 4)\n"
      + "[t] [INFO] [Replay] EW_REPLAY_CASE_END m1\n"
      + "[t] [INFO] [LLM] LLM prompt route: provider=egOne, prompt_family=c\n"
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(body.utf8))
    try handle.close()
    let read = Self.routeLines(url, from: offset, until: "EW_REPLAY_CASE_END m1")
    #expect(read.markerFound == true)
    #expect(read.lines.count == 1)
    #expect(read.lines.first?.hasSuffix("prompt_family=b") == true)
    #expect(read.skips.count == 2)
    let missing = Self.routeLines(url, from: offset, until: "EW_REPLAY_CASE_END m2")
    #expect(missing.markerFound == false)
  }

  /// Guard and model results stay graded; a missing or broken dependency invalidates the run,
  /// and an error the table does not know is treated as broken, never as the model's answer.
  @Test("polisher errors split into production outcomes and infrastructure failures")
  func polisherErrorClassification() {
    #expect(
      ReplayPolisherCall.classify(AFMPolishError(underlying: LLMError.frameworkUnavailable("off")))
        == "infrastructure")
    #expect(
      ReplayPolisherCall.classify(
        AFMPolishError(underlying: LLMError.outputLanguageDrift(expected: "fr", actual: "en")))
        == "production_outcome")
    #expect(
      ReplayPolisherCall.classify(AFMPolishError(underlying: CocoaError(.featureUnsupported)))
        == "production_outcome")
    #expect(ReplayPolisherCall.classify(AFMContextWindowExceeded(stage: .predicted)) == "production_outcome")
    #expect(ReplayPolisherCall.classify(LLMError.unsupportedInputLanguage("hi")) == "production_outcome")
    #expect(
      ReplayPolisherCall.classify(LLMError.outputLanguageDrift(expected: "fr", actual: "en"))
        == "production_outcome")
    #expect(ReplayPolisherCall.classify(LLMError.egOneSkipped(.inputTooLong)) == "production_outcome")
    #expect(ReplayPolisherCall.classify(LLMError.egOneSkipped(.outputTruncated)) == "production_outcome")
    #expect(ReplayPolisherCall.classify(LLMError.egOneSkipped(.crashed)) == "infrastructure")
    #expect(ReplayPolisherCall.classify(LLMError.egOneSkipped(.notReady)) == "infrastructure")
    #expect(ReplayPolisherCall.classify(LLMError.providerUnavailable) == "infrastructure")
    #expect(ReplayPolisherCall.classify(CancellationError()) == "cancelled")
    #expect(ReplayPolisherCall.classify(URLError(.cancelled)) == "cancelled")
    #expect(ReplayPolisherCall.classify(URLError(.notConnectedToInternet)) == "infrastructure")
  }

  @Test("the Mini arm requires its own endpoint and model hash; other arms refuse one")
  func miniEndpointIsRequiredOnlyForMini() throws {
    let full = [
      "EW_REPLAY_MINI_PORT": "47000", "EW_REPLAY_MINI_TOKEN": "t",
      "EW_REPLAY_MINI_CONTEXT": "16384", "EW_REPLAY_MINI_SHA256": "abc",
    ]
    let endpoint = try #require(try Self.miniEndpoint(arm: .mini, env: full))
    #expect(endpoint.port == 47000)
    #expect(endpoint.hasLearnedWordAdapter == false)
    #expect(throws: (any Error).self) { try Self.miniEndpoint(arm: .mini, env: [:]) }
    #expect(throws: (any Error).self) { try Self.miniEndpoint(arm: .egOne, env: full) }
    #expect(try Self.miniEndpoint(arm: .egOne, env: [:]) == nil)
  }

  /// The Mini arm must name its own server; any other arm must not. A Mini run without one
  /// would silently polish with EG-1 under Mini's name.
  struct ReplayConfigurationError: Error, CustomStringConvertible {
    let description: String
  }

  static func miniEndpoint(arm: Arm, env: [String: String]) throws -> EGOneEndpoint? {
    func need(_ key: String) throws -> String {
      guard let value = env[key], !value.isEmpty else {
        throw ReplayConfigurationError(description: "the Mini arm needs \(key)")
      }
      return value
    }
    guard arm == .mini else {
      if env["EW_REPLAY_MINI_PORT"] != nil {
        throw ReplayConfigurationError(description: "a Mini endpoint was named for arm \(arm)")
      }
      return nil
    }
    guard let port = UInt16(try need("EW_REPLAY_MINI_PORT")),
      let context = Int(try need("EW_REPLAY_MINI_CONTEXT"))
    else { throw ReplayConfigurationError(description: "Mini port or context is not a number") }
    let token = try need("EW_REPLAY_MINI_TOKEN")
    _ = try need("EW_REPLAY_MINI_SHA256")
    return EGOneEndpoint(
      port: port, authToken: token, contextTokens: context, hasLearnedWordAdapter: false)
  }


  nonisolated static func fileSize(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
      .uint64Value ?? 0
  }

  /// The step's `LLM prompt route:` lines written after `offset`, read up to this case's own end
  /// marker. `markerFound == false` means the log could not be read to the end of this case, so
  /// an empty `lines` is "not observed", never "no route".
  nonisolated static func routeLines(_ url: URL, from offset: UInt64, until marker: String)
    -> (lines: [String], markerFound: Bool, skips: [String])
  {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false, []) }
    defer { try? handle.close() }
    try? handle.seek(toOffset: offset)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    var lines: [String] = []
    var skips: [String] = []
    for line in text.split(separator: "\n") {
      if line.contains(marker) { return (lines, true, skips) }
      if line.contains("LLM prompt route:") { lines.append(String(line)) }
      // The runner's own terminal line for a polish that did not deliver (timeouts, skips,
      // failures, including ones raised before any polisher was asked).
      if line.contains("[TextProcessing]"), line.hasSuffix("— skipping") { skips.append(String(line)) }
      // The polish step's own deliberate short-input bypass (`LLMPolishStep`), which raises
      // nothing and so has no runner skip line.
      if line.contains("LLM polish skipped: transcript too short") { skips.append(String(line)) }
    }
    return (lines, false, skips)
  }
}

/// What one polisher invocation received and returned.
struct ReplayPolisherCall: Sendable {
  let provider: String
  let messages: [(role: String, content: String)]
  let output: String?
  let error: String?
  /// `infrastructure` (a dependency the run needed was missing or broken: the run is invalid)
  /// or `production_outcome` (a guard or model result the app delivers as-is: the pre-polish
  /// text is the arm's real outcome). Nil when the call succeeded.
  let errorClass: String?
  var json: [String: Any] {
    [
      "provider": provider,
      "messages": messages.map { ["role": $0.role, "content": $0.content] },
      "output": output ?? NSNull(), "error": error ?? NSNull(),
      "error_class": errorClass ?? NSNull(),
    ]
  }

  /// The exam's classification of a polisher error, from the production error types. Anything
  /// not listed is infrastructure, so an unknown failure invalidates the run rather than being
  /// graded as the model's answer.
  static func classify(_ error: Error) -> String {
    // `AFMPolishError` wraps whatever the Apple generation block threw, including a runtime
    // that became unavailable (`AppleIntelligenceConnector.swift`), so read what it wraps.
    if let wrapped = error as? AFMPolishError {
      if wrapped.underlying is LLMError || wrapped.underlying is AFMPolishError
        || wrapped.underlying is CancellationError
      {
        return classify(wrapped.underlying)
      }
      // A FoundationModels generation error (guardrail, refusal, decoding): the model's own
      // result, which the user receives as the pre-polish text.
      return "production_outcome"
    }
    if error is AFMContextWindowExceeded { return "production_outcome" }
    // The polish task was cancelled. In this harness nothing cancels a case, so the producer is
    // the runner's own step deadline (`TextProcessingRunner` timeout) or a torn-down request;
    // the runner's logged skip line for the case decides which (driver).
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return "cancelled" }
    guard let llm = error as? LLMError else { return "infrastructure" }
    switch llm {
    case .unsupportedInputLanguage, .outputLanguageDrift: return "production_outcome"
    case .egOneSkipped(let reason):
      switch reason {
      case .inputTooLong, .outputTruncated: return "production_outcome"
      case .notReady, .downloadPending, .crashed: return "infrastructure"
      }
    default: return "infrastructure"
    }
  }

}

actor ReplayCallLog {
  /// The case in flight, stamped on checker records so a selection that returns after its case
  /// ended is visible as late instead of being read as the next case's.
  private(set) var currentCase = ""
  func begin(_ caseID: String) { currentCase = caseID }
  private(set) var calls: [ReplayPolisherCall] = []
  private(set) var plans: [[String: String]] = []
  func append(_ call: ReplayPolisherCall) { calls.append(call) }
  func appendPlan(_ plan: [String: String]) { plans.append(plan) }
  func drain() -> ([ReplayPolisherCall], [[String: String]]) {
    defer {
      calls = []
      plans = []
    }
    return (calls, plans)
  }
}

/// Forwards to the production polisher and records the request it was given. Both entry points
/// are forwarded explicitly, so the connector's own envelope or legacy path still runs.
struct CapturingPolisher: TranscriptPolisher {
  let inner: any TranscriptPolisher
  let provider: String
  let log: ReplayCallLog

  func polish(
    text: String, instructions: PolishInstructions, config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    let messages = [("system", instructions.systemPrompt), ("user", text)]
    return try await record(messages) {
      try await inner.polish(
        text: text, instructions: instructions, config: config, onToken: onToken)
    }
  }

  func polish(
    envelope: PromptEnvelope, config: LLMProviderConfig, onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    let messages = envelope.messages.map { ($0.role.rawValue, $0.content) }
    return try await record(messages) {
      try await inner.polish(envelope: envelope, config: config, onToken: onToken)
    }
  }

  private func record(
    _ messages: [(String, String)], _ call: () async throws -> LLMResult
  ) async throws -> LLMResult {
    do {
      let result = try await call()
      await log.append(
        .init(
          provider: provider, messages: messages.map { (role: $0.0, content: $0.1) },
          output: result.polishedText, error: nil, errorClass: nil))
      return result
    } catch {
      await log.append(
        .init(
          provider: provider, messages: messages.map { (role: $0.0, content: $0.1) },
          output: nil, error: String(describing: error),
          errorClass: ReplayPolisherCall.classify(error)))
      throw error
    }
  }
}

/// #4450: answers produced by another engine for the EG-1 slot. Each answer is handed to the
/// real EG-1 connector parse, wrapped as the chat-completion body llama-server returns, so the
/// truncation refusal, tag stripping and emptiness rule are production's. A case with no answer
/// throws (infrastructure: the run is invalid, never graded as the model's output).
struct ReplayAnswerPolisher: TranscriptPolisher {
  let answers: [String: (output: String, finishReason: String)]
  let log: ReplayCallLog

  struct MissingAnswer: Error { let id: String }

  func polish(
    text: String, instructions: PolishInstructions, config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult { try await answer() }

  func polish(
    envelope: PromptEnvelope, config: LLMProviderConfig, onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult { try await answer() }

  private func answer() async throws -> LLMResult {
    let id = await log.currentCase
    guard let a = answers[id] else { throw MissingAnswer(id: id) }
    let body: [String: Any] = [
      "choices": [["message": ["role": "assistant", "content": a.output],
                   "finish_reason": a.finishReason]]
    ]
    return try EGOneConnector.parseSuccess(data: try JSONSerialization.data(withJSONObject: body))
  }
}

/// Records the plan the production planner made, then returns it unchanged.
struct RecordingPlanner: PromptPlanning {
  let inner: any PromptPlanning
  let log: ReplayCallLog
  func plan(input: PromptBuildInput) -> PolishPlan {
    let plan = inner.plan(input: input)
    let system = plan.envelope.messages.first { $0.role == .system }?.content ?? ""
    let record = [
      "family": plan.family.rawValue, "mode": String(describing: plan.mode),
      "system_sha256": ReplayRig.sha256(Data(system.utf8)),
    ]
    let log = log
    Task { await log.appendPlan(record) }
    return plan
  }
}

/// Resumes one waiter with the first value fired; later fires are ignored.
@MainActor
final class ReplayOnceSignal {
  private var value: Bool?
  private var waiter: CheckedContinuation<Bool, Never>?
  func fire(_ v: Bool) {
    guard value == nil else { return }
    value = v
    waiter?.resume(returning: v)
    waiter = nil
  }
  func wait() async -> Bool {
    if let value { return value }
    return await withCheckedContinuation { waiter = $0 }
  }
}

/// The settings the runtime callbacks read. Each case installs its own settings here before it
/// freezes, so Word Check residency and EG-1 activation see the same settings the case froze.
@MainActor
final class ReplaySettingsBox {
  var settings: SettingsManager
  init(_ settings: SettingsManager) { self.settings = settings }
}

/// The objects one arm's replay runs on, built once per process like the app builds them once
/// per launch; each case still freezes and prepares like one import.
@MainActor
final class ReplayRig {
  let arm: FileImportReplayRunner.Arm
  let identity: [String: Any]
  private let root: URL
  private let settingsSuiteName: String
  private let settingsPlist: [String: Any]?
  private let corrector: CorrectorVocabulary
  private let log = ReplayCallLog()
  private let runner: FileImportRunner
  private let checkerEligibility: LearnedWordCheckerEligibility
  private let localPolish: LocalPolishRuntimeSet
  private let wordCheck: WordCheckRuntime
  private let classifierHolder: OutputClassifierHolder
  private let appResources: URL
  private var lastChecker: [String: String] = [:]
  private var settingsBox: ReplaySettingsBox?

  struct CaseResult {
    let outcome: FileImportRunner.PartOutcome
    let calls: [ReplayPolisherCall]
    let plans: [[String: String]]
    let checker: [String: String]
    let snapshotJSON: Any
  }

  private init(
    arm: FileImportReplayRunner.Arm, identity: [String: Any], root: URL, settingsSuiteName: String,
    settingsPlist: [String: Any]?, corrector: CorrectorVocabulary, runner: FileImportRunner,
    checkerEligibility: LearnedWordCheckerEligibility, localPolish: LocalPolishRuntimeSet,
    wordCheck: WordCheckRuntime, classifierHolder: OutputClassifierHolder, appResources: URL
  ) {
    self.arm = arm
    self.identity = identity
    self.root = root
    self.settingsSuiteName = settingsSuiteName
    self.settingsPlist = settingsPlist
    self.corrector = corrector
    self.runner = runner
    self.checkerEligibility = checkerEligibility
    self.localPolish = localPolish
    self.wordCheck = wordCheck
    self.classifierHolder = classifierHolder
    self.appResources = appResources
  }

  nonisolated static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func make(
    arm: FileImportReplayRunner.Arm, appBundle: URL, modelsDir: URL, settingsPlist: String?,
    wordsFile: String?, mini: EGOneEndpoint?, miniSHA256: String?
  ) async throws -> ReplayRig {
    let fm = FileManager.default
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      "ew-4450-replay-\(UUID().uuidString)", isDirectory: true)
    let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
    let resources = appBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
    let serverBinary = resources.appendingPathComponent("llama-server")
    try #require(fm.isExecutableFile(atPath: serverBinary.path), "no llama-server in \(appBundle)")
    let manifestBundle = try #require(
      Bundle(
        url: FileImportReplayRunner.repoRoot.appendingPathComponent(
          "Sources/EnviousWispr/Resources")))

    // Settings: an isolated suite, fresh-install defaults unless an exported domain is named
    // (the fidelity check loads the dev app's own exported settings so both sides match).
    let suiteName = "ew-4450-replay-\(UUID().uuidString)"
    let defaults = try #require(TestDefaults.suite(suiteName))
    var plist: [String: Any]?
    if let settingsPlist {
      let data = try Data(contentsOf: URL(fileURLWithPath: settingsPlist))
      plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
      defaults.setPersistentDomain(plist ?? [:], forName: suiteName)
    }
    let settingsBox = ReplaySettingsBox(SettingsManager(defaults: defaults))

    // Vocabulary: the coordinator's launch read (built-ins merged with the file), then the seed
    // split `wireCustomWords` performs. A missing file is a fresh install.
    let wordsURL =
      wordsFile.map { URL(fileURLWithPath: $0) }
      ?? root.appendingPathComponent("fresh-custom-words.json")
    let wordsCopy = root.appendingPathComponent("custom-words.json")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    if fm.fileExists(atPath: wordsURL.path) { try fm.copyItem(at: wordsURL, to: wordsCopy) }
    let words = try #require(CustomWordsManager(fileURL: wordsCopy).loadSnapshot()?.words)
    try #require(!words.isEmpty, "the vocabulary read returned no words, not even built-ins")
    let corrector = LanePartitioner.split(words, generation: 0).corrector

    // Model delivery rooted in the temporary Application Support; installed files are hard
    // links, so admission hashes the user's real bytes without writing to their install.
    let flags = try #require(TestDefaults.suite("\(suiteName)-flags"))
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting, manifestBundle: manifestBundle,
      appSupportOverride: root, deliveryFlagDefaults: flags)
    let dataDir = appSupport.appendingPathComponent("EnviousWispr", isDirectory: true)
    let egOneManifest = try EGOneManifest.loadBundled(from: manifestBundle)
    let egOneDelivery = try DeliveryManifest.loadBundled(
      resource: "eg1-delivery-manifest", bundle: manifestBundle)
    let egOneRegistration = DeliveryRegistration(
      manifest: egOneDelivery,
      installDirectory: dataDir.appendingPathComponent("Models/eg-1", isDirectory: true),
      metadataDirectory: dataDir.appendingPathComponent("ModelDelivery", isDirectory: true))
    for name in ["eg-1", "eg-1-checker", "word-check"] {
      try linkTree(
        from: modelsDir.appendingPathComponent(name, isDirectory: true),
        to: dataDir.appendingPathComponent("Models/\(name)", isDirectory: true))
    }
    let egOneAdapter = EGOneDeliveryAdapter(
      controller: home.controller, registration: egOneRegistration,
      version: egOneManifest.resolvedDisplayVersion)
    let egOneAdmitted = await egOneAdapter.adoptIfPresent()
    let checkerRegistration = try #require(home.checkerRegistrations[.egOne])
    let checkerAdmitted = await home.controller.admitIfComplete(checkerRegistration)
    let wordCheckAdmitted: Bool
    if let registration = home.wordCheckRegistration {
      wordCheckAdmitted = await home.controller.admitIfComplete(registration)
    } else {
      wordCheckAdmitted = false
    }

    let promptTemplateID = egOneManifest.promptTemplateID
    let egOneRuntime = EGOneRuntime(
      manifest: egOneManifest.runtimeFacts(expectedModelName: LLMProvider.egOneModelName),
      serverBinaryURL: serverBinary, delivery: egOneAdapter,
      makeHealthProbe: LlamaServerHealthProbe.make,
      makeLaunchConfiguration: LlamaServerLaunchBuilder.makeConfiguration,
      learnedWordAdapterProvider: {
        return await home.admittedCompatibleCheckerURL(
          engine: .egOne, baseRegistration: egOneRegistration, promptTemplateID: promptTemplateID)
      })
    egOneRuntime.isActiveProvider = { settingsBox.settings.effectiveFileImportLLMProvider == .egOne }
    let s1MiniRuntime = EGOneRuntime(
      manifest: nil, serverBinaryURL: serverBinary, delivery: nil,
      makeHealthProbe: LlamaServerHealthProbe.make,
      makeLaunchConfiguration: LlamaServerLaunchBuilder.makeConfiguration,
      coordinator: egOneRuntime.serverCoordinator, provider: .s1Mini)
    let localPolish = LocalPolishRuntimeSet(egOne: egOneRuntime, s1Mini: s1MiniRuntime)
    let checkerEligibility = LearnedWordCheckerEligibility(
      delivery: home,
      engines: [
        .egOne: .init(
          base: egOneRegistration, promptTemplateID: promptTemplateID, runtime: egOneRuntime,
          debugThreshold: nil)
      ])
    let wordCheck = WordCheckRuntime(
      delivery: home,
      isDictionaryEnabled: { settingsBox.settings.wordCorrectionEnabled },
      someEngineLacksOwnChecker: {
        let settings = settingsBox.settings
        return LearnedWordCheckerEngine(provider: settings.llmProvider) == nil
          || LearnedWordCheckerEngine(provider: settings.effectiveFileImportLLMProvider) == nil
      },
      isOnboardingComplete: { true })
    checkerEligibility.wordCheck = wordCheck
    // The word check learns its model is admitted through an asynchronous state replay. In the
    // app that lands long before any import; here the first case can arrive first and read
    // "downloading". Wait for the controller's own replay, then require the runtime to report
    // ready (its status read never loads the model).
    if wordCheckAdmitted {
      // Signalled by the word check itself: its delivery-state handler ends with
      // `onStatusChange`, so readiness is read when the runtime says something changed, after
      // checking the current status first. The status read never loads the model.
      let ready = LearnedCheckerSettingsStatus(checkedBy: WordCheckRuntime.judge)
      if wordCheck.settingsStatus() != ready {
        let signal = ReplayOnceSignal()
        let previous = wordCheck.onStatusChange
        wordCheck.onStatusChange = { [weak wordCheck] in
          previous()
          if wordCheck?.settingsStatus() == ready { signal.fire(true) }
        }
        // Hang guard only: the controller replays an admitted state to a late observer at once.
        let guardTask = Task { @MainActor in
          try? await Task.sleep(for: .seconds(60))
          signal.fire(false)
        }
        let becameReady = await signal.wait()
        guardTask.cancel()
        wordCheck.onStatusChange = previous
        try #require(becameReady, "word check never reported ready: \(wordCheck.settingsStatus())")
      }
    }
    let classifierHolder = OutputClassifierHolder()

    // The polisher factories are the step's own defaults, wrapped. Read off a throwaway step so
    // the wrapped closure is exactly the one production would have used.
    // #4473: the EG-1 factory is no longer a step default. It is read from the explicit llama
    // pair, the same connector the app's composition root supplies.
    let llamaPolishers = BundledLocalPolisherFactories.llamaForTests
    let probe = LLMPolishStep(
      keychainManager: KeychainManager(), localPolishers: llamaPolishers, telemetry: .silent())
    let productionFactory = probe.makePolisher
    let productionEGOne = llamaPolishers.egOne
    // The production planner reads the EG-1 family from `Bundle.main`, which in a test host is
    // the xctest bundle, so it would fall back to `.egOneFixed`. Built from the same committed
    // manifest the app bundles, exactly what the app's `bundledEGOneFamily` resolves.
    let egOneFamily = try #require(egOneManifest.promptFamily)
    let productionPlanner = DefaultPromptPlanner(egOneFamily: egOneFamily)
    let rigLog = ReplayCallLog()
    // #4450: the canned arm's answers, {"id", "output", "finish_reason"} per line.
    var cannedMap: [String: (output: String, finishReason: String)]?
    var cannedSHA256: String?
    if arm == .canned {
      let path = try #require(
        ProcessInfo.processInfo.environment["EW_REPLAY_CANNED"], "EW_REPLAY_CANNED")
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      cannedSHA256 = sha256(data)
      var map: [String: (output: String, finishReason: String)] = [:]
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.isEmpty {
        let row = try #require(
          try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let id = try #require(row["id"] as? String)
        let output = try #require(row["output"] as? String)
        map[id] = (output, (row["finish_reason"] as? String) ?? "stop")
      }
      cannedMap = map
    }
    let canned = cannedMap
    let runner = FileImportRunner(
      keychainManager: KeychainManager(),
      localPolishers: llamaPolishers.replacingEGOne { endpoint in
        if let canned {
          return CapturingPolisher(
            inner: ReplayAnswerPolisher(answers: canned, log: rigLog), provider: "canned", log: rigLog)
        }
        return CapturingPolisher(
          inner: productionEGOne(mini ?? endpoint), provider: mini == nil ? "egOne" : "mini",
          log: rigLog)
      },
      egOneRuntime: egOneRuntime, s1MiniRuntime: s1MiniRuntime,
      outputClassifierHolder: classifierHolder,
      languageIdentifier: DictationLanguageResolver.identify,
      promptPlanner: RecordingPlanner(inner: productionPlanner, log: rigLog),
      checkerSelectionProvider: { [checkerEligibility] provider, language in
        let caseID = await rigLog.currentCase
        let selection = await checkerEligibility.selection(provider: provider, language: language)
        await rigLog.appendPlan([
          "checker_case": caseID,
          "checker_provider": provider.rawValue, "checker_language": language ?? "",
          "checker_identity": selection.identity ?? "",
          "checker_absence": selection.absence.map { String(describing: $0) } ?? "",
        ])
        return selection
      },
      makePolisher: { provider, keychain, classifier, list in
        productionFactory(provider, keychain, classifier, list).map {
          CapturingPolisher(inner: $0, provider: provider.rawValue, log: rigLog)
            as any TranscriptPolisher
        }
      })

    // The server and classifier come from the built app; the manifests from the committed
    // resources. Refuse a build whose bundled manifests differ from the committed ones.
    var manifestIdentity: [String: String] = [:]
    for name in [
      "eg1-manifest.json", "eg1-delivery-manifest.json", "eg1-checker-delivery-manifest.json",
      "word-check-delivery-manifest.json",
    ] {
      let committed = try Data(contentsOf: manifestBundle.bundleURL.appendingPathComponent(name))
      let bundled = try Data(contentsOf: resources.appendingPathComponent(name))
      try #require(committed == bundled, "\(name): app bundle differs from the committed resource")
      manifestIdentity[name] = sha256(committed)
    }
    let terms = corrector.terms.map {
      ["canonical": $0.canonical, "aliases": $0.aliases, "learned_aliases": $0.learnedAliases]
        as [String: Any]
    }
    let termsData = try JSONSerialization.data(withJSONObject: terms, options: [.sortedKeys])
    var identity: [String: Any] = [
      "manifests_committed_equal_bundled": manifestIdentity,
      "classifier_sha256": try treeSHA256(resources.appendingPathComponent("OutputClassifier.mlmodelc"))
        + ":" + treeSHA256(resources.appendingPathComponent("OutputClassifierTokenizer")),
      "settings_sha256": try settingsPlist.map { sha256(try Data(contentsOf: URL(fileURLWithPath: $0))) }
        ?? "fresh-install",
      "words_sha256": try wordsFile.map { sha256(try Data(contentsOf: URL(fileURLWithPath: $0))) }
        ?? "fresh-install",
      "corrector_terms": terms, "corrector_terms_sha256": sha256(termsData),
      "apple_dispatch": "the capture wrapper is not AppleIntelligenceConnector, so LLMPolishStep's "
        + "concrete prepared-session cast does not apply; the protocol entry calls the same "
        + "overload with prepared: nil, which is file import's unclaimed-session path. The "
        + "captured system text is the connector's input, not Apple's assembled model prompt.",
      "app_bundle": appBundle.path,
      "llama_server_sha256": try sha256(Data(contentsOf: serverBinary)),
      "eg1_manifest_prompt_template": promptTemplateID,
      "eg1_prompt_family": egOneFamily.rawValue,
      "eg1_model_revision": egOneDelivery.identity.revision,
      "eg1_admitted": egOneAdmitted, "eg1_checker_admitted": checkerAdmitted,
      "eg1_checker_revision": checkerRegistration.manifest.identity.revision,
      "word_check_admitted": wordCheckAdmitted,
      "settings_source": settingsPlist ?? "fresh-install",
      "words_source": wordsFile ?? "fresh-install",
      "vocabulary_terms": words.count,
      
      "afm_adapter_path_set": ProcessInfo.processInfo.environment["EW_AFM_ADAPTER_PATH"] != nil,
    ]
    #if DEBUG
      identity["dev_adapter_polish_enabled"] = settingsBox.settings.devAdapterPolishEnabled
    #endif
    if let cannedSHA256 {
      identity["canned_answers_sha256"] = cannedSHA256
      identity["canned_answers_path"] = ProcessInfo.processInfo.environment["EW_REPLAY_CANNED"]
    }
    if let mini {
      identity["mini_endpoint_port"] = Int(mini.port)
      identity["mini_model_sha256"] = miniSHA256 ?? NSNull()
      // #4450: the same EG-1 slot also serves EG-1 1.3 (Qwen3.5-4B); the driver names the model.
      identity["mini_label"] =
        ProcessInfo.processInfo.environment["EW_REPLAY_MINI_LABEL"]
        ?? ("Mini polishing in the EG-1 slot (production preparation, EG-1 prompt and request); the "
          + "word check is served by EG-1's runtime and checker adapter, which a shipped Mini "
          + "would replace with its own: an evaluation configuration, not a complete Mini stack")
    }
    let rig = ReplayRig(
      arm: arm, identity: identity, root: root, settingsSuiteName: suiteName,
      settingsPlist: plist, corrector: corrector, runner: runner,
      checkerEligibility: checkerEligibility, localPolish: localPolish, wordCheck: wordCheck,
      classifierHolder: classifierHolder, appResources: resources)
    rig.logStore = rigLog
    rig.settingsBox = settingsBox
    return rig
  }

  private var logStore: ReplayCallLog?

  /// One import: fresh settings for the case's backend and the arm's provider, the beginRun
  /// freeze, the word-check preload, the bundled server's preparation, then the part.
  func process(id: String, text: String, backend: ASRBackendType, engineLanguage: String?) async throws
    -> CaseResult
  {
    await (logStore ?? log).begin(id)
    let suite = "\(settingsSuiteName)-\(UUID().uuidString)"
    let defaults = try #require(TestDefaults.suite(suite))
    if let settingsPlist { defaults.setPersistentDomain(settingsPlist, forName: suite) }
    let settings = SettingsManager(defaults: defaults)
    // The engine and polisher the case needs, set as a user picks them (and as the fidelity
    // drill's dev-control door set them on the app side): the backend and `llmProvider` only.
    settings.selectedBackend = backend
    settings.llmProvider = arm.provider
    try #require(
      settings.effectiveFileImportLLMProvider == arm.provider,
      "settings give \(settings.effectiveFileImportLLMProvider), arm needs \(arm.provider)")
    try #require(settings.selectedBackend == backend, "settings backend differs from the case")

    let box = try #require(settingsBox)
    box.settings = settings
    let snapshot = FileImportSettingsFreeze.snapshot(settings: settings)
    let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
    runner.freeze(settings: snapshot, vocabulary: corrector, cloudModelList: nil)
    wordCheck.fileImportStarted(
      needsWordCheck: LearnedWordCheckerEngine(
        provider: LLMProvider(rawValue: snapshot.llmProvider) ?? .none) == nil)
    // In the app this preload runs while the file is still decoding and transcribing, so the
    // first part finds the model loaded. The replay starts from recogniser text, so it waits for
    // the load the preload started; without this the first case's check outlived the step's
    // selection deadline and was skipped (round 3, `old-r3/replay_alias_none_fresh.jsonl`).
    await wordCheck.runningLoadsFinishedForTests()
    let configuration = FileImportSettingsFreeze.configuration(
      for: snapshot, ollamaModelIsRemote: false)
    if configuration.polishProvider == .appleIntelligence {
      try await loadClassifier()
    }
    if let provider = configuration.localPolishProvider {
      try await prepareLocalPolish(provider)
    }
    defer {
      localPolish.releaseImportHold()
      runner.releaseCheckerSelections()
    }
    let outcome = try await runner.process(part: text, engineLanguage: engineLanguage)
    let (calls, plans) = await (logStore ?? log).drain()
    return CaseResult(
      outcome: outcome, calls: calls, plans: plans, checker: lastChecker, snapshotJSON: snapshotJSON)
  }

  /// `prepareLocalPolish` from `WisprBootstrapper`: activation awaited, the endpoint checked,
  /// then the import hold. A refusal invalidates the case rather than letting the step skip.
  private func prepareLocalPolish(_ provider: LLMProvider) async throws {
    let runtime = try #require(localPolish.runtime(for: .singleModel(for: provider)))
    if let activation = runtime.activateAndProbe() { await activation.value }
    let endpoint = await runtime.activeEndpoint()
    try #require(endpoint != nil, "\(provider) endpoint unavailable after activation")
    try #require(await localPolish.holdForImport(provider), "\(provider) import hold refused")
    lastChecker = [
      "provider": provider.rawValue,
      "server_has_learned_word_adapter": String(endpoint?.hasLearnedWordAdapter ?? false),
    ]
  }

  /// The prewarm `reconcileOutputClassifierDemand` runs for an Apple Intelligence consumer.
  private func loadClassifier() async throws {
    let resources = appResources
    _ = await classifierHolder.beginLoadIfNeeded(requestedAt: classifierHolder.releaseGeneration) {
      try await CoreMLOutputClassifier.load(resourceURL: resources)
    }
    try #require(classifierHolder.classifier != nil, "output classifier did not load")
  }

  func tearDown() {
    localPolish.releaseImportHold()
    localPolish.runtime(for: .singleModel(for: .egOne))?.terminateServerForAppQuit()
    try? FileManager.default.removeItem(at: root)
  }

  /// One digest over a directory tree: every regular file's relative path and bytes, sorted.
  static func treeSHA256(_ root: URL) throws -> String {
    let fm = FileManager.default
    let enumerator = try #require(fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var entries: [(String, String)] = []
    for case let url as URL in enumerator
    where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
      entries.append((String(url.path.dropFirst(root.path.count + 1)), sha256(try Data(contentsOf: url))))
    }
    try #require(!entries.isEmpty, "empty tree \(root.path)")
    return sha256(Data(entries.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)\n" }.joined().utf8))
  }

  /// Recreates `source` under `destination` with every regular file hard-linked.
  private static func linkTree(from source: URL, to destination: URL) throws {
    let fm = FileManager.default
    try #require(fm.fileExists(atPath: source.path), "installed model missing: \(source.path)")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let enumerator = try #require(
      fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]))
    for case let url as URL in enumerator {
      let relative = String(url.path.dropFirst(source.path.count + 1))
      let target = destination.appendingPathComponent(relative)
      if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
      } else {
        try fm.linkItem(at: url, to: target)
      }
    }
  }
}
