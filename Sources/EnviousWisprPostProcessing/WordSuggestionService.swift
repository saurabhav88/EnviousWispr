import EnviousWisprCore
import Foundation
import os

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Explicit, priority-aware permit queue backing `WordSuggestionService`'s
/// shared production door (#1701). Not "await inside an actor" — actors are
/// reentrant across a suspension point, so a method that merely awaits model
/// work inside an actor would still let a second call interleave. This type
/// grants an explicit permit token instead: exactly one holder at a time,
/// `.interactive` waiters served ahead of already-queued `.background`
/// waiters, FIFO within a priority, and the current holder is never
/// pre-empted — priority affects only queue ordering, not interruption.
///
/// `internal` (default) visibility: invisible to consumers outside this
/// module (AppKit imports the module without `@testable`); reachable from
/// `WordSuggestionServiceTests` only via `@testable import`, which is the
/// narrow seam those tests use to drive queue ordering and cancellation
/// deterministically without touching FoundationModels.
actor AliasSuggestionPermitQueue {
  private struct Waiter {
    let id: UUID
    let priority: AliasSuggestionPriority
    let latch: CancellationLatch
    let continuation: CheckedContinuation<Bool, Never>
  }

  /// Per-`acquire` cancellation signal, set synchronously and thread-safely
  /// (via `OSAllocatedUnfairLock`) from `withTaskCancellationHandler`'s
  /// `onCancel` closure, which is NOT
  /// actor-isolated and may fire before, during, or after `register` runs.
  /// Deliberately NOT actor state: an actor-owned `Set<UUID>` needs a
  /// tombstone entry for every id whose `onCancel` races ahead of or past
  /// `register`, and once `register` has already run for that id, nothing
  /// could ever remove the tombstone (Grounded Review Chunk 1 finding —
  /// reachable via Add-term's frequent debounced task cancellation, not a
  /// rare edge: real unbounded growth, not the "bounded/inert" residue the
  /// prior revision claimed). A latch scoped to the call stack is freed by
  /// ARC when `acquire`'s frame unwinds — nothing persists in the actor
  /// regardless of cancellation timing.
  private final class CancellationLatch: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { lock.withLock { $0 } }
    func cancel() { lock.withLock { $0 = true } }
  }

  private var waiters: [Waiter] = []
  private var permitHeld = false

  /// Waits for the permit. Returns `true` once granted; returns `false`,
  /// without ever granting a permit, when the caller's task was cancelled
  /// before its turn arrived. A `false` result means zero model work should
  /// run and the caller must not call `release()`.
  func acquire(id: UUID, priority: AliasSuggestionPriority) async -> Bool {
    let latch = CancellationLatch()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        register(id: id, priority: priority, latch: latch, continuation: continuation)
      }
    } onCancel: {
      latch.cancel()
      Task { await self.cancelWaiting(id: id) }
    }
  }

  /// Test seam: current queue depth. Lets a test deterministically poll
  /// (`await Task.yield()` in a loop, never `Task.sleep`/wall-clock) until a
  /// concurrently-started waiter has actually registered, instead of guessing
  /// at timing. `internal`: reachable only via `@testable import`.
  var waiterCountForTesting: Int { waiters.count }

  /// Releases the held permit, granting it directly to the next LIVE queued
  /// waiter (priority, then FIFO) if one exists. Must be called exactly once
  /// for every `acquire` that returned `true` — including when the caller
  /// itself discovers a post-grant cancellation and never runs its operation.
  ///
  /// Walks (never just peeks) the front of the queue: `onCancel` sets a
  /// waiter's latch synchronously but removes it from `waiters` via a
  /// separately-scheduled actor message (`cancelWaiting`, below) — this
  /// method can run BEFORE that removal message arrives (Grounded Review
  /// Chunk 1 round 3 finding), so a queued-but-not-yet-removed cancelled
  /// waiter must never be handed the permit even briefly. Each cancelled
  /// waiter encountered is resumed `false` and dropped; the loop keeps going
  /// until it finds a live waiter to grant, or the queue is exhausted.
  func release() {
    while !waiters.isEmpty {
      let next = waiters.removeFirst()
      if next.latch.isCancelled {
        next.continuation.resume(returning: false)
        continue
      }
      next.continuation.resume(returning: true)
      // permitHeld stays true: ownership transfers directly to `next`, never
      // a window where the permit is unheld while a waiter is queued.
      return
    }
    permitHeld = false
  }

  private func register(
    id: UUID,
    priority: AliasSuggestionPriority,
    latch: CancellationLatch,
    continuation: CheckedContinuation<Bool, Never>
  ) {
    if latch.isCancelled {
      continuation.resume(returning: false)
      return
    }
    if !permitHeld {
      permitHeld = true
      continuation.resume(returning: true)
      return
    }
    let insertIndex =
      priority == .interactive
      ? (waiters.firstIndex(where: { $0.priority == .background }) ?? waiters.count)
      : waiters.count
    waiters.insert(
      Waiter(id: id, priority: priority, latch: latch, continuation: continuation),
      at: insertIndex)
  }

  /// Test seam: marks a currently-queued waiter's cancellation latch as
  /// cancelled WITHOUT removing it from the queue — simulates the exact
  /// interleaving `release()`'s doc comment above describes, where
  /// `onCancel` has set the latch but the asynchronous `cancelWaiting`
  /// removal message has not yet reached the actor (Grounded Review Chunk 1
  /// round 3 finding). No-op if `id` is not currently queued. `internal`:
  /// reachable only via `@testable import`.
  func cancelLatchWithoutRemovingForTesting(id: UUID) {
    guard let waiter = waiters.first(where: { $0.id == id }) else { return }
    waiter.latch.cancel()
  }

  /// No-op when `id` is neither currently queued nor still pending
  /// registration — covers both "already granted" (nothing to remove) and
  /// "already resolved via the latch" (the latch, not this method, was the
  /// signal that mattered).
  private func cancelWaiting(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}

#if DEBUG
  /// Test-only storage for `benchmarkSuggest`'s deterministic override
  /// (#1701 Grounded Review Chunk 1 finding). An actor, not a plain `var` on
  /// `WordSuggestionService`, so storage stays Sendable-safe without
  /// `nonisolated(unsafe)`/`@unchecked` — `WordSuggestionService` otherwise
  /// has only immutable stored properties. Always empty (`value == nil`) in
  /// production; nothing production-facing ever writes to it. `#if DEBUG`-
  /// gated end to end (Grounded Review Chunk 1 round 2 finding): the Release
  /// alias-eval harness calls `benchmarkSuggest` directly to measure real
  /// latency and concurrency (`scripts/eval/alias_runner`) — this box, its
  /// property, and the check inside `benchmarkSuggest` must not add an actor
  /// hop to that measured path.
  actor RawSuggestionOverrideBox {
    private(set) var value:
      (@Sendable (String) async throws -> (category: WordCategory, aliases: [String]))?

    func set(
      _ newValue: (@Sendable (String) async throws -> (category: WordCategory, aliases: [String]))?
    ) {
      value = newValue
    }
  }
#endif

/// Wraps `withPermit`'s operation result so a `nil` FROM the operation itself
/// (a normal "no suggestion" outcome) is never confused with `withDeadline`
/// abandoning the operation (Phase 3 review finding A, #1701).
private struct PermitOperationResult<Value: Sendable>: Sendable {
  let value: Value
}

public final class WordSuggestionService: Sendable {
  /// Serializes every production alias-suggestion call — `suggest(for:)` and
  /// `suggestAliases(for:category:)` — through one in-flight permit at a time,
  /// interactive before background (#1701). `internal` (narrowest visibility
  /// that compiles): invisible to consumers outside this module; reachable
  /// from `WordSuggestionServiceTests` only via `@testable import`. This is
  /// the sole production door — there is no second, unserialized path to the
  /// model left for a future caller to reach by accident.
  let permitQueue = AliasSuggestionPermitQueue()

  #if DEBUG
    /// Test-only override for `benchmarkSuggest`'s on-device path (#1701).
    /// See `RawSuggestionOverrideBox`. `internal`: reachable only via
    /// `@testable import`. `#if DEBUG`-gated: absent from Release builds.
    let rawSuggestionOverrideForTesting = RawSuggestionOverrideBox()
  #endif

  public var isAvailable: Bool {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *) else { return false }
      return SystemLanguageModel.default.availability == .available
    #else
      return false
    #endif
  }

  public init() {}

  /// Runs `operation` while holding the shared permit, in priority order.
  /// Returns `whenNotGranted` — never invoking `operation` — when the calling
  /// task is cancelled either while queued or in the gap between permit grant
  /// and this check (both are zero-model-call cancellation points; #1701).
  /// `internal`: this is the test seam `WordSuggestionServiceTests` drives
  /// directly to exercise the exact queue/permit mechanics both production
  /// entry points use, without touching FoundationModels (unavailable/
  /// unreliable in a test environment).
  ///
  /// `afterGrantForTesting` is a test-only hook, always `nil` in production
  /// (`suggest`/`suggestAliases` never pass it, so `await nil?()` is an
  /// instant no-op — zero behavior change on the real path). It exists
  /// because the real cancelled-after-grant race is impossible to hit
  /// deterministically through actual `Task` scheduling on a multi-threaded
  /// executor; this hook lets a test park the call at exactly that point,
  /// cancel it, then resume, proving the check fires correctly without
  /// relying on scheduler timing.
  /// `deadlineSeconds` has no default (Phase 3 review finding A, #1701):
  /// `withDeadline`, never `withThrowingTimeout`, bounds `operation` — a
  /// FoundationModels call that ignores cancellation cannot make
  /// `withThrowingTimeout`'s task-group scope return, which would strand
  /// this permit forever and block every later interactive and background
  /// caller. `withDeadline` returns at the true deadline WITHOUT awaiting an
  /// abandoned operation; the abandoned physical task may keep running in
  /// the background while a later logical request starts — an accepted
  /// tradeoff over permanently blocking every suggestion request.
  func withPermit<T: Sendable>(
    priority: AliasSuggestionPriority,
    whenNotGranted: T,
    deadlineSeconds: Double,
    afterGrantForTesting: (@Sendable () async -> Void)? = nil,
    operation: @escaping @Sendable () async -> T
  ) async -> T {
    let id = UUID()
    let granted = await permitQueue.acquire(id: id, priority: priority)
    guard granted else { return whenNotGranted }
    await afterGrantForTesting?()
    if Task.isCancelled {
      await permitQueue.release()
      return whenNotGranted
    }
    let result = await withDeadline(seconds: deadlineSeconds) {
      PermitOperationResult(value: await operation())
    }
    await permitQueue.release()
    return result?.value ?? whenNotGranted
  }

  /// Preserves the existing five-second policy — not a new timing invention
  /// (Phase 3 review finding A, #1701).
  private static let suggestionDeadlineSeconds = 5.0

  public func suggest(
    for word: String,
    priority: AliasSuggestionPriority = .interactive
  ) async -> WordSuggestions? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *),
        case .available = SystemLanguageModel.default.availability
      else { return nil }

      return await withPermit(
        priority: priority, whenNotGranted: nil, deadlineSeconds: Self.suggestionDeadlineSeconds
      ) {
        await self.runSuggestion(for: word)
      }
    #else
      return nil
    #endif
  }

  /// Benchmark-only entry point for the alias-eval harness (#637).
  ///
  /// Returns BOTH raw (pre-filter) and filtered aliases plus timing/error
  /// metadata so the eval scorer can grade the degeneration axis. When
  /// `disableTimeout=true`, the 5-second wrapper is omitted so the harness
  /// can measure true latency without censoring slow responses.
  ///
  /// NEVER call from production code. Production reads `suggest(for:)`,
  /// which shares the same `runRawSuggestion` core but wraps a 5s timeout
  /// and returns `WordSuggestions?` after running the degeneration filter.
  // periphery:ignore - eval harness API (scripts/eval/alias_runner)
  public func benchmarkSuggest(
    for word: String,
    disableTimeout: Bool = false
  ) async -> WordSuggestionBenchmarkRecord {
    let startTime = Date()
    #if DEBUG
      // Test-only path (#1701 Grounded Review Chunk 1 finding), absent from
      // Release entirely — the Release alias-eval harness calls this method
      // directly to measure real latency and concurrency, so Release must
      // never add an actor hop here even when the override is unset.
      // Bypasses the live-availability gate below too, not just the
      // raw-suggestion call — real Apple Intelligence eligibility is
      // environment-dependent (this suite's own dev machine has it enabled,
      // so a test asserting the unavailable branch would be flaky/wrong on a
      // machine where it isn't), so a deterministic test needs the whole
      // on-device decision replaced, not just the model call inside it.
      if let override = await rawSuggestionOverrideForTesting.value {
        do {
          let resolved = try await override(word)
          let filtered = Self.filterDegeneratedAliases(resolved.aliases, canonical: word)
          return WordSuggestionBenchmarkRecord(
            category: resolved.category,
            rawAliases: resolved.aliases,
            filteredAliases: filtered,
            timedOut: false,
            errorDescription: nil,
            latencyMs: Self.elapsedMs(since: startTime)
          )
        } catch {
          return WordSuggestionBenchmarkRecord(
            category: .general,
            rawAliases: [],
            filteredAliases: [],
            timedOut: false,
            errorDescription: "\(error)",
            latencyMs: Self.elapsedMs(since: startTime)
          )
        }
      }
    #endif
    #if canImport(FoundationModels)
      guard #available(macOS 26, *),
        case .available = SystemLanguageModel.default.availability
      else {
        return WordSuggestionBenchmarkRecord(
          category: .general,
          rawAliases: [],
          filteredAliases: [],
          timedOut: false,
          errorDescription: "framework_unavailable",
          latencyMs: Self.elapsedMs(since: startTime)
        )
      }
      let raw: (category: WordCategory, aliases: [String])?
      var timedOut = false
      var errorDescription: String?
      if disableTimeout {
        do {
          raw = try await self.runRawSuggestion(for: word)
        } catch {
          raw = nil
          errorDescription = "\(error)"
        }
      } else {
        do {
          raw = try await withThrowingTimeout(seconds: 5) {
            try await self.runRawSuggestion(for: word)
          }
        } catch is TimeoutError {
          raw = nil
          timedOut = true
        } catch {
          raw = nil
          errorDescription = "\(error)"
        }
      }
      guard let resolved = raw else {
        return WordSuggestionBenchmarkRecord(
          category: .general,
          rawAliases: [],
          filteredAliases: [],
          timedOut: timedOut,
          errorDescription: errorDescription,
          latencyMs: Self.elapsedMs(since: startTime)
        )
      }
      let filtered = Self.filterDegeneratedAliases(resolved.aliases, canonical: word)
      return WordSuggestionBenchmarkRecord(
        category: resolved.category,
        rawAliases: resolved.aliases,
        filteredAliases: filtered,
        timedOut: false,
        errorDescription: nil,
        latencyMs: Self.elapsedMs(since: startTime)
      )
    #else
      return WordSuggestionBenchmarkRecord(
        category: .general,
        rawAliases: [],
        filteredAliases: [],
        timedOut: false,
        errorDescription: "framework_unavailable",
        latencyMs: Self.elapsedMs(since: startTime)
      )
    #endif
  }

  private static func elapsedMs(since start: Date) -> Int {
    Int((Date().timeIntervalSince(start) * 1000.0).rounded())
  }

  // Step 1 — classification only.
  private static let classificationInstructions = """
    Classify the input word into ONE of these categories. Return only the \
    category name. Pick the FIRST rule that matches.

    1. acronym  -- the input is ALL CAPITAL LETTERS only, no lowercase, no \
    digits, no punctuation. Examples: OKR, PR, KPI, RSI, AWS, NATO, HIPAA, CRM.
    2. domain   -- the input mixes lowercase and uppercase letters OR contains \
    a digit, dot, or other symbol. Examples: gRPC, GraphQL, OAuth2, WebSocket, \
    WebRTC, S3, github.com.
    3. person   -- the input is a human name (capitalized first letter, \
    otherwise lowercase). Examples: Parvati, Saurabh, Miyamoto, Aiyana.
    4. brand    -- the input is a product, company, or framework name. \
    Examples: Kubernetes, Postgres, Tailwind, Linear, DigitalOcean, Slack.
    5. general  -- everything else (regular vocabulary). Examples: webhook, \
    async, middleware.

    Output exactly one of: acronym, domain, person, brand, general.
    """

  // Step 2 — generation, given a known category.
  // Style: Restored exp4 baseline (prose + per-category examples, no MUST
  // language). This is the proven 18.2% configuration. All three minimal
  // styles (JSON-only, Bare Schema, Wrong/Right Contrast) regressed below
  // this; AFM needs both task definition and concrete examples for this
  // task. Examples use IN-CORPUS words intentionally so AFM's prior
  // knowledge of those words helps; the corpus is intentionally distinct
  // from the example words for unfamiliar items.
  private static func aliasInstructions(for category: WordCategory) -> String {
    switch category {
    case .acronym:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write an \
        ACRONYM wrong. The acronym is spelled letter-by-letter aloud. Each \
        letter is heard as a syllable.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Each output must be \
        SUBSTANTIVELY different from the input. Never echo the input. \
        Example for "OKR":
        okay are
        oh K R
        okayer
        Example for "PR":
        pee are
        peer
        pee R
        Example for "HIPAA":
        hippa
        hip ah
        hipper

        Never return the same line twice. If you cannot produce 3 \
        substantively different mistranscriptions, return an empty response.
        """
    case .domain:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        TECHNICAL TERM wrong. The term mixes letters and words; ASR splits \
        it into chunks or letter-syllables.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Each output must be \
        SUBSTANTIVELY different from the canonical -- NOT just a space \
        inserted, NOT just casing changed. Example for "gRPC":
        gee R P C
        jee R P C
        gee are pee see
        Example for "GraphQL":
        graph Q L
        graf Q L
        graph queue ell
        Example for "WebSocket":
        wep sock it
        wep socket
        web sok it

        Never output the canonical term with only added or removed spaces. \
        If you cannot produce 3 distinct mistranscriptions, return empty.
        """
    case .person:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        PERSON'S NAME wrong. ASR mishears via vowel and consonant swaps and \
        word-boundary errors.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Never output honorifics, \
        relatives, last names, or alternate identities. Example for "Parvati":
        par vati
        poor vati
        pavathi
        Example for "Saurabh":
        Sourabh
        Sorab
        Sarab
        Example for "Miyamoto":
        me ya moto
        mia motto
        miyomoto

        If you cannot produce 3 substantively different mistranscriptions, \
        return empty.
        """
    case .brand:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        BRAND NAME wrong. ASR splits the brand into phonetic chunks of how \
        it is pronounced.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Each must be \
        SUBSTANTIVELY different from the canonical -- NOT a suffix-strip, \
        NOT just a space. Example for "Kubernetes":
        kuber netties
        cube ernetes
        cooper nettys
        Example for "Postgres":
        post grass
        post gress
        post grease
        Example for "Tailwind":
        tail wind
        tail ind
        tale wynd

        If you cannot produce 3 distinct mistranscriptions, return empty.
        """
    case .general:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        REGULAR WORD wrong. ASR splits at word boundaries or swaps vowels \
        and consonants.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Example for "webhook":
        web hook
        web hooke
        wuh book
        Example for "async":
        a sync
        a sink
        ay sync
        Example for "middleware":
        middle ware
        middle wear
        midware

        If you cannot produce 3 distinct mistranscriptions, return empty.
        """
    }
  }

  // MARK: - Degeneration filter (Phase 1 #637)

  /// Drops AFM responses that degenerate into echoes of the canonical word.
  /// Filter rules:
  /// - Drop empty entries (after trim).
  /// - Drop entries equal to canonical (case + whitespace insensitive).
  /// - Drop near-duplicates of canonical (`WordCorrector.score >= 0.95`).
  /// - De-dupe (case + whitespace insensitive).
  ///
  /// Returns the surviving aliases. Callers should treat an empty result
  /// from a non-empty input as model degeneration (return nil).
  ///
  /// Threshold 0.95 sits inside bible §17 R1 tunable range (0.85-0.99).
  static func filterDegeneratedAliases(_ raw: [String], canonical: String) -> [String] {
    let canonicalNormalized = canonical.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalNormalized.isEmpty else { return [] }
    var seen = Set<String>()
    var kept: [String] = []
    let scorer = WordCorrector()
    for alias in raw {
      let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let normalized = trimmed.lowercased()
      if normalized == canonicalNormalized { continue }
      if seen.contains(normalized) { continue }
      if scorer.score(trimmed, against: canonical) >= 0.95 { continue }
      seen.insert(normalized)
      kept.append(trimmed)
    }
    return kept
  }

  /// Parse plain-string AFM output into an array of alias candidates.
  /// Accepts numbered, dashed, or newline-separated outputs. Strips leading
  /// numbering, surrounding quotes (straight or curly), bracket artifacts,
  /// and whitespace. Drops obvious meta-commentary lines (model often
  /// produces "Note:", "Example for X:", "If you cannot..." etc.) and
  /// markdown code-fence delimiter lines (the model sometimes wraps its
  /// list in ```plaintext ... ```, #1763).
  /// Used by the plain-string alias-generation path (mirroring the polish
  /// path's plain-string + post-filter pattern).
  static func parsePlainStringAliases(_ raw: String) -> [String] {
    var aliases: [String] = []
    let metaTokens = [
      "note:", "example for", "example:", "if you", "the input", "forbidden",
      "mistranscription", "cannot produce", "phonetic", "speech-to-text",
      "asr", "i have ", "i did not", "no mistranscript", "no aliases",
      "return empty", "explanation",
    ]
    // A line that starts with 3+ of the same fence character (backtick or
    // tilde, the two CommonMark fence delimiters) — a real alias never
    // starts this way, so the rest of the line (any info string, or none)
    // is accepted rather than allowlisted. Compiled once per call.
    let fenceRegex = try? NSRegularExpression(
      pattern: #"^(?:`{3,}|~{3,}).*$"#
    )
    // List/blockquote container markers: all three CommonMark bullet
    // characters (-, *, +), ordered markers, and blockquote '>'. Compiled
    // once per call, applied repeatedly below (they nest arbitrarily, e.g.
    // "- > text" or "\"- text\"", so a single fixed-order pass of
    // bracket/list/quote stripping can leave an inner wrapper behind —
    // GitHub cloud review, PR #1765 r2/r3). Bullet markers require trailing
    // whitespace or end-of-line so the fixed-point loop below cannot
    // repeatedly eat real content like "+44" or "--alias" one character at
    // a time (Codex final sweep, PR #1765 r4). Ordered markers instead
    // require the following char be NOT a digit — AFM sometimes emits a
    // compact numbered item with no space ("1.kuber netties"), which must
    // still strip, while a decimal/version-shaped alias ("1.2") must not
    // have its leading "1." mistaken for a marker; `(?!\d)` also succeeds
    // at end-of-line, covering a marker-only line ("1.") with no separate
    // alternative needed (GitHub cloud review, PR #1765 r5/r6). Blockquote
    // '>' keeps optional whitespace since CommonMark permits ">text".
    let listPrefixRegex = try? NSRegularExpression(
      pattern: #"^(?:\d+[.)](?!\d)|[-*•+](?:\s+|$)|>\s*)"#
    )
    for line in raw.components(separatedBy: .newlines) {
      var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { continue }
      // Strip list/blockquote markers, brackets, and quotes to a fixed
      // point — any interleaving or nesting of these wrapper types (a
      // quoted bullet, a bulleted blockquote, brackets around a numbered
      // line) converges to the real inner content, not just one layer of
      // it. List-marker stripping runs FIRST in each pass, before comma/
      // period trimming ever gets a chance to eat a marker's own "."/")"
      // out from under it and leave an orphaned digit behind (GitHub cloud
      // review, PR #1765 r6) — comma/period trimming is deliberately
      // deferred to a single pass after the loop converges, below.
      var previous = ""
      while previous != s {
        previous = s
        if let listPrefixRegex {
          let range = NSRange(s.startIndex..., in: s)
          s = listPrefixRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        s = s.trimmingCharacters(
          in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if s.isEmpty { continue }
      // Comma/period trimming runs ONCE, after convergence, not inside the
      // loop — combining it with quote trimming let it strip a marker's own
      // "." out from under the list-marker regex before that regex ever saw
      // the whole marker (GitHub cloud review, PR #1765 r6).
      s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",."))
      s = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { continue }
      // Fence check runs AFTER wrapper convergence — a wrapped fence line
      // (numbered, bulleted, quoted, blockquoted, or any nesting of those)
      // does not match the bare-fence pattern until every wrapper is gone.
      if let fenceRegex,
        fenceRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
      {
        continue
      }
      // Drop meta-commentary by token match.
      let lower = s.lowercased()
      var isMeta = false
      for tok in metaTokens where lower.contains(tok) {
        isMeta = true
        break
      }
      if isMeta { continue }
      // Drop any line containing a colon (sentence/header/JSON-key guard).
      // Aliases are short tokens; a colon is a strong signal of meta text.
      if s.contains(":") { continue }
      // Drop very long lines (aliases are short).
      if s.count > 40 { continue }
      aliases.append(s)
    }
    return aliases
  }

  /// Deterministic classification by syntax. Returns nil when AFM should
  /// classify (proper-noun shapes and CamelCase compounds, where brand
  /// vs person vs domain vs general needs semantic judgment).
  /// Catches obvious all-caps acronyms (CRM, JSON, SQL, API) and obvious
  /// domains with digits/dots/symbols (S3, OAuth2, github.com, K8s,
  /// C++, C#, F#, R&D) and lowercase-start-with-uppercase patterns
  /// (gRPC, iOS).
  static func classifyByHeuristic(_ word: String) -> WordCategory? {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let hasUpper = trimmed.contains(where: { $0.isUppercase })
    let hasLower = trimmed.contains(where: { $0.isLowercase })
    let allLetters = trimmed.allSatisfy({ $0.isLetter })

    // All-letters all-uppercase (no lowercase, no digits, no punctuation,
    // no symbols of any kind) and 2-8 long -> acronym. CRM, JSON, SQL.
    if allLetters && hasUpper && !hasLower && trimmed.count >= 2 && trimmed.count <= 8 {
      return .acronym
    }

    // Anything containing a non-letter character (digit, dot, slash, dash,
    // underscore, plus, hash, ampersand, etc.) -> domain. Covers S3,
    // OAuth2, github.com, K8s, multi-word-handle, C++, C#, F#, R&D.
    if !allLetters {
      return .domain
    }

    // Pure letters at this point. Lowercase-first with internal uppercase
    // -> domain (gRPC, iOS).
    if let first = trimmed.first, first.isLowercase, hasUpper {
      return .domain
    }

    // CamelCase starting uppercase, all-lowercase, or capitalized first +
    // lowercase rest: ambiguous between person, brand, general, even
    // domain (WebSocket vs Kubernetes vs DigitalOcean). Let AFM decide.
    return nil
  }

  /// Pool aliases from multiple AFM calls, preserving order, deduplicating
  /// by normalized lowercase form. Returns up to `max` unique aliases.
  static func dedupePool(_ lists: [[String]], max: Int) -> [String] {
    var seen = Set<String>()
    var pooled: [String] = []
    for list in lists {
      for s in list {
        let key =
          s
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if key.isEmpty { continue }
        if seen.contains(key) { continue }
        seen.insert(key)
        pooled.append(s)
        if pooled.count >= max { return pooled }
      }
    }
    return pooled
  }

  // MARK: - Guided generation with @Generable (full Xcode toolchain)

  #if canImport(FoundationModels) && hasAttribute(Generable)
    @Generable
    @available(macOS 26.0, *)
    struct ClassificationResult {
      @Guide(description: "One of: acronym, domain, person, brand, general")
      var category: String
    }

    @Generable
    @available(macOS 26.0, *)
    struct AliasesResult {
      @Guide(
        description:
          "3 to 5 distinct phonetic mistranscriptions of the input. Each must differ from the input."
      )
      var suggestedAliases: [String]
    }

    @available(macOS 26, *)
    private func runRawSuggestion(
      for word: String,
      knownCategory: WordCategory? = nil
    ) async throws -> (category: WordCategory, aliases: [String]) {
      // A caller that already knows the category (contacts import pins .person)
      // skips both the heuristic and the AFM classifier call. Otherwise:
      // heuristic classification first — skips one AFM call for clear-cut cases
      // (all-caps short = acronym; mixed-case or digits/dots = domain). The AFM
      // classifier has been observed to misclassify obvious acronyms like CRM,
      // JSON, SQL, API as brand/general/domain.
      let category: WordCategory
      if let knownCategory {
        category = knownCategory
      } else if let heuristic = Self.classifyByHeuristic(word) {
        category = heuristic
      } else {
        let classificationSession = LanguageModelSession(
          model: SystemLanguageModel.default,
          instructions: Self.classificationInstructions
        )
        let classificationResponse = try await classificationSession.respond(
          to: "Word: \(word)",
          generating: ClassificationResult.self
        )
        category =
          WordCategory(rawValue: classificationResponse.category.lowercased()) ?? .general
      }

      // Multi-call pooling: 3 sequential AFM calls with the same prompt,
      // dedup by normalized form, take up to 8 unique outputs. AFM
      // single-call mode-collapses on hard inputs; pooling rescues those.
      // 3 calls was the empirical sweet spot; 4 calls regressed brand.
      let aliasUserPrompt = """
        Word: \(word)
        Forbidden: "\(word)", "\(word.lowercased())".
        """
      var pooled: [[String]] = []
      for _ in 0..<3 {
        let aliases = await Self.singleAliasCall(
          instructions: Self.aliasInstructions(for: category),
          prompt: aliasUserPrompt
        )
        pooled.append(aliases)
      }
      return (category, Self.dedupePool(pooled, max: 8))
    }

    @available(macOS 26, *)
    private static func singleAliasCall(
      instructions: String,
      prompt: String
    ) async -> [String] {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )
      do {
        let response = try await session.respond(
          to: prompt,
          options: GenerationOptions(maximumResponseTokens: 120)
        )
        return parsePlainStringAliases(response.content)
      } catch {
        return []
      }
    }

    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
      do {
        let raw = try await runRawSuggestion(for: word)
        let filtered = Self.filterDegeneratedAliases(raw.aliases, canonical: word)
        // Empty after filter (with non-empty raw) means AFM degenerated into self-echoes.
        // Treat as model failure so the UI can render "No suggestions available" instead
        // of zero or duplicate chips.
        // Phase 8 (#620) telemetry hook deferred — PostProcessing module cannot
        // import EnviousWisprServices per the dep-direction guard. Phase 8 proper
        // will inject a telemetry callback at the call site.
        guard !filtered.isEmpty else { return nil }
        return WordSuggestions(category: raw.category, suggestedAliases: filtered)
      } catch {
        return nil
      }
    }

  // MARK: - Dynamic schema fallback (CLT-only builds without macro plugin)

  #elseif canImport(FoundationModels)
    @available(macOS 26, *)
    private func runRawSuggestion(
      for word: String,
      knownCategory: WordCategory? = nil
    ) async throws -> (category: WordCategory, aliases: [String]) {
      // Step 1 — classification. A caller that already knows the category
      // (contacts import pins .person) skips it; otherwise heuristic first, AFM
      // as fallback.
      let category: WordCategory
      if let knownCategory {
        category = knownCategory
      } else if let heuristic = Self.classifyByHeuristic(word) {
        category = heuristic
      } else {
        let classificationSession = LanguageModelSession(
          model: SystemLanguageModel.default,
          instructions: Self.classificationInstructions
        )
        let classificationDynamic = DynamicGenerationSchema(
          name: "Classification",
          properties: [
            DynamicGenerationSchema.Property(
              name: "category",
              schema: DynamicGenerationSchema(type: String.self)
            )
          ]
        )
        let classificationSchema = try GenerationSchema(
          root: classificationDynamic, dependencies: []
        )
        let classificationResponse = try await classificationSession.respond(
          to: "Word: \(word)",
          schema: classificationSchema
        )
        let categoryStr = try classificationResponse.content.value(
          String.self, forProperty: "category"
        )
        category = WordCategory(rawValue: categoryStr.lowercased()) ?? .general
      }

      // Step 2 — alias generation (plain-string output, 3-call pooling).
      let aliasUserPrompt = """
        Word: \(word)
        Forbidden: "\(word)", "\(word.lowercased())".
        """
      var pooled: [[String]] = []
      for _ in 0..<3 {
        let aliases = await Self.singleAliasCallDynamic(
          instructions: Self.aliasInstructions(for: category),
          prompt: aliasUserPrompt
        )
        pooled.append(aliases)
      }
      return (category, Self.dedupePool(pooled, max: 8))
    }

    @available(macOS 26, *)
    private static func singleAliasCallDynamic(
      instructions: String,
      prompt: String
    ) async -> [String] {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )
      do {
        let response = try await session.respond(
          to: prompt,
          options: GenerationOptions(maximumResponseTokens: 120)
        )
        return parsePlainStringAliases(response.content)
      } catch {
        return []
      }
    }

    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
      do {
        let raw = try await runRawSuggestion(for: word)
        let filtered = Self.filterDegeneratedAliases(raw.aliases, canonical: word)
        guard !filtered.isEmpty else { return nil }
        return WordSuggestions(category: raw.category, suggestedAliases: filtered)
      } catch {
        return nil
      }
    }
  #endif
}

// MARK: - AliasSuggesting (contacts-import enrichment, #636 follow-up)

extension WordSuggestionService: AliasSuggesting {
  /// On-device alias generation for an already-classified word. Mirrors
  /// `suggest(for:)`'s availability gate, 5-second timeout, and degeneration
  /// filter, but skips classification (the caller pins the category) and returns
  /// the bare alias list. nil when unavailable, timed out, or the model
  /// degenerated to self-echoes. `priority` has no default (#1701) — every
  /// caller states its own scheduling intent explicitly.
  package func suggestAliases(
    for word: String, category: WordCategory, priority: AliasSuggestionPriority
  ) async -> [String]? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *),
        case .available = SystemLanguageModel.default.availability
      else { return nil }
      return await withPermit(
        priority: priority, whenNotGranted: nil, deadlineSeconds: Self.suggestionDeadlineSeconds
      ) {
        do {
          let raw = try await self.runRawSuggestion(for: word, knownCategory: category)
          let filtered = Self.filterDegeneratedAliases(raw.aliases, canonical: word)
          return filtered.isEmpty ? nil : filtered
        } catch {
          return nil
        }
      }
    #else
      return nil
    #endif
  }

  /// Delegates to `suggest(for:priority:)` directly, which already owns
  /// availability, timeout, classification, filtering, and permit handling
  /// — never a second `withPermit` wrapper here, or one logical request
  /// would attempt to acquire the shared permit twice (Phase 3 review
  /// finding A, #1701).
  package func suggestAliases(
    for word: String, priority: AliasSuggestionPriority
  ) async -> [String]? {
    let suggestions = await suggest(for: word, priority: priority)
    return suggestions?.suggestedAliases
  }
}

public struct WordSuggestions: Sendable {
  public let category: WordCategory
  public let suggestedAliases: [String]
}

/// Benchmark-only carrier for the alias-eval harness (#637). Returned by
/// `WordSuggestionService.benchmarkSuggest(for:disableTimeout:)`. NEVER
/// persisted, NEVER consumed by production code.
public struct WordSuggestionBenchmarkRecord: Sendable {
  public let category: WordCategory
  public let rawAliases: [String]
  public let filteredAliases: [String]
  public let timedOut: Bool
  public let errorDescription: String?
  public let latencyMs: Int

  public init(
    category: WordCategory,
    rawAliases: [String],
    filteredAliases: [String],
    timedOut: Bool,
    errorDescription: String?,
    latencyMs: Int
  ) {
    self.category = category
    self.rawAliases = rawAliases
    self.filteredAliases = filteredAliases
    self.timedOut = timedOut
    self.errorDescription = errorDescription
    self.latencyMs = latencyMs
  }
}
