import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation

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
@MainActor
final class LivePreviewCoordinator {

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

  private let audioCapture: any AudioCaptureInterface
  private let isEnabled: () -> Bool
  private let languageMode: () -> LanguageMode

  /// The prepared recognizer, kept across recordings so the second press does not
  /// pay preparation again. `Any` because the type cannot be named below macOS 26.
  private var preparedRecognizer: Any?
  /// The locale `preparedRecognizer` was prepared for, so a language change
  /// rebuilds it.
  private var preparedLocale: Locale?

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
    audioCapture: any AudioCaptureInterface,
    isEnabled: @escaping () -> Bool,
    languageMode: @escaping () -> LanguageMode
  ) {
    self.audioCapture = audioCapture
    self.isEnabled = isEnabled
    self.languageMode = languageMode
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
      // The last text is deliberately left in `display` rather than blanked. The
      // polishing pill is a different view and never renders it, so nothing shows
      // it; and the next `setRecording(true)` sets `.waiting` synchronously, before
      // the new panel is created on the following run loop pass, so a new recording
      // can never open showing the previous one's words.
    }
  }

  private func startSession(generation: UInt64) {
    sessionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      guard #available(macOS 26.0, *) else {
        self.display = .unavailable(LivePreviewCopy.needsNewerMacOS)
        return
      }
      await self.runSession(generation: generation)
    }
  }

  @available(macOS 26.0, *)
  private func runSession(generation: UInt64) async {
    let mode = languageMode()
    let code = Self.previewLanguageCode(mode)
    // Both the setting and the code derived from it. "Why is there no preview in
    // my language" is answerable from this one line: it distinguishes a user on
    // Auto-detect (where we guess from the system) from one who locked a language
    // Apple cannot transcribe, and those have different answers.
    await Self.log("resolving language, mode=\(mode) code=\(code)")
    guard let locale = await ApplePreviewRecognizer.resolveLocale(code: code) else {
      guard isCurrent(generation) else { return }
      display = .unavailable(LivePreviewCopy.languageUnsupported)
      await Self.log("no recognizer locale for language=\(code)")
      return
    }
    guard isCurrent(generation) else { return }

    // Say "getting ready" rather than "listening" while preparation runs. On first
    // use of a language that can mean downloading an Apple speech model, and a pill
    // promising to listen while nothing appears is the exact impression this
    // feature exists to prevent.
    let alreadyPrepared = preparedRecognizer is ApplePreviewRecognizer && preparedLocale == locale
    if !alreadyPrepared { display = .unavailable(LivePreviewCopy.preparing) }

    guard await ensurePrepared(for: locale),
      let recognizer = preparedRecognizer as? ApplePreviewRecognizer
    else {
      guard isCurrent(generation) else { return }
      display = .unavailable(LivePreviewCopy.notReady)
      await Self.log("not ready for locale=\(locale.identifier(.bcp47))")
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
    let publish: @Sendable (String) -> Void = { [weak self] text in
      Task { @MainActor in
        guard let self, self.isRunning, self.sessionGeneration == generation else { return }
        self.display = .text(text)
      }
    }

    let session: ApplePreviewRecognizer.Session
    do {
      session = try await recognizer.startSession(onText: publish)
    } catch {
      guard isCurrent(generation) else { return }
      display = .unavailable(LivePreviewCopy.notReady)
      await Self.log("session refused to start: \(error)")
      return
    }
    await Self.log("session started, locale=\(locale.identifier(.bcp47))")

    await feedLoop(into: recognizer, session: session) { updates += 1 }
    // Closes the resources THIS session owns, so it cannot reach a newer one.
    await recognizer.endSession(session)
    // Reports what the PILL received, so an empty preview is distinguishable from
    // a preview that ran and heard nothing. Those look identical on screen and
    // have completely different causes.
    let shown: Int
    if case .text(let t) = display { shown = t.count } else { shown = 0 }
    await Self.log("session ended, feeds=\(updates) shownChars=\(shown)")
  }

  /// Whether the recording that started this session is still the current one.
  ///
  /// Checked after every await that precedes a `display` write. Without it, a
  /// session abandoned during locale resolution or model preparation resumes later
  /// and writes its own outcome over the pill of a recording that is already
  /// underway — "not ready" appearing over live words.
  private func isCurrent(_ generation: UInt64) -> Bool {
    sessionGeneration == generation
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
  /// language's task running with an unconditional write to `preparedRecognizer`
  /// and `preparedLocale` at the end of it. It could land after the new language's
  /// task and hand the next recording a German recognizer while every check said
  /// English was ready. The generation below is what makes the write conditional;
  /// review caught the original.
  @available(macOS 26.0, *)
  private func ensurePrepared(for locale: Locale) async -> Bool {
    if preparedRecognizer is ApplePreviewRecognizer, preparedLocale == locale { return true }

    // A language change invalidates the in-flight preparation for the old one. The
    // generation bump is what actually invalidates it; clearing the reference only
    // stops US waiting on it.
    if preparedLocale != locale {
      preparationGeneration &+= 1
      preparationTask = nil
      preparedRecognizer = nil
    }

    if let existing = preparationTask { return await existing.value }

    let generation = preparationGeneration
    let task = Task<Bool, Never> { [weak self] in
      let fresh = ApplePreviewRecognizer(locale: locale)
      do {
        try await fresh.prepare()
      } catch {
        return false
      }
      guard let self else { return false }
      return await MainActor.run {
        // Publish only if the language has not moved on while this ran.
        guard self.preparationGeneration == generation else { return false }
        self.preparedRecognizer = fresh
        self.preparedLocale = locale
        return true
      }
    }
    preparationTask = task
    preparedLocale = locale
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
  @available(macOS 26.0, *)
  private func feedLoop(
    into recognizer: ApplePreviewRecognizer,
    session: ApplePreviewRecognizer.Session,
    onFeed: @escaping () -> Void
  ) async {
    // `Int.max`, not 0, and the difference is not cosmetic. `getSamplesSnapshot`
    // clamps `fromIndex` to the total and returns an EMPTY slice when the clamped
    // index reaches it, so this reads the count without copying anything. Asking
    // from 0 would copy the entire captured buffer — on a long recording that is
    // hundreds of megabytes allocated and copied ON THE MAIN ACTOR, by a limb, to
    // obtain a number it then uses and discards the samples of.
    var fed = await audioCapture.getSamplesSnapshot(fromIndex: Int.max).totalCount

    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(Self.feedIntervalMs))
      if Task.isCancelled { break }
      let snapshot = await audioCapture.getSamplesSnapshot(fromIndex: fed)
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
      await recognizer.feed(snapshot.samples, session: session)
    }
  }

  // MARK: - Locale

  /// The ISO 639-1 code to preview in.
  ///
  /// Apple's recognizer must commit to one language up front, so Auto-detect has
  /// no answer to give it. The system language is the honest guess: it is what the
  /// user's Mac is set to, and being wrong costs a preview rather than a transcript.
  ///
  /// Only the POLICY lives here. Turning a bare code into one of the recognizer's
  /// 54 locales is a vendor question, answered by the vendor in
  /// `ApplePreviewRecognizer.resolveLocale(code:)`.
  static func previewLanguageCode(_ mode: LanguageMode) -> String {
    switch mode {
    case .locked(let code): return code
    case .auto: return Locale.current.language.languageCode?.identifier ?? "en"
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
