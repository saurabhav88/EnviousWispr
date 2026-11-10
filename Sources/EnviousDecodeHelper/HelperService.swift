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
  private var served = 0

  /// Loads the tokenizer and both models. Any failure is thrown: there is no other model to
  /// fall back to and nothing is downloaded.
  init(arguments: HelperArguments) async throws {
    let loaded = try await HelperTokenizer.load(
      modelFolder: arguments.modelFolder, modelName: arguments.modelName,
      contextTokens: arguments.contextTokens)
    tokenizer = loaded.tokenizer
    configuration = loaded.configuration
    token = arguments.token
    session = try await EnviousDecodeSession.load(
      targetDirectory: arguments.modelFolder, draftDirectory: arguments.draftFolder)
  }

  /// The answer to one request, or nil when the request was cancelled (nothing is sent).
  func respond(to request: HelperRequest) -> HelperResponse? {
    served += 1
    let number = served
    let started = DispatchTime.now().uptimeNanoseconds
    func milliseconds() -> Int { Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) }
    func refuse(_ status: Int, _ type: String, _ message: String) -> HelperResponse {
      // Only the two known paths and methods are written; anything else a client sent is not.
      let path =
        ["/health", "/v1/chat/completions"].contains(request.path) ? request.path : "other"
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
    case (_, "/health"), (_, "/v1/chat/completions"):
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
