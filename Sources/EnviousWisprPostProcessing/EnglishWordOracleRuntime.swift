import AppKit
import Foundation
import NaturalLanguage
import os

/// The single runtime owner of the English word oracle: readiness,
/// availability, the permanent timeout latch, and the only contact with
/// `NSSpellChecker` and `NLTagger` in the app.
///
/// ## Why an owner at all
///
/// The spelling dictionary is served by a separate process. An unbounded call
/// to it sits on the paste path, so a hang there means a dictation never
/// pastes — a heart-path failure. The caller bounds each decision with
/// `withOrderedDeadline`; this type owns what happens around that.
///
/// ## Why ONE lock is enough
///
/// `withOrderedDeadline` runs `onTimeout` to completion *before* resuming the
/// caller, and `onTimeout` is `@MainActor`. So a lock held across a stalled
/// system call would block the main actor and hang paste anyway, defeating the
/// deadline. This avoids that by eliminating concurrency rather than managing
/// it, which also removes any dependence on `NSSpellChecker`'s undocumented
/// thread safety:
///
/// 1. While `.warming`, every decision refuses without touching the checker, so
///    prewarm never overlaps a decision.
/// 2. Decisions are already sequential — one recording session, and the
///    delivery closure is `@MainActor`.
/// 3. The timeout latch is PERMANENT, so no later call can reach the checker to
///    race an abandoned one. At most one abandoned call can exist.
/// 4. The lock is taken only for short state reads and writes, never across a
///    system call, so `onTimeout` can always acquire it immediately.
///
/// A stalled prewarm needs no deadline either: the state simply stays
/// `.warming`, decisions refuse, and capitals are kept — today's behaviour.
///
/// Issue #1803.
package enum EnglishWordOracleRuntime {

  private enum Phase: Sendable {
    case warming
    case ready(EnglishWordOracle)
    case unavailable(CursorInsertionRepair.CaseSkipReason)
  }

  private struct State: Sendable {
    var prewarmStarted = false
    var phase: Phase = .warming
    /// Bumped by every deliberate state change. A prewarm that started before a
    /// change must not publish after it: `prewarmStarted` guards STARTING one,
    /// not one already in flight, and a reset restores exactly the `.warming`
    /// phase its publish step looks for (local diff review r3, residual).
    var epoch = 0
  }

  private static let state = OSAllocatedUnfairLock(initialState: State())

  // MARK: - Prewarm

  /// Prepare the oracle once, off the paste path.
  ///
  /// `@concurrent` is load-bearing, not decoration. `WisprBootstrapper` is
  /// `@MainActor`, so a plain `Task { }` there would INHERIT the main actor and
  /// run the measured ~76-85 ms of language resolution and scheme probing on
  /// it — reinstating at launch exactly the stall this design removes from
  /// paste. Measured: unwarmed first paste 105.6 ms, warmed 0.5 ms.
  @concurrent
  package static func prewarm() async {
    let startedEpoch = state.withLock { state -> Int? in
      guard !state.prewarmStarted else { return nil }
      state.prewarmStarted = true
      return state.epoch
    }
    guard let startedEpoch else { return }

    let prepared = prepare()

    state.withLock { state in
      // Publish only if NOTHING has changed the state since this prewarm began.
      // The phase check alone is insufficient: a reset restores `.warming`, so a
      // stale prepare would satisfy it and overwrite the state a test just
      // established.
      guard state.epoch == startedEpoch, case .warming = state.phase else { return }
      state.phase = prepared
    }
  }

  /// Resolve the dictionary language and probe tagger availability.
  ///
  /// Both are one-time and both are expensive: 20.2 ms and 80.3 ms measured
  /// cold. Neither is ever repeated.
  private static func prepare() -> Phase {
    // NEVER the raw dictation language, the checker's currently selected
    // language, or nil. Measured: `checkSpelling(language:)` with an
    // unrecognised identifier reports EVERY word correctly spelled — it fails
    // OPEN, which would lowercase names wholesale. Choosing from
    // `availableLanguages` makes that path unreachable rather than detected.
    guard let english = resolveEnglishLanguage(from: NSSpellChecker.shared.availableLanguages)
    else {
      return .unavailable(.dictionaryUnavailable)
    }
    // A scheme/language pair may be unsupported, or its assets not loaded, on
    // this device. We never request a download; an absent model keeps capitals.
    guard NLTagger.availableTagSchemes(for: .word, language: .english).contains(.lexicalClass)
    else {
      return .unavailable(.wordClassUnavailable)
    }

    let tag = NSSpellChecker.uniqueSpellDocumentTag()

    // A nonsense word no dictionary can contain, unique to this process.
    //
    // `checkSpelling` reports "no misspelling found" as `NSNotFound` — the SAME
    // value it returns when the spell service is not answering at all. That
    // failure is silent and fails OPEN, so every word would read as ordinary and
    // names would be lowercased wholesale.
    //
    // The sentinel is checked ONLY when a word came back valid, which is the one
    // direction where a fail-open does damage; a refusal needs no confirmation.
    // So the cost lands only on the lowering path, and never on a refusal.
    //
    // Per-process random, not a fixed string: an earlier fixed-canary design was
    // rejected because any user can `learnWord` a known constant and turn the
    // health check into a permanent false outage. This one cannot be learned in
    // advance.
    let sentinel = "zqx\(UInt32.random(in: 100_000...999_999))vkj"

    let oracle = EnglishWordOracle(
      unavailableReason: nil,
      isOrdinaryWord: { word in
        let checker = NSSpellChecker.shared
        // Re-validated every lookup: a dictionary removed mid-process would
        // otherwise recreate the stale-identifier fail-open path.
        guard checker.availableLanguages.contains(english) else {
          markUnavailableIfReady(.dictionaryUnavailable)
          return false
        }
        return isOrdinary(
          word,
          sentinel: sentinel,
          spelledCorrectly: { candidate in
            checker.checkSpelling(
              of: candidate, startingAt: 0, language: english, wrap: false,
              inSpellDocumentWithTag: tag, wordCount: nil
            ).location == NSNotFound
          },
          onServiceFailure: { markUnavailableIfReady(.dictionaryUnavailable) })
      },
      isLearnedWord: { NSSpellChecker.shared.hasLearnedWord($0) },
      wordClassIsSafe: { left, payload in
        let joined = left + payload
        // A fresh tagger per decision: the SDK forbids using one instance from
        // more than one thread at a time, and construction is inside the
        // measured 0.30 ms.
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = joined
        tagger.setLanguage(.english, range: joined.startIndex..<joined.endIndex)
        let index = joined.index(joined.startIndex, offsetBy: left.count)
        guard
          let lexicalClass = tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0
        else { return false }
        return safeWordClasses.contains(lexicalClass)
      })
    return .ready(oracle)
  }


  /// Is `word` ordinary, with a guard against the spell service failing open?
  ///
  /// Extracted so the guard is TESTABLE without a live spell service. An
  /// untested fail-open guard is indistinguishable from no guard at all, and
  /// this one exists because `checkSpelling` reports "no misspelling" and "not
  /// answering" with the same `NSNotFound`.
  ///
  /// The sentinel is checked ONLY after a word comes back valid: that is the one
  /// direction where failing open does damage. A refusal needs no confirmation,
  /// so a rejected word costs exactly one lookup.
  package static func isOrdinary(
    _ word: String,
    sentinel: String,
    spelledCorrectly: (String) -> Bool,
    onServiceFailure: () -> Void
  ) -> Bool {
    guard spelledCorrectly(word) else { return false }
    guard !spelledCorrectly(sentinel) else {
      onServiceFailure()
      return false
    }
    return true
  }

  /// Every class a proper name is not. `Noun`, `OtherWord` and no tag at all
  /// refuse, which is the conservative direction.
  private static let safeWordClasses: Set<NLTag> = [
    .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective,
    .preposition, .particle, .interjection, .number,
  ]

  /// Pick an installed English dictionary deterministically.
  static func resolveEnglishLanguage(from availableLanguages: [String]) -> String? {
    availableLanguages
      .filter { identifier in
        identifier
          .replacingOccurrences(of: "_", with: "-")
          .split(separator: "-", maxSplits: 1)
          .first?
          .lowercased() == "en"
      }
      .sorted()
      .first
  }

  // MARK: - Decisions

  /// The oracle as it stands right now. Never blocks.
  package static func snapshot() -> EnglishWordOracle {
    state.withLock { state in
      switch state.phase {
      case .warming: return .unavailable(.oracleWarming)
      case .ready(let oracle): return oracle
      case .unavailable(let reason): return .unavailable(reason)
      }
    }
  }

  /// Latch permanently after a live decision exceeded its deadline.
  ///
  /// Synchronous and non-suspending by contract: `withOrderedDeadline` requires
  /// `onTimeout` to complete before the caller resumes, so anything that could
  /// wait here would recreate the hang the deadline exists to prevent.
  package static func disableAfterTimeout() {
    state.withLock { state in
      state.epoch += 1
      state.phase = .unavailable(.oracleTimedOut)
    }
  }

  /// Mark unavailable ONLY while still ready.
  ///
  /// `withOrderedDeadline.claim()` discards a late decision but cannot roll back
  /// side effects inside the operation. Without this guard, a stalled call that
  /// later found the identifier missing would write `.dictionaryUnavailable`
  /// over an already-installed `.oracleTimedOut` — it could not re-block paste,
  /// but it would violate the permanent-latch contract and mislabel telemetry.
  private static func markUnavailableIfReady(_ reason: CursorInsertionRepair.CaseSkipReason) {
    state.withLock { state in
      guard case .ready = state.phase else { return }
      state.epoch += 1
      state.phase = .unavailable(reason)
    }
  }

  // MARK: - Test seams
  //
  // Deliberately NOT `#if DEBUG`. `KernelFinalizationWiringTests` needs an
  // installed oracle to run at all, and CI compiles the test targets in Release
  // as well (`build-release`), where a DEBUG-only member does not exist — six
  // of its cases would fail there for a reason unrelated to what they test
  // (`swift-testing-patterns.md` swift-testing-debug-seam-needs-if-debug).
  // `package` keeps them inside the package with no public surface.

  /// Restore the pristine warming state between cases.
  ///
  /// Marks prewarm as ALREADY STARTED so a real one cannot fire underneath the
  /// test. Building a dictation driver triggers `prewarm()`, and many suites do
  /// that concurrently — without this, a background prepare could publish
  /// `.ready` over a test's expected state and make full-suite results
  /// order-dependent (local diff review r3).
  package static func resetForTesting() {
    state.withLock { state in
      state = State(prewarmStarted: true, phase: .warming, epoch: state.epoch + 1)
    }
  }

  /// Install a fixed phase without touching a system service.
  package static func installForTesting(_ oracle: EnglishWordOracle) {
    state.withLock { state in
      state.epoch += 1
      state.prewarmStarted = true
      if let reason = oracle.unavailableReason {
        state.phase = .unavailable(reason)
      } else {
        state.phase = .ready(oracle)
      }
    }
  }
}
