import AVFoundation
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation

/// Read-only access to the audio the capture manager has already stored.
///
/// **A closure, not `AudioCaptureInterface`, and that is the limb boundary in
/// miniature.** That interface also exposes `startCapture`, `stopCapture`,
/// `rebuildEngine`, `configureVAD` and the buffer callbacks — everything needed to
/// disturb a live recording. A display-only feature holding a reference to all of
/// that is one careless line away from being able to break a dictation, and no
/// comment prevents that line. Handing it a single read narrows the limb's reach to
/// exactly what it needs: the samples that already exist.
typealias LivePreviewSampleReader =
  @MainActor @Sendable (Int) async -> (samples: [Float], totalCount: Int)

/// The most text this session ever handed the pill.
///
/// A reference box because the writer is the publish closure and the reader is the
/// session task that outlives it. The PEAK rather than the last value: the preview
/// is bounded and trims its front on long dictations, so the final string can be
/// shorter than what was displayed earlier, and "how much did the user ever see"
/// is the question this answers.
///
/// `@MainActor`-confined by use — every mutation happens inside the publish
/// closure's main-actor hop, and the single read happens on the same actor — so it
/// needs no lock and makes no cross-actor promise it cannot keep.
@MainActor
final class ShownCharsBox {
  private(set) var peak = 0
  func record(_ count: Int) { peak = max(peak, count) }
}

/// What the recording pill should render for the live preview (#1988).
///
/// `unavailable` carries a sentence rather than being folded into `off` because
/// an empty preview reads as "it did not hear me", which is the exact anxiety
/// this feature exists to remove. If the user turned it on and we cannot deliver,
/// the pill says so.
enum LivePreviewDisplay: Equatable {
  /// The user has it switched off, or this recording is not eligible. The pill
  /// renders at its normal size with no preview area.
  case off
  /// Running, nothing heard yet.
  case waiting
  /// Running, with text. Always the full retained tail; the view decides how much
  /// of it fits.
  case text(String)
  /// Switched on but cannot run. The string is a short user-facing sentence.
  case unavailable(String)
}

/// Drives the live preview and owns every reason it might not run.
///
/// ## This is a limb, and the limb rules are the whole design
///
/// The critical path is trigger, capture, transcribe, paste. The preview must
/// never appear in it. Concretely, and each of these is load-bearing rather than
/// defensive habit:
///
/// - **The heart never awaits it.** `setRecording(_:)` returns immediately; all
///   work happens in a detached task.
/// - **It never touches the audio path.** It polls the samples the capture
///   manager has already stored, exactly as the crash-recovery spool does
///   (`AudioCaptureManager.startRecoveryFeed`). It installs no tap, takes no
///   callback slot, and holds no lock the recording path can block on. The
///   kernel's `onBufferCaptured` is a single-consumer slot the kernel owns;
///   sharing it would have put display code inside the heart's own callback.
/// - **It cannot fail loudly.** Every error becomes a display state. There is no
///   throwing path out of this type.
/// - **It is bounded.** Retained text is capped, so a 77-minute dictation cannot
///   grow a display artifact without limit.
///
/// Measured before any of it was built (#1988 limb safety gate, 72 trials over 6
/// of the founder's own dictations x 4 arms x 3 repeats): with the preview
/// running concurrently, the transcription output was **byte-identical in 18 of
/// 18 trials**, feed-schedule slip moved +0.1 ms and finalize latency moved
/// within the run's own noise floor. The instrument was proven able to detect
/// contention first — saturating every core moved slip 5.3 ms, well outside that
/// floor — so the null result is evidence rather than an absence of evidence.
/// Adopts `CorrectorVocabularyConsumer` so Custom Words reach the preview the same
/// way they reach the pipeline's own correction step — one propagator, one lane,
/// no second source of truth for what a user's vocabulary is (#1988 acceptance:
/// "the custom dictionary applies to preview text, so a user's own names do not
/// visibly mangle mid-dictation").
@MainActor
final class LivePreviewCoordinator: CorrectorVocabularyConsumer {

  /// Poll cadence for handing new audio to the recognizer. Matches the 100 ms
  /// chunking the benchmark harness used, so the screening numbers describe this
  /// feed. Apple emits updates every ~210-290 ms, so a faster poll would buy
  /// nothing.
  private static let feedIntervalMs = 100

  /// Upper bound on retained display text. The preview shows a tail of at most a
  /// couple of lines; the founder's own longest dictation ran to 9,388 words,
  /// none of which a pill can show. Retaining all of it would be permanent
  /// display-only memory growth, so the front is trimmed. Nothing user-visible
  /// depends on the discarded prefix.

  /// Current display state. Read by the pill's provider closure at 20 Hz, the
  /// same way audio level and elapsed time already are.
  private(set) var display: LivePreviewDisplay = .off

  private let readSamples: LivePreviewSampleReader
  private let isEnabled: () -> Bool
  private let languageMode: () -> LanguageMode

  /// Which engine can serve a given language, and why not when it cannot.
  ///
  /// Injected rather than chosen here, so this type never names a vendor and never
  /// encodes one engine's availability rules as the feature's (#2077). Today the
  /// installer supplies Apple's; a second engine changes the closure, not this file.
  private let resolveEngine: LivePreviewEngineResolver

  /// The prepared engine, kept across recordings so the second press does not pay
  /// preparation again.
  private var preparedEngine: (any LivePreviewEngine)?
  /// The candidate key `preparedEngine` was prepared for, so a change of language
  /// OR of engine rebuilds it. Previously a `Locale`, which could not distinguish
  /// two engines previewing the same language.
  private var preparedKey: LivePreviewEngineKey?

  /// Custom Words, written by `CustomWordsPropagator`. Building lookups is the
  /// expensive half, so it happens HERE, once per vocabulary generation, rather
  /// than once per recording inside the recognizer — the same reason
  /// `WordCorrectionStep` caches on `generation`.
  ///
  /// An empty vocabulary stores `nil` lookups rather than empty ones, so the
  /// recognizer's guard short-circuits instead of running a full correction pass
  /// that cannot match anything. Most users have no custom words.
  var correctorVocabulary: CorrectorVocabulary = .empty {
    didSet { rebuildCorrectorLookupsIfNeeded() }
  }

  /// Lookups for `correctorVocabulary`, or `nil` when there is nothing to correct.
  private var correctorLookups: WordCorrector.Lookups?

  /// The generation `correctorLookups` was built for. **Optional, and that is
  /// load-bearing:** the seed `wireCustomWords` sends carries generation 0, and so
  /// does the `.empty` this property starts at, so comparing the incoming
  /// generation against the PREVIOUS VALUE's would treat a real vocabulary
  /// arriving at launch as a no-op change and drop it. Custom Words would then
  /// reach the preview only after the user edited them — never, for anyone whose
  /// vocabulary was already there. Comparing against what was actually BUILT
  /// starts at `nil`, which cannot collide with a real generation.
  private var builtLookupsGeneration: UInt64?

  /// Test seam, mirroring `WordCorrectionStep.lookupCacheBuilds`: how many times
  /// lookups have actually been built. Lets a test prove the seed vocabulary was
  /// picked up AND that a repeated generation does not rebuild.
  package private(set) var correctorLookupBuilds = 0

  /// Test seam: whether a correcting snapshot currently exists. Distinguishes
  /// "built, and there is something to correct" from "built nothing because the
  /// vocabulary is empty", which are different states with the same build count.
  package var hasCorrectorLookupsForTesting: Bool { correctorLookups != nil }

  private var sessionTask: Task<Void, Never>?
  /// In-flight preparation, shared by every session that arrives while it runs.
  ///
  /// Preparation is deliberately NOT owned by a session. First use of a language
  /// can download an Apple speech model, which takes as long as it takes; if a
  /// session owned that work, cancelling the recording would either abandon a
  /// half-finished download or leave the next session waiting behind it. Held
  /// separately, it survives the recording that triggered it, is never cancelled,
  /// and is shared rather than duplicated.
  private var preparationTask: Task<Bool, Never>?
  /// Bumped whenever the preview language changes, so a preparation still running
  /// for the old language cannot publish itself as the current one.
  private var preparationGeneration: UInt64 = 0
  /// Bumped once per recording. Every asynchronous hand-off is checked against it,
  /// because `isRunning` says "a recording is live" and not "THIS recording".
  private var sessionGeneration: UInt64 = 0
  private var isRunning = false

  init(
    readSamples: @escaping LivePreviewSampleReader,
    isEnabled: @escaping () -> Bool,
    languageMode: @escaping () -> LanguageMode,
    resolveEngine: @escaping LivePreviewEngineResolver
  ) {
    self.readSamples = readSamples
    self.isEnabled = isEnabled
    self.languageMode = languageMode
    self.resolveEngine = resolveEngine
  }

  // MARK: - Lifecycle

  /// Start or stop the preview for the current recording.
  ///
  /// Idempotent in both directions, deliberately: this is called from two places
  /// (the first overlay push in `RecordingStarter`, and every state-driven push in
  /// `DictationLifecycleCoordinator`), and a second start must not open a second
  /// analyzer. Returns immediately in all cases.
  func setRecording(_ recording: Bool) {
    if recording {
      guard !isRunning else { return }
      guard isEnabled() else {
        display = .off
        return
      }
      isRunning = true
      // Allocated HERE, synchronously, not inside the session task. `isRunning`
      // flips to true for the new recording immediately, so any window between
      // that and the generation bump is a window where a queued callback from the
      // PREVIOUS recording still matches and paints stale words. Locale resolution
      // and preparation are both awaits inside the task, so that window was real.
      sessionGeneration &+= 1
      display = .waiting
      startSession(generation: sessionGeneration)
    } else {
      guard isRunning else { return }
      isRunning = false
      let task = sessionTask
      sessionTask = nil
      task?.cancel()
      // **Dropped, not merely hidden.** This used to keep the last text on the
      // grounds that nothing renders it after a recording ends, which was true and
      // is not the point: the settings copy now tells the user the preview "is
      // discarded when the recording ends", and a claim a user reads before
      // enabling a feature has to be true of the code, not just of what is on
      // screen. Holding the transcript until the next recording made it false.
      //
      // Costs nothing it was buying: the old rationale only ever argued that
      // keeping it was harmless, never that anything needed it, and the next
      // `setRecording(true)` sets `.waiting` synchronously regardless.
      display = .off
    }
  }

  private func startSession(generation: UInt64) {
    sessionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runSession(generation: generation)
    }
  }

  private func runSession(generation: UInt64) async {
    // The engine decides both halves of this: whether it can run on this Mac at
    // all, and what to do with the user's language setting. Neither is a fact about
    // the preview feature, and an earlier draft that assumed Apple's answers would
    // have silently disabled a second engine on every Mac below macOS 26.
    let resolution = await resolveEngine(languageMode())
    guard isCurrent(generation) else { return }

    guard case .ready(let candidate) = resolution else {
      if case .blocked(let reason) = resolution {
        display = .unavailable(Self.sentence(for: reason))
      }
      return
    }

    // Say "getting ready" rather than "listening" while preparation runs. On first
    // use of a language that can mean downloading a speech model, and a pill
    // promising to listen while nothing appears is the exact impression this
    // feature exists to prevent.
    let alreadyPrepared = preparedEngine != nil && preparedKey == candidate.key
    if !alreadyPrepared { display = .unavailable(LivePreviewCopy.preparing) }

    guard await ensurePrepared(candidate), let engine = preparedEngine else {
      guard isCurrent(generation) else { return }
      display = .unavailable(LivePreviewCopy.notReady)
      await Self.log("not ready for \(candidate.key.engine)/\(candidate.key.commitment)")
      return
    }

    if Task.isCancelled { return }
    guard isCurrent(generation) else { return }
    display = .waiting

    // Diagnostics: transitions only, never per-update. The pill repaints several
    // times a second and logging each one would bury the log AND charge the main
    // actor for text nobody reads. `updates` is counted here and reported once.
    var updates = 0
    // `generation` is this recording's identity, allocated by `setRecording` before
    // any of the awaits above. Every asynchronous hand-off is checked against it,
    // because `isRunning` alone cannot tell "this recording" from "a recording".

    // The recognizer calls back from its own actor. Hop to the main actor and
    // publish so the 20 Hz pill read is a plain property read. The text arrives
    // already bounded (`LivePreviewTextBound`, applied at the producer).
    // Counted as it is PUBLISHED, never read back off `display` afterwards.
    // Reading `display` at the end of the session cannot work: stopping sets it to
    // `.off` before this task resumes, so the figure was structurally pinned at 0
    // and reported "heard nothing" for every recording including the ones that
    // worked. It was the only signal separating "ran and heard nothing" from "never
    // ran", so a permanently-zero counter made the two indistinguishable — the exact
    // question it existed to answer.
    let shownChars = ShownCharsBox()
    let publish: @Sendable (String) -> Void = { [weak self] text in
      Task { @MainActor in
        guard let self, self.isRunning, self.sessionGeneration == generation else { return }
        shownChars.record(text.count)
        self.display = .text(text)
      }
    }

    let session: any LivePreviewEngineSession
    do {
      // Read synchronously on the main actor at the moment the session opens, so
      // the session cannot start before the vocabulary reaches it.
      session = try await engine.openSession(lookups: correctorLookups, onText: publish)
    } catch {
      guard isCurrent(generation) else { return }
      display = .unavailable(LivePreviewCopy.notReady)
      await Self.log("session refused to start: \(error)")
      return
    }
    await Self.log(
      "session started, engine=\(candidate.key.engine) on=\(candidate.key.commitment)")

    await feedLoop(session: session) { updates += 1 }
    // Closes the resources THIS session owns, so it cannot reach a newer one.
    await session.end()
    // Reports what the PILL was actually given, so an empty preview is
    // distinguishable from a preview that ran and heard nothing. Those look
    // identical on screen and have completely different causes.
    await Self.log("session ended, feeds=\(updates) shownChars=\(shownChars.peak)")
  }

  /// Whether the recording that started this session is still the current one AND
  /// a recording is still live.
  ///
  /// Checked after every await that precedes a `display` write. Without the
  /// generation half, a session abandoned during locale resolution or model
  /// preparation resumes later and writes its own outcome over the pill of a
  /// recording that is already underway — "not ready" appearing over live words.
  ///
  /// **`isRunning` is the other half, and it became load-bearing when stopping
  /// started discarding the text.** Stopping cancels the session task and clears
  /// `display`, but does NOT bump the generation, because no newer recording has
  /// claimed one. Cancellation is cooperative: an await inside an Apple API can
  /// still return normally, after which every generation check passes and the
  /// resumed code writes its outcome over the `.off` that the stop just set. That
  /// resurrects state after the recording ended — at best "not ready" appearing on
  /// a pill nobody is using, at worst undoing the discard the settings copy
  /// promises. Checking both means "this recording, and it is still happening".
  private func isCurrent(_ generation: UInt64) -> Bool {
    isRunning && sessionGeneration == generation
  }

  /// Turn an engine's structured refusal into the sentence the user reads.
  ///
  /// **The mapping lives here, in the app shell, on purpose.** Engines report a
  /// reason; what the user is told is brand-governed copy with its own rules and its
  /// own frozen tests, and an engine module has no business owning it. Exhaustive by
  /// construction, so a new refusal reason cannot ship without someone deciding what
  /// it says.
  private static func sentence(for reason: LivePreviewUnavailability) -> String {
    switch reason {
    case .unsupportedSystem: return LivePreviewCopy.needsNewerMacOS
    case .unsupportedLanguage: return LivePreviewCopy.languageUnsupported
    case .installRequired(let languageName):
      return LivePreviewSettingsCopy.previewNeedsLanguagePack(languageName)
    }
  }

  /// One log seam so every preview line carries the same category and the whole
  /// limb can be grepped with `LIVE_PREVIEW`.
  private static func log(_ message: String) async {
    await AppLogger.shared.log("LIVE_PREVIEW \(message)", category: "LivePreview")
  }

  /// Make sure a recognizer for `locale` exists and is ready, returning whether it
  /// is. Never makes one recording's preview wait on another recording.
  ///
  /// A caller arriving while preparation is in flight awaits THAT task rather than
  /// starting a second one, so several recordings during one model download cause
  /// one download and wait only on it. That distinction is the whole point: waiting
  /// on the work is unavoidable, waiting on an unrelated recording's task is not,
  /// and an earlier draft did the second — one slow first-run download would have
  /// silently disabled the preview for every recording after it.
  ///
  /// A cancelled session that is parked here simply returns and checks
  /// `Task.isCancelled`; the preparation continues, which is what makes the NEXT
  /// recording fast.
  ///
  /// **Dropping a reference to a task does not stop the task.** Switching language
  /// mid-preparation used to clear `preparationTask` and move on, leaving the old
  /// language's task running with an unconditional write to `preparedEngine` and
  /// `preparedKey` at the end of it. It could land after the new language's task
  /// and hand the next recording a German recognizer while every check said English
  /// was ready. The generation below is what makes the write conditional; review
  /// caught the original.
  /// Rebuild the cached lookups and hand them to whatever recognizer exists.
  ///
  /// Not availability-gated: `CustomWordsPropagator` writes the vocabulary on
  /// every Mac we support, and gating the STORE on macOS 26 would mean a machine
  /// that later prepares a recognizer has nothing to seed it with.
  /// Rebuild the cached lookups. Nothing is PUSHED anywhere: the snapshot is read
  /// synchronously at `startSession` and handed in as an argument, so there is no
  /// installation step that a session can outrun.
  ///
  /// Not availability-gated: `CustomWordsPropagator` writes the vocabulary on
  /// every Mac we support, and gating the STORE on macOS 26 would leave a machine
  /// that later prepares a recognizer with nothing to hand it.
  private func rebuildCorrectorLookupsIfNeeded() {
    guard builtLookupsGeneration != correctorVocabulary.generation else { return }
    builtLookupsGeneration = correctorVocabulary.generation
    correctorLookupBuilds += 1
    correctorLookups =
      correctorVocabulary.terms.isEmpty
      ? nil : WordCorrector.buildLookups(words: correctorVocabulary.terms)
  }

  private func ensurePrepared(_ candidate: LivePreviewEngineCandidate) async -> Bool {
    let key = candidate.key
    if preparedEngine != nil, preparedKey == key { return true }

    // A change of engine OR language invalidates the in-flight preparation for the
    // old one. The generation bump is what actually invalidates it; clearing the
    // reference only stops US waiting on it.
    if preparedKey != key {
      preparationGeneration &+= 1
      preparationTask = nil
      preparedEngine = nil
    }

    if let existing = preparationTask { return await existing.value }

    let generation = preparationGeneration
    let make = candidate.makeEngine
    let task = Task<Bool, Never> { [weak self] in
      let fresh = make()
      do {
        try await fresh.prepare()
      } catch {
        return false
      }
      guard let self else { return false }
      return await MainActor.run {
        // Publish only if the engine or language has not moved on while this ran.
        guard self.preparationGeneration == generation else { return false }
        self.preparedEngine = fresh
        self.preparedKey = key
        return true
      }
    }
    preparationTask = task
    preparedKey = key
    let ok = await task.value
    // Let a later recording retry, but only if nothing newer has already claimed
    // the slot — clearing unconditionally would discard a live preparation.
    if !ok, preparationGeneration == generation { preparationTask = nil }
    return ok
  }

  /// Hand newly captured audio to the recognizer until the recording ends.
  ///
  /// Reads `getSamplesSnapshot(fromIndex:)`, the same incremental accessor the
  /// crash-recovery spool uses. `fed` starts at whatever the buffer already holds
  /// so a late start never replays the beginning at speed, and it re-syncs if the
  /// count goes backwards, which is what a buffer reset between recordings looks
  /// like from here.
  private func feedLoop(
    session: any LivePreviewEngineSession,
    onFeed: @escaping () -> Void
  ) async {
    // `Int.max`, not 0, and the difference is not cosmetic. `getSamplesSnapshot`
    // clamps `fromIndex` to the total and returns an EMPTY slice when the clamped
    // index reaches it, so this reads the count without copying anything. Asking
    // from 0 would copy the entire captured buffer — on a long recording that is
    // hundreds of megabytes allocated and copied ON THE MAIN ACTOR, by a limb, to
    // obtain a number it then uses and discards the samples of.
    var fed = await readSamples(Int.max).totalCount

    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(Self.feedIntervalMs))
      if Task.isCancelled { break }
      let snapshot = await readSamples(fed)
      if snapshot.totalCount < fed {
        // The capture buffer was cleared under us (recording ended, or the next
        // one began). Re-sync rather than going permanently silent, which is what
        // an unconditional high-water mark would do here.
        fed = snapshot.totalCount
        continue
      }
      guard !snapshot.samples.isEmpty else { continue }
      fed = snapshot.totalCount
      onFeed()
      await session.feed(snapshot.samples)
    }
  }

}

/// User-facing copy for the preview's non-running states. One home, so a change
/// is a conscious act. No em-dashes or en-dashes (brand rule).
/// The type name keeps "LivePreview" because that is what the feature is called
/// internally; the STRINGS avoid "live" for the reason given on
/// `LivePreviewSettingsCopy.sectionHeader`, and a test enforces it.
enum LivePreviewCopy {
  static let needsNewerMacOS = "On-screen preview needs macOS 26."
  static let languageUnsupported = "On-screen preview does not support this language yet."
  static let notReady = "On-screen preview is not ready yet."
  /// Shown while the recognizer is being prepared, which on first use of a language
  /// can include downloading an Apple speech model.
  static let preparing = "Getting the preview ready..."
  /// Shown in the pill while the preview is running but has not heard words yet.
  static let listening = "Listening..."
}
