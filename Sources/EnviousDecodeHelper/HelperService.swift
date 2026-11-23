import EnviousDecodeKit
import Foundation
import MLX

/// Writes one line to standard error. The helper's lines never hold the bearer token or any
/// request or answer text: only what happened, token counts and times.
func helperLog(_ line: String) {
  FileHandle.standardError.write(Data("envious-decode: \(line)\n".utf8))
}

/// The one owner of the loaded models. It is an actor, and a request's work on the models (the
/// generation or the word-check scoring) never suspends, so one request runs to its end before
/// the next one starts: the session is never used by two requests at once. The only place a
/// request waits is the wake below, before any work on the models; every request waiting there
/// shares ONE load and then runs its work one at a time. A request is worked on inside the
/// connection's own task, so when the client goes away and that task is cancelled, generation
/// stops at its next round and a request waiting for the models stops waiting.
///
/// #3853: with `--sleep-idle-seconds` the helper frees the models (and the word-check adapter
/// and the instruction snapshot with them) after that long without use, and keeps running.
/// The next request that needs the models loads them again and waits for it; a request that
/// does not need them (`/health`, a refused request) neither loads nor counts as use.
actor HelperService {
  private let arguments: HelperArguments
  /// The loaded pair, or nil while the helper sleeps.
  private var session: EnviousDecodeSession?
  /// The one load in progress, shared by every request that arrives while the helper wakes. It
  /// publishes the session itself when it ends, whether or not anyone is still waiting for it.
  private var loadTask: Task<Void, Never>?
  /// Requests waiting for that load. Each leaves on its own when its connection goes away; the
  /// load runs on for the others and for the next request.
  private var loadWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  /// Requests that need the models and have not finished with them, from before they wait for a
  /// load until their work ends. The idle check never frees the models while this is not zero.
  private var modelRequestsInFlight = 0
  private var idle: EnviousDecodeIdleSleep
  private let tokenizer: EnviousDecodeTokenizer
  private let configuration: EnviousDecodeRequestConfiguration
  private let token: String
  /// The ids of the two answer letters, when a word-check adapter is loaded.
  private let wordCheckAnswers: (a: Int, b: Int)?
  private var served = 0

  /// The models could not be loaded for a request: the helper stays asleep and answers 503,
  /// and the next request that needs them tries again.
  private struct WakeFailure: Error {}

  /// What can stop the helper from starting besides a model that does not load.
  enum StartError: Error, CustomStringConvertible {
    case answerLettersAreNotSingleTokens
    var description: String {
      "the tokenizer does not hold the two word-check answer letters as one token each"
    }
  }

  /// Loads the tokenizer, both models and, when its folder is given, the word-check adapter.
  /// Any failure is thrown: there is no other model or adapter to fall back to and nothing is
  /// downloaded. An adapter that does not fit the polish model stops the start; the app then
  /// starts the helper again without one.
  init(arguments: HelperArguments, token: String) async throws {
    self.arguments = arguments
    idle = EnviousDecodeIdleSleep(
      idleSeconds: arguments.sleepIdleSeconds, startedAt: Self.nowNanoseconds())
    let loaded = try await HelperTokenizer.load(
      modelFolder: arguments.modelFolder, modelName: arguments.modelName,
      contextTokens: arguments.contextTokens)
    tokenizer = loaded.tokenizer
    configuration = loaded.configuration
    self.token = token
    if arguments.wordCheckAdapterFolder != nil {
      let a = loaded.tokenizer.encode(HelperWordCheck.answers.a)
      let b = loaded.tokenizer.encode(HelperWordCheck.answers.b)
      guard a.count == 1, b.count == 1, a != b else {
        throw StartError.answerLettersAreNotSingleTokens
      }
      wordCheckAnswers = (a[0], b[0])
    } else {
      wordCheckAnswers = nil
    }
    session = try await EnviousDecodeSession.load(
      targetDirectory: arguments.modelFolder, draftDirectory: arguments.draftFolder,
      wordCheckAdapterDirectory: arguments.wordCheckAdapterFolder)
    if let wordCheckAnswers {
      helperLog("word check loaded answer_tokens=\(wordCheckAnswers.a),\(wordCheckAnswers.b)")
    }
    idle.noteUse(at: Self.nowNanoseconds())
    startIdleWatcher()
  }

  private static func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  /// Checks once a second whether the models have been unused long enough to free. It runs on
  /// this actor between requests: a request's work on the models never suspends, so the check
  /// can never run in the middle of one, and `isLoading` keeps it away from a wake.
  private func startIdleWatcher() {
    guard arguments.sleepIdleSeconds != nil else { return }
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self else { return }
        await self.sleepIfIdle()
      }
    }
  }

  private func sleepIfIdle() {
    guard modelRequestsInFlight == 0,
      idle.shouldSleep(
        at: Self.nowNanoseconds(), modelsLoaded: session != nil, isLoading: loadTask != nil)
    else { return }
    // The session goes first: it holds the models, the checker and the instruction snapshot.
    // The cache is cleared after, so the buffers the models held are returned to the system.
    session = nil
    MLX.Memory.clearCache()
    helperLog("sleeping idle_seconds=\(arguments.sleepIdleSeconds ?? 0)")
  }

  /// The loaded pair, loading it first when the helper sleeps. Every request that arrives while
  /// the load runs waits for that same load. A waiter whose connection goes away stops waiting
  /// at once and the load runs on for the others. The load publishes the session itself when it
  /// ends, so a load nobody waits for any more still leaves the helper in a state the idle check
  /// understands. A failed load leaves the helper asleep and fails every waiter with
  /// `WakeFailure`; the next request that needs the models tries again.
  private func awake() async throws -> EnviousDecodeSession {
    try Task.checkCancellation()
    if let session { return session }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          waiter.resume(throwing: CancellationError())
          return
        }
        if session != nil {
          waiter.resume()
          return
        }
        loadWaiters[id] = waiter
        if loadTask == nil {
          loadTask = Task { await self.reloadModels() }
        }
      }
    } onCancel: {
      Task { await self.cancelLoadWaiter(id) }
    }
    try Task.checkCancellation()
    guard let session else { throw WakeFailure() }
    return session
  }

  private func cancelLoadWaiter(_ id: UUID) {
    loadWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  /// The one load: publishes the session, counts the wake as use from the moment it finished,
  /// and tells every waiter that is still there.
  private func reloadModels() async {
    let startedAt = Self.nowNanoseconds()
    let result: Result<Void, any Error>
    do {
      session = try await EnviousDecodeSession.load(
        targetDirectory: arguments.modelFolder, draftDirectory: arguments.draftFolder,
        wordCheckAdapterDirectory: arguments.wordCheckAdapterFolder)
      let finishedAt = Self.nowNanoseconds()
      idle.noteUse(at: finishedAt)
      helperLog("waking ms=\((finishedAt - startedAt) / 1_000_000)")
      result = .success(())
    } catch {
      helperLog("waking failed")
      result = .failure(WakeFailure())
    }
    loadTask = nil
    let waiters = loadWaiters
    loadWaiters.removeAll()
    for waiter in waiters.values { waiter.resume(with: result) }
  }

  /// The answer to one request, or nil when the request was cancelled (nothing is sent).
  func respond(to request: HelperRequest) async -> HelperResponse? {
    served += 1
    let number = served
    let started = DispatchTime.now().uptimeNanoseconds
    func milliseconds() -> Int { Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }
    func refuse(_ status: Int, _ type: String, _ message: String) -> HelperResponse {
      // Only the known paths and methods are written; anything else a client sent is not.
      let path = Self.paths.contains(request.path) ? request.path : "other"
      let method = ["GET", "POST"].contains(request.method) ? request.method : "other"
      helperLog("request \(number) \(method) \(path) status=\(status) type=\(type)")
      return .error(status, type: type, message: message)
    }

    guard authorized(request) else {
      return refuse(401, "authentication_error", "missing or wrong bearer token")
    }
    switch (request.method, request.path) {
    case ("GET", "/health"):
      helperLog("request \(number) GET /health status=200")
      return HelperResponse(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
    case ("POST", "/v1/chat/completions"):
      break
    case ("POST", HelperWordCheck.path):
      return await respondToWordCheck(request, number: number, milliseconds: milliseconds)
    case ("POST", Self.wakePath):
      // The body the app sends is an empty JSON object; anything else is refused before it can
      // load a model.
      guard let body = try? JSONSerialization.jsonObject(with: request.body),
        let object = body as? [String: Any], object.isEmpty
      else {
        return refuse(400, "invalid_request_error", "the wake body must be an empty JSON object")
      }
      return await respondToWake(number: number, milliseconds: milliseconds)
    case (_, "/health"), (_, "/v1/chat/completions"), (_, HelperWordCheck.path), (_, Self.wakePath):
      return refuse(405, "invalid_request_error", "method not served on this path")
    default:
      return refuse(404, "invalid_request_error", "no such path")
    }

    let prepared: EnviousDecodePreparedRequest
    do {
      prepared = try EnviousDecodeRequestMapper.prepare(
        body: request.body, configuration: configuration, tokenizer: tokenizer)
    } catch let error as EnviousDecodeRequestError {
      helperLog(
        "request \(number) POST /v1/chat/completions status=400 type=\(error.errorType)")
      let body = (try? EnviousDecodeRequestMapper.errorBody(for: error)) ?? Data()
      return HelperResponse(status: 400, body: body)
    } catch {
      return refuse(500, "server_error", "the request could not be prepared")
    }
    // A request with no usable instruction prefix runs cold, and the log says so.
    let prefix = prepared.instructionPrefixTokenIDs.map { String($0.count) } ?? "cold"
    helperLog(
      "request \(number) begin prompt_tokens=\(prepared.promptTokenIDs.count) prefix=\(prefix) max_new_tokens=\(prepared.maxNewTokens)"
    )
    modelRequestsInFlight += 1
    defer { modelRequestsInFlight -= 1 }
    do {
      let session = try await awake()
      try Task.checkCancellation()
      defer { idle.noteUse(at: Self.nowNanoseconds()) }
      let result = try session.generate(
        promptTokenIDs: prepared.promptTokenIDs, maxNewTokens: prepared.maxNewTokens,
        stopTokenIDs: prepared.stopTokenIDs,
        instructionPrefixTokenIDs: prepared.instructionPrefixTokenIDs)
      let body = try EnviousDecodeRequestMapper.response(
        for: result, configuration: configuration, tokenizer: tokenizer)
      helperLog(
        "request \(number) end status=200 generated_tokens=\(result.tokenIDs.count) finish=\(result.endedOnStopToken ? "stop" : "length") restored_prefix_tokens=\(result.restoredPrefixTokens) ms=\(milliseconds())"
      )
      return HelperResponse(status: 200, body: body)
    } catch is CancellationError {
      helperLog("request \(number) end status=cancelled ms=\(milliseconds())")
      return nil
    } catch is WakeFailure {
      helperLog("request \(number) end status=503 type=model_unavailable ms=\(milliseconds())")
      return .error(503, type: "model_unavailable", message: "the model could not be loaded")
    } catch EnviousDecodeSessionError.requestRefused(let reason) {
      helperLog("request \(number) end status=400 type=invalid_request_error ms=\(milliseconds())")
      return .error(400, type: "invalid_request_error", message: reason)
    } catch {
      // A refused instruction prefix lands here too: the mapper made that prefix, so it is
      // this helper's fault, not the client's. It is not retried cold.
      helperLog("request \(number) end status=500 type=server_error ms=\(milliseconds())")
      return .error(500, type: "server_error", message: "generation failed")
    }
  }

  /// `POST /wake`: loads the models when the helper sleeps and answers when they are ready;
  /// does nothing when they are loaded. It never generates. The app sends it when a recording
  /// starts, so the first take after a sleep finds the models loaded (#3853).
  private static let wakePath = "/wake"
  private static let paths = ["/health", "/v1/chat/completions", HelperWordCheck.path, wakePath]

  private func respondToWake(number: Int, milliseconds: () -> Int) async -> HelperResponse? {
    modelRequestsInFlight += 1
    defer { modelRequestsInFlight -= 1 }
    do {
      _ = try await awake()
      try Task.checkCancellation()
      // A wake means a recording just started, so use is expected: it counts as use, once per
      // recording. It cannot keep the helper awake on its own beyond one idle time.
      idle.noteUse(at: Self.nowNanoseconds())
      helperLog("request \(number) POST \(Self.wakePath) status=200 ms=\(milliseconds())")
      return HelperResponse(status: 200, body: Data(#"{"status":"awake"}"#.utf8))
    } catch is CancellationError {
      helperLog("request \(number) POST \(Self.wakePath) status=cancelled ms=\(milliseconds())")
      return nil
    } catch {
      helperLog("request \(number) POST \(Self.wakePath) status=503 type=model_unavailable")
      return .error(503, type: "model_unavailable", message: "the model could not be loaded")
    }
  }

  /// The answer to one learned-word request. It runs on this actor like a polish request, so
  /// the two never run at once; the questions are scored in the checker's own model tree and
  /// leave nothing behind for polish.
  private func respondToWordCheck(
    _ request: HelperRequest, number: Int, milliseconds: () -> Int
  ) async -> HelperResponse? {
    func refuse(_ status: Int, _ type: String, _ message: String) -> HelperResponse {
      helperLog(
        "request \(number) POST \(HelperWordCheck.path) status=\(status) type=\(type) ms=\(milliseconds())"
      )
      return .error(status, type: type, message: message)
    }
    let questions: [HelperWordCheck.Question]
    do {
      questions = try HelperWordCheck.parse(
        body: request.body, modelName: configuration.modelName)
    } catch let refusal as HelperWordCheck.Refusal {
      return refuse(400, "invalid_request_error", refusal.message)
    } catch {
      return refuse(400, "invalid_request_error", "the request could not be read")
    }
    // Whether this helper has a checker is fixed by its launch (the adapter folder), not by
    // whether the models are loaded right now.
    guard let wordCheckAnswers, arguments.wordCheckAdapterFolder != nil else {
      return refuse(503, "word_check_unavailable", "this helper has no word-check adapter")
    }
    let prompts = questions.map { tokenizer.encode(HelperWordCheck.prompt(for: $0)) }
    let longest = prompts.map(\.count).max() ?? 0
    // The same limit and the same answer as a polish prompt that does not fit.
    guard longest < configuration.contextTokens else {
      let error = EnviousDecodeRequestError.contextExceeded(
        promptTokens: longest, contextTokens: configuration.contextTokens)
      helperLog(
        "request \(number) POST \(HelperWordCheck.path) status=400 type=\(error.errorType)")
      let body = (try? EnviousDecodeRequestMapper.errorBody(for: error)) ?? Data()
      return HelperResponse(status: 400, body: body)
    }
    helperLog(
      "request \(number) wordcheck begin questions=\(questions.count) longest_prompt_tokens=\(longest)"
    )
    modelRequestsInFlight += 1
    defer { modelRequestsInFlight -= 1 }
    do {
      let session = try await awake()
      try Task.checkCancellation()
      defer { idle.noteUse(at: Self.nowNanoseconds()) }
      let scores = try session.wordCheckScores(
        promptTokenIDs: prompts, answerTokenIDs: wordCheckAnswers)
      guard
        let body = HelperWordCheck.responseBody(
          ids: questions.map(\.id), scores: scores.map { (pA: $0.pA, pB: $0.pB) })
      else { return refuse(500, "server_error", "the scores are not usable numbers") }
      helperLog("request \(number) wordcheck end status=200 ms=\(milliseconds())")
      return HelperResponse(status: 200, body: body)
    } catch is CancellationError {
      helperLog("request \(number) wordcheck end status=cancelled ms=\(milliseconds())")
      return nil
    } catch is WakeFailure {
      return refuse(503, "model_unavailable", "the model could not be loaded")
    } catch EnviousDecodeWordCheckError.requestRefused(let reason) {
      return refuse(400, "invalid_request_error", reason)
    } catch {
      return refuse(500, "server_error", "scoring failed")
    }
  }

  /// `Authorization: Bearer <token>`, compared without stopping at the first difference.
  private func authorized(_ request: HelperRequest) -> Bool {
    guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else {
      return false
    }
    let given = Array(header.dropFirst("Bearer ".count).utf8)
    let expected = Array(token.utf8)
    var difference = given.count ^ expected.count
    for index in 0..<max(given.count, expected.count) {
      difference |= Int(
        (index < given.count ? given[index] : 0) ^ (index < expected.count ? expected[index] : 0))
    }
    return difference == 0
  }
}
