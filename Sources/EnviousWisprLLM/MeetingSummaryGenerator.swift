import CryptoKit
import EnviousWisprCore
import Foundation

/// Writes a meeting summary with the user's own AI Polish provider (#3972 R39, R44). A task of
/// its own, never the dictation polish pipeline: its prompt, budgets and validators are for a
/// summary, and nothing here changes how dictation is polished. Text goes only to the provider
/// the user chose, under their key.
///
/// A long meeting is summarized in parts (map) and the part answers are combined (reduce), each
/// call sized in tokens to the window the provider runs with, with a bounded number of
/// attempts. No call silently loses words: every provider is asked to report a prompt too long
/// for its window rather than cut it (Ollama through `truncate: false`; the others always do),
/// so a plan is made with an estimate, re-made once with the stricter byte count when a model
/// reports an overflow, and refused as too long if the model reports one again. This is the
/// one retry owner for summary calls: connectors are
/// told not to retry (`LLMProviderConfig.maxRetries`), and failures the shared policy calls
/// retryable (`LLMRetryPolicy.isRetryable`) are tried again here, at most twice per call, each
/// attempt admitted on its own.
public enum MeetingSummary {
  /// Bumped whenever the prompt or the plan changes what a summary says; part of each summary's
  /// inputs, so an older summary shows as out of date.
  /// 2 (#3999): a long part answer is shortened by the model, never clipped.
  public static let promptVersion = 2

  /// Whether the selected provider and model can write a summary, and why not (R44 capability
  /// matrix).
  public enum Capability: Equatable, Sendable {
    case supported(Execution)
    /// No AI Polish provider is selected.
    case noProvider
    /// The model is a small model trained to clean up dictation; it cannot summarize.
    case notForSummaries
  }

  /// Where the model runs: a local model competes with dictation for the Mac, a hosted one does
  /// not (R44: by execution location, never by name alone).
  public enum Execution: String, Equatable, Sendable {
    case local
    case hosted
  }

  /// `ollamaModelIsRemote`: the daemon's own fact for the selected Ollama model (a cloud model
  /// runs elsewhere). Unknown counts as LOCAL here, the opposite of Transcribe a File's privacy
  /// default, because the mistakes differ: treating a hosted model as local only makes the
  /// summary wait for dictation, while treating a local model as hosted would run it beside
  /// dictation. EG-1 and S1-mini are refused under any provider, including a tagged Ollama
  /// reference, by the same identity helpers the connector routes on.
  public static func capability(
    _ provider: LLMProvider, model: String, ollamaModelIsRemote: Bool?
  ) -> Capability {
    switch provider {
    case .openAI, .gemini, .claude: return .supported(.hosted)
    case .ollama:
      if OllamaSetupService.isFirstPartyModel(model) || OllamaSetupService.isS1MiniModel(model) {
        return .notForSummaries
      }
      return .supported(ollamaModelIsRemote == true ? .hosted : .local)
    case .appleIntelligence: return .supported(.local)
    case .egOne, .s1Mini: return .notForSummaries
    case .none: return .noProvider
    }
  }

  /// The window one call runs in.
  public struct Window: Equatable, Sendable {
    /// The model's context in tokens.
    public let contextTokens: Int
    /// Tokens kept free for the answer: visible text plus any thinking counted against it.
    /// Where a cap is sent, it is this value.
    public let outputReserveTokens: Int

    public init(contextTokens: Int, outputReserveTokens: Int) {
      self.contextTokens = contextTokens
      self.outputReserveTokens = outputReserveTokens
    }
  }

  /// Visible output tokens one call asks for.
  public static let outputTokens = 1_500
  /// Tokens kept beside the counted instructions and framing: the framing words this file adds
  /// around a part and any special tokens a chat template adds, plus a margin like the Apple
  /// Intelligence preflight's.
  static let framingTokens = 200
  static let safetyMarginTokens = 128
  /// A window with fewer tokens than this for transcript and notes is refused, never enlarged.
  static let minimumInputTokens = 1_000
  /// The most calls a plan may need when every answer is as long as it may be.
  public static let maxCalls = 64
  /// The most attempts one summary may make, retries and the re-plan included.
  public static let maxAttempts = 80

  public enum Failure: Error, Equatable {
    /// The meeting needs more calls than `maxCalls` on this window, or the model still said
    /// its window was exceeded when planned with the byte count.
    case tooLong
    /// The window leaves too little room for any transcript.
    case windowTooSmall
    /// Every retry failed, the failure was not retryable, or the attempt limit was reached.
    case providerFailed
    /// The provider answered with nothing.
    case empty
    /// The provider stopped before the answer was finished, or a part answer stayed longer
    /// than its share of the final call even after one request to shorten it (#3999).
    case truncated
    case cancelled
    /// One call took longer than its time limit; not tried again.
    case timedOut
  }

  /// Thrown by a call whose prompt the model said was too long for its window; never leaves
  /// `write`, which re-plans with the byte count or reports `.tooLong`.
  struct ContextExceeded: Error {}

  /// The instructions every call carries.
  static let instructions = """
    You write summaries of meetings from their transcripts. Use only what the transcript and \
    the notes say; never add facts, names or decisions that are not there. Write in the \
    language of the transcript. Keep it short and plain.
    """

  /// The final shape, asked for in the last call.
  static let finalShape = """
    Write the summary in Markdown with these sections, leaving out a section that has nothing:
    ## Overview (two or three sentences)
    ## Key points (bullets)
    ## Decisions (bullets)
    ## Action items (bullets; name the owner when someone said they would do it)
    """

  // MARK: - Counting

  /// How a plan counts tokens. Neither is a proof that a call fits: a tokenizer can expand a
  /// character on normalization (U+FDFA is 3 bytes and 4 tokens in one), and a chat template
  /// adds its own text. What keeps words from being lost is that every provider reports an
  /// overflow; the counts only decide how often that happens.
  enum Counting: Equatable {
    /// A per-script planning estimate (`Tally.estimate`), the first plan.
    case estimate
    /// UTF-8 bytes, the plan after a reported overflow: never below the estimate for any
    /// scalar, and at or above the real count for byte-level and byte-fallback tokenizers on
    /// text they do not expand.
    case bytes
  }

  struct Tally {
    var ascii = 0
    var digits = 0
    var latin = 0
    var other = 0
    var bytes = 0

    mutating func add(_ scalar: Unicode.Scalar) {
      bytes += scalar.utf8.count
      switch scalar.value {
      case 0x30...0x39: digits += 1
      case 0..<0x80: ascii += 1
      case 0x80..<0x250: latin += 1
      default: other += 1
      }
    }

    /// One token per scalar outside Latin, one per ASCII digit, one per two accented Latin
    /// scalars, one per three other ASCII scalars (English averages about four).
    var estimate: Int { (ascii + 2) / 3 + digits + (latin + 1) / 2 + other }

    func tokens(_ counting: Counting) -> Int {
      counting == .bytes ? bytes : estimate
    }
  }

  static func tokens(_ text: String, _ counting: Counting) -> Int {
    var tally = Tally()
    for scalar in text.unicodeScalars { tally.add(scalar) }
    return tally.tokens(counting)
  }

  /// The planning estimate, for tests and callers that show a size.
  static func estimatedTokens(_ text: String) -> Int { tokens(text, .estimate) }

  /// The longest head of `text` that fits `limit`, never splitting a character, except a single
  /// character larger than `limit` (many combining marks), which is cut between its scalars so
  /// the cut always moves forward and loses nothing. Non-empty for a non-empty `text` and a
  /// `limit` of at least four (one scalar is at most four bytes).
  static func prefix(_ text: String, tokens limit: Int, _ counting: Counting) -> String {
    var tally = Tally()
    var end = text.startIndex
    for index in text.indices {
      var next = tally
      for scalar in text[index].unicodeScalars { next.add(scalar) }
      guard next.tokens(counting) <= limit else { break }
      tally = next
      end = text.index(after: index)
    }
    if end > text.startIndex || text.isEmpty { return String(text[..<end]) }
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      var next = tally
      next.add(scalar)
      guard next.tokens(counting) <= limit || scalars.isEmpty else { break }
      tally = next
      scalars.append(scalar)
    }
    return String(scalars)
  }

  // MARK: - Plan

  /// Tokens of transcript, notes or part answers one call may carry in `window`, beside the
  /// counted instructions, final shape, framing and margin. Refused, never enlarged, when too
  /// small.
  static func inputBudget(_ window: Window, _ counting: Counting) throws -> Int {
    let budget =
      window.contextTokens - window.outputReserveTokens - tokens(instructions, counting)
      - tokens(finalShape, counting) - framingTokens - safetyMarginTokens
    guard budget >= minimumInputTokens else { throw Failure.windowTooSmall }
    return budget
  }

  /// The most tokens kept from one part answer: a quarter of the budget, so every combine call
  /// holds at least three answers and each round of combining shrinks the list.
  static func partialCap(_ budget: Int) -> Int { budget / 4 }

  /// Tokens `joined` adds around each answer ("Part 12:" and the blank line, 11 bytes at
  /// most below 1,000 parts), rounded up.
  static let answerHeaderTokens = 16

  /// The parts of `text` for one call, cut at line ends where possible. Every iteration of the
  /// inner loop consumes at least one scalar (`prefix`), so it always ends.
  static func parts(of text: String, budget: Int, _ counting: Counting) -> [String] {
    guard tokens(text, counting) > budget else { return [text] }
    var parts: [String] = []
    var current = ""
    var currentTokens = 0
    func flush() {
      if !current.isEmpty { parts.append(current) }
      current = ""
      currentTokens = 0
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = Substring(line)
      // A line longer than a part is split on its own.
      while tokens(String(line), counting) > budget {
        flush()
        let head = prefix(String(line), tokens: budget, counting)
        parts.append(head)
        line = Substring(line.unicodeScalars.dropFirst(head.unicodeScalars.count))
      }
      // Per-line counts round up and count the newline, so their sum bounds the part's.
      let lineTokens = tokens(String(line), counting) + 1
      if currentTokens + lineTokens > budget { flush() }
      current += current.isEmpty ? String(line) : "\n" + line
      currentTokens += lineTokens
    }
    flush()
    return parts
  }

  /// One input of the map step: a part of the transcript, or a part of notes too long to go
  /// whole into the final call.
  struct Piece: Equatable {
    enum Source: Equatable {
      case transcript
      case notes
    }
    let source: Source
    let text: String
  }

  /// How a summary is written in one window.
  struct Plan: Equatable {
    let counting: Counting
    /// Nil: the meeting fits one call with its notes.
    let pieces: [Piece]?
    /// Notes that go whole into the final call ("" when none, or when they are in `pieces`).
    let inlineNotes: String
    /// Tokens of part answers the final call may carry beside `inlineNotes`.
    let finalBudget: Int
    /// Tokens of part answers one combine call may carry.
    let budget: Int
    /// The most calls the plan can make when every answer is as long as it may be.
    let worstCaseCalls: Int
  }

  static func plan(
    transcript: String, notes: String, window: Window, counting: Counting
  ) throws -> Plan {
    let budget = try inputBudget(window, counting)
    let notesTokens = tokens(notes, counting)
    if tokens(transcript, counting) + notesTokens <= budget {
      return Plan(
        counting: counting, pieces: nil, inlineNotes: notes, finalBudget: budget,
        budget: budget, worstCaseCalls: 1)
    }
    // Notes up to half the budget go whole into the final call; longer notes are summarized
    // in parts like the transcript, so the final call always has room for part answers.
    let inlineNotes = notesTokens <= budget / 2 ? notes : ""
    var pieces = parts(of: transcript, budget: budget, counting).map {
      Piece(source: .transcript, text: $0)
    }
    if inlineNotes.isEmpty, !notes.isEmpty {
      pieces += parts(of: notes, budget: budget, counting).map { Piece(source: .notes, text: $0) }
    }
    let finalBudget = budget - tokens(inlineNotes, counting)
    let worst = worstCaseCalls(pieces: pieces.count, budget: budget, finalBudget: finalBudget)
    guard worst <= maxCalls else { throw Failure.tooLong }
    return Plan(
      counting: counting, pieces: pieces, inlineNotes: inlineNotes, finalBudget: finalBudget,
      budget: budget, worstCaseCalls: worst)
  }

  /// Calls made when every part answer is `partialCap` long: the map, each round of combining,
  /// and the final call. The run below combines while `answerTokens` exceeds the final budget,
  /// and its greedy groups hold at least `perGroup` answers, so it never makes more.
  static func worstCaseCalls(pieces: Int, budget: Int, finalBudget: Int) -> Int {
    let answer = partialCap(budget) + answerHeaderTokens
    let perGroup = max(2, budget / answer)
    var calls = pieces
    var count = pieces
    while count * answer > finalBudget {
      count = (count + perGroup - 1) / perGroup
      calls += count
    }
    return calls + 1
  }

  static func joined(_ answers: [String]) -> String {
    answers.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }
      .joined(separator: "\n\n")
  }

  /// A bound on `tokens(joined(answers))`: each answer plus its header.
  static func answerTokens(_ answers: [String], _ counting: Counting) -> Int {
    answers.reduce(0) { $0 + tokens($1, counting) + answerHeaderTokens }
  }

  /// SHA-256 of what decides a summary besides its inputs: provider, model, output cap and
  /// prompt version (never a key), so a model change makes an older summary out of date.
  public static func configurationFingerprint(provider: LLMProvider, model: String) -> String {
    let canonical = "\(provider.rawValue)|\(model)|\(outputTokens)|\(promptVersion)"
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Whether `error` is a cancellation, from the task or from the transport.
  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let error = error as? URLError, error.code == .cancelled { return true }
    return false
  }

  // MARK: - Run

  /// One model call: the system instructions and the user prompt in, the answer out.
  public typealias Complete = @Sendable (_ instructions: String, _ prompt: String) async throws
    -> String
  /// Runs before every attempt; a local model waits here for dictation to be idle (R44).
  public typealias Admit = @Sendable () async throws -> Void

  /// Writes the summary, one call after another (each finished before the next): one call for
  /// a meeting that fits; otherwise a call per part, rounds that combine the answers until they
  /// fit, and the final call. Refused before any call when the window is too small or the worst
  /// case needs more than `maxCalls`.
  public static func write(
    transcript: String, notes: String, window: Window, callTimeoutSeconds: Double,
    admit: Admit, complete: @escaping Complete
  ) async throws -> String {
    let attempts = AttemptCounter()
    func run(_ counting: Counting) async throws -> String {
      try await write(
        plan(transcript: transcript, notes: notes, window: window, counting: counting),
        transcript: transcript, timeoutSeconds: callTimeoutSeconds, attempts: attempts, admit: admit,
        complete: complete)
    }
    do { return try await run(.estimate) } catch is ContextExceeded {}
    do { return try await run(.bytes) } catch is ContextExceeded { throw Failure.tooLong }
  }

  private static func write(
    _ plan: Plan, transcript: String, timeoutSeconds: Double, attempts: AttemptCounter, admit: Admit,
    complete: @escaping Complete
  ) async throws -> String {
    let counting = plan.counting
    func ask(_ prompt: String) async throws -> String {
      try await call(
        prompt, timeoutSeconds: timeoutSeconds, attempts: attempts, admit: admit,
        complete: complete)
    }
    guard let pieces = plan.pieces else {
      // The whole transcript, which `plan` has just measured against the budget.
      return try await ask(finalPrompt(notes: plan.inlineNotes, body: "Transcript:\n\(transcript)"))
    }
    let cap = partialCap(plan.budget)
    // About three-quarters of a word per estimated token, or one word per six bytes when the
    // plan counts bytes (an English word and its space); `fitted` below is the bound.
    let words = counting == .bytes ? cap / 6 : cap * 3 / 4
    // Calls the plan leaves unused when every answer is as long as it may be: the only room
    // for a shortening request, so `worstCaseCalls` stays the bound (#3999).
    var headroom = maxCalls - plan.worstCaseCalls
    /// A part answer within `cap` as written. A longer one is never clipped (that silently
    /// dropped its later decisions and action items, #3999): the model is asked once to
    /// shorten it, and an answer that still does not fit, or no room to ask, fails the
    /// summary as `.truncated`.
    func fitted(_ answer: String) async throws -> String {
      let size = tokens(answer, counting)
      guard size > cap else { return answer }
      // A target measured from this answer, so an answer that already kept the word limit is
      // still asked for less; a share of its length holds in every script (#3999).
      let percent = max(1, cap * 80 / size)
      let request = """
        Shorten these bullets to at most \(percent)% of their length. Keep every decision and \
        action item, with its owner when stated.

        \(answer)
        """
      guard headroom > 0, tokens(request, counting) <= plan.budget else {
        throw Failure.truncated
      }
      headroom -= 1
      let shorter = try await ask(request)
      guard tokens(shorter, counting) <= cap else { throw Failure.truncated }
      return shorter
    }
    var answers: [String] = []
    for (index, piece) in pieces.enumerated() {
      let what = piece.source == .transcript ? "a meeting transcript" : "the user's own notes"
      let answer = try await ask(
        """
        This is part \(index + 1) of \(pieces.count) of \(what). List its key points, decisions \
        and action items (with owners when stated) as short bullets, at most \(words) words.

        Part:
        \(piece.text)
        """)
      answers.append(try await fitted(answer))
    }
    while answerTokens(answers, counting) > plan.finalBudget {
      var groups: [[String]] = [[]]
      for answer in answers {
        if !groups[groups.count - 1].isEmpty,
          answerTokens(groups[groups.count - 1] + [answer], counting) > plan.budget
        {
          groups.append([])
        }
        groups[groups.count - 1].append(answer)
      }
      var combined: [String] = []
      for group in groups {
        let answer = try await ask(
          """
          Below are the key points of consecutive parts of a meeting, in order. Combine them \
          into one list of short bullets, at most \(words) words; drop repeats.

          \(joined(group))
          """)
        combined.append(try await fitted(answer))
      }
      answers = combined
    }
    return try await ask(
      finalPrompt(
        notes: plan.inlineNotes,
        body: """
          Below are the key points of each part of the meeting, in order. Join them into one \
          summary; drop repeats.

          \(joined(answers))
          """))
  }

  private static func finalPrompt(notes: String, body: String) -> String {
    let notesBlock = notes.isEmpty ? "" : "\n\nThe user's own notes:\n\(notes)"
    return "\(finalShape)\(notesBlock)\n\n\(body)"
  }

  /// Attempts made by one summary, retries and the re-plan included. Touched only by the
  /// summary's own calls, which run one after another.
  final class AttemptCounter: @unchecked Sendable {
    var count = 0
  }

  /// One call with its retries. Each attempt counts against `maxAttempts` and is admitted on
  /// its own, and cancellation is checked after the wait for admission and after the answer.
  /// The time limit covers the model call only, never the wait in `admit`. It cancels the call
  /// and waits for it to end (`withThrowingTimeout`), so a local model still finishes one call
  /// before the next starts (R44); a call that ignores cancellation can run past the limit.
  private static func call(
    _ prompt: String, timeoutSeconds: Double, attempts: AttemptCounter, admit: Admit,
    complete: @escaping Complete
  ) async throws -> String {
    var retries = 0
    while true {
      do {
        try Task.checkCancellation()
        try await admit()
        try Task.checkCancellation()
        attempts.count += 1
        guard attempts.count <= maxAttempts else { throw Failure.providerFailed }
        let answer = try await withThrowingTimeout(seconds: timeoutSeconds) {
          try await complete(instructions, prompt)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !answer.isEmpty else { throw Failure.empty }
        return answer
      } catch let failure as Failure {
        throw failure
      } catch let exceeded as ContextExceeded {
        throw exceeded
      } catch LLMError.classified(.inputTooLong) {
        throw ContextExceeded()
      } catch LLMError.classified(.outputTruncated) {
        throw Failure.truncated
      } catch is TimeoutError {
        throw Failure.timedOut
      } catch let error where isCancellation(error) {
        throw Failure.cancelled
      } catch {
        retries += 1
        guard retries <= 2, LLMRetryPolicy.isRetryable(error) else {
          throw Failure.providerFailed
        }
      }
    }
  }
}
