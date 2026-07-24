import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 1 (#637) — pins the AFM alias degeneration filter contract.
/// Bible §7.
@Suite("WordSuggestionService — AFM alias degeneration filter")
struct WordSuggestionServiceTests {

  @Test("4× exact self-echo filtered to empty")
  func exactSelfEchoFilteredToEmpty() {
    let raw = ["gemini", "gemini", "gemini", "gemini"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "gemini")
    #expect(kept.isEmpty, "All exact self-echoes must be filtered")
  }

  @Test("Mixed-case self-echo filtered")
  func mixedCaseSelfEchoFiltered() {
    let raw = ["Gemini", "GEMINI", "gemini", "GeMiNi"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept.isEmpty, "Case variants of canonical must be filtered")
  }

  @Test("Whitespace variants of canonical filtered")
  func whitespaceVariantsFiltered() {
    let raw = [" gemini ", "  gemini", "gemini   "]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "gemini")
    #expect(kept.isEmpty, "Whitespace-padded canonicals must be filtered")
  }

  @Test("De-dupe collapses repeats (case + whitespace insensitive)")
  func deDupeCollapsesRepeats() {
    let raw = ["Jamini", "jamini", " JAMINI ", "Jeh meh nee"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept.count == 2, "Duplicates collapse to one (Jamini); Jeh meh nee is unique")
    #expect(
      kept.contains(where: { $0.lowercased().trimmingCharacters(in: .whitespaces) == "jamini" }))
    #expect(kept.contains("Jeh meh nee"))
  }

  @Test("Empty entries dropped")
  func emptyEntriesDropped() {
    let raw = ["", "  ", "jamini", "\t\n"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept == ["jamini"])
  }

  @Test("Valid aliases pass through (Kubernetes regression check)")
  func validAliasesPassThrough() {
    let raw = ["kuber netties", "cube ernetes", "cooper nettys"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Kubernetes")
    #expect(kept.count == 3, "Phonetic variants should survive the filter")
    #expect(kept == raw)
  }

  @Test("Empty input returns empty")
  func emptyInputReturnsEmpty() {
    let kept = WordSuggestionService.filterDegeneratedAliases([], canonical: "anything")
    #expect(kept.isEmpty)
  }

  @Test("Empty canonical returns empty (degenerate input guard)")
  func emptyCanonicalGuardsAgainstAcceptingAll() {
    let kept = WordSuggestionService.filterDegeneratedAliases(["a", "b"], canonical: "")
    #expect(
      kept.isEmpty, "Empty canonical means we cannot meaningfully evaluate self-echo; return empty")
  }

  @Test("Single-character canonical with valid aliases")
  func singleCharCanonical() {
    // "X" canonical with phonetic alternates
    let raw = ["ecks", "eks"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "X")
    // #881 TO-5: both phonetic aliases score far below the 0.95 near-duplicate
    // gate and neither equals "x", so both must survive in input order. The old
    // `kept.count >= 0` was always true — it could not catch a score-gate
    // inversion or threshold drift that silently dropped valid aliases (the
    // exact Kubernetes-class degeneration the suite exists to prevent).
    #expect(kept == ["ecks", "eks"])
  }
}

/// Pins the plain-string alias parser added in the 2026-05-06 ship.
/// The parser turns AFM's free-text response into a list of alias candidates.
@Suite("WordSuggestionService — plain-string alias parser")
struct WordSuggestionServiceParserTests {

  @Test("Newline-separated lines parse")
  func newlineSeparated() {
    let raw = "okay are\noh K R\nokayer"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R", "okayer"])
  }

  @Test("Numbered list strips numbering")
  func numberedListStripsNumbering() {
    let raw = "1. par vati\n2. poor vati\n3) pavathi"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["par vati", "poor vati", "pavathi"])
  }

  @Test("Bulleted list strips bullets")
  func bulletsStripped() {
    let raw = "- web hook\n* a sync\n• middle ware"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["web hook", "a sync", "middle ware"])
  }

  @Test("Surrounding quotes (straight and curly) stripped")
  func quotesStripped() {
    let raw = "\"ee tee ay\"\n'et a'\n\u{201C}eh tay\u{201D}\n\u{2018}ee t ay\u{2019}"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["ee tee ay", "et a", "eh tay", "ee t ay"])
  }

  @Test("Bracket artifacts stripped")
  func bracketsStripped() {
    let raw = "[okay are]\n(oh K R)\nokayer"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R", "okayer"])
  }

  @Test("Trailing comma stripped (JSON-array bleed)")
  func trailingCommaStripped() {
    let raw = "okay are,\noh K R,\nokayer"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R", "okayer"])
  }

  @Test("Meta-commentary line with 'Note:' is dropped")
  func metaNoteDropped() {
    let raw =
      "Sourabh\nSorab\nSarab\nNote: I have excluded Saurabh as it is forbidden."
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["Sourabh", "Sorab", "Sarab"])
  }

  @Test("Meta-commentary 'Example for X:' is dropped")
  func metaExampleDropped() {
    let raw = "Example for \"Parvati\":\npar vati\npoor vati"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["par vati", "poor vati"])
  }

  @Test("Sentences containing 'If you' or 'phonetic' dropped")
  func metaPhraseDropped() {
    let raw =
      "okay are\noh K R\nIf you cannot produce 3 mistranscriptions, return empty.\nPhonetic mishears only."
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Lines with a colon are dropped (sentence/header guard)")
  func colonLinesDropped() {
    let raw = "okay are\nNote things: bla\noh K R"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Long lines (>40 chars) dropped")
  func longLinesDropped() {
    let longSentence = String(repeating: "x", count: 50)
    let raw = "okay are\n\(longSentence)\noh K R"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Empty lines and whitespace-only lines dropped")
  func emptyLinesDropped() {
    let raw = "\n\nokay are\n   \n\noh K R\n\n"
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["okay are", "oh K R"])
  }

  @Test("Combined real-world: numbering + quotes + meta + bullets")
  func combinedRealWorld() {
    let raw = """
      1. "kuber netties"
      2. "cube ernetes"
      - cooper nettys
      Note: these are phonetic mistranscriptions.
      """
    let parsed = WordSuggestionService.parsePlainStringAliases(raw)
    #expect(parsed == ["kuber netties", "cube ernetes", "cooper nettys"])
  }

  @Test("Empty input returns empty")
  func emptyInputReturnsEmpty() {
    #expect(WordSuggestionService.parsePlainStringAliases("").isEmpty)
    #expect(WordSuggestionService.parsePlainStringAliases("   ").isEmpty)
    #expect(WordSuggestionService.parsePlainStringAliases("\n\n\n").isEmpty)
  }

  @Test("Fence-only lines are dropped without stripping legitimate backticks or tildes")
  func fenceOnlyLinesDropped() {
    let raw = [
      "```plaintext",
      "```PlainText",
      "``` c#",
      "```text/plain",
      "```plain text",
      "```",
      "````",
      "`````swift",
      "~~~plaintext",
      "~~~ plain text",
      "~~~",
      "kuber ``` netties",
      "`inline alias`",
      "``double inline alias``",
      "~ish sound",
    ].joined(separator: "\n")

    let parsed = WordSuggestionService.parsePlainStringAliases(raw)

    #expect(
      parsed == [
        "kuber ``` netties",
        "`inline alias`",
        "``double inline alias``",
        "~ish sound",
      ])
  }

  @Test("Kubernetes response strips Markdown fences (#1763 regression)")
  func kubernetesResponseStripsMarkdownFences() {
    let raw = [
      "kuber netties",
      "cube ernetes",
      "cooper nettys",
      "```plaintext",
      "```",
    ].joined(separator: "\n")

    let parsed = WordSuggestionService.parsePlainStringAliases(raw)

    #expect(parsed == ["kuber netties", "cube ernetes", "cooper nettys"])
  }

  @Test("Fence lines wrapped in a numbered, bulleted, or quoted marker are still dropped")
  func fenceLinesWithListMarkersOrQuotesDropped() {
    let raw = [
      "1. kuber netties",
      "2. cube ernetes",
      "3. cooper nettys",
      "4. ```plaintext",
      "- ```",
      "\"```\"",
    ].joined(separator: "\n")

    let parsed = WordSuggestionService.parsePlainStringAliases(raw)

    #expect(parsed == ["kuber netties", "cube ernetes", "cooper nettys"])
  }
}

/// Pins the multi-call dedupe pool helper.
@Suite("WordSuggestionService — dedupePool")
struct WordSuggestionServiceDedupePoolTests {

  @Test("Single list passes through, deduped")
  func singleListDedupes() {
    let pool = WordSuggestionService.dedupePool([["a", "b", "a", "c"]], max: 10)
    #expect(pool == ["a", "b", "c"])
  }

  @Test("Multiple lists pooled with order-preserving dedup")
  func multipleListsOrderPreserved() {
    let pool = WordSuggestionService.dedupePool(
      [["alpha", "beta"], ["beta", "gamma", "delta"]],
      max: 10
    )
    #expect(pool == ["alpha", "beta", "gamma", "delta"])
  }

  @Test("Dedup is case-insensitive on lowercase + trim")
  func dedupCaseInsensitive() {
    let pool = WordSuggestionService.dedupePool(
      [["Hello", "WORLD"], [" hello ", "world", "Foo"]],
      max: 10
    )
    #expect(pool == ["Hello", "WORLD", "Foo"])
  }

  @Test("Max cap honored")
  func maxCapHonored() {
    let pool = WordSuggestionService.dedupePool(
      [["a", "b", "c"], ["d", "e", "f"]],
      max: 4
    )
    #expect(pool == ["a", "b", "c", "d"])
  }

  @Test("Empty lists handled")
  func emptyListsHandled() {
    #expect(WordSuggestionService.dedupePool([], max: 5).isEmpty)
    #expect(WordSuggestionService.dedupePool([[]], max: 5).isEmpty)
    #expect(WordSuggestionService.dedupePool([[], [], []], max: 5).isEmpty)
  }

  @Test("Empty strings dropped during pool")
  func emptyStringsDropped() {
    let pool = WordSuggestionService.dedupePool(
      [["", "a", "  "], ["b", "", "\t"]],
      max: 10
    )
    #expect(pool == ["a", "b"])
  }
}

/// Pins the deterministic syntactic classifier added in the 2026-05-06 ship.
@Suite("WordSuggestionService — heuristic classifier")
struct WordSuggestionServiceHeuristicClassifierTests {

  @Test("All-caps short word -> acronym")
  func allCapsShortIsAcronym() {
    #expect(WordSuggestionService.classifyByHeuristic("OKR") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("PR") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("CRM") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("HIPAA") == .acronym)
    #expect(WordSuggestionService.classifyByHeuristic("URL") == .acronym)
  }

  @Test("All-caps too-long word is NOT acronym")
  func allCapsTooLongIsNotAcronym() {
    // 9+ letters falls outside the 2-8 range
    #expect(WordSuggestionService.classifyByHeuristic("LONGACRONYM") != .acronym)
  }

  @Test("Single character is NOT acronym (too short)")
  func singleCharIsNotAcronym() {
    #expect(WordSuggestionService.classifyByHeuristic("A") != .acronym)
  }

  @Test("Has digit -> domain")
  func hasDigitIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("S3") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("OAuth2") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("Web3") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("K8s") == .domain)
  }

  @Test("Has dot -> domain")
  func hasDotIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("github.com") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("npm.io") == .domain)
  }

  @Test("Lowercase-first with uppercase -> domain")
  func lowercaseFirstWithUpperIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("gRPC") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("iOS") == .domain)
  }

  @Test("Capital-first all-lowercase rest -> nil (AFM decides)")
  func properNounShapeIsNil() {
    // Saurabh, Kubernetes, Postgres, Slack — proper nouns of person/brand kind
    #expect(WordSuggestionService.classifyByHeuristic("Saurabh") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("Kubernetes") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("Postgres") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("Slack") == nil)
  }

  @Test("CamelCase with multiple capitals -> nil (AFM decides)")
  func camelCaseIsNil() {
    // WebSocket = domain in corpus, DigitalOcean = brand. Heuristic can't
    // tell, so it returns nil and lets AFM classify.
    #expect(WordSuggestionService.classifyByHeuristic("WebSocket") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("DigitalOcean") == nil)
  }

  @Test("All-lowercase -> nil (AFM decides)")
  func allLowercaseIsNil() {
    #expect(WordSuggestionService.classifyByHeuristic("webhook") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("async") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("middleware") == nil)
  }

  @Test("Has slash, colon, dash, underscore -> domain")
  func hasOtherSymbolIsDomain() {
    #expect(WordSuggestionService.classifyByHeuristic("foo/bar") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("user:pass") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("multi-word") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("snake_case") == .domain)
  }

  @Test("Has plus, hash, ampersand or other punctuation -> domain (NOT acronym)")
  func hasUncommonPunctuationIsDomain() {
    // Codex review 2026-05-06: original symbol blocklist missed +, #, &.
    // C++ / C# / F# / R&D would have been classified as acronym which is
    // wrong by the prompt rules. These must route to domain.
    #expect(WordSuggestionService.classifyByHeuristic("C++") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("C#") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("F#") == .domain)
    #expect(WordSuggestionService.classifyByHeuristic("R&D") == .domain)
  }

  @Test("Empty string -> nil")
  func emptyIsNil() {
    #expect(WordSuggestionService.classifyByHeuristic("") == nil)
    #expect(WordSuggestionService.classifyByHeuristic("   ") == nil)
  }
}

// MARK: - Permit queue test helpers (#1701)

/// Deterministically waits for a waiter to actually register on the queue —
/// polls real actor state via `Task.yield()`, bounded by a deadline-fallback
/// `withThrowingTimeout` (`swift-patterns.md` RULE:
/// tests-no-unconditional-continuation-await — an unbounded wait hangs CI on
/// a genuine regression instead of failing; mirrors
/// `LLMTelemetrySinkLiveTests`'s deadline-fallback shape, Grounded Review
/// Chunk 1 finding).
private func waitForWaiterCount(
  _ queue: AliasSuggestionPermitQueue, toEqual expected: Int, timeoutSeconds: Double = 5
) async throws {
  try await withThrowingTimeout(seconds: timeoutSeconds) {
    while await queue.waiterCountForTesting != expected {
      try Task.checkCancellation()
      await Task.yield()
    }
  }
}

/// Test-only rendezvous: `wait()` parks until `resume()` is called elsewhere.
/// `waitUntilParked()` blocks until a concurrently-running `wait()` call has
/// genuinely parked, giving tests a happens-before point to act from — e.g.
/// cancelling a task only once it is provably suspended inside the hook
/// under test, never racing real Swift Concurrency scheduling. Both are
/// deadline-bounded (`withThrowingTimeout`, never an unconditional wait —
/// same rule and finding as `waitForWaiterCount` above).
private actor ResumeGate {
  private(set) var parked = false
  private var released = false

  func markParked() { parked = true }
  func resume() { released = true }

  func wait(timeoutSeconds: Double = 5) async throws {
    markParked()
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.released == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }

  func waitUntilParked(timeoutSeconds: Double = 5) async throws {
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.parked == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }
}

/// Records call order from concurrent tasks without a data race.
private actor OrderLog {
  private(set) var entries: [String] = []
  func record(_ entry: String) { entries.append(entry) }
}

/// Counts operation invocations without a data race.
private actor CallCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

/// Simulates a FoundationModels call that ignores cancellation entirely
/// (Phase 3 review finding A, #1701): `waitIgnoringCancellation()` never
/// calls `Task.checkCancellation()`, unlike every other gate in this file —
/// that is the whole point, since a genuinely cooperating wait would not
/// reproduce the hang `withDeadline` exists to survive.
private actor NonCooperativeGate {
  private(set) var parked = false
  private var released = false

  func markParked() { parked = true }
  func release() { released = true }

  func waitIgnoringCancellation() async {
    markParked()
    while !released {
      await Task.yield()
    }
  }

  func waitUntilParked(timeoutSeconds: Double = 5) async throws {
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.parked == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }
}

/// Pins the explicit permit queue behind `WordSuggestionService.suggest(for:)`
/// and `.suggestAliases(for:category:)` (#1701). Swift actors are reentrant
/// across a suspension point, so a naive "await inside an actor" would not
/// actually serialize two concurrent callers — these tests exercise the
/// actual continuation-based queue, not a simulation of it. Every test drives
/// `AliasSuggestionPermitQueue` / `WordSuggestionService.withPermit` directly
/// via `@testable import`: the public `suggest`/`suggestAliases` entry points
/// gate on live FoundationModels/macOS 26 runtime availability, which is
/// unavailable-or-unreliable in a test environment (this file has never
/// exercised those two methods end-to-end, for the same reason — see the
/// suites above, which only ever test the pure static helpers). The queue
/// mechanics under test here are identical regardless of which entry point
/// calls them.
@Suite("WordSuggestionService — permit queue (#1701)")
struct WordSuggestionServicePermitQueueTests {

  @Test(
    "An interactive arrival is granted the next permit ahead of already-queued background waiters")
  func interactiveJumpsBackgroundQueue() async throws {
    let queue = AliasSuggestionPermitQueue()
    let holderGranted = await queue.acquire(id: UUID(), priority: .interactive)
    #expect(holderGranted)

    let bg1: Task<Bool, Never> = Task { await queue.acquire(id: UUID(), priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 1)
    let bg2: Task<Bool, Never> = Task { await queue.acquire(id: UUID(), priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 2)
    let interactive: Task<Bool, Never> = Task {
      await queue.acquire(id: UUID(), priority: .interactive)
    }
    try await waitForWaiterCount(queue, toEqual: 3)

    await queue.release()  // holder done — interactive must jump ahead of bg1/bg2
    #expect(await interactive.value)
    #expect(await queue.waiterCountForTesting == 2)  // bg1, bg2 still waiting

    await queue.release()  // interactive done — bg1 (FIFO-first) granted next
    #expect(await bg1.value)
    #expect(await queue.waiterCountForTesting == 1)

    await queue.release()  // bg1 done — bg2 granted last
    #expect(await bg2.value)
    #expect(await queue.waiterCountForTesting == 0)

    await queue.release()  // bg2 done — no waiters remain
  }

  @Test("Two background requests are served FIFO")
  func backgroundRequestsAreFIFO() async throws {
    let queue = AliasSuggestionPermitQueue()
    let holderGranted = await queue.acquire(id: UUID(), priority: .interactive)
    #expect(holderGranted)

    let first: Task<Bool, Never> = Task { await queue.acquire(id: UUID(), priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 1)
    let second: Task<Bool, Never> = Task { await queue.acquire(id: UUID(), priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 2)

    await queue.release()
    #expect(await first.value)
    #expect(await queue.waiterCountForTesting == 1)  // second must still be waiting

    await queue.release()
    #expect(await second.value)
  }

  @Test("A request cancelled while queued performs zero model operations")
  func cancelledWhileQueuedNeverRunsOperation() async throws {
    let queue = AliasSuggestionPermitQueue()
    let holderGranted = await queue.acquire(id: UUID(), priority: .interactive)
    #expect(holderGranted)

    let waiting: Task<Bool, Never> = Task { await queue.acquire(id: UUID(), priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 1)

    waiting.cancel()
    #expect(await waiting.value == false)
    #expect(await queue.waiterCountForTesting == 0)  // removed, not left dangling

    await queue.release()  // holder done — nobody left to grant
    #expect(await queue.waiterCountForTesting == 0)
  }

  @Test(
    "release() skips a queued waiter whose latch is cancelled but not yet removed, granting the next live waiter directly — exactly-one continuation resumption throughout (Grounded Review Chunk 1 round 3 finding)"
  )
  func releaseSkipsLatchCancelledWaiterBeforeRemovalArrives() async throws {
    let queue = AliasSuggestionPermitQueue()
    let holderGranted = await queue.acquire(id: UUID(), priority: .interactive)
    #expect(holderGranted)

    let firstID = UUID()
    let first: Task<Bool, Never> = Task { await queue.acquire(id: firstID, priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 1)
    let second: Task<Bool, Never> = Task { await queue.acquire(id: UUID(), priority: .background) }
    try await waitForWaiterCount(queue, toEqual: 2)

    // Simulate the exact race release()'s doc comment describes: the latch
    // is cancelled, but the async `cancelWaiting` removal message has NOT
    // yet reached the actor — `first` is still physically present in
    // `waiters` when release() runs below.
    await queue.cancelLatchWithoutRemovingForTesting(id: firstID)

    await queue.release()  // holder done — must skip the cancelled `first` and grant `second` directly
    #expect(await second.value)
    #expect(await first.value == false)
    // release()'s skip-loop physically removed `first` too — nothing left
    // for the (now redundant, since it already ran here) real cancellation
    // path to find later; no double-resume, no leaked entry.
    #expect(await queue.waiterCountForTesting == 0)
  }

  @Test(
    "A request cancelled after grant but before inference starts performs zero model operations")
  func cancelledInGapBetweenGrantAndInferencePerformsZeroModelCalls() async throws {
    let service = WordSuggestionService()
    let counter = CallCounter()
    let gate = ResumeGate()

    // Permit is free, so acquire() grants immediately; the operation is held
    // at the gate right after grant, before it can run — the exact window
    // this test proves is cancellation-safe.
    let waiting: Task<Bool, Never> = Task {
      await service.withPermit(
        priority: .interactive,
        whenNotGranted: false,
        deadlineSeconds: 30,
        afterGrantForTesting: { try? await gate.wait() }
      ) {
        await counter.increment()
        return true
      }
    }
    try await gate.waitUntilParked()  // provably suspended right after grant, before the isCancelled check

    waiting.cancel()
    await gate.resume()

    #expect(await waiting.value == false)
    #expect(await counter.count == 0)
  }

  @Test("A higher-priority arrival never preempts the in-flight permit holder")
  func inFlightHolderNeverPreempted() async throws {
    let queue = AliasSuggestionPermitQueue()
    let holderGranted = await queue.acquire(id: UUID(), priority: .background)
    #expect(holderGranted)

    let interactive: Task<Bool, Never> = Task {
      await queue.acquire(id: UUID(), priority: .interactive)
    }
    try await waitForWaiterCount(queue, toEqual: 1)
    // Nothing in the design can force the background holder to give up the
    // permit early — the interactive arrival can only queue.
    #expect(await queue.waiterCountForTesting == 1)

    await queue.release()  // only the holder's own explicit release grants it
    #expect(await interactive.value)
  }

  @Test(
    "A bulk-import (.background) arrival cannot preempt an in-flight Add-term (.interactive) request"
  )
  func bulkImportNeverPreemptsAddTerm() async throws {
    // The exact cross-producer acceptance test named in the plan (issue-1701
    // §6, `BulkImportEnrichmentCoordinator` row): `.background` stands in for
    // bulk import's real priority, `.interactive` for `CustomWordEditSheet`'s
    // real Add-term priority, driven through the SAME shared
    // `WordSuggestionService` instance both production callers actually use
    // — composing `inFlightHolderNeverPreempted` and
    // `sharedPermitAcrossEntryPoints` with the real producer framing, which
    // neither proves alone.
    let service = WordSuggestionService()
    let holdGate = ResumeGate()

    let addTerm: Task<Bool, Never> = Task {
      await service.withPermit(priority: .interactive, whenNotGranted: false, deadlineSeconds: 30) {
        try? await holdGate.wait()
        return true
      }
    }
    try await holdGate.waitUntilParked()  // Add-term now holds the one permit

    let bulk: Task<Bool, Never> = Task {
      await service.withPermit(priority: .background, whenNotGranted: false, deadlineSeconds: 30) {
        true
      }
    }
    try await waitForWaiterCount(service.permitQueue, toEqual: 1)
    // Nothing can force the in-flight Add-term holder to give up the permit
    // early — a bulk arrival can only queue, never interrupt.
    #expect(await service.permitQueue.waiterCountForTesting == 1)

    await holdGate.resume()
    #expect(await addTerm.value)  // Add-term finished normally, never interrupted
    #expect(await bulk.value)  // bulk granted only after Add-term released
  }

  @Test("Both production entry points serialize through one shared permit")
  func sharedPermitAcrossEntryPoints() async throws {
    let service = WordSuggestionService()
    let order = OrderLog()
    let holdGate = ResumeGate()

    let first: Task<Bool, Never> = Task {
      await service.withPermit(priority: .interactive, whenNotGranted: false, deadlineSeconds: 30) {
        try? await holdGate.wait()
        await order.record("first")
        return true
      }
    }
    try await holdGate.waitUntilParked()  // `first` now holds the one permit

    let second: Task<Bool, Never> = Task {
      await service.withPermit(priority: .background, whenNotGranted: false, deadlineSeconds: 30) {
        await order.record("second")
        return true
      }
    }
    // `second` genuinely had to queue behind `first` on `service.permitQueue`
    // — proof they share the exact same instance, not independent permits.
    try await waitForWaiterCount(service.permitQueue, toEqual: 1)

    await holdGate.resume()
    #expect(await first.value)
    #expect(await second.value)
    #expect(await order.entries == ["first", "second"])
  }

  #if DEBUG
    // `rawSuggestionOverrideForTesting` is `#if DEBUG`-gated end to end
    // (Grounded Review Chunk 1 round 2 finding) so the Release alias-eval
    // harness's `benchmarkSuggest` measurements never gain an added actor
    // hop; this test is gated the same way since it references that symbol.
    @Test(
      "benchmarkSuggest never touches the production permit queue, driven with a deterministic fake — no live model inference"
    )
    func benchmarkSuggestStaysOutsideQueue() async throws {
      let service = WordSuggestionService()
      // Deterministic fake, no live FoundationModels call — real Apple
      // Intelligence eligibility is environment-dependent (Grounded Review
      // Chunk 1 finding: the prior revision's assertion on the real model's
      // output was flaky by construction — it happened to pass on this
      // machine only because this machine has it enabled).
      await service.rawSuggestionOverrideForTesting.set { word in
        (category: .general, aliases: ["\(word)-alt-one", "\(word)-alt-two"])
      }
      let holdGate = ResumeGate()

      let holder: Task<Bool, Never> = Task {
        await service.withPermit(priority: .interactive, whenNotGranted: false, deadlineSeconds: 30)
        {
          try? await holdGate.wait()
          return true
        }
      }
      try await holdGate.waitUntilParked()  // production permit held and stays held

      // If `benchmarkSuggest` called `withPermit`/`permitQueue.acquire` like
      // a production entry point would, this call would deadlock until
      // `holdGate.resume()` below, which cannot run before this line does.
      let record = await service.benchmarkSuggest(for: "gemini")
      #expect(record.rawAliases == ["gemini-alt-one", "gemini-alt-two"])
      #expect(record.errorDescription == nil)
      #expect(record.timedOut == false)

      await holdGate.resume()
      #expect(await holder.value)
    }
  #endif

  @Test(
    "A request already cancelled before entering acquire() is granted no permit and leaves no queue state"
  )
  func cancelledBeforeRegistrationLeavesNoState() async throws {
    // Creating a Task and immediately calling .cancel() does NOT prove the
    // child hasn't started — it can run concurrently on another executor
    // thread (Grounded Review Chunk 1 round 2 finding). A gate makes this
    // deterministic instead: park BEFORE ever calling acquire(), cancel
    // while provably parked, then resume — acquire() is entered already
    // cancelled, which `withTaskCancellationHandler` guarantees invokes
    // `onCancel` before `operation` ever runs.
    let queue = AliasSuggestionPermitQueue()
    let gate = ResumeGate()
    let task: Task<Bool, Never> = Task {
      try? await gate.wait()
      return await queue.acquire(id: UUID(), priority: .interactive)
    }
    try await gate.waitUntilParked()
    task.cancel()
    await gate.resume()
    #expect(await task.value == false)
    #expect(await queue.waiterCountForTesting == 0)
  }

  @Test(
    "Repeated grant-then-cancel-while-parked-after-grant leaves no residual actor state (Grounded Review Chunk 1 finding)"
  )
  func repeatedGrantThenCancelInGapLeavesNoResidue() async throws {
    // Reproduces the exact shape of the leak Grounded Review found: a
    // request is granted immediately (permit free) and is THEN cancelled
    // while still parked in the post-grant hook, before its operation ever
    // runs — a real, repeatedly reachable path via Add-term's debounced
    // `.task(id:)` restarting on every keystroke. Cancelling only after the
    // task has already completed (the round-1 version of this test) proves
    // nothing: a completed task's cancellation handler is no longer active.
    // The `CancellationLatch` redesign scopes the cancellation signal to the
    // call stack instead of an actor-owned Set, so nothing should
    // accumulate across repeated cycles of this real shape.
    let service = WordSuggestionService()
    for _ in 0..<50 {
      let counter = CallCounter()
      let gate = ResumeGate()
      let waiting: Task<Bool, Never> = Task {
        await service.withPermit(
          priority: .interactive,
          whenNotGranted: false,
          deadlineSeconds: 30,
          afterGrantForTesting: { try? await gate.wait() }
        ) {
          await counter.increment()
          return true
        }
      }
      try await gate.waitUntilParked()  // permit granted; parked before the isCancelled check
      waiting.cancel()
      await gate.resume()
      #expect(await waiting.value == false)
      #expect(await counter.count == 0)
      #expect(await service.permitQueue.waiterCountForTesting == 0)
    }
  }

  @Test(
    "a model call that ignores cancellation cannot strand the permit past its deadline (Phase 3 review finding A)"
  )
  func nonCooperatingOperationDoesNotStrandThePermit() async throws {
    let service = WordSuggestionService()
    let gate = NonCooperativeGate()

    let first: Task<Bool, Never> = Task {
      await service.withPermit(
        priority: .interactive, whenNotGranted: false, deadlineSeconds: 0.05
      ) {
        await gate.waitIgnoringCancellation()
        return true
      }
    }
    try await gate.waitUntilParked()  // first operation genuinely started, ignoring cancellation

    let second: Task<Bool, Never> = Task {
      await service.withPermit(priority: .interactive, whenNotGranted: false, deadlineSeconds: 30) {
        true
      }
    }
    try await waitForWaiterCount(service.permitQueue, toEqual: 1)  // genuinely queued behind first

    // The key assertion is not elapsed-time precision — it is that the
    // second operation is granted and completes while the first is STILL
    // physically running (its gate is still closed here), proving the
    // logical permit was released at the deadline despite the
    // non-cooperating first caller.
    let secondResult = try await withThrowingTimeout(seconds: 5) { await second.value }
    #expect(secondResult, "the second request must be granted despite the first still running")

    let firstResult = await first.value
    #expect(firstResult == false, "the abandoned first caller receives whenNotGranted")

    await gate.release()  // clean teardown of the still-running abandoned operation
  }
}
