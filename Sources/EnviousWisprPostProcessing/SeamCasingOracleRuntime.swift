import AppKit
import Foundation
import NaturalLanguage
import os

/// The single runtime owner of seam-casing word knowledge, one language at a
/// time: readiness, availability, the permanent timeout latch, and the only
/// contact with `NSSpellChecker` and `NLTagger` in the app.
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
/// ## What #1922 changed, and what it had to add
///
/// Going per-language is what put point 1 at risk. With one language, prewarm ran
/// once at launch and nothing else ever prepared. With twelve, any dictation in a
/// new language can start a preparation at any moment. Two guards restore the
/// argument, and neither is sufficient alone:
///
/// - **One global drain**, so at most one builder is ever inside the checker.
///   Independent per-language warmers would void the proof outright.
/// - **A decision LEASE**, because refusing new snapshots does not stop one taken
///   microseconds earlier from calling in during preparation.
///
/// Issues #1803, #1922.
package enum SeamCasingOracleRuntime {

  private enum Phase: Sendable {
    case warming
    case ready(SeamCasingOracle)
    case unavailable(CursorInsertionRepair.CaseSkipReason)
  }

  private struct State: Sendable {
    var prewarmStarted = false
    /// One phase PER LANGUAGE. Absent means never requested.
    ///
    /// Keyed by the base code the repair resolved, never by the raw dictation
    /// tag: `LanguageNormalizer.baseCode` has already folded `de-DE` and `de_AT`
    /// together, so two spellings of one language cannot each build an oracle.
    var phases: [String: Phase] = [:]
    /// Bumped by every deliberate state change. A preparation that started
    /// before a change must not publish after it: `prewarmStarted` guards
    /// STARTING one, not one already in flight, and a reset restores exactly the
    /// `.warming` phase its publish step looks for (local diff review r3).
    var epoch = 0

    /// Languages requested but not yet prepared, in request order.
    var pending: [String] = []
    /// A preparation system call is running right now.
    var preparing = false
    /// How many decisions hold a lease and may still call into the checker.
    ///
    /// THE RACE THIS CLOSES, because refusing at snapshot time does not close it:
    /// a snapshot taken microseconds BEFORE preparation begins is already out,
    /// and its `NSSpellChecker` call would land inside the preparation window —
    /// two callers in the one shared checker, which is precisely the invariant
    /// the runtime's one-lock argument depends on. Refusing future snapshots is
    /// necessary and not sufficient; the drain must also WAIT for in-flight
    /// decisions. Grounded review r2, HIGH.
    var decisionLeases = 0

    /// A permanent latch stops everything, everywhere, forever.
    var latched: CursorInsertionRepair.CaseSkipReason?
  }

  /// What a language needs from macOS before it may decide anything.
  ///
  /// Availability is PROFILE-SPECIFIC and getting this wrong is silent: the
  /// shipped code required `.nameType` unconditionally, which exists for exactly
  /// en/fr/de/it, so the eight dictionary-only languages would have resolved
  /// unavailable and the release would have shipped four languages while
  /// claiming twelve — with every test green, because refusing without name
  /// detection is correct ENGLISH behaviour. #1922, found while writing this
  /// file and independently by grounded review r2.
  ///
  /// The dictionary sentinel is required by EVERY profile and must never be
  /// relaxed. Be precise about what it does, because the two guards are easy to
  /// conflate: the POLICY TABLE is what makes the 23 unsupported European
  /// languages abstain — they never reach this type at all — while the sentinel
  /// protects a SUPPORTED language against a dictionary that is listed but
  /// answers yes to everything. Only the tag-scheme requirements vary.
  struct CapabilityProfile: Sendable {
    let needsNameType: Bool
    let needsLexicalClass: Bool

    static func forLanguage(_ base: String) -> CapabilityProfile {
      switch base {
      // German's entire rule IS the noun veto, so a missing word-class scheme
      // makes it unavailable rather than merely weaker.
      case "de": return CapabilityProfile(needsNameType: true, needsLexicalClass: true)
      case "en", "fr", "it": return CapabilityProfile(needsNameType: true, needsLexicalClass: false)
      // Dictionary only, deliberately. Measured at 95.6-99.4% precision on
      // held-out text with name detection absent; the residual risk is stated in
      // the #1922 plan's second persona rather than engineered away.
      default: return CapabilityProfile(needsNameType: false, needsLexicalClass: false)
      }
    }
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
    let start = state.withLock { state -> Bool in
      guard !state.prewarmStarted else { return false }
      state.prewarmStarted = true
      // English is warmed unconditionally at launch because it is by far the
      // most common language and this is the one moment that is definitely off
      // the paste path. Every other language is prepared on first request.
      state.phases["en"] = .warming
      state.pending.append("en")
      return true
    }
    guard start else { return }
    await drain()
  }

  /// Prepare pending languages one at a time, never while a decision is in
  /// flight, and never on the paste path.
  ///
  /// Serialization is not tidiness. The runtime's one-lock argument (see the
  /// type doc) holds only because preparation and decisions never overlap in the
  /// one shared `NSSpellChecker`. Independent per-language warmers would void
  /// it, and so would draining while a decision holds a lease.
  @concurrent
  private static func drain() async {
    while true {
      let next: (String, Int)? = state.withLock { state in
        guard state.latched == nil else { return nil }
        // Wait for in-flight decisions. Their `NSSpellChecker` calls were
        // authorised before we got here and must finish before we start ours.
        guard state.decisionLeases == 0, !state.preparing else { return nil }
        guard let base = state.pending.first else { return nil }
        state.pending.removeFirst()
        state.preparing = true
        return (base, state.epoch)
      }
      guard let (base, startedEpoch) = next else {
        // Either nothing to do, or a lease is out. A lease holder re-pokes the
        // drain on release, so returning here cannot strand pending work.
        return
      }

      let prepared = prepare(base: base)

      state.withLock { state in
        state.preparing = false
        // Publish only if NOTHING has changed since this preparation began. The
        // phase check alone is insufficient: a reset restores `.warming`, so a
        // stale prepare would satisfy it and overwrite state a test just set.
        guard state.epoch == startedEpoch, case .warming? = state.phases[base] else { return }
        state.phases[base] = prepared
      }
    }
  }

  /// Kick the drain from a non-async context, without ever blocking the caller.
  private static func pokeDrain() {
    Task.detached(priority: .utility) { await drain() }
  }

  /// Resolve the dictionary language and probe tagger availability.
  ///
  /// Both are one-time and both are expensive: 20.2 ms and 80.3 ms measured
  /// cold. Neither is ever repeated.
  private static func prepare(base: String) -> Phase {
    // The one seam in this function, and it exists because the serialization
    // contract cannot be demonstrated any other way. `drain()` is the only code
    // that can prove "one builder at a time, and never while a decision holds a
    // lease", and the real body below calls `NSSpellChecker` and `NLTagger` — a
    // test driving that would measure the machine, and could not hold a
    // preparation open at a chosen instant, which IS the experiment.
    if let build = preparationOverride.withLock({ $0 }) {
      let oracle = build(base)
      if let reason = oracle.unavailableReason { return .unavailable(reason) }
      return .ready(oracle)
    }
    // NEVER the raw dictation language, the checker's currently selected
    // language, or nil. Measured: `checkSpelling(language:)` with an
    // unrecognised identifier reports EVERY word correctly spelled — it fails
    // OPEN, which would lowercase names wholesale. Choosing from
    // `availableLanguages` makes that path unreachable rather than detected.
    guard let identifier = resolveLanguage(base, from: NSSpellChecker.shared.availableLanguages)
    else {
      return .unavailable(.dictionaryUnavailable)
    }
    let profile = CapabilityProfile.forLanguage(base)
    let nlLanguage = NLLanguage(base)
    let schemes = NLTagger.availableTagSchemes(for: .word, language: nlLanguage)
    let hasNameType = schemes.contains(.nameType)
    // A scheme/language pair may be unsupported, or its assets not loaded, on
    // this device. We never request a download; an absent model keeps capitals.
    // PROFILE-specific, not universal. Requiring `.nameType` everywhere is what
    // would have silently reduced twelve languages to four.
    if profile.needsNameType, !hasNameType {
      return .unavailable(.wordClassUnavailable)
    }
    if profile.needsLexicalClass, !schemes.contains(.lexicalClass) {
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

    let oracle = SeamCasingOracle(
      unavailableReason: nil,
      dictionaryVerdict: { word in
        let checker = NSSpellChecker.shared
        // Re-validated every lookup: a dictionary removed mid-process would
        // otherwise recreate the stale-identifier fail-open path. The dictation
        // that discovers it reports the outage itself rather than looking like
        // an ordinary miss.
        guard checker.availableLanguages.contains(identifier) else {
          markUnavailableIfReady(.dictionaryUnavailable, base: base)
          return .unavailable(.dictionaryUnavailable)
        }
        let ordinary = isOrdinary(
          word,
          sentinel: sentinel,
          spelledCorrectly: { candidate in
            checker.checkSpelling(
              of: candidate, startingAt: 0, language: identifier, wrap: false,
              inSpellDocumentWithTag: tag, wordCount: nil
            ).location == NSNotFound
          },
          onServiceFailure: { markUnavailableIfReady(.dictionaryUnavailable, base: base) })
        // A yes-to-everything service is an outage too, not a plain refusal.
        if !ordinary, case .unavailable(let reason)? = currentUnavailableReason(base) {
          return .unavailable(reason)
        }
        return ordinary ? .ordinary : .notOrdinary
      },
      isLearnedWord: { NSSpellChecker.shared.hasLearnedWord($0) },
      isRecognizedName: { left, payload in
        let joined = left + payload
        // A fresh tagger per decision: the SDK forbids using one instance from
        // more than one thread at a time, and construction is inside the
        // measured cost.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = joined
        let index = joined.index(joined.startIndex, offsetBy: left.count)
        // No tag is NOT an outage, so it is not routed to `.wordClassUnavailable`.
        // Probed 2026-07-26 across gibberish, keyboard mash, twelve non-English
        // languages, emoji, digits, URLs and code: every one returned a real tag
        // (`OtherWord` for gibberish, `Other` for languages where the scheme is
        // unsupported). The single input that returned nil was a query
        // at a position holding no word, which cannot arise here because a word
        // was already extracted. Zero nils in 11,577 real continuations.
        guard let name = tagger.tag(at: index, unit: .word, scheme: .nameType).0 else {
          return false
        }
        return Self.nameTags.contains(name)
      },
      isNoun: { payload in
        // The PAYLOAD alone, never the joined seam. #1803 measured that adding
        // the surrounding document made German worse, flipping `Morgen` from
        // adverb to noun. That is the opposite of `isRecognizedName` above,
        // which needs the left context — the two questions want different
        // inputs, so they are asked separately rather than sharing a string.
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        // Pinned, not sniffed. `NLTagger` guesses the language of a short
        // fragment badly, and this closure is only ever built for a language
        // whose `.lexicalClass` availability was already probed in `prepare`.
        tagger.setLanguage(nlLanguage, range: payload.startIndex..<payload.endIndex)
        tagger.string = payload
        guard
          let tag = tagger.tag(at: payload.startIndex, unit: .word, scheme: .lexicalClass).0
        else {
          // No tag is not an outage, and here it is also not a licence to lower:
          // this is a VETO, so the safe answer is "treat it as a noun" and keep
          // the capital.
          return true
        }
        return tag == .noun
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

  /// The stored unavailable reason, if the runtime has latched one.
  private static func currentUnavailableReason(_ base: String) -> Phase? {
    state.withLock { state in
      if case .unavailable? = state.phases[base] { return state.phases[base] }
      return nil
    }
  }

  /// What counts as a name. Anything else falls through to the dictionary.
  private static let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

  /// Pick an installed dictionary for `base` deterministically.
  ///
  /// Chosen from `availableLanguages` and never from the raw dictation tag,
  /// because `checkSpelling(language:)` with an unrecognised identifier reports
  /// EVERY word correctly spelled — it fails OPEN, which would lowercase names
  /// wholesale. Selecting from the installed list makes that path unreachable
  /// rather than merely detected.
  ///
  /// `.sorted().first` is arbitrary but deterministic, which matters more than
  /// which regional variant wins: `en_GB` and `en_US` disagree about `colour`,
  /// not about whether a word is ordinary, and a stable choice keeps one machine
  /// answering the same way across launches.
  static func resolveLanguage(_ base: String, from availableLanguages: [String]) -> String? {
    availableLanguages
      .filter { identifier in
        identifier
          .replacingOccurrences(of: "_", with: "-")
          .split(separator: "-", maxSplits: 1)
          .first?
          .lowercased() == base
      }
      .sorted()
      .first
  }

  // MARK: - Decisions

  /// The oracle for `base` as it stands right now. Never blocks.
  ///
  /// Requesting an unprepared language returns `.oracleWarming` and schedules
  /// its preparation OFF the paste path. The first dictation in a new language
  /// keeps its capital — today's behaviour — and every later one is served.
  /// Preparation costs ~100 ms against a 100 ms wall-clock deadline whose
  /// timeout latches casing off process-wide and permanently (#1946), so doing
  /// it inline would mean one German dictation on a busy Mac disables casing in
  /// every language until relaunch.
  ///
  /// Returns a LEASED oracle when ready. The caller MUST release it (see
  /// `releaseDecisionLease`), which the repair does in `defer`. Without the
  /// lease the drain could begin a preparation call while an already-issued
  /// decision is still inside the shared checker — the race refusing-at-snapshot
  /// does not close, because that snapshot escaped before preparation started.
  package static func snapshot(for base: String?) -> SeamCasingOracle {
    let (oracle, needsDrain) = state.withLock { state -> (SeamCasingOracle, Bool) in
      if let latched = state.latched { return (.unavailable(latched), false) }
      guard let base else { return (.unavailable(.languageNotSupported), false) }
      // A preparation call is inside the checker right now: everyone refuses,
      // including languages that are already built.
      if state.preparing { return (.unavailable(.oracleWarming), false) }

      switch state.phases[base] {
      case .ready(let oracle):
        state.decisionLeases += 1
        return (oracle, false)
      case .warming:
        return (.unavailable(.oracleWarming), false)
      case .unavailable(let reason):
        return (.unavailable(reason), false)
      case nil:
        state.phases[base] = .warming
        state.pending.append(base)
        return (.unavailable(.oracleWarming), true)
      }
    }
    if needsDrain { pokeDrain() }
    return oracle
  }

  /// Release a lease taken by `snapshot(for:)`, and let preparation proceed.
  ///
  /// Must be called exactly once per READY snapshot, from a `defer` so an early
  /// return or a thrown error cannot strand it. A stranded lease does not
  /// corrupt anything, but it stops every future language from ever preparing.
  package static func releaseDecisionLease() {
    let resume = state.withLock { state -> Bool in
      guard state.decisionLeases > 0 else { return false }
      state.decisionLeases -= 1
      return state.decisionLeases == 0 && !state.pending.isEmpty && !state.preparing
    }
    if resume { pokeDrain() }
  }

  /// Latch permanently after a live decision exceeded its deadline.
  ///
  /// Synchronous and non-suspending by contract: `withOrderedDeadline` requires
  /// `onTimeout` to complete before the caller resumes, so anything that could
  /// wait here would recreate the hang the deadline exists to prevent.
  package static func disableAfterTimeout() {
    state.withLock { state in
      state.epoch += 1
      // PROCESS-WIDE and across every language, deliberately: a hung spell
      // service is hung for all of them, and this is one shared checker. The
      // latch is read first by `snapshot(for:)`, so no language can escape it.
      state.latched = .oracleTimedOut
      state.pending.removeAll()
    }
  }

  /// Mark unavailable ONLY while still ready.
  ///
  /// `withOrderedDeadline.claim()` discards a late decision but cannot roll back
  /// side effects inside the operation. Without this guard, a stalled call that
  /// later found the identifier missing would write `.dictionaryUnavailable`
  /// over an already-installed `.oracleTimedOut` — it could not re-block paste,
  /// but it would violate the permanent-latch contract and mislabel telemetry.
  private static func markUnavailableIfReady(
    _ reason: CursorInsertionRepair.CaseSkipReason, base: String
  ) {
    state.withLock { state in
      guard case .ready? = state.phases[base] else { return }
      state.epoch += 1
      // Scoped to the language that discovered it. A missing German dictionary
      // says nothing about the English one, and demoting all of them would turn
      // one language's outage into a whole-feature outage.
      state.phases[base] = .unavailable(reason)
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
    // Cleared here as well as by the setter, so a case that fails mid-way cannot
    // leave a blocking builder installed for every suite after it. The exclusion
    // helper resets on the way out, which makes this the backstop.
    preparationOverride.withLock { $0 = nil }
    state.withLock { state in
      state = State(prewarmStarted: true, epoch: state.epoch + 1)
    }
  }

  /// Stand in for the system preparation of one language.
  ///
  /// Set AFTER `resetForTesting()`, which clears it. Returning an oracle with a
  /// non-nil `unavailableReason` stands in for a preparation that found the
  /// language unusable.
  package static func setPreparationOverrideForTesting(
    _ build: (@Sendable (String) -> SeamCasingOracle)?
  ) {
    preparationOverride.withLock { $0 = build }
  }

  private static let preparationOverride =
    OSAllocatedUnfairLock<(@Sendable (String) -> SeamCasingOracle)?>(initialState: nil)

  /// Install a fixed phase for one language without touching a system service.
  ///
  /// Defaults to English so the many existing suites that installed "the"
  /// oracle keep meaning what they meant before this type became per-language.
  /// A suite testing German must say so, which is the point: an oracle silently
  /// installed under the wrong language would make a German test pass on an
  /// English answer.
  package static func installForTesting(_ oracle: SeamCasingOracle, for base: String = "en") {
    state.withLock { state in
      state.epoch += 1
      state.prewarmStarted = true
      if let reason = oracle.unavailableReason {
        state.phases[base] = .unavailable(reason)
      } else {
        state.phases[base] = .ready(oracle)
      }
    }
  }

  /// Leases outstanding right now. Test-only.
  ///
  /// Exists so a test can PROVE the drain waits rather than asserting it in a
  /// comment: take a lease, enqueue a second language, and show its preparation
  /// cannot start until the lease is released.
  package static func outstandingLeasesForTesting() -> Int {
    state.withLock { $0.decisionLeases }
  }
}
