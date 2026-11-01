import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #4319: when these fail, an EG-1 meeting summary is answered by the learned-word checker's
/// weights, a looping answer cut at the cap is saved as a summary, a slow summary is cut off at
/// the dictation polish limit, or a failure is hidden as a silent polish skip instead of a
/// failed summary the user can write again.
@Suite("EG-1 summary call", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct EGOneSummaryCallTests {
  /// Records the request and answers with a canned response.
  final class Transport: @unchecked Sendable {
    // Test-only recorder; one call per test, never concurrent.
    var requests: [URLRequest] = []
    let answer: Result<(Data, Int), Error>

    init(_ answer: Result<(Data, Int), Error>) { self.answer = answer }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
      requests.append(request)
      let (data, status) = try answer.get()
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (data, response)
    }
  }

  static func endpoint(adapter: Bool) -> EGOneEndpoint {
    EGOneEndpoint(
      port: 51234, authToken: "test-token", contextTokens: 16_384, hasLearnedWordAdapter: adapter)
  }

  static func body(content: String?, finish: String = "stop") -> Data {
    var message: [String: Any] = ["role": "assistant"]
    if let content { message["content"] = content }
    let json: [String: Any] = ["choices": [["message": message, "finish_reason": finish]]]
    return try! JSONSerialization.data(withJSONObject: json)
  }

  static func call(_ transport: Transport, adapter: Bool = true, timeout: Double = 300)
    async throws -> String
  {
    try await EGOneSummaryCall.complete(
      endpoint: endpoint(adapter: adapter), instructions: "Summarize.", prompt: "TRANSCRIPT",
      timeoutSeconds: timeout, send: { try await transport.send($0) })
  }

  @Test("the request: system and user as given, EG-1, the summary cap, temperature 0, checker off")
  func requestShape() async throws {
    let transport = Transport(.success((Self.body(content: "Title: Plan\n\nA summary."), 200)))
    let answer = try await Self.call(transport)
    #expect(answer == "Title: Plan\n\nA summary.")
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://127.0.0.1:51234/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.timeoutInterval == 310, "the summary's own timeout fires first")
    let sent = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
    #expect(json["model"] as? String == "eg-1")
    #expect(json["max_tokens"] as? Int == MeetingSummary.outputTokens)
    #expect(json["temperature"] as? Int == 0)
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(
      messages == [
        ["role": "system", "content": "Summarize."], ["role": "user", "content": "TRANSCRIPT"],
      ])
    let lora = try #require(json["lora"] as? [[String: Any]])
    #expect(lora.count == 1)
    #expect(lora.first?["id"] as? Int == 0)
    #expect(lora.first?["scale"] as? Double == 0)
    #expect(json["id_slot"] as? Int == EGOneSlots.polish)
  }

  @Test("without a loaded checker adapter the request names no adapter and no slot")
  func noAdapter() async throws {
    let transport = Transport(.success((Self.body(content: "ok"), 200)))
    _ = try await Self.call(transport, adapter: false)
    let sent = try #require(transport.requests.first?.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
    #expect(json["lora"] == nil)
    #expect(json["id_slot"] == nil)
  }

  @Test("summary and polish switch the checker off through the same owner")
  func sharedAdapterOwner() throws {
    let polish = try EGOneConnector.makeRequestBody(
      system: "s", user: "u",
      config: LLMProviderConfig(
        model: "eg-1", apiKeyKeychainId: nil, outputTokens: .capped(64), temperature: 0,
        thinking: nil, maxRetries: 0),
      hasLearnedWordAdapter: true)
    let summary = EGOneSummaryCall.requestBody(
      instructions: "s", prompt: "u", hasLearnedWordAdapter: true)
    #expect(polish["id_slot"] as? Int == summary["id_slot"] as? Int)
    #expect(
      (polish["lora"] as? [[String: Any]])?.first?["scale"] as? Double
        == (summary["lora"] as? [[String: Any]])?.first?["scale"] as? Double)
  }

  @Test("a length stop is a cut-off summary, never saved, whatever text came with it")
  func lengthIsTruncated() async {
    let looping = String(repeating: "- The meeting will discuss the design.\n", count: 200)
    let transport = Transport(.success((Self.body(content: looping, finish: "length"), 200)))
    await #expect(throws: MeetingSummary.Failure.truncated) { try await Self.call(transport) }
  }

  @Test("a missing or blank answer is an empty summary")
  func emptyAnswers() async {
    for content in [nil, "", "  \n "] as [String?] {
      let transport = Transport(.success((Self.body(content: content), 200)))
      await #expect(throws: MeetingSummary.Failure.empty, "\(String(describing: content))") {
        try await Self.call(transport)
      }
    }
    let malformed = Transport(.success((Data("not json".utf8), 200)))
    await #expect(throws: MeetingSummary.Failure.empty) { try await Self.call(malformed) }
  }

  @Test("another HTTP status is a request failure the summary does not retry")
  func httpStatus() async {
    let transport = Transport(.success((Data(), 503)))
    do {
      _ = try await Self.call(transport)
      Issue.record("expected a failure")
    } catch let error as LLMError {
      #expect(LLMRetryPolicy.isRetryable(error) == false, "\(error)")
      guard case .requestFailed = error else {
        Issue.record("expected requestFailed, got \(error)")
        return
      }
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test("a transport timeout is the summary's timeout; a cancel is a cancel")
  func timeoutAndCancel() async {
    let timedOut = Transport(.failure(URLError(.timedOut)))
    await #expect(throws: MeetingSummary.Failure.timedOut) { try await Self.call(timedOut) }
    let cancelled = Transport(.failure(URLError(.cancelled)))
    await #expect(throws: CancellationError.self) { try await Self.call(cancelled) }
  }

  @Test("a dropped connection stays a connection error the summary may retry")
  func connectionLost() async {
    for code in [URLError.Code.networkConnectionLost, .cannotConnectToHost] {
      let transport = Transport(.failure(URLError(code)))
      do {
        _ = try await Self.call(transport)
        Issue.record("expected a failure")
      } catch let error as URLError {
        #expect(error.code == code)
        #expect(LLMRetryPolicy.isRetryable(error), "\(code)")
      } catch {
        Issue.record("unexpected \(error)")
      }
    }
  }
}
