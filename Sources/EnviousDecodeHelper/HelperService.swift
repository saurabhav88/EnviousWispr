import EnviousDecodeKit
import Foundation

/// Writes one line to standard error. The helper's lines never hold the bearer token or any
/// request or answer text: only what happened, token counts and times.
func helperLog(_ line: String) {
  FileHandle.standardError.write(Data("envious-decode: \(line)\n".utf8))
}

/// The one owner of the loaded models. It is an actor and `respond` never suspends, so one
/// request runs to its end before the next one starts: the session is never used by two
/// requests at once. A request is worked on inside the connection's own task, so when the
/// client goes away and that task is cancelled, generation stops at its next round.
actor HelperService {
  private let session: EnviousDecodeSession
  private let tokenizer: EnviousDecodeTokenizer
  private let configuration: EnviousDecodeRequestConfiguration
  private let token: String
  /// The ids of the two answer letters, when a word-check adapter is loaded.
  private let wordCheckAnswers: (a: Int, b: Int)?
  private var served = 0

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
  }

  /// The answer to one request, or nil when the request was cancelled (nothing is sent).
  func respond(to request: HelperRequest) -> HelperResponse? {
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
      return respondToWordCheck(request, number: number, milliseconds: milliseconds)
    case (_, "/health"), (_, "/v1/chat/completions"), (_, HelperWordCheck.path):
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
    do {
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

  private static let paths = ["/health", "/v1/chat/completions", HelperWordCheck.path]

  /// The answer to one learned-word request. It runs on this actor like a polish request, so
  /// the two never run at once; the questions are scored in the checker's own model tree and
  /// leave nothing behind for polish.
  private func respondToWordCheck(
    _ request: HelperRequest, number: Int, milliseconds: () -> Int
  ) -> HelperResponse? {
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
    guard let wordCheckAnswers, session.hasWordCheck else {
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
    do {
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
