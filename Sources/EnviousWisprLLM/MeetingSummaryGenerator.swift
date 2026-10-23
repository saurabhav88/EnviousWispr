import CryptoKit
import EnviousWisprCore
import Foundation

/// Writes a meeting summary with the user's own AI Polish provider (#3972 R39, R44). A task of
/// its own, never the dictation polish pipeline: its prompt, budgets and validators are for a
/// summary, and nothing here changes how dictation is polished. Text goes only to the provider
/// the user chose, under their key.
///
/// A long meeting is summarized in parts (map) and the parts are joined (reduce), each part
/// sized to the provider's context window, with a bounded number of calls. Only retryable
/// failures (network, rate limits) are tried again, at most twice.
public enum MeetingSummary {
  /// Bumped whenever the prompt or the plan changes what a summary says; part of each summary's
  /// inputs, so an older summary shows as out of date.
  public static let promptVersion = 1

  /// Whether the selected provider can write a summary, and why not (R44 capability matrix).
  public enum Capability: Equatable, Sendable {
    case supported(Execution)
    /// No AI Polish provider is selected.
    case noProvider
    /// The provider is a small model trained to clean up dictation; it cannot summarize.
    case notForSummaries
  }

  /// Where the provider runs: a local model competes with dictation for the Mac, a hosted one
  /// does not (R44: by execution location, never by name alone).
  public enum Execution: String, Equatable, Sendable {
    case local
    case hosted
  }

  /// `ollamaModelIsRemote`: the daemon's own fact for the selected Ollama model (a cloud model
  /// runs elsewhere); unknown counts as hosted, like Transcribe a File's classification.
  public static func capability(_ provider: LLMProvider, ollamaModelIsRemote: Bool?)
    -> Capability
  {
    switch provider {
    case .openAI, .gemini, .claude: return .supported(.hosted)
    case .ollama: return .supported((ollamaModelIsRemote ?? true) ? .hosted : .local)
    case .appleIntelligence: return .supported(.local)
    case .egOne, .s1Mini: return .notForSummaries
    case .none: return .noProvider
    }
  }

  /// The context window a request is planned against, in tokens. Hosted models have far larger
  /// windows; these are conservative floors for the models users pick. Apple Intelligence
  /// reports its own (`SystemLanguageModel.contextSize`), passed in by the caller.
  public static func contextTokens(_ provider: LLMProvider, appleContextTokens: Int?) -> Int {
    switch provider {
    case .openAI: return 100_000
    case .gemini: return 200_000
    case .claude: return 150_000
    case .ollama: return 6_000
    case .appleIntelligence: return appleContextTokens ?? 4_096
    case .egOne, .s1Mini, .none: return 0
    }
  }

  /// Output tokens one call may use.
  public static let outputTokens = 1_500
  /// Characters per token assumed when sizing parts: low, so a part never overflows a window.
  static let charactersPerToken = 3
  /// Tokens kept for instructions and framing.
  static let promptOverheadTokens = 700
  /// The most model calls one summary may make (parts plus the joins).
  public static let maxCalls = 64

  public enum Failure: Error, Equatable {
    /// The meeting needs more calls than `maxCalls` on this provider's window.
    case tooLong
    /// Every retry failed, or the failure was not retryable.
    case providerFailed
    /// The provider answered with nothing.
    case empty
    case cancelled
  }

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

  /// Characters of transcript, notes or part answers one call may carry on a window of
  /// `contextTokens` (the instructions and framing are covered by `promptOverheadTokens`).
  static func promptBudget(_ contextTokens: Int) -> Int {
    max(2_000, (contextTokens - outputTokens - promptOverheadTokens) * charactersPerToken)
  }

  /// The most characters kept from one part answer. A quarter of the budget, so every combine
  /// call holds at least three answers and each round of combining shrinks the list.
  static func partialCap(_ budget: Int) -> Int { budget / 4 }

  /// The parts of `text` for one call, cut at line ends where possible.
  static func parts(of text: String, budget: Int) -> [String] {
    guard text.count > budget else { return [text] }
    var parts: [String] = []
    var current = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = String(line)
      // A line longer than a part is split on its own.
      while line.count > budget {
        if !current.isEmpty {
          parts.append(current)
          current = ""
        }
        parts.append(String(line.prefix(budget)))
        line = String(line.dropFirst(budget))
      }
      if current.count + line.count + 1 > budget, !current.isEmpty {
        parts.append(current)
        current = ""
      }
      current += current.isEmpty ? line : "\n" + line
    }
    if !current.isEmpty { parts.append(current) }
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

  /// How a summary is written on one window.
  struct Plan: Equatable {
    /// Nil: the meeting fits one call with its notes.
    let pieces: [Piece]?
    /// Notes that go whole into the final call ("" when none, or when they are in `pieces`).
    let inlineNotes: String
    /// Characters of part answers the final call may carry beside `inlineNotes`.
    let finalBudget: Int
    /// Characters of part answers one combine call may carry.
    let budget: Int
    /// The most calls the plan can make when every answer is as long as it may be.
    let worstCaseCalls: Int
  }

  static func plan(transcript: String, notes: String, contextTokens: Int) throws -> Plan {
    let budget = promptBudget(contextTokens)
    if transcript.count + notes.count <= budget {
      return Plan(
        pieces: nil, inlineNotes: notes, finalBudget: budget, budget: budget, worstCaseCalls: 1)
    }
    // Notes up to half the budget go whole into the final call; longer notes are summarized
    // in parts like the transcript, so the final call always has room for part answers.
    let inlineNotes = notes.count <= budget / 2 ? notes : ""
    var pieces = parts(of: transcript, budget: budget).map { Piece(source: .transcript, text: $0) }
    if inlineNotes.isEmpty, !notes.isEmpty {
      pieces += parts(of: notes, budget: budget).map { Piece(source: .notes, text: $0) }
    }
    let finalBudget = budget - inlineNotes.count
    let worst = worstCaseCalls(pieces: pieces.count, budget: budget, finalBudget: finalBudget)
    guard worst <= maxCalls else { throw Failure.tooLong }
    return Plan(
      pieces: pieces, inlineNotes: inlineNotes, finalBudget: finalBudget, budget: budget,
      worstCaseCalls: worst)
  }

  /// Calls made when every part answer is `partialCap` long: the map, each round of combining,
  /// and the final call.
  static func worstCaseCalls(pieces: Int, budget: Int, finalBudget: Int) -> Int {
    let answer = partialCap(budget) + answerHeader
    let perGroup = max(2, budget / answer)
    var calls = pieces
    var count = pieces
    while count * answer > finalBudget {
      count = (count + perGroup - 1) / perGroup
      calls += count
    }
    return calls + 1
  }

  /// Characters `joined` adds before each answer ("Part 12:\n" plus the blank line).
  static let answerHeader = 16

  static func joined(_ answers: [String]) -> String {
    answers.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }
      .joined(separator: "\n\n")
  }

  /// `answer` cut to `cap` characters, at a line end where one is near.
  static func capped(_ answer: String, _ cap: Int) -> String {
    guard answer.count > cap else { return answer }
    let head = String(answer.prefix(cap))
    if let cut = head.lastIndex(of: "\n"), head.distance(from: head.startIndex, to: cut) > cap / 2 {
      return String(head[..<cut])
    }
    return head
  }

  /// SHA-256 of what decides a summary besides its inputs: provider, model, output cap and
  /// prompt version (never a key), so a model change makes an older summary out of date.
  public static func configurationFingerprint(provider: LLMProvider, model: String) -> String {
    let canonical = "\(provider.rawValue)|\(model)|\(outputTokens)|\(promptVersion)"
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Whether a failure is worth one more try: the network or a rate limit, never a bad key, a
  /// missing model or a refusal.
  public static func isRetryable(_ error: Error) -> Bool {
    if let error = error as? LLMError {
      switch error {
      case .rateLimited, .requestFailed: return true
      default: return false
      }
    }
    if let error = error as? URLError {
      return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost]
        .contains(error.code)
    }
    return false
  }

  /// One model call: the system instructions and the user prompt in, the answer out.
  public typealias Complete = @Sendable (_ instructions: String, _ prompt: String) async throws
    -> String
  /// Runs before every call; a local provider waits here for dictation to be idle (R44).
  public typealias Admit = @Sendable () async throws -> Void

  /// Writes the summary, one call after another (each finished before the next): one call for
  /// a meeting that fits; otherwise a call per part, rounds that combine the answers until they
  /// fit, and the final call. Refused before any call when the worst case needs more than
  /// `maxCalls`.
  public static func write(
    transcript: String, notes: String, contextTokens: Int, admit: Admit, complete: Complete
  ) async throws -> String {
    let plan = try plan(transcript: transcript, notes: notes, contextTokens: contextTokens)
    var calls = 0
    func ask(_ prompt: String) async throws -> String {
      calls += 1
      // The worst case bounds every run; this holds if an estimate above is ever wrong.
      guard calls <= maxCalls else { throw Failure.tooLong }
      return try await call(prompt, admit: admit, complete: complete)
    }
    guard let pieces = plan.pieces else {
      return try await ask(finalPrompt(notes: notes, body: "Transcript:\n\(transcript)"))
    }
    let cap = partialCap(plan.budget)
    let words = cap / 8
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
      answers.append(capped(answer, cap))
    }
    while joined(answers).count > plan.finalBudget {
      var groups: [[String]] = [[]]
      for answer in answers {
        if !groups[groups.count - 1].isEmpty,
          joined(groups[groups.count - 1] + [answer]).count > plan.budget
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
        combined.append(capped(answer, cap))
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

  private static func call(_ prompt: String, admit: Admit, complete: Complete) async throws
    -> String
  {
    var attempt = 0
    while true {
      do {
        try Task.checkCancellation()
        try await admit()
        let answer = try await complete(instructions, prompt).trimmingCharacters(
          in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Failure.empty }
        return answer
      } catch is CancellationError {
        throw Failure.cancelled
      } catch let failure as Failure {
        throw failure
      } catch {
        attempt += 1
        guard attempt <= 2, isRetryable(error) else { throw Failure.providerFailed }
      }
    }
  }
}
