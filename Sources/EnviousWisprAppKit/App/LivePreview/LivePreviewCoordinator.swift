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

  /// The POST-OPEN work of the session most recently cancelled, kept until it has
  /// actually finished tearing down.
  ///
  /// **Cancellation is a request, not a completion, and that is the fourth axis
  /// of this PR's release findings.** Four rounds swept WHICH entry point
  /// releases and WHEN it fires; all four cancelled `sessionTask` and moved on.
  /// A cancelled task still holds its engine and its session as locals until it
  /// reaches `session.end()`, so the next recording could open a second session
  /// over the same cached WhisperKit instance while the previous one was still
  /// inside its final decode — the very thing `PreviewSessionTurnover` and the
  /// joinable `end()` exist to prevent, reached from above them.
  ///
  /// `startSession` awaits this before running. The heart still never waits: it
  /// is the NEW preview that waits for the OLD preview, entirely inside the limb.
  ///
  /// **Only the post-open work, never the whole session task**, and the
  /// difference is a wedge. A task cancelled during preparation is suspended on
  /// `preparationTask.value`, which cancelling does not interrupt — model warm-up
  /// is an unstructured task by design, so that a later recording can adopt it.
  /// Draining the whole task would make every future preview wait on a warm-up
  /// that `releasePreparedEngine` has already invalidated by generation, so a
  /// slow or hung load would wedge the preview permanently after one
  /// disable/enable. There is nothing to drain before a session exists: no
  /// session means no decode to collide with.
  private var drainingTeardown: Task<Void, Never>?

  /// The live session's own feed-and-teardown task, registered the instant the
  /// session opens so a cancel always has something precise to drain.
  private var liveTeardown: Task<Void, Never>?
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
        // **Release the prepared engine too, not just the display (#2108).**
        //
        // This slot is deliberately kept across recordings so a second press does
        // not pay preparation again, and it is otherwise cleared only when the
        // candidate KEY changes. Turning the preview off changes no key, so an
        // engine prepared before the user disabled it stayed resident for the
        // life of the process. That cost nothing while Apple's engine was the
        // only one — it holds a locale — but the universal engine holds a loaded
        // WhisperKit model, so the same slot now pins roughly 50-60 MB for a
        // feature the user has switched off. Cloud review caught it.
        //
        // Dropping the reference is the whole release: the engine owns its
        // runtime, which owns the model, so ARC unloads the chain. Clearing the
        // key with it means the next enable rebuilds rather than resurrecting a
        // half-released engine.
        releasePreparedEngine()
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
      cancelSessionTask()
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
    // Wait for the PREVIOUS session's teardown to finish before this one opens.
    // See `drainingTeardown`: a cancelled task still owns its engine and its
    // session until it reaches `session.end()`.
    let predecessor = drainingTeardown
    drainingTeardown = nil
    sessionTask = Task { @MainActor [weak self] in
      await predecessor?.value
      // Re-check AFTER the wait: the recording this task was started for may
      // already be over, and opening a session for it then would be the stale
      // repaint `generation` exists to stop.
      guard let self, self.isCurrent(generation) else { return }
      await self.runSession(generation: generation)
    }
  }

  /// Cancel the live session task and REMEMBER it until it has drained.
  ///
  /// The `guard` is what keeps a single slot sufficient: a second cancel needs a
  /// `sessionTask`, and only `startSession` creates one — and that consumes the
  /// pending drain first. So two cancels can never race for this slot.
  private func cancelSessionTask() {
    guard let task = sessionTask else { return }
    sessionTask = nil
    task.cancel()
    // The inner task is unstructured, so the outer cancel does not reach it.
    // Cancel it explicitly and drain THAT — see `drainingTeardown` for why the
    // whole session task is the wrong unit.
    guard let live = liveTeardown else { return }
    liveTeardown = nil
    live.cancel()
    drainingTeardown = live
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
        // **A blocked engine must not stay cached (#2108).**
        //
        // Found by enumerating the class rather than by review: five of this
        // PR's findings were "the bound is downstream of the growth" and three
        // were "the release misses a path", so the remaining paths were swept
        // exhaustively instead of waiting for the next round to surface one.
        //
        // Every refusal reason can persist for the rest of a session — the user
        // turns live transcription on, or locks a language the model does not
        // cover, or removes the model. The prepared engine holds a loaded 217 MB
        // model that cannot serve ANY recording while the reason holds, so
        // keeping it is a pure cost. Re-preparing when the block clears costs one
        // model load, which is what the first preparation cost anyway.
        //
        // Apple's engine made this invisible: a blocked Apple engine holds a
        // locale.
        releasePreparedEngine()
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
    // **Registered with NO await between this and the open.** A cancel landing in
    // such a gap would leave a live session undrained, and worse, this inner task
    // does not inherit the outer task's cancellation — so it would happily feed a
    // session the user had already stopped. The currency check inside is what
    // makes a late arrival end the session instead of running it.
    let live = Task { @MainActor [weak self] in
      var updates = 0
      if let self, self.isCurrent(generation) {
        await self.feedLoop(session: session) { updates += 1 }
      }
      // Closes the resources THIS session owns, so it cannot reach a newer one.
      // Runs on every path, including the abandoned one.
      await session.end()
      // Reports what the PILL was actually given, so an empty preview is
      // distinguishable from a preview that ran and heard nothing. Those look
      // identical on screen and have completely different causes.
      await Self.log("session ended, feeds=\(updates) shownChars=\(shownChars.peak)")
    }
    // **Register ONLY while this recording is still the current one.** A session
    // opened for an ABANDONED recording must never replace the live
    // registration: on completion it clears the slot, and the CURRENT preview is
    // then unregistered — so a later stop cannot cancel its feed loop and it
    // decodes on across recordings. The window is real because disabling the
    // preview releases the prepared engine, so the replacement gets a different
    // recognizer with its own turnover lock; the adapter cannot close it from
    // below. The task above still ends its session on this path.
    if isCurrent(generation) { liveTeardown = live }

    await Self.log(
      "session started, engine=\(candidate.key.engine) on=\(candidate.key.commitment)")
    await live.value
    // Only clear the slot if it is still ours: a newer session may already own it.
    if liveTeardown == live { liveTeardown = nil }
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
    case .modelNotInstalled: return LivePreviewCopy.previewModelNotInstalled
    case .heartIsStreaming: return LivePreviewCopy.heartIsStreaming
    }
  }

  /// Release the cached engine because the SETTING changed, not because a
  /// recording started.
  ///
  /// The release inside `setRecording(true)` only fires on the next recording. A
  /// user who finishes a recording and then turns the preview off without
  /// recording again never reaches it, so the model stayed resident indefinitely
  /// — the exact leak the release was added to fix, in the commoner order of
  /// events. Cloud review caught it after the first fix.
  ///
  /// Wired from `PipelineSettingsSync`'s `livePreviewEnabled` case, which is the
  /// one place that learns a setting moved.
  func releaseForDisabledSetting() {
    guard !isEnabled() else { return }
    // **Tear down the ACTIVE session first, not just the cached slot.**
    //
    // Switching the preview off mid-recording used to clear only the cache:
    // `runSession` still held the engine and session as locals, `sessionTask`
    // kept feeding audio, and a later `onText` could repaint over `.off`. So the
    // model stayed loaded AND DECODING until the recording ended, for a feature
    // the user had just turned off — the worst version of this leak, because it
    // is also the visible one.
    //
    // Mirrors the stop path exactly rather than approximating it: same order,
    // same fields. Half-porting a teardown is what produced three separate
    // release findings on this PR already.
    if isRunning {
      isRunning = false
      cancelSessionTask()
    }
    releasePreparedEngine()
    display = .off
  }

  /// Drop the prepared engine and everything it holds.
  ///
  /// Separate from the key-change path because the two have different triggers
  /// and the same remedy: a key change means "prepare a different engine", this
  /// means "prepare none". Both must clear the key, or a later enable would find
  /// a matching key with no engine behind it.
  /// Whether an engine is currently cached in the slot above.
  ///
  /// A test seam, `package` rather than `internal` so the test module reaches it
  /// on a plain import. It exists because the alternative — observing a weak
  /// reference to the engine — measures the whole retention graph: an in-flight
  /// preparation task and a draining session task each hold the engine as a
  /// local, so a weak-reference assertion fails identically whether the slot is
  /// still full or the observation was simply early. This asserts the property
  /// the fix actually changes.
  package var hasPreparedEngineForTests: Bool { preparedEngine != nil }

  /// Whether a session is open AND its teardown is registered — the precondition
  /// for the coordinator's drain.
  ///
  /// A test seam for the same reason as the one above: a test that waits only for
  /// "the engine opened a session" can act during the window between
  /// `openSession` returning and this registration, and would then be asserting a
  /// guarantee this layer does not make. The adapter's own turnover lock covers
  /// that window, because it records the handle before releasing.
  package var hasLiveSessionForTests: Bool { liveTeardown != nil }

  private func releasePreparedEngine() {
    // **Bump the generation FIRST.** Clearing the task reference does not cancel
    // the task: a `prepare()` still suspended when the user disables the preview
    // resumes, sees an unchanged `preparationGeneration`, and writes its engine
    // back into `preparedEngine` — so the model becomes resident again AFTER this
    // method returns, which is the exact bug this method exists to fix. The
    // generation is the publish guard those completions check, so raising it is
    // what actually invalidates them. Cloud review caught this in the first fix.
    preparationGeneration &+= 1
    preparationTask = nil
    preparedEngine = nil
    preparedKey = nil
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
  /// #2108. The universal preview model has not been downloaded. Names the
  /// action rather than the fault: nothing is broken, the user has simply not
  /// chosen to download it yet.
  static let previewModelNotInstalled =
    "Download the preview model in Settings to see words appear."
  /// #2108 Gate C. Live transcription already decodes continuously while you
  /// speak, and a second decoder would slow it by half (measured). Says what is
  /// happening rather than naming a setting the reader has to go and find.
  static let heartIsStreaming = "On-screen preview pauses while live transcription is on."
}
