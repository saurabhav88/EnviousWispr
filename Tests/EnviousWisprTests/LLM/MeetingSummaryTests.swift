import Foundation
import Testing
import os

@testable import EnviousWisprCore
@testable import EnviousWisprLLM
import EnviousWisprAppKitTestSupport

/// #3972 R39, R44 (build chunk C12): when these fail, a summary is written by a model that
/// cannot summarize, a long meeting overflows the model's window or loses words silently, a cut
/// answer is saved as a summary, a bad key is retried, or a local model starts work while the
/// user dictates.
@Suite("Meeting summary writer", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSummaryTests {
  /// Records every call, answers from `answers` in order, and counts admissions.
  final class Calls: @unchecked Sendable {
    // Test-only recorder touched from the summary's sequential calls; never concurrently.
    var prompts: [String] = []
    var admissions = 0
    var answers: [Result<String, Error>] = []

    func complete(_ instructions: String, _ prompt: String) async throws -> String {
      prompts.append(prompt)
      guard !answers.isEmpty else { return "summary \(prompts.count)" }
      return try answers.removeFirst().get()
    }
  }

  /// Apple Intelligence's window today.
  static let small = MeetingSummary.Window(
    contextTokens: 4_096, outputReserveTokens: MeetingSummary.outputTokens)
  /// Ollama's summary window for a thinking model.
  static let ollama = MeetingSummary.Window(contextTokens: 8_192, outputReserveTokens: 3_548)
  static let large = MeetingSummary.Window(
    contextTokens: 128_000, outputReserveTokens: 9_500)

  /// Whether a call's prompt, with the instructions beside it, fits `window` counted in UTF-8
  /// bytes (independent of the planner's own counter).
  static func fitsInBytes(_ prompt: String, _ window: MeetingSummary.Window) -> Bool {
    prompt.utf8.count + MeetingSummary.instructions.utf8.count
      <= window.contextTokens - window.outputReserveTokens - MeetingSummary.safetyMarginTokens
  }

  /// The same, counted with the planner's estimate (for windows that report an overflow).
  static func fitsInEstimate(_ prompt: String, _ window: MeetingSummary.Window) -> Bool {
    MeetingSummary.estimatedTokens(prompt)
      + MeetingSummary.estimatedTokens(MeetingSummary.instructions)
      <= window.contextTokens - window.outputReserveTokens - MeetingSummary.safetyMarginTokens
  }

  static func write(
    _ calls: Calls, transcript: String, notes: String = "",
    window: MeetingSummary.Window = large, timeout: Double = 60
  ) async throws -> String {
    try await MeetingSummary.write(
      transcript: transcript, notes: notes, facts: "", window: window, callTimeoutSeconds: timeout,
      admit: { calls.admissions += 1 }, complete: calls.complete
    ).text
  }

  @Test("every provider has a capability; cleanup models are refused under any provider")
  func capabilityMatrix() {
    let hosted = MeetingSummary.Capability.supported(.hosted)
    let local = MeetingSummary.Capability.supported(.local)
    func of(_ provider: LLMProvider, _ model: String = "m", remote: Bool? = nil)
      -> MeetingSummary.Capability
    {
      MeetingSummary.capability(provider, model: model, ollamaModelIsRemote: remote)
    }
    #expect(of(.openAI) == hosted)
    #expect(of(.gemini) == hosted)
    #expect(of(.claude) == hosted)
    #expect(of(.ollama, "llama3.2", remote: false) == local)
    #expect(of(.ollama, "gpt-oss:120b-cloud", remote: true) == hosted)
    #expect(
      of(.ollama, "llama3.2", remote: nil) == local,
      "an Ollama model of unknown location waits for dictation like a local one")
    #expect(of(.appleIntelligence) == local)
    #expect(of(.egOne) == .notForSummaries)
    #expect(of(.s1Mini) == .notForSummaries)
    #expect(of(.none) == .noProvider)
    // The cleanup models picked through Ollama, with any tag or case.
    #expect(of(.ollama, "eg-1", remote: false) == .notForSummaries)
    #expect(of(.ollama, "eg-1:q4", remote: false) == .notForSummaries)
    #expect(of(.ollama, "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M") == .notForSummaries)
    // Similar names are other models.
    #expect(of(.ollama, "eg-10", remote: false) == local)
    #expect(of(.ollama, "s1-mini-acme", remote: false) == local)
    // Every case is covered: a new provider must be classified here.
    for provider in LLMProvider.allCases { _ = of(provider) }
  }

  @Test("the estimate counts every script; the byte count is the UTF-8 length")
  func counting() {
    #expect(MeetingSummary.estimatedTokens("") == 0)
    #expect(MeetingSummary.estimatedTokens("abc def gh") == 4)
    #expect(MeetingSummary.estimatedTokens("2026") == 4)
    #expect(MeetingSummary.estimatedTokens("会議の議事録") == 6)
    #expect(MeetingSummary.estimatedTokens("Привет") == 6)
    #expect(MeetingSummary.estimatedTokens("café") == 2)
    for text in ["abc def gh", "会議の議事録", "Привет", "café", "👍🏽"] {
      #expect(MeetingSummary.tokens(text, .bytes) == text.utf8.count)
    }
    #expect(MeetingSummary.prefix("会議の議事録", tokens: 4, .estimate) == "会議の議")
    #expect(MeetingSummary.prefix("会議の議事録", tokens: 7, .bytes) == "会議")
    #expect(
      MeetingSummary.prefix("👍🏽👍🏽", tokens: 3, .estimate) == "👍🏽", "never splits a character")
  }

  @Test("one character larger than a whole part is cut between its scalars and the cut ends")
  func oversizedCharacter() async throws {
    // One grapheme: a letter with 5,000 combining marks (10,001 bytes).
    let huge = "a" + String(repeating: "\u{0301}", count: 5_000)
    #expect(huge.count == 1)
    let text = "before\n" + huge + "\nafter"
    for counting in [MeetingSummary.Counting.estimate, .bytes] {
      let budget = try MeetingSummary.inputBudget(Self.small, counting)
      let parts = MeetingSummary.parts(of: text, budget: budget, counting)
      #expect(parts.count > 1)
      #expect(parts.allSatisfy { MeetingSummary.tokens($0, counting) <= budget })
      // Lines are cut at their ends and the long line between its scalars: every scalar but
      // the two line breaks is in exactly one part.
      #expect(
        parts.joined().unicodeScalars.filter { $0 != "\n" }.count
          == text.unicodeScalars.filter { $0 != "\n" }.count, "no scalar lost or added")
      #expect(parts.allSatisfy { !$0.isEmpty })
    }
    let calls = Calls()
    _ = try await Self.write(calls, transcript: text, window: Self.small)
    #expect(calls.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
  }

  @Test("a meeting that fits is one call with the notes; a long one is parts plus one join")
  func mapReduce() async throws {
    let short = Calls()
    let one = try await Self.write(short, transcript: "You: we ship Friday", notes: "Ask Priya")
    #expect(one == "summary 1")
    #expect(short.prompts.count == 1)
    #expect(short.prompts[0].contains("Ask Priya"))
    #expect(short.prompts[0].contains("You: we ship Friday"))

    let line = String(repeating: "word ", count: 40)
    let transcript = Array(repeating: "Speaker 1: \(line)", count: 150).joined(separator: "\n")
    let long = Calls()
    _ = try await Self.write(long, transcript: transcript, window: Self.small)
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let parts = MeetingSummary.parts(of: transcript, budget: budget, .estimate)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { MeetingSummary.estimatedTokens($0) <= budget })
    #expect(parts.joined(separator: "\n") == transcript, "no words lost or added by the cut")
    #expect(long.prompts.count == parts.count + 1, "one call per part and one join")
    #expect(long.prompts.last?.contains("Join them into one summary") == true)
    #expect(long.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
    #expect(long.admissions == long.prompts.count, "admitted before every attempt")
  }

  static let lines = [
    "Speaker 1: " + String(repeating: "word ", count: 40),
    "話者1: " + String(repeating: "会議の議事録", count: 30),
  ]

  @Test(
    "on a small window, long answers are combined in rounds and every call fits, in any script",
    arguments: lines)
  func smallWindowRounds(line: String) async throws {
    let transcript = Array(repeating: line, count: 300).joined(separator: "\n")
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let parts = MeetingSummary.parts(of: transcript, budget: budget, .estimate)
    #expect(parts.joined(separator: "\n") == transcript)
    let long = Calls()
    // As long as a part answer may be, so the answers need combining without any shortening.
    long.answers = Array(
      repeating: .success(Self.answer(of: line, withinTokens: MeetingSummary.partialCap(budget))),
      count: 200)
    let summary = try await Self.write(
      long, transcript: transcript, notes: "Ask Priya", window: Self.small)
    #expect(!long.prompts.contains { $0.hasPrefix("Shorten") })
    #expect(!summary.isEmpty)
    #expect(long.prompts.count > parts.count + 1, "the answers needed at least one combine round")
    #expect(long.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "Ask Priya", window: Self.small, counting: .estimate)
    #expect(long.prompts.count <= plan.worstCaseCalls)
  }

  @Test("a reported overflow re-plans once with the byte bound; a second one is too long")
  func overflowReplans() async throws {
    let line = String(repeating: "word ", count: 40)
    let transcript = Array(repeating: "Speaker 1: \(line)", count: 150).joined(separator: "\n")
    let once = Calls()
    once.answers = [.failure(LLMError.classified(.inputTooLong))]
    _ = try await Self.write(once, transcript: transcript, window: Self.small)
    let estimateFirst = MeetingSummary.parts(
      of: transcript, budget: try MeetingSummary.inputBudget(Self.small, .estimate), .estimate)
    let bytes = try MeetingSummary.plan(
      transcript: transcript, notes: "", window: Self.small, counting: .bytes)
    #expect(once.prompts.first?.contains(estimateFirst[0]) == true, "the estimate went first")
    #expect(once.prompts.count == 1 + (bytes.pieces?.count ?? 0) + 1, "then the byte plan, whole")
    #expect(once.prompts.dropFirst().allSatisfy { Self.fitsInBytes($0, Self.small) })

    let always = Calls()
    always.answers = Array(repeating: .failure(LLMError.classified(.inputTooLong)), count: 10)
    await #expect(throws: MeetingSummary.Failure.tooLong) {
      _ = try await Self.write(always, transcript: transcript, window: Self.small)
    }
    #expect(always.prompts.count == 2, "one try per plan, never retried")
  }

  /// `line` repeated, one per line, as many times as fit in `cap` estimated tokens.
  static func answer(of line: String, withinTokens cap: Int) -> String {
    var text = ""
    while MeetingSummary.estimatedTokens(text + line + "\n") <= cap { text += line + "\n" }
    return text
  }

  /// A long meeting on the small window, its plan, and a part answer `factor` times too long
  /// for its share of the final call, ending in an action item a clip would drop.
  static func longMeeting(factor: Int = 2) throws -> (
    transcript: String, plan: MeetingSummary.Plan, cap: Int, oversized: String
  ) {
    let line = "Speaker 1: " + String(repeating: "word ", count: 40)
    let transcript = Array(repeating: line, count: 150).joined(separator: "\n")
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "", window: small, counting: .estimate)
    let cap = MeetingSummary.partialCap(plan.budget)
    let oversized =
      answer(of: "- point " + String(repeating: "x", count: 60), withinTokens: cap * factor)
      + "- ACTION: Maria sends the screenshots"
    return (transcript, plan, cap, oversized)
  }

  @Test("a part answer too long for the final call is shortened by the model, never clipped")
  func longPartAnswerIsShortened() async throws {
    let meeting = try Self.longMeeting()
    let calls = Calls()
    calls.answers = [.success(meeting.oversized), .success("- ACTION: Maria sends the screenshots")]
    _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    #expect(calls.prompts[1].hasPrefix("Shorten these bullets"), "asked to shorten, once")
    #expect(calls.prompts[1].contains("ACTION: Maria sends the screenshots"))
    let join = try #require(calls.prompts.last)
    #expect(join.contains("Part 1:\n- ACTION: Maria sends the screenshots"), "the shortened answer is used")
    #expect(!join.contains("- point "), "no clipped copy of the long answer reaches the join")
    #expect(calls.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
  }

  @Test("a combined answer too long for the final call is shortened too")
  func longCombinedAnswerIsShortened() async throws {
    let line = "Speaker 1: " + String(repeating: "word ", count: 40)
    let transcript = Array(repeating: line, count: 300).joined(separator: "\n")
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "", window: Self.small, counting: .estimate)
    let pieces = try #require(plan.pieces).count
    let cap = MeetingSummary.partialCap(plan.budget)
    let calls = Calls()
    // Full-length part answers force a combine round; its first answer is too long.
    calls.answers =
      Array(repeating: .success(Self.answer(of: line, withinTokens: cap)), count: pieces)
      + [.success(Self.answer(of: line, withinTokens: cap * 2)), .success("- combined")]
    _ = try await Self.write(calls, transcript: transcript, window: Self.small)
    #expect(calls.prompts[pieces].hasPrefix("Below are the key points"), "a combine call")
    #expect(calls.prompts[pieces + 1].hasPrefix("Shorten these bullets"))
  }

  @Test("a shortening request is retried and admitted like any other call")
  func shorteningIsRetriedAndAdmitted() async throws {
    let meeting = try Self.longMeeting()
    let calls = Calls()
    calls.answers = [
      .success(meeting.oversized), .failure(LLMError.classified(.rateLimited)),
      .success("- ACTION: Maria sends the screenshots"),
    ]
    _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    #expect(calls.prompts[1].hasPrefix("Shorten these bullets"))
    #expect(calls.prompts[2] == calls.prompts[1], "the same request, tried again")
    #expect(calls.admissions == calls.prompts.count, "every attempt admitted, the retry included")
    let join = try #require(calls.prompts.last)
    #expect(join.contains("- ACTION: Maria sends the screenshots"))
  }

  @Test("a shortening request the model calls too long re-plans with the byte bound")
  func shorteningOverflowReplans() async throws {
    let meeting = try Self.longMeeting()
    let calls = Calls()
    calls.answers = [.success(meeting.oversized), .failure(LLMError.classified(.inputTooLong))]
    _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    let bytes = try MeetingSummary.plan(
      transcript: meeting.transcript, notes: "", window: Self.small, counting: .bytes)
    // The estimate plan's part and shortening request, then the whole byte plan.
    #expect(calls.prompts.count == 2 + (bytes.pieces?.count ?? 0) + 1)
    #expect(calls.prompts.dropFirst(2).allSatisfy { Self.fitsInBytes($0, Self.small) })
  }

  @Test("on the byte plan, an answer within the word limit but over the byte share is shortened by share")
  func bytePlanShortensByShare() async throws {
    let meeting = try Self.longMeeting()
    let bytes = try MeetingSummary.plan(
      transcript: meeting.transcript, notes: "", window: Self.small, counting: .bytes)
    let cap = MeetingSummary.partialCap(bytes.budget)
    // Few words, just over the byte share: it kept any word limit and is still too long.
    var answer = "-"
    while answer.utf8.count <= cap { answer += " word" }
    let calls = Calls()
    calls.answers = [
      .failure(LLMError.classified(.inputTooLong)), .success(answer), .success("- short"),
    ]
    _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    let request = try #require(calls.prompts.first { $0.hasPrefix("Shorten these bullets") })
    let percent = cap * 80 / answer.utf8.count
    #expect(request.hasPrefix("Shorten these bullets to at most \(percent)% of their length"))
    #expect(percent < 100, "the target is smaller than the answer as written")
    #expect(calls.prompts.contains { $0.contains("Part 1:\n- short") }, "the shortened answer is used")
  }

  @Test("an answer still too long after shortening fails the summary as truncated")
  func stillTooLongIsTruncated() async throws {
    let meeting = try Self.longMeeting()
    let calls = Calls()
    calls.answers = [.success(meeting.oversized), .success(meeting.oversized)]
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    }
    #expect(calls.prompts.count == 2, "one part, one shortening request, nothing after")
  }

  @Test("an answer too long even to send back for shortening fails as truncated without a call")
  func unsendableAnswerIsTruncated() async throws {
    let meeting = try Self.longMeeting(factor: 5)
    #expect(MeetingSummary.estimatedTokens(meeting.oversized) > meeting.plan.budget)
    let calls = Calls()
    calls.answers = [.success(meeting.oversized)]
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    }
    #expect(calls.prompts.count == 1)
  }

  @Test("shortening requests use only the calls the plan leaves unused; then the summary fails")
  func shorteningStaysInsideTheCallLimit() async throws {
    // The most parts the call limit allows on this window: the least room left over.
    let line = "Speaker 1: " + String(repeating: "word ", count: 40)
    var count = 150
    var best: (transcript: String, plan: MeetingSummary.Plan)?
    while true {
      let transcript = Array(repeating: line, count: count).joined(separator: "\n")
      guard
        let plan = try? MeetingSummary.plan(
          transcript: transcript, notes: "", window: Self.small, counting: .estimate)
      else { break }
      best = (transcript, plan)
      count += 150
    }
    let meeting = try #require(best)
    let headroom = MeetingSummary.maxCalls - meeting.plan.worstCaseCalls
    let pieces = try #require(meeting.plan.pieces).count
    #expect(headroom < pieces, "fewer spare calls than parts")
    let cap = MeetingSummary.partialCap(meeting.plan.budget)
    let oversized = Self.answer(of: line, withinTokens: cap * 2)
    let calls = Calls()
    // Every part answer is too long; every shortening answer fits.
    calls.answers = (0..<(headroom + 1)).flatMap { _ in
      [Result<String, Error>.success(oversized), .success("- short")]
    }
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await Self.write(calls, transcript: meeting.transcript, window: Self.small)
    }
    #expect(calls.prompts.filter { $0.hasPrefix("Shorten") }.count == headroom)
    #expect(calls.prompts.count <= MeetingSummary.maxCalls)
  }

  @Test("notes too long for the final call are summarized in parts, not dropped or cut")
  func longNotes() async throws {
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let notes = Array(repeating: "my note line", count: budget / 3).joined(separator: "\n")
    let transcript = String(repeating: "t ", count: budget * 2)
    let calls = Calls()
    _ = try await Self.write(calls, transcript: transcript, notes: notes, window: Self.small)
    #expect(
      calls.prompts.contains { $0.contains("the user's own notes") && $0.contains("my note") })
    #expect(calls.prompts.allSatisfy { Self.fitsInEstimate($0, Self.small) })
    #expect(calls.prompts.last?.contains("my note line") == false)
    let sent = calls.prompts.joined()
    #expect(sent.components(separatedBy: "my note line").count - 1 >= budget / 3)
  }

  @Test("notes count toward the window")
  func notesCountTowardTheWindow() throws {
    let budget = try MeetingSummary.inputBudget(Self.small, .estimate)
    let plan = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: (budget - 30) * 3),
      notes: String(repeating: "n", count: 200), window: Self.small, counting: .estimate)
    #expect(plan.pieces != nil)
    let fits = try MeetingSummary.plan(
      transcript: String(repeating: "t", count: (budget - 100) * 3),
      notes: String(repeating: "n", count: 200), window: Self.small, counting: .estimate)
    #expect(fits.pieces == nil)
  }

  @Test("a window too small for any transcript is refused before any call, never enlarged")
  func windowTooSmall() async throws {
    let calls = Calls()
    await #expect(throws: MeetingSummary.Failure.windowTooSmall) {
      _ = try await Self.write(
        calls, transcript: "t",
        window: MeetingSummary.Window(
          contextTokens: 2_048, outputReserveTokens: 1_500))
    }
    #expect(calls.prompts.isEmpty)
  }

  @Test("a meeting needing more than the call limit is refused before any call")
  func tooLong() async throws {
    for window in [Self.small, Self.ollama] {
      let calls = Calls()
      let transcript = String(repeating: "会", count: 4_000 * (MeetingSummary.maxCalls + 2))
      await #expect(throws: MeetingSummary.Failure.tooLong) {
        _ = try await Self.write(calls, transcript: transcript, window: window)
      }
      #expect(calls.prompts.isEmpty)
    }
  }

  @Test("the shared retry policy decides; each try is admitted; at most two retries")
  func retries() async throws {
    let flaky = Calls()
    flaky.answers = [
      .failure(LLMError.classified(.rateLimited)),
      .failure(LLMError.classified(.providerServerError)), .success("ok"),
    ]
    #expect(try await Self.write(flaky, transcript: "t") == "ok")
    #expect(flaky.prompts.count == 3)
    #expect(flaky.admissions == 3, "every attempt waits for admission again")

    let down = Calls()
    down.answers = Array(repeating: .failure(URLError(.timedOut)), count: 5)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await Self.write(down, transcript: "t")
    }
    #expect(down.prompts.count == 3, "one call and two retries, never more")

    for failFast in [PolishFailureReason.apiKeyRejected, .outOfCredits, .rateLimitedOrQuota] {
      let calls = Calls()
      calls.answers = [.failure(LLMError.classified(failFast))]
      await #expect(throws: MeetingSummary.Failure.providerFailed) {
        _ = try await Self.write(calls, transcript: "t")
      }
      #expect(calls.prompts.count == 1, "\(failFast) is not retried")
    }

    let empty = Calls()
    empty.answers = [.success("   ")]
    await #expect(throws: MeetingSummary.Failure.empty) {
      _ = try await Self.write(empty, transcript: "t")
    }
  }

  @Test("cancellation during admission starts no call; a cancelled request is not retried")
  func cancellation() async throws {
    let calls = Calls()
    let task = Task {
      try await MeetingSummary.write(
        transcript: "t", notes: "", facts: "", window: Self.large, callTimeoutSeconds: 60,
        admit: { withUnsafeCurrentTask { $0?.cancel() } }, complete: calls.complete)
    }
    await #expect(throws: MeetingSummary.Failure.cancelled) { _ = try await task.value }
    #expect(calls.prompts.isEmpty, "the admission returned after cancel; no call started")

    let transport = Calls()
    transport.answers = [.failure(URLError(.cancelled)), .success("late")]
    await #expect(throws: MeetingSummary.Failure.cancelled) {
      _ = try await Self.write(transport, transcript: "t")
    }
    #expect(transport.prompts.count == 1)
  }

  @Test("a call past its time limit is stopped, ended and not tried again")
  func timeLimit() async throws {
    let calls = Calls()
    let ended = Calls()
    await #expect(throws: MeetingSummary.Failure.timedOut) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", facts: "", window: Self.large, callTimeoutSeconds: 0.05,
        admit: {},
        complete: { instructions, prompt in
          _ = try await calls.complete(instructions, prompt)
          do {
            // deadline-fallback: the model that never answers; only the time limit ends it.
            try await Task.sleep(for: .seconds(3_600))
          } catch {
            ended.prompts.append("cancelled")
            throw error
          }
          return "late"
        })
    }
    #expect(calls.prompts.count == 1, "a timed-out call is not tried again")
    #expect(ended.prompts == ["cancelled"], "the call ended before the writer returned")
  }

  @Test("the configuration fingerprint changes with the model and never carries a key")
  func fingerprint() {
    let a = MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4o-mini")
    let b = MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4.1")
    let c = MeetingSummary.configurationFingerprint(provider: .gemini, model: "gpt-4o-mini")
    #expect(a != b)
    #expect(a != c)
    #expect(a == MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4o-mini"))
    #expect(a.count == 64)
  }

  // MARK: - Providers

  /// An isolated key folder: never the real Keychain or key files.
  static func keychain() -> KeychainManager {
    let folder = TestTemporaryDirectory.url
      .appending(path: "ew-tests-3972-summary-\(UUID().uuidString)")
    return KeychainManager(
      backend: .legacyFiles, legacyStore: FileLegacyKeyStore(storageDirectory: folder))
  }

  /// Counts readiness and version probes and network requests, and answers each request from
  /// `replies`.
  final class Ollama: @unchecked Sendable {
    enum Reply {
      /// A chat answer and its `done_reason`.
      case chat(String, String)
      /// An HTTP error status and body.
      case http(Int, String)
      case fail(Error)
    }

    // Test-only recorder; the summary's calls run one after another.
    var probes = 0
    var versionAsks = 0
    var requests: [[String: Any]] = []
    var replies: [Reply] = []
    let facts: OllamaModelFacts?
    let version: String?

    init(facts: OllamaModelFacts?, version: String? = "0.12.6") {
      self.facts = facts
      self.version = version
    }

    func readiness(_ model: String) async -> OllamaReadiness {
      probes += 1
      guard let facts else { return .serverDown }
      return .ready(facts: facts)
    }

    func serverVersion() async -> String? {
      versionAsks += 1
      return version
    }

    func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
      // swift-patterns RULE: fake-executor-must-yield-before-throw.
      await Task.yield()
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
      requests.append(body as? [String: Any] ?? [:])
      let reply = replies.isEmpty ? .chat("summary", "stop") : replies.removeFirst()
      let (code, data): (Int, Data)
      switch reply {
      case .chat(let text, let done):
        code = 200
        data = try JSONSerialization.data(withJSONObject: [
          "message": ["role": "assistant", "content": text], "done": true, "done_reason": done,
        ])
      case .http(let status, let text):
        code = status
        data = Data(text.utf8)
      case .fail(let error):
        throw error
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
      return (data, response)
    }
  }

  static func prepare(_ provider: LLMProvider, _ model: String, _ ollama: Ollama) async
    -> Result<MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable>
  {
    await MeetingSummaryProviders.prepare(
      provider: provider, model: model, keychain: keychain(),
      ollamaReadiness: { await ollama.readiness($0) },
      ollamaVersion: { await ollama.serverVersion() },
      ollamaExecutor: { try await ollama.execute($0) })
  }

  @Test("cleanup models and no provider are refused before Ollama is asked or called")
  func refusedProviders() async {
    let cases: [(LLMProvider, String)] = [
      (.egOne, ""), (.s1Mini, ""), (.none, ""), (.ollama, "eg-1:q4"),
      (.ollama, "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"),
    ]
    for (provider, model) in cases {
      let ollama = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false))
      let result = await Self.prepare(provider, model, ollama)
      #expect(
        result.failureValue == (provider == .none ? .noProvider : .notForSummaries),
        "\(provider) \(model)")
      #expect(ollama.probes == 0)
      #expect(ollama.requests.isEmpty)
    }
    let down = Ollama(facts: nil)
    #expect(await Self.prepare(.ollama, "llama3.2", down).failureValue == .notReady)
  }

  @Test(
    "an Ollama summary runs where the daemon says, in its planned window, without connector retries"
  )
  func ollamaRequests() async throws {
    let local = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: true))
    let prepared = try #require(await Self.prepare(.ollama, "qwen3", local).successValue)
    #expect(prepared.execution == .local)
    #expect(prepared.window.contextTokens == MeetingSummaryProviders.ollamaContextTokens)
    // Every request fails: the summary's own one call and two retries are the only requests,
    // so a connector that also retried would multiply them.
    local.replies = Array(repeating: .fail(URLError(.timedOut)), count: 20)
    await #expect(throws: MeetingSummary.Failure.providerFailed) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", facts: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
        complete: prepared.complete)
    }
    #expect(local.requests.count == 3, "the connector tries once; the summary owns the retries")
    let options = try #require(local.requests.first?["options"] as? [String: Any])
    #expect(options["num_ctx"] as? Int == MeetingSummaryProviders.ollamaContextTokens)
    #expect(options["num_predict"] as? Int == prepared.window.outputReserveTokens)
    #expect(local.requests.first?["think"] as? String == "low", "the same thinking rule as polish")
    #expect(local.requests.first?["truncate"] as? Bool == false, "the daemon must not cut the prompt")
    #expect(local.requests.first?["shift"] as? Bool == false, "nor drop text while answering")

    local.replies = []
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", facts: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
      complete: prepared.complete)
    #expect(summary.text == "summary")

    let hosted = Ollama(facts: OllamaModelFacts(isRemote: true, thinks: false))
    let remote = try #require(
      await Self.prepare(.ollama, "gpt-oss:120b-cloud", hosted).successValue)
    #expect(remote.execution == .hosted)
    #expect(remote.window.outputReserveTokens == MeetingSummary.outputTokens)
  }

  @Test("an Ollama answer cut at its output cap is refused, not saved as a summary")
  func ollamaTruncation() async throws {
    let local = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false))
    let prepared = try #require(await Self.prepare(.ollama, "llama3.2", local).successValue)
    local.replies = [.chat("## Overview\nThe team agreed to", "length")]
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", facts: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
        complete: prepared.complete)
    }
    #expect(local.requests.count == 1, "a cut answer is not retried")
  }

  @Test("polish requests keep the daemon's window: no num_ctx unless a caller sets one")
  func polishBodyUnchanged() {
    let body = OllamaConnector.makeRequestBody(
      model: "m", messages: [], maxTokens: 256, temperature: 0, thinking: nil)
    let options = body["options"] as? [String: Any]
    #expect(options?["num_ctx"] == nil)
    #expect(options?.count == 2)
    #expect(body["truncate"] == nil && body["shift"] == nil, "polish keeps the daemon's cutting")
  }

  @Test("each hosted profile sends the output cap it reserves; unknown models are planned small")
  func hostedProfiles() async throws {
    func window(_ provider: LLMProvider, _ model: String) -> Int {
      MeetingSummaryProviders.hostedContextTokens(provider, model: model)
    }
    #expect(window(.openAI, "gpt-4o-mini") == 128_000)
    #expect(window(.openAI, "gpt-4") == 8_000)
    #expect(window(.openAI, "gpt-3.5-turbo") == 8_000)
    #expect(window(.gemini, "gemini-2.5-flash") == 128_000)
    #expect(window(.gemini, "gemini-1.0-pro") == 8_000)
    #expect(window(.claude, "claude-sonnet-5-5") == 128_000)
    #expect(window(.claude, "claude-2.1") == 8_000)

    for (provider, model) in [
      (LLMProvider.openAI, "gpt-4o-mini"), (.openAI, "o3"), (.openAI, "gpt-4"),
      (.gemini, "gemini-2.5-flash"), (.claude, "claude-sonnet-5-5"),
    ] {
      let prepared = try #require(
        await MeetingSummaryProviders.prepare(
          provider: provider, model: model, keychain: Self.keychain()
        )
        .successValue)
      let config = MeetingSummaryProviders.hostedConfig(provider, model: model, keyID: "k")
      #expect(config.outputTokens == .capped(prepared.window.outputReserveTokens), "\(model)")
      #expect(config.maxRetries == 0)
    }
    #expect(MeetingSummaryProviders.hostedOutputTokens(.openAI, model: "o3") == 9_500)
    #expect(MeetingSummaryProviders.hostedOutputTokens(.openAI, model: "gpt-4o-mini") == 1_500)

    // An unknown model that may think does not fit the small planning window: refused before
    // any call. An unknown model that does not think fits it.
    let gemini10 = MeetingSummary.Window(
      contextTokens: window(.gemini, "gemini-1.0-pro"),
      outputReserveTokens: MeetingSummaryProviders.hostedOutputTokens(
        .gemini, model: "gemini-1.0-pro"))
    let calls = Calls()
    await #expect(throws: MeetingSummary.Failure.windowTooSmall) {
      _ = try await Self.write(calls, transcript: "t", window: gemini10)
    }
    #expect(calls.prompts.isEmpty)
    let gpt4 = MeetingSummary.Window(
      contextTokens: window(.openAI, "gpt-4"),
      outputReserveTokens: MeetingSummaryProviders.hostedOutputTokens(.openAI, model: "gpt-4"))
    #expect(try await Self.write(Calls(), transcript: "t", window: gpt4) == "summary 1")
  }

  @Test("an Ollama app older than 0.12.6, or of unknown version, is refused before any call")
  func ollamaVersionGate() async throws {
    for (version, supported) in [
      ("0.12.5", false), ("0.11.10", false), ("0.0.0", false), ("garbage", false),
      ("0.12.6", true), ("0.12.10", true), ("0.13.0-rc1", true), ("1.0", true),
    ] {
      #expect(OllamaConnector.supportsNoTruncation(version: version) == supported, "\(version)")
    }
    #expect(OllamaConnector.supportsNoTruncation(version: nil) == false)

    for version in ["0.12.5", nil] as [String?] {
      let old = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false), version: version)
      #expect(await Self.prepare(.ollama, "llama3.2", old).failureValue == .ollamaTooOld)
      #expect(old.versionAsks == 1)
      #expect(old.requests.isEmpty)
    }
  }

  @Test(
    "Ollama's own too-long errors re-plan with the byte count, then fail as too long",
    arguments: [
      "the input length exceeds the context length",
      "the prompt is longer than the context length currently available to the model; shorten the prompt",
    ])
  func ollamaOverflow(message: String) async throws {
    let error = #"{"error": "\#(message)"}"#
    let once = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false))
    let prepared = try #require(await Self.prepare(.ollama, "llama3.2", once).successValue)
    once.replies = [.http(400, error)]
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", facts: "", window: prepared.window, callTimeoutSeconds: 60, admit: {},
      complete: prepared.complete)
    #expect(summary.text == "summary")
    #expect(once.requests.count == 2, "the overflow is not retried; the byte plan runs once")

    // A template or a normalizing tokenizer can still overflow the byte plan: reported, never
    // a summary written from part of the meeting.
    let always = Ollama(facts: OllamaModelFacts(isRemote: false, thinks: false))
    let again = try #require(await Self.prepare(.ollama, "llama3.2", always).successValue)
    always.replies = [.http(400, error), .http(400, error), .chat("late", "stop")]
    await #expect(throws: MeetingSummary.Failure.tooLong) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", facts: "", window: again.window, callTimeoutSeconds: 60, admit: {},
        complete: again.complete)
    }
    #expect(always.requests.count == 2)
  }

  @Test("Ollama's error mapping: only a context message is too long; other 400s stay bad requests")
  func ollamaClassification() {
    #expect(
      OllamaConnector.classify(
        statusCode: 400, bodyString: #"{"error":"the input length exceeds the context length"}"#)
        == .inputTooLong)
    #expect(
      OllamaConnector.classify(
        statusCode: 413, bodyString: "the request exceeds the available context size") == .inputTooLong)
    #expect(OllamaConnector.classify(statusCode: 400, bodyString: #"{"error":"invalid"}"#) == .badRequest)
    #expect(OllamaConnector.classify(statusCode: 413, bodyString: "too big") == .badRequest)
    #expect(OllamaConnector.classify(statusCode: 404, bodyString: "") == .modelUnavailable)
  }

  // MARK: - The real OpenAI connector

  struct TestKey: LegacyKeyFileStorage {
    func store(key: String, value: String) throws {}
    func retrieve(key: String) throws -> String { "sk-test-not-a-real-key" }
    func delete(key: String) throws {}
  }

  /// Pops one scripted HTTP reply per request and counts requests.
  final class Script: Sendable {
    private let state: OSAllocatedUnfairLock<(replies: [(Int, String)], bodies: [Data])>

    init(_ replies: [(Int, String)]) {
      state = OSAllocatedUnfairLock(initialState: (replies: replies, bodies: []))
    }

    var requests: Int { state.withLock { $0.bodies.count } }

    func body(_ index: Int) -> [String: Any] {
      let data = state.withLock { $0.bodies[index] }
      return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func executor() -> OpenAIConnector.RequestExecutor {
      { request, _ in
        // swift-patterns RULE: fake-executor-must-yield-before-throw.
        await Task.yield()
        return try self.state.withLock { state in
          state.bodies.append(request.httpBody ?? Data())
          guard !state.replies.isEmpty else { throw URLError(.badServerResponse) }
          let (code, body) = state.replies.removeFirst()
          let response = HTTPURLResponse(
            url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
          return (Data(body.utf8), response)
        }
      }
    }
  }

  static let ok = (
    200, #"{"choices": [{"message": {"content": "Summary."}, "finish_reason": "stop"}]}"#
  )
  static let rateLimit = (429, #"{"error": {"type": "requests", "message": "Rate limit reached"}}"#)
  static let quota = (
    429, #"{"error": {"type": "insufficient_quota", "code": "insufficient_quota"}}"#
  )
  static let busy = (503, #"{"error": {"message": "The server is overloaded"}}"#)
  static let badKey = (401, #"{"error": {"message": "Incorrect API key provided"}}"#)
  static let tooLongReply = (
    400, #"{"error": {"code": "context_length_exceeded", "message": "maximum context length"}}"#
  )
  static let cut = (
    200, #"{"choices": [{"message": {"content": "Summary"}, "finish_reason": "length"}]}"#
  )

  static func openAI(_ script: Script, model: String = "gpt-4o-mini") -> MeetingSummary.Complete {
    MeetingSummaryProviders.envelope(
      OpenAIConnector(
        keychainManager: KeychainManager(backend: .legacyFiles, legacyStore: TestKey()),
        requestExecutor: script.executor()),
      MeetingSummaryProviders.hostedConfig(
        .openAI, model: model, keyID: KeychainManager.openAIKeyID))
  }

  @Test("shared summary connector cleanup stays at the source-owning adapter")
  func summaryChatterCompatibility() async throws {
    let response = (200, #"{"choices":[{"message":{"content":"Sure, I can do that tomorrow."},"finish_reason":"stop"}]}"#)
    let added = try await Self.openAI(Script([response]))("instructions", "I can do that tomorrow")
    #expect(added == "I can do that tomorrow.")
    let kept = try await Self.openAI(Script([response]))("instructions", "sure I can do that tomorrow")
    #expect(kept == "Sure, I can do that tomorrow.")
    let wrapper = Script([(200, #"{"choices":[{"message":{"content":"Here is the cleaned text:"},"finish_reason":"stop"}]}"#)])
    await #expect(throws: MeetingSummary.Failure.empty) {
      _ = try await MeetingSummary.write(
        transcript: "the review is tomorrow", notes: "", facts: "", window: Self.large,
        callTimeoutSeconds: 60, admit: {}, complete: Self.openAI(wrapper))
    }
    #expect(wrapper.requests == 1)
  }

  @Test(
    "real OpenAI replies: busy and rate-limited are retried and admitted; quota and key are not")
  func openAIReplies() async throws {
    let retried = Script([Self.rateLimit, Self.busy, Self.ok])
    let admissions = Calls()
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", facts: "", window: Self.large, callTimeoutSeconds: 60,
      admit: { admissions.admissions += 1 }, complete: Self.openAI(retried))
    #expect(summary.text == "Summary.")
    #expect(retried.requests == 3)
    #expect(admissions.admissions == 3)
    #expect(retried.body(0)["max_completion_tokens"] as? Int == MeetingSummary.outputTokens)

    for failFast in [Self.quota, Self.badKey] {
      let script = Script([failFast, Self.ok])
      await #expect(throws: MeetingSummary.Failure.providerFailed) {
        _ = try await MeetingSummary.write(
          transcript: "t", notes: "", facts: "", window: Self.large, callTimeoutSeconds: 60, admit: {},
          complete: Self.openAI(script))
      }
      #expect(script.requests == 1, "HTTP \(failFast.0) is not retried")
    }

    let cut = Script([Self.cut])
    await #expect(throws: MeetingSummary.Failure.truncated) {
      _ = try await MeetingSummary.write(
        transcript: "t", notes: "", facts: "", window: Self.large, callTimeoutSeconds: 60, admit: {},
        complete: Self.openAI(cut))
    }
    #expect(cut.requests == 1)
  }

  @Test("a real OpenAI context-length error re-plans with the byte bound")
  func openAIOverflow() async throws {
    let script = Script([Self.tooLongReply, Self.ok])
    let summary = try await MeetingSummary.write(
      transcript: "t", notes: "", facts: "", window: Self.large, callTimeoutSeconds: 60, admit: {},
      complete: Self.openAI(script))
    #expect(summary.text == "Summary.")
    #expect(script.requests == 2)
  }

  @Test("#4012: the Title line is split off; an unusable title leaves the summary whole")
  func splitTitle() {
    let summary = "## Overview\nShip Friday."
    func split(_ answer: String) -> [String?] {
      let parts = MeetingSummary.splitTitle(answer)
      return [parts.title, parts.summary]
    }
    #expect(split("Title: Launch plan\n\(summary)") == ["Launch plan", summary])
    #expect(split("**Title:** Launch plan\n\(summary)") == ["Launch plan", summary])
    #expect(split("\n# Title: \"Launch plan\"\n\(summary)") == ["Launch plan", summary])
    #expect(split(summary) == [nil, summary])
    #expect(split("Title:\n\(summary)") == [nil, summary])
    let long = String(repeating: "x", count: MeetingSummary.maxTitleLength + 1)
    #expect(split("Title: \(long)\n\(summary)") == [nil, summary])
    #expect(split("Title: C#\n\(summary)") == ["C#", summary])
    #expect(split("**Title: Launch plan**\n\(summary)") == ["Launch plan", summary])
    #expect(split("Title:\r\n\(summary)") == [nil, summary])
    #expect(split("Title: Launch plan\r\n\(summary)") == ["Launch plan", summary])
    #expect(split("Title: *nix tooling\n\(summary)") == ["*nix tooling", summary])
    #expect(MeetingSummary.finalShape.contains("Title:"))
  }

  // MARK: - Written in parts (#4044)

  @Test("the cloud defaults named by the long-meeting hint retain large planning windows")
  func longMeetingHintDefaultCapacity() {
    // #4044: "The default OpenAI, Gemini and Claude models fit much longer meetings in one
    // piece." This binds their minimum planning capacity.
    for provider: LLMProvider in [.openAI, .gemini, .claude] {
      let model = LLMProvider.defaultModel(for: provider)
      #expect(
        MeetingSummaryProviders.hostedContextTokens(provider, model: model) >= 128_000,
        "\(provider.rawValue) default \(model) no longer supports the hint's capacity claim")
    }
  }

  @Test("the saved parts fact follows the successful plan")
  func writtenPartsFact() async throws {
    let short = Calls()
    let one = try await MeetingSummary.write(
      transcript: "You: we ship Friday", notes: "", facts: "", window: Self.small,
      callTimeoutSeconds: 60, admit: {}, complete: short.complete)
    #expect(one.text == "summary 1")
    #expect(one.inParts == false)
    #expect(short.prompts.count == 1)

    let meeting = try Self.longMeeting()
    let long = Calls()
    let parts = try await MeetingSummary.write(
      transcript: meeting.transcript, notes: "", facts: "", window: Self.small,
      callTimeoutSeconds: 60, admit: {}, complete: long.complete)
    #expect(parts.inParts == true)
    #expect(long.prompts.count > 1)
  }

  @Test("retries and a single-call byte re-plan do not mean parts")
  func extraRequestsAreNotParts() async throws {
    for error in [
      LLMError.classified(.rateLimited),
      LLMError.classified(.inputTooLong),
    ] {
      let calls = Calls()
      calls.answers = [.failure(error), .success("Summary.")]
      let result = try await MeetingSummary.write(
        transcript: "You: ship Friday", notes: "", facts: "", window: Self.large,
        callTimeoutSeconds: 60, admit: {}, complete: calls.complete)
      #expect(result.inParts == false)
      #expect(calls.prompts.count == 2)
    }
  }

  @Test("a byte re-plan that splits the input reports parts")
  func byteReplanDeterminesParts() async throws {
    let transcript = String(repeating: "word ", count: 400)
    let calls = Calls()
    calls.answers = [.failure(LLMError.classified(.inputTooLong))]
    let result = try await MeetingSummary.write(
      transcript: transcript, notes: "", facts: "", window: Self.small,
      callTimeoutSeconds: 60, admit: {}, complete: calls.complete)
    #expect(calls.prompts.first?.contains("Transcript:") == true)
    #expect(calls.prompts.dropFirst().contains { $0.contains("This is part") })
    #expect(result.inParts == true)
  }

  @Test("long notes alone can cause parts")
  func notesDetermineParts() async throws {
    let calls = Calls()
    let result = try await MeetingSummary.write(
      transcript: "You: ship Friday",
      notes: String(repeating: "my note line\n", count: 800),
      facts: "", window: Self.small, callTimeoutSeconds: 60,
      admit: {}, complete: calls.complete)
    #expect(result.inParts == true)
    #expect(calls.prompts.contains { $0.contains("the user's own notes") })
  }
}

extension Result {
  fileprivate var successValue: Success? { try? get() }
  fileprivate var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
