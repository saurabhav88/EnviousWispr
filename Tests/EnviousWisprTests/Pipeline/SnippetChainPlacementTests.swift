import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #628 — where the snippet step sits in the chain, and what a user without snippets pays.
///
/// Two classes, deliberately split.
///
/// The ORDER test is `.driftGuard`: it fails when we change our own code, which is the point.
/// The order is not arbitrary — every position in it was argued for in a different issue — and
/// nothing else in the codebase would notice if a future change reordered it.
///
/// The empty-store test is `.productOutcome`: it is the promise that shipping this feature
/// costs nothing to the user who never opens it. Premise P4 in the plan, and it is proved by
/// RUNNING the chain rather than by reading that the step is disabled — reaching a guard is not
/// reaching its branch.
// One class on the suite, as the inventory requires. `.productOutcome` rather than
// `.driftGuard`: the empty-store test is the load-bearing one — it is the promise that a user
// who never opens Snippets is unaffected — and the order freeze is the supporting detail.
@Suite("Snippet chain placement (#628)", .tags(.productOutcome))
struct SnippetChainPlacementTests {

  @MainActor
  private func makeSteps() -> LimbSteps {
    LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep())
  }

  @Test("The chain order is frozen, and snippet expansion is first")
  @MainActor
  func chainOrderIsFrozen() {
    let names = makeSteps().orderedChain.map(\.name)

    #expect(
      names == [
        "Snippet Expansion",
        "Word Correction",
        "Filler Removal",
        "Emoji Formatter",
        "Inverse Text Normalization",
        "English Spelling",
        "LLM Polish",
        "English Spelling (after polish)",
        "Emoji Restore",
      ])
  }

  /// The structural half. `orderedChain` only removes the drift risk if BOTH paths actually
  /// read it — a second literal array reintroduced in either file would compile, pass every
  /// behavioural test, and silently give recovery a different chain from live.
  ///
  /// Reading the source is the right instrument here: the question is "does a second list
  /// exist", and no runtime assertion can observe a list nobody called.
  @Test("Both chain callers read the single ordered authority")
  func bothCallersUseTheSingleAuthority() throws {
    for file in ["KernelFinalizationWiring.swift", "RecoveryTextProcessor.swift"] {
      // Walk UP to the package root rather than counting `..` hops. A hop count is a
      // measurement of where this test file currently sits, so moving the file silently
      // repoints the read at a path that does not exist — which is a FAILING test on correct
      // code, the direction that invites "fixing" a machine that was already right.
      var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      while !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("Package.swift").path)
      {
        let parent = root.deletingLastPathComponent()
        try #require(
          parent.path != root.path, "walked past the filesystem root looking for Package.swift")
        root = parent
      }
      let url = root.appendingPathComponent("Sources/EnviousWisprPipeline/\(file)")
      let source = try String(contentsOf: url, encoding: .utf8)

      #expect(source.contains("steps: steps.orderedChain"), "\(file) must use the shared chain")
      #expect(
        !source.contains("steps.wordCorrection, steps.fillerRemoval"),
        "\(file) has re-inlined a second chain array")
    }
  }

  /// P4. Run the SAME text through the chain with the snippet step present and absent, and
  /// require the outputs to be identical — not merely that the step reported itself disabled.
  @Test("An empty snippet store leaves the chain output byte-identical")
  @MainActor
  func emptyStoreChangesNothing() async throws {
    let steps = makeSteps()
    // Left at `.empty`, which is what a user who has never opened Snippets has.
    #expect(steps.snippetExpansion.isEnabled == false)

    let runner = TextProcessingRunner()
    let input = "backslash my email address, and the path is backslash users"

    let withStep = try await runner.run(
      rawText: input, evidence: .locked("en"), targetAppName: nil, steps: steps.orderedChain)
    let withoutStep = try await runner.run(
      rawText: input, evidence: .locked("en"), targetAppName: nil,
      steps: steps.orderedChain.filter { $0.name != "Snippet Expansion" })

    #expect(withStep.context.text == withoutStep.context.text)
    #expect(withStep.context.polishedText == withoutStep.context.polishedText)
    #expect(withStep.context.protectedExpansions.isEmpty)
    #expect(withStep.context.pipelineFellBackToRaw == withoutStep.context.pipelineFellBackToRaw)
  }

  /// The other half of P4: with a vocabulary loaded, the step transforms. Without this the
  /// test above passes against a step that can NEVER fire, which is a guard that is green
  /// because it is broken.
  ///
  /// Driven through `process` directly, NOT through the runner, and that is deliberate. Every
  /// step carries a wall-clock budget (`maxDuration`, 50 ms here), and the runner silently
  /// skips a step that exceeds it, keeping that step's input. Under a full parallel suite this
  /// machine can miss 50 ms of pure string work, so a chain-level assertion here would fail on
  /// correct code — which it did, once, at 56 seconds. The load-dependent assertion is the
  /// defect, not the budget: the question this test asks is what the STEP does, and the runner's
  /// timing is a different question with its own coverage.
  @Test("A loaded snippet store arms the step")
  @MainActor
  func loadedStoreArmsTheStep() async throws {
    let step = SnippetExpansionStep()
    step.snippetVocabulary = SnippetVocabulary(
      snippets: [Snippet(trigger: "my email address", expansion: "sam@example.com")],
      keyword: SnippetVocabulary.defaultKeyword,
      generation: 1)

    #expect(step.isEnabled)

    let context = TextProcessingContext(
      text: "email me at backslash my email address", language: "en")
    let result = try await step.process(context)

    #expect(result.protectedExpansions.count == 1)
    #expect(result.protectedExpansions.first?.expansion == "sam@example.com")
    // The chain carries the SENTINEL, not the address: the address must not reach polish.
    #expect(!result.text.contains("sam@example.com"))
    #expect(result.text.contains(try #require(result.protectedExpansions.first).sentinel))

    var resolved = result
    SnippetFinalizer.finalize(&resolved)
    #expect(resolved.text == "email me at sam@example.com")
  }

  // MARK: - The clipboard gate (#3018)

  /// Counts reads and hands back a fixed answer, so "did we touch the user's clipboard" is a
  /// number rather than an inference from a log line.
  @MainActor
  private final class ClipboardProbe {
    private(set) var reads = 0
    var text: String?
    init(text: String? = nil) { self.text = text }
    func read() -> String? {
      reads += 1
      return text
    }
  }

  private static let fixedInstant = Date(timeIntervalSince1970: 1_789_584_300)

  @MainActor
  private func step(
    probe: ClipboardProbe, now: Date = SnippetChainPlacementTests.fixedInstant
  ) -> SnippetExpansionStep {
    SnippetExpansionStep(
      expander: SnippetExpander(),
      now: { now },
      clipboardText: { probe.read() })
  }

  private func gateVocabulary() -> SnippetVocabulary {
    SnippetVocabulary(
      snippets: [
        Snippet(trigger: "my link", expansion: "see {{clipboard}}"),
        Snippet(trigger: "my sign off", expansion: "thanks, sam"),
      ],
      keyword: SnippetVocabulary.defaultKeyword,
      generation: 1)
  }

  /// The four rows the privacy promise rests on, asserted through the INJECTED reader rather than
  /// through the DEBUG log field: the pre-merge suite runs Release, where that field does not
  /// exist, so a log-reading test would silently stop checking the thing that matters most.
  ///
  /// A saved clipboard snippet that does not fire is the third row, and it is the one the first
  /// design of this step got wrong: it would have read the pasteboard on every dictation.
  @Test("The clipboard is read only when a snippet that uses it actually fires")
  @MainActor
  func theClipboardIsReadOnlyOnAFiringTake() async throws {
    // 1. Nothing matches.
    let noMatch = ClipboardProbe(text: "https://x.dev")
    let quiet = step(probe: noMatch)
    quiet.snippetVocabulary = gateVocabulary()
    let untouched = try await quiet.process(
      TextProcessingContext(text: "just an ordinary sentence", language: "en"))
    #expect(noMatch.reads == 0)
    #expect(untouched.protectedExpansions.isEmpty)

    // 2. A snippet fires, and it uses no fill-in.
    let literal = ClipboardProbe(text: "https://x.dev")
    let literalStep = step(probe: literal)
    literalStep.snippetVocabulary = gateVocabulary()
    let literalOut = try await literalStep.process(
      TextProcessingContext(text: "bye backslash my sign off", language: "en"))
    #expect(literal.reads == 0)
    #expect(literalOut.protectedExpansions.count == 1)
    #expect(literalOut.protectedExpansions.first?.expansion == "thanks, sam")

    // 3. A clipboard snippet is SAVED but a different snippet fires.
    let unfired = ClipboardProbe(text: "https://x.dev")
    let unfiredStep = step(probe: unfired)
    unfiredStep.snippetVocabulary = gateVocabulary()
    _ = try await unfiredStep.process(
      TextProcessingContext(text: "bye backslash my sign off", language: "en"))
    #expect(unfired.reads == 0)

    // 4. The clipboard snippet itself fires: read once, and once only.
    let fired = ClipboardProbe(text: "https://x.dev")
    let firedStep = step(probe: fired)
    firedStep.snippetVocabulary = gateVocabulary()
    let firedOut = try await firedStep.process(
      TextProcessingContext(text: "here you go backslash my link", language: "en"))
    #expect(fired.reads == 1)
    // Exactly ONE outcome is committed. The probe pass fired too, and its record must not survive.
    #expect(firedOut.protectedExpansions.count == 1)
    #expect(firedOut.protectedExpansions.first?.expansion == "see https://x.dev")
    #expect(firedOut.text.contains("https://x.dev") == false)
  }

  @Test("A clipboard holding no plain text pastes nothing, and is still read once")
  @MainActor
  func anEmptyClipboardPastesNothing() async throws {
    let probe = ClipboardProbe(text: nil)
    let subject = step(probe: probe)
    subject.snippetVocabulary = gateVocabulary()

    let out = try await subject.process(
      TextProcessingContext(text: "here you go backslash my link", language: "en"))

    #expect(probe.reads == 1)
    #expect(out.protectedExpansions.first?.expansion == "see ")
  }

  /// The step's own job here is to carry ITS instant through to the delivered text. What that
  /// instant LOOKS like is pinned by `SnippetPlaceholderTests` against written-out literals, so
  /// this case uses the Core resolver as its oracle and asserts the two answers differ for two
  /// different injected instants — which is what fails if the step reads the wall clock instead.
  @Test("The injected instant reaches the delivered text")
  @MainActor
  func theInjectedInstantReachesTheText() async throws {
    let probe = ClipboardProbe()
    let subject = step(probe: probe)
    subject.snippetVocabulary = SnippetVocabulary(
      snippets: [Snippet(trigger: "my stamp", expansion: "filed {{date}}")],
      keyword: SnippetVocabulary.defaultKeyword,
      generation: 1)

    let out = try await subject.process(
      TextProcessingContext(text: "note this backslash my stamp please", language: "en"))

    let expected = SnippetPlaceholder.resolve(
      "filed {{date}}",
      using: SnippetDynamicValues(
        now: Self.fixedInstant, locale: .current, timeZone: .current, clipboard: nil))
    #expect(out.protectedExpansions.first?.expansion == expected)

    let aYearLater = SnippetPlaceholder.resolve(
      "filed {{date}}",
      using: SnippetDynamicValues(
        now: Self.fixedInstant.addingTimeInterval(365 * 24 * 60 * 60), locale: .current,
        timeZone: .current, clipboard: nil))
    #expect(expected != aYearLater, "the control itself must discriminate")
    #expect(probe.reads == 0)
  }

  // MARK: - Cost, measured rather than assumed (#3018)

  /// What a fill-in take actually costs, against the step's own one-second backstop.
  ///
  /// OFF by default and enabled by `EW_SNIPPET_FILLIN_BENCH=<report path>`: it moves hundreds of
  /// megabytes through strings, which is a measurement rather than a check, and a constrained CI
  /// runner should not pay for it on every run. It asserts CORRECTNESS on every sample — fast wrong
  /// output is a failed measurement — and asserts no absolute wall-clock bound, because a number
  /// measured on this Mac is not a bound for the support floor (macOS 14, M1, 8 GB).
  ///
  /// The reader runs against an ISOLATED named pasteboard. That exercises the real
  /// `ClipboardCleanup.userPlainText` implementation; it does NOT prove the public initializer's
  /// `.general` wiring, which only Live UAT can show.
  ///
  /// The matrix exists to separate the two candidate cost drivers rather than to produce one
  /// number: the pasteboard READ, and the resolved sentinel-collision domain, which holds one copy
  /// of the clipboard per SAVED clipboard snippet.
  @Test(
    "Measure the clipboard read and the two-pass step",
    .enabled(if: ProcessInfo.processInfo.environment["EW_SNIPPET_FILLIN_BENCH"] != nil))
  @MainActor
  func measureTheTwoPassCost() async throws {
    let reportPath = try #require(ProcessInfo.processInfo.environment["EW_SNIPPET_FILLIN_BENCH"])
    var report = "# Snippet fill-in cost, \(Date())\n"
    report += "machine=\(ProcessInfo.processInfo.hostName) "
    report += "cores=\(ProcessInfo.processInfo.processorCount) "
    #if DEBUG
      report += "configuration=Debug\n"
    #else
      report += "configuration=Release\n"
    #endif
    report += "backstop=\(SnippetExpansionStep().maxDuration)\n"
    report +=
      "note: step timing excludes the runner's initial actor hop, which the backstop also covers.\n\n"

    func summarise(_ label: String, _ samples: [Duration], first: Duration) {
      let ms =
        samples
        .map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
        .sorted()
      let firstMs =
        Double(first.components.seconds) * 1000 + Double(first.components.attoseconds) / 1e15
      report += String(
        format: "%-56@ n=%d first=%.3fms median=%.3fms p95=%.3fms max=%.3fms\n",
        label as NSString, ms.count, firstMs, ms[ms.count / 2],
        ms[min(ms.count - 1, Int(Double(ms.count) * 0.95))], ms.last ?? 0)
    }

    /// `clipboardSnippets` saved snippets that carry `{{clipboard}}`, plus a date snippet and a
    /// literal one, so a take can fire each kind.
    func vocabulary(clipboardSnippets: Int) -> SnippetVocabulary {
      var snippets: [Snippet] = [
        Snippet(trigger: "my link", expansion: "see {{clipboard}}"),
        Snippet(trigger: "my stamp", expansion: "filed {{date}}"),
        Snippet(trigger: "my sign off", expansion: "thanks, sam"),
      ]
      for index in 0..<max(0, clipboardSnippets - 1) {
        snippets.append(
          Snippet(trigger: "my saved \(index)", expansion: "saved \(index): {{clipboard}}"))
      }
      return SnippetVocabulary(
        snippets: snippets, keyword: SnippetVocabulary.defaultKeyword, generation: 1)
    }

    func board(holding payload: String) -> NSPasteboard {
      let board = NSPasteboard.withUniqueName()
      board.clearContents()
      board.setString(payload, forType: .string)
      return board
    }

    /// Ordinary user content. `carrying: true` plants an EXACT sentinel candidate, which is what
    /// makes `domainCanCollide` true and adds a per-mint scan of the whole domain.
    func payload(bytes: Int, carryingCandidate: Bool) -> String {
      let tail = carryingCandidate ? "EWSNIPinside" : "ordinary text"
      return String(repeating: "x", count: max(0, bytes - tail.count)) + tail
    }

    func timeStep(
      label: String, text: String, vocabulary: SnippetVocabulary, payload: String,
      expected: [String], expectedReads: Int, forcedCandidate: String? = nil
    ) async throws {
      let timing = try await Self.timeSteps(
        text: text, vocabulary: vocabulary, payload: payload, expected: expected,
        expectedReads: expectedReads, forcedCandidate: forcedCandidate)
      summarise(label, timing.samples, first: timing.first)
    }

    /// The exact text each fired snippet must deliver. Built once, outside every timed interval.
    func linkRecord(_ payload: String) -> [String] { ["see " + payload] }

    // 1. The pasteboard read on its own.
    for bytes in [1024, 1 << 20, 10 << 20] {
      let pb = board(holding: payload(bytes: bytes, carryingCandidate: false))
      var samples: [Duration] = []
      let first = ContinuousClock().measure { _ = ClipboardCleanup.userPlainText(from: pb) }
      for _ in 0..<30 {
        var answer: String?
        samples.append(
          ContinuousClock().measure { answer = ClipboardCleanup.userPlainText(from: pb) })
        #expect(answer?.count == bytes)
      }
      summarise("reader bytes=\(bytes)", samples, first: first)
    }
    report += "\n"

    // 2. One fired clipboard snippet, across clipboard size and SAVED clipboard-snippet count.
    for bytes in [1 << 20, 10 << 20] {
      for saved in [1, 4, 16] {
        let body = payload(bytes: bytes, carryingCandidate: false)
        try await timeStep(
          label: "step one-fired bytes=\(bytes) saved=\(saved) ordinary",
          text: "here you go backslash my link and that is all",
          vocabulary: vocabulary(clipboardSnippets: saved),
          payload: body, expected: linkRecord(body), expectedReads: 1)
      }
    }
    report += "\n"

    // 3. The worst case there is: the user's clipboard holds the EXACT token the source mints, and
    //    the source is degenerate, so every attempt collides and the mint walks to its fallback.
    //    The candidate is INJECTED rather than hoped for; a random source would never collide.
    for bytes in [1 << 20, 10 << 20] {
      let body = payload(bytes: bytes, carryingCandidate: true)
      try await timeStep(
        label: "step one-fired bytes=\(bytes) saved=16 forced-collision",
        text: "here you go backslash my link and that is all",
        vocabulary: vocabulary(clipboardSnippets: 16),
        payload: body, expected: linkRecord(body), expectedReads: 1,
        forcedCandidate: "EWSNIPinside")
    }
    report += "\n"

    // 3b. The REACHABLE slow path, and the one the arithmetic must not stand in for: the user's
    //     clipboard holds the literal `EWSNIP`, so `domainCanCollide` is true and every mint scans
    //     the domain again, but the candidate source is the SHIPPED random one, so nothing
    //     actually collides. One fire and three fires, because the scans are per mint.
    for fires in [1, 3] {
      let prefixBody = payload(bytes: 10 << 20, carryingCandidate: true)
      let text =
        fires == 1
        ? "here you go backslash my link and that is all"
        : "backslash my link then backslash my saved 0 then backslash my saved 1 thanks"
      let expected =
        fires == 1
        ? ["see " + prefixBody]
        : ["see " + prefixBody, "saved 0: " + prefixBody, "saved 1: " + prefixBody]
      try await timeStep(
        label: "step \(fires)-fired bytes=\(10 << 20) saved=16 prefix-random",
        text: text,
        vocabulary: vocabulary(clipboardSnippets: 16),
        payload: prefixBody, expected: expected, expectedReads: 1)
    }
    report += "\n"

    // 3b2. MIXED text, which is what a real document is. One accented character or curly quote
    //      means the byte search can no longer answer a miss on its own, so every unsuccessful
    //      candidate search falls back to `String.contains`. Both halves of that are measured: an
    //      ordinary mixed clipboard, where only the prefix screen pays, and a mixed clipboard that
    //      also holds the prefix, where every mint pays.
    for carryingPrefix in [false, true] {
      let tail = carryingPrefix ? "EWSNIP" : "ordinary"
      let mixedBody =
        "\u{e9}\u{201c}" + String(repeating: "x", count: (10 << 20) - tail.count - 2) + tail
      try await timeStep(
        label:
          "step 3-fired bytes=\(10 << 20) saved=16 mixed-\(carryingPrefix ? "prefix" : "ordinary")",
        text: "backslash my link then backslash my saved 0 then backslash my saved 1 thanks",
        vocabulary: vocabulary(clipboardSnippets: 16),
        payload: mixedBody,
        expected: [
          "see " + mixedBody, "saved 0: " + mixedBody, "saved 1: " + mixedBody,
        ],
        expectedReads: 1)
    }
    report += "\n"

    // 3c. A PREFIX-DENSE clipboard. Every mint's domain scan matches immediately here rather than
    //     walking the whole payload, which is the opposite shape from the payload above, so both
    //     ends of the prefix axis are measured rather than one.
    for bytes in [1 << 20, 10 << 20] {
      let unit = "EWSNIP-"
      let dense = String(repeating: unit, count: max(1, bytes / unit.count))
      try await timeStep(
        label: "step 3-fired bytes=\(dense.utf8.count) saved=16 prefix-dense",
        text: "backslash my link then backslash my saved 0 then backslash my saved 1 thanks",
        vocabulary: vocabulary(clipboardSnippets: 16),
        payload: dense,
        expected: ["see " + dense, "saved 0: " + dense, "saved 1: " + dense],
        expectedReads: 1)
    }
    report += "\n"

    // 4. Three fired snippets in one take, which mints three sentinels against the same domain.
    for bytes in [1 << 20, 10 << 20] {
      let body = payload(bytes: bytes, carryingCandidate: false)
      try await timeStep(
        label: "step three-fired bytes=\(bytes) saved=16 ordinary",
        text: "backslash my link then backslash my saved 0 then backslash my saved 1 thanks",
        vocabulary: vocabulary(clipboardSnippets: 16),
        payload: body,
        expected: ["see " + body, "saved 0: " + body, "saved 1: " + body],
        expectedReads: 1)
    }
    report += "\n"

    // 5. The takes that must be unaffected, with a 10 MiB clipboard sitting on the board and
    //    sixteen clipboard snippets SAVED: a literal snippet firing, and a date snippet firing.
    //    Neither reads the clipboard, so neither may pay for it.
    let quietBoard = payload(bytes: 10 << 20, carryingCandidate: false)
    try await timeStep(
      label: "step literal-fired bytes=\(10 << 20) saved=16 (no clipboard read)",
      text: "bye backslash my sign off",
      vocabulary: vocabulary(clipboardSnippets: 16),
      payload: quietBoard, expected: ["thanks, sam"], expectedReads: 0)
    let stamped = SnippetPlaceholder.resolve(
      "filed {{date}}",
      using: SnippetDynamicValues(
        now: Self.fixedInstant, locale: .current, timeZone: .current, clipboard: nil))
    try await timeStep(
      label: "step date-fired bytes=\(10 << 20) saved=16 (no clipboard read)",
      text: "note this backslash my stamp please",
      vocabulary: vocabulary(clipboardSnippets: 16),
      payload: quietBoard, expected: [stamped], expectedReads: 0)

    try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
    print(report)
  }

  /// Times `process` against an isolated board holding `payload`.
  ///
  /// A METHOD taking only Sendable arguments, not a nested function taking the board. A nested
  /// `async` function does not inherit the enclosing actor, so its `NSPasteboard` parameter arrives
  /// task-isolated and the main-actor reader closure cannot capture it — an error the Release lane
  /// raises and the Debug lane did not.
  ///
  /// Correctness is asserted on EVERY sample, against the exact expected text and the exact number
  /// of clipboard reads. A fast wrong answer is a failed measurement, and a length check is not a
  /// correctness check.
  @MainActor
  private static func timeSteps(
    text: String, vocabulary: SnippetVocabulary, payload: String, expected: [String],
    expectedReads: Int, forcedCandidate: String? = nil
  ) async throws -> (samples: [Duration], first: Duration) {
    let board = NSPasteboard.withUniqueName()
    board.clearContents()
    board.setString(payload, forType: .string)

    let probe = ClipboardProbe()
    probe.text = payload
    let expander =
      forcedCandidate.map { candidate in SnippetExpander(candidateSource: { candidate }) }
      ?? SnippetExpander()
    let step = SnippetExpansionStep(
      expander: expander,
      now: { Self.fixedInstant },
      clipboardText: {
        // Counts the reads AND performs the real one, so the count and the cost are the same run.
        _ = probe.read()
        return ClipboardCleanup.userPlainText(from: board)
      })
    step.snippetVocabulary = vocabulary
    let context = TextProcessingContext(text: text, language: "en")

    let clock = ContinuousClock()
    var start = clock.now
    let warm = try await step.process(context)
    let first = clock.now - start
    #expect(warm.protectedExpansions.map(\.expansion) == expected)
    #expect(probe.reads == expectedReads)

    var samples: [Duration] = []
    for index in 0..<30 {
      start = clock.now
      let out = try await step.process(context)
      samples.append(clock.now - start)
      #expect(out.protectedExpansions.map(\.expansion) == expected)
      #expect(probe.reads == expectedReads * (index + 2))
    }
    return (samples, first)
  }
}
