import Foundation

/// The in-app help check (#3275): split the message on this Mac, ask enviouswispr.com which help
/// section answers each concern, and either offer cards or send the report as written. It never
/// holds a report back on its own: every failure, timeout or doubt ends in ordinary sending.
public struct HelpCheck: Sendable {
  /// The on-device split. Returns `.unavailable` rather than throwing.
  public typealias Decompose = @Sendable (String) async -> HelpCheckDecomposition
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  /// macOS 26 validation (#3275 plan): normal-length p99 3.28 s on an M4 MacBook Air; slower splits
  /// fall back to the whole message, which can never be suppressed.
  public static let decompositionDeadline: Duration = .seconds(4)
  /// From Send to cards or sending: the split, both server calls and the transfer.
  public static let overallDeadline: Duration = .seconds(7)

  let decompose: Decompose
  let decompositionVersion: String
  let client: HelpCheckClient
  let appVersion: String
  let sleep: Sleep

  public init(
    decompose: @escaping Decompose, decompositionVersion: String, appVersion: String,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.init(
      decompose: decompose, decompositionVersion: decompositionVersion, client: .live,
      appVersion: appVersion, sleep: sleep)
  }

  init(
    decompose: @escaping Decompose, decompositionVersion: String, client: HelpCheckClient,
    appVersion: String, sleep: @escaping Sleep
  ) {
    self.decompose = decompose
    self.decompositionVersion = decompositionVersion
    self.client = client
    self.appVersion = appVersion
    self.sleep = sleep
  }

  /// What the check concluded.
  public enum Conclusion: Equatable, Sendable {
    /// Cards to offer. Nothing is sent until the user chooses.
    case suggestions(HelpCheckSuggestions)
    /// Nothing to offer: send the report now with this outcome. `splitFailure` is why the
    /// on-device split was skipped, when it was, for counting (never user text).
    case send(FeedbackHelpOutcome, splitFailure: FeedbackHelpOutcome.FailureReason?)
  }

  /// Runs the check against the untouched message. Always returns within `overallDeadline` (plus
  /// scheduling), whatever the split or the network does; late work is cancelled, not awaited.
  public func run(_ message: String) async -> Conclusion {
    // The overall deadline's fallback names the path actually taken: a split that timed out
    // and then a request that ran out the clock is whole-message, with the split's failure.
    let stage = Stage()
    let finished: Conclusion? = await Self.first(
      within: Self.overallDeadline, sleep: sleep, orElse: nil
    ) { [self] in
      await self.check(message, stage: stage)
    }
    if let finished { return finished }
    let (mode, splitFailure) = stage.value
    return Self.fallback(.timeout, mode: mode, splitFailure: splitFailure)
  }

  /// Which path the check is on, for the overall deadline's fallback: decomposed until the split
  /// says otherwise.
  private final class Stage: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: FeedbackHelpOutcome.Mode = .decomposed
    private var splitFailure: FeedbackHelpOutcome.FailureReason?

    var value: (FeedbackHelpOutcome.Mode, FeedbackHelpOutcome.FailureReason?) {
      lock.withLock { (mode, splitFailure) }
    }

    func set(_ mode: FeedbackHelpOutcome.Mode, _ splitFailure: FeedbackHelpOutcome.FailureReason?) {
      lock.withLock {
        self.mode = mode
        self.splitFailure = splitFailure
      }
    }
  }

  private func check(_ message: String, stage: Stage) async -> Conclusion {
    let split = await Self.first(
      within: Self.decompositionDeadline, sleep: sleep,
      orElse: HelpCheckDecomposition.unavailable(.afmTimeout)
    ) { [decompose] in
      await decompose(message)
    }
    let request: HelpCheckRequest
    let anchored: [Bool]
    var summaries: [String] = []
    let splitFailure: FeedbackHelpOutcome.FailureReason?
    switch split {
    case .concerns(let concerns, let hitCap):
      let prepared = HelpCheckPreparation.prepare(concerns, hitCap: hitCap, in: message)
      request = HelpCheckRequest(
        originalMessage: message, mode: .decomposed, issues: prepared.issues,
        overflow: prepared.overflow, decompositionVersion: decompositionVersion,
        appVersion: appVersion)
      anchored = prepared.issues.map { issue in
        guard let start = issue.startUTF16, let end = issue.endUTF16 else { return false }
        let units = Array(message.utf16)
        return String(decoding: units[start..<end], as: UTF16.self) == issue.evidence
      }
      splitFailure = nil
      summaries = prepared.issues.map(\.summary)
    case .unavailable(let reason):
      request = HelpCheckRequest(
        originalMessage: message, mode: .wholeMessageAlwaysSend, issues: [], overflow: false,
        decompositionVersion: decompositionVersion, appVersion: appVersion)
      anchored = [false]
      splitFailure = reason
    }
    stage.set(request.mode, splitFailure)
    guard !Task.isCancelled else {
      return Self.fallback(.timeout, mode: request.mode, splitFailure: splitFailure)
    }

    switch await client.check(request) {
    case .failure(let failure):
      return Self.fallback(failure.reason, mode: request.mode, splitFailure: splitFailure)
    case .success(let reply):
      guard reply.status == .ok else {
        return Self.fallback(
          Self.serverReason(reply.reason), mode: request.mode, splitFailure: splitFailure)
      }
      let suggestions = HelpCheckSuggestions(
        mode: request.mode, overflow: request.overflow, reply: reply, anchored: anchored,
        splitFailure: splitFailure, summaries: summaries)
      if suggestions.cards.isEmpty {
        // Nothing worth showing (praise, or no match): send now, recording what was checked.
        return .send(suggestions.outcome(solved: []), splitFailure: splitFailure)
      }
      return .suggestions(suggestions)
    }
  }

  /// The server's closed reasons; a variable HTTP code is `http_error`; anything else is a bad reply.
  static func serverReason(_ reason: String) -> FeedbackHelpOutcome.FailureReason {
    if reason.hasPrefix("http_") { return .httpError }
    return FeedbackHelpOutcome.FailureReason(rawValue: reason) ?? .badReply
  }

  static func fallback(
    _ reason: FeedbackHelpOutcome.FailureReason, mode: FeedbackHelpOutcome.Mode,
    splitFailure: FeedbackHelpOutcome.FailureReason? = nil
  ) -> Conclusion {
    .send(
      FeedbackHelpOutcome(
        terminalOutcome: .fallbackSent, failureReason: reason, mode: mode, overflow: false,
        coveragePassed: nil, versions: nil, shownCardCount: 0, issues: [])!,
      splitFailure: splitFailure)
  }

  /// The first of `work` or the deadline. The loser is cancelled and NOT awaited, so a split that
  /// ignores cancellation cannot hold the check past its deadline.
  static func first<T: Sendable>(
    within deadline: Duration, sleep: @escaping Sleep, orElse timedOut: T,
    _ work: @escaping @Sendable () async -> T
  ) async -> T {
    let once = Once<T>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        once.set(continuation)
        let worker = Task { once.resume(await work()) }
        let timer = Task {
          try? await sleep(deadline)
          once.resume(timedOut)
        }
        once.onFinish = {
          worker.cancel()
          timer.cancel()
        }
      }
    } onCancel: {
      once.resume(timedOut)
    }
  }

  /// Resumes one continuation exactly once, from whichever side finishes first.
  private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var finished = false
    var onFinish: (@Sendable () -> Void)? {
      get { lock.withLock { finishAction } }
      set {
        let runNow = lock.withLock { () -> Bool in
          finishAction = newValue
          return finished
        }
        if runNow { newValue?() }
      }
    }
    private var finishAction: (@Sendable () -> Void)?

    func set(_ continuation: CheckedContinuation<T, Never>) {
      let early = lock.withLock { () -> T? in
        self.continuation = continuation
        return pending
      }
      if let early { deliver(early) }
    }

    func resume(_ value: T) {
      let ready = lock.withLock { () -> Bool in
        guard !finished, pending == nil else { return false }
        if continuation == nil {
          pending = value
          return false
        }
        return true
      }
      if ready { deliver(value) }
    }

    private func deliver(_ value: T) {
      let (continuation, action) = lock.withLock {
        () -> (CheckedContinuation<T, Never>?, (@Sendable () -> Void)?) in
        guard !finished else { return (nil, nil) }
        finished = true
        let c = self.continuation
        self.continuation = nil
        return (c, finishAction)
      }
      continuation?.resume(returning: value)
      action?()
    }
  }
}

/// Cards the check can offer, and the app's own rule for when "all solved" may end a report.
public struct HelpCheckSuggestions: Equatable, Sendable {
  public let mode: FeedbackHelpOutcome.Mode
  public let overflow: Bool
  public let reply: HelpCheckReply
  /// Per concern: the quote is the message's exact text at its range.
  public let anchored: [Bool]
  /// Why the split was skipped, when it was (whole-message mode).
  public let splitFailure: FeedbackHelpOutcome.FailureReason?
  /// Each concern's short name from the on-device split, in order, for the cards' wording
  /// ("Did this fix …?"). Written by the model on this Mac; empty in whole-message mode.
  public var summaries: [String] = []

  /// The concern's short name for the cards, or nil when there is none to show.
  public func summary(for issueID: String) -> String? {
    guard let index = reply.results.firstIndex(where: { $0.id == issueID }),
      index < summaries.count
    else { return nil }
    let text = summaries[index].trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  public static let maxCards = FeedbackHelpOutcome.maxShownCards

  /// One card per distinct help target, in concern order, at most three; concerns that share a
  /// target share its card.
  public struct Card: Equatable, Sendable {
    public let result: HelpCheckReply.Result
    /// Every concern this card answers.
    public let issueIDs: [String]
  }

  public var cards: [Card] {
    var cards: [Card] = []
    for result in reply.results where result.matchType != .none {
      let target = result.sectionID ?? result.pageSlug
      if let index = cards.firstIndex(where: {
        ($0.result.sectionID ?? $0.result.pageSlug) == target
      }) {
        cards[index] = Card(
          result: cards[index].result, issueIDs: cards[index].issueIDs + [result.id])
      } else if cards.count < Self.maxCards {
        cards.append(Card(result: result, issueIDs: [result.id]))
      }
    }
    return cards
  }

  /// The app's own rule, independent of the server: "all solved" may end the report only for a
  /// decomposed split with no overflow, whole-list coverage at the gate, every concern anchored
  /// exactly and matched to a verified can_resolve section shown on a card, and the server
  /// agreeing. `suppression_allowed: false` from the server always wins.
  public var suppressionAllowed: Bool {
    let shown = Set(cards.flatMap(\.issueIDs))
    return reply.suppressionAllowed && mode == .decomposed && !overflow
      && (reply.coverage ?? 0) >= HelpCheckReply.coverageGate && !reply.results.isEmpty
      && anchored.count == reply.results.count
      && zip(reply.results, anchored).allSatisfy { result, isAnchored in
        isAnchored && result.resolutionEligible && result.matchType == .section
          && result.deflection == .canResolve && shown.contains(result.id)
      }
  }

  /// Concerns the user may mark solved on a card: in decomposed mode, a verified can_resolve
  /// section the server calls resolvable, whose quote is the message's exact text, shown on a card.
  public func canMarkSolved(_ issueID: String) -> Bool {
    guard mode == .decomposed, let index = reply.results.firstIndex(where: { $0.id == issueID }),
      index < anchored.count
    else { return false }
    let result = reply.results[index]
    return anchored[index] && result.resolutionEligible && !result.requiresSend
      && result.matchType == .section && result.deflection == .canResolve
      && Set(cards.flatMap(\.issueIDs)).contains(issueID)
  }

  /// Every concern's id, for confirming all solved.
  public var issueIDs: Set<String> { Set(reply.results.map(\.id)) }

  /// The frozen outcome for a report that is sent. `solved` holds ids the user marked solved;
  /// ids that cannot be marked solved are recorded as still happening.
  public func outcome(solved: Set<String>) -> FeedbackHelpOutcome {
    let issues = reply.results.enumerated().compactMap { index, result in
      let resolution: FeedbackHelpOutcome.Resolution =
        result.matchType == .none
        ? .unmatched
        : (solved.contains(result.id) && canMarkSolved(result.id) ? .solved : .stillHappening)
      return FeedbackHelpOutcome.Issue(
        index: index,
        matchKind: FeedbackHelpOutcome.MatchKind(rawValue: result.matchType.rawValue) ?? .none,
        pageSlug: result.pageSlug, sectionID: result.sectionID, deflection: result.deflection,
        resolution: resolution)
    }
    // Solved only counts where it could be marked; the terminal follows what was recorded.
    let resolvedTerminal: FeedbackHelpOutcome.TerminalOutcome =
      issues.contains { $0.resolution == .solved } ? .partialSent : .stillSent
    // Every value here comes from a reply `HelpCheckReply.decode` accepted, which enforces the
    // same bounds, so this should not fail. If a decode gap ever lets it, a debug build stops
    // here; a release build still sends the report, with an outcome that claims nothing.
    if issues.count == reply.results.count,
      let outcome = FeedbackHelpOutcome(
        terminalOutcome: resolvedTerminal, failureReason: nil, mode: mode, overflow: overflow,
        coveragePassed: reply.coverage.map { $0 >= HelpCheckReply.coverageGate },
        versions: reply.versions, shownCardCount: cards.count, issues: issues)
    {
      return outcome
    }
    assertionFailure("help outcome out of bounds from a decoded reply")
    return FeedbackHelpOutcome(
      terminalOutcome: .fallbackSent, failureReason: .badReply, mode: mode, overflow: overflow,
      coveragePassed: nil, versions: nil, shownCardCount: 0, issues: [])!
  }
}

/// How one help check ended (#3275), for the one terminal usage event. Counts and closed values
/// only: never the message, a summary, a quote, card text or a link.
public struct HelpCheckTerminal: Equatable, Sendable {
  public enum Outcome: String, Sendable {
    /// Every concern confirmed solved; nothing was sent.
    case helped
    /// The report was saved for sending (with or without cards, some solved or none).
    case stillSent = "still_sent"
    /// The cards were closed; nothing was sent and the draft stays.
    case dismissed
    /// The report was meant to send but the outbox refused it (full or unavailable).
    case notSaved = "not_saved"
  }

  public let outcome: Outcome
  public let mode: FeedbackHelpOutcome.Mode
  public let overflow: Bool
  public let coveragePassed: Bool?
  public let issues: Int
  public let cards: Int
  public let sections: Int
  public let pages: Int
  public let solved: Int
  public let unmatched: Int
  public let failure: FeedbackHelpOutcome.FailureReason?
  public let splitFailure: FeedbackHelpOutcome.FailureReason?
  /// Seconds from Send to cards or sending.
  public let checkSeconds: Double
  public let versions: FeedbackHelpOutcome.Versions?

  /// A closed bucket for the check's duration, against the 4 s split and 7 s overall deadlines.
  public var durationBucket: String {
    switch checkSeconds {
    case ..<1: "lt_1s"
    case ..<2: "1_2s"
    case ..<4: "2_4s"
    case ..<7: "4_7s"
    default: "ge_7s"
    }
  }

  /// From the outcome frozen with a sent (or refused) report.
  init(
    _ outcome: Outcome, record: FeedbackHelpOutcome,
    splitFailure: FeedbackHelpOutcome.FailureReason?, checkSeconds: Double
  ) {
    self.outcome = outcome
    self.mode = record.mode
    self.overflow = record.overflow
    self.coveragePassed = record.coveragePassed
    self.issues = record.issueCount
    self.cards = record.shownCardCount
    self.sections = record.sectionMatchCount
    self.pages = record.pageOnlyCount
    self.solved = record.solvedIssueCount
    self.unmatched = record.unmatchedIssueCount
    self.failure = record.failureReason
    self.splitFailure = splitFailure
    self.checkSeconds = checkSeconds
    self.versions = record.versions
  }
}
