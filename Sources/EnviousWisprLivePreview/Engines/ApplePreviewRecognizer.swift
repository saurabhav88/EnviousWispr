@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Speech

/// The live-preview recognizer: Apple's on-device `SpeechAnalyzer` driving a
/// `DictationTranscriber`, used for DISPLAY ONLY (#1988).
///
/// This is a limb in the strictest sense. Nothing it produces reaches the
/// clipboard: the pasted text still comes from the shipped Parakeet/WhisperKit
/// path, decoded from the whole recording after the key is released, and then
/// through custom words, the deterministic layer and polish. This engine exists
/// so the user can SEE that we heard them while they are still talking.
///
/// ## Why a second recognizer rather than reading our own engine's partials
///
/// Measured on #1988 and recorded on the issue. Parakeet's `confirmedTranscript`
/// cannot populate before `minContextForConfirmation: 10.0` seconds, so a preview
/// fed from it is BLANK for the first 10-13 seconds of every dictation. It also
/// required Background transcription to be ON, which our own shipped help panel
/// tells Parakeet users to leave OFF (3.7% vs 2.0% word error). Seeing your words
/// would have cost accuracy. Every competitor that ships this feature runs a
/// separate display recognizer for the same reason, including FluidVoice, which
/// uses Parakeet exactly as we do and still ships a separate realtime provider.
///
/// ## Why THIS engine
///
/// Screened against five candidates over 30 clips, then two live human trials and
/// a five-language panel (#1988 comments). It ships zero bytes (the model is in
/// the OS, shared with system dictation), covers 33 languages, and formats numbers,
/// dates, addresses and emails inline — the trial's deciding factor, because
/// watching `two zero three nine five four` crawl across the pill reads as the
/// software failing even though the pasted result is correct.
///
/// Its cost is the macOS 26 floor, which is why the setting is disabled below that.
///
/// ## Traps, all of which cost real time to find
///
/// 1. A `DictationTranscriber` belongs to exactly ONE `SpeechAnalyzer`. Handing the
///    same instance to a second one crashes inside `setWorkers(for:reusingFrom:)`
///    with EXC_BREAKPOINT and no catchable error, so every session builds a fresh
///    module.
/// 2. `finalizeAndFinishThroughEndOfInput()` on an analyzer that never received
///    input waits forever. Only finalize when audio was actually fed.
/// 3. Skipping `bestAvailableAudioFormat` crashes inside Apple's framework with
///    EXC_BREAKPOINT and no error, which reads like a caller bug.
/// 4. Installing a language is NOT the same as claiming it. See
///    `reserveLocale(_:)`.
@available(macOS 26.0, *)
actor ApplePreviewRecognizer: LivePreviewEngine {

  /// 16 kHz mono float — the format `AudioCaptureManager` already converts every
  /// captured buffer to (`AudioCaptureManager.targetSampleRate`). Feeding the
  /// preview the same samples the transcription path stores means the two can
  /// never disagree about what the microphone heard.
  private static let captureSampleRate: Double = 16000

  /// How many 100 ms audio chunks may wait for the analyzer before the oldest are
  /// dropped. Fifty is five seconds, comfortably past the ~210-290 ms cadence Apple
  /// was measured at, so a healthy stream never reaches it and only a genuine stall
  /// does.
  private static let maxQueuedChunks = 50

  private let locale: Locale

  private var targetFormat: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var sourceFormat: AVAudioFormat?

  /// The only session state this actor keeps. Everything else a session owns lives
  /// on the `Session` value the caller holds.
  ///
  /// **Three review rounds found races here, all the same shape, because the
  /// analyzer, continuation and collector used to be actor FIELDS.** An actor
  /// serializes calls but is reentrant at every `await`, so any operation that
  /// suspended could come back to fields a newer session had replaced: a teardown
  /// clearing the live session's analyzer, a superseded start leaking its own, a
  /// stale feed pushing audio into the wrong stream. Each was patchable with one
  /// more token check, and a third round proved that was the wrong fix.
  ///
  /// With per-session values there is nothing shared to overwrite. Every operation
  /// acts on the resources it was handed, so it cannot touch another session's even
  /// if it wanted to, and this counter exists only to answer "is this session still
  /// the current one" for the caller's benefit.
  private var currentToken: UInt64 = 0

  init(locale: Locale) {
    self.locale = locale
  }

  // MARK: - Preparation

  /// Claim the locale and resolve the audio format. Throws so the caller can
  /// degrade; it is never called from the heart.
  ///
  /// **No `SFSpeechRecognizer` authorization call, and no
  /// `com.apple.security.personal-information.speech-recognition` entitlement:
  /// this path needs neither. MEASURED, not assumed** — a standalone probe ran
  /// this exact stack (reserve, `DictationTranscriber`, `SpeechAnalyzer`, real
  /// audio, real text out) under three signatures: ad-hoc unhardened, self-signed
  /// with hardened runtime, and the real Developer ID cert with hardened runtime
  /// and this app's shipping entitlements. All three transcribed, with
  /// `SFSpeechRecognizer.authorizationStatus()` reporting `notDetermined`
  /// throughout — never requested, never granted. The legacy authorization gate
  /// gates the legacy recognizer, which could ship audio to Apple's servers; this
  /// analyzes on-device audio the app already holds microphone permission for.
  ///
  /// Recorded because a review round raised the opposite as a P1, reasoning by
  /// analogy from the Contacts case (#636), where a usage string without the
  /// matching entitlement failed SILENTLY on hardened runtime. That analogy is
  /// sound and the conclusion is still wrong, so the measurement lives here
  /// rather than in a session log. `NSSpeechRecognitionUsageDescription` stays in
  /// Info.plist: it is not what grants access, but macOS terminates an app that
  /// touches a protected class without one, and that is cheap insurance against a
  /// future OS tightening this.
  /// Re-measure before contradicting: `scratchpad/speechprobe/` in the #1988
  /// session, or rebuild the probe from this doc comment.
  ///
  /// **This method MUST NOT download, install, remove or repair model bytes (#2080).** It opens
  /// and warms what is already installed, nothing more.
  ///
  /// It used to call `downloadAndInstall()` right here, so pressing the record key could start an
  /// unannounced ~140 MB download. The user asked to dictate; they did not ask for that. Founder
  /// directive 2026-08-15: pack installation is the user's action, taken deliberately from the
  /// Live Preview settings page.
  ///
  /// A missing pack is now reported by the RESOLVER as `.blocked(.installRequired)` before this
  /// is ever reached, so the pill can say which language needs downloading instead of the user
  /// waiting on a silent transfer. `ApplePackCatalog` is the only thing in this module that
  /// installs, and only when asked.
  func prepare() async throws {
    // **Registered for the whole warm-up, not merely reserved.** An unregistered claim is
    // evictable, so with the five slots full a download starting now could release this locale
    // while `prepareToAnalyze` is still suspended on it — preparation then fails for a pack that
    // is present. Registering protects it; the single `do/catch` below is what keeps the balance
    // honest, because `prepare()` has five exits and an earlier version that registered here
    // leaked one per prepared language.
    try await Self.acquireLocaleForSession(locale)
    let claimedTag = locale.identifier(.bcp47)
    do {
      try await performPrepare()
    } catch {
      await Self.endUse(claimedTag)
      throw error
    }
    // **Give the claim BACK, system reservation included.**
    //
    // Keeping it was a warm-up optimisation, and it was the source of every eviction race in this
    // file: each language you previewed left a claim behind, so a multilingual user reached
    // Apple's five-slot cap through ordinary use, and from then on every new claim had to evict
    // somebody else's. Recordings already return theirs when they end; warm-up was the one path
    // that did not.
    //
    // What this establishes, exactly: held claims are now proportional to work IN FLIGHT rather
    // than to the number of languages ever previewed. Before, previewing your sixth language was
    // enough to reach the cap and stay there for the rest of the process; now nothing accumulates
    // across recordings. Three code paths register a claim — warm-up (here), `openSession`, and
    // the catalogue's download — each releasing on every exit.
    //
    // NOT established, and deliberately not claimed: that the cap of five is now unreachable. That
    // would need a bound on concurrent work, and there is none at this layer — the one-download-
    // at-a-time rule lives in the settings model, not here. Eviction therefore remains a real path
    // and keeps its tests; this change removes the accumulation that made it routine.
    //
    // The cost is one inventory call at `openSession`, which already re-acquires anyway.
    await Self.endUse(claimedTag)
  }

  /// The warm-up itself. Runs inside `prepare()`'s registration.
  private func performPrepare() async throws {

    // Built to negotiate the audio format, NOT to install anything. Constructing a
    // `DictationTranscriber` is inert; only `assetInstallationRequest` + `downloadAndInstall`
    // fetch bytes, and neither appears in this method any more.
    let probe = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)

    guard
      let source = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Self.captureSampleRate,
        channels: 1, interleaved: false)
    else {
      throw LivePreviewError.audioFormatUnavailable
    }
    sourceFormat = source

    guard
      let target = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [probe], considering: source)
    else {
      throw LivePreviewError.audioFormatUnavailable
    }
    targetFormat = target

    // Warm with a THROWAWAY of the same preset. `prepareToAnalyze` pays the
    // system-level spin-up that the first real session would otherwise be charged
    // for — measured on the benchmark corpus as the difference between a first
    // clip that looks broken (3573 ms to first text) and one that does not (630 ms).
    // Deliberately never finalized: see trap 2.
    let warmModule = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    let warmAnalyzer = SpeechAnalyzer(modules: [warmModule])
    do {
      try await warmAnalyzer.prepareToAnalyze(in: target)
    } catch {
      // The FOURTH abandoned-analyzer site: preparation throwing leaves before the
      // cancel below. Preparation failure is retried on a later recording, so each
      // failure would strand another analyzer. `defer` cannot be used here because
      // the cleanup is async.
      await warmAnalyzer.cancelAndFinishNow()
      throw error
    }
    // The THIRD abandoned-analyzer site, and the one a sweep of the previous two
    // missed. Warm-up runs on first use and on every language change, and an
    // analyzer that is simply dropped retains its analysis and model resources, so
    // a user switching languages a few times accumulates them. `cancelAndFinishNow`
    // rather than a finalize: trap 2's hang applies to FINALIZING an analyzer that
    // received no input, not to cancelling one.
    await warmAnalyzer.cancelAndFinishNow()
  }

  /// Claim a locale for this process before transcribing in it.
  ///
  /// **Installing is not provisioning, and skipping this does not fail at install.**
  /// The installer reports success and `installedLocales` lists the language; the
  /// failure arrives later at transcription as "No GeneralASR asset for language
  /// de", which reads as a missing download and sends the investigation the wrong
  /// way. Cost three rounds on #1988 before it was understood.
  ///
  /// `maximumReservedLocales` is 5 on macOS 26.6 and exceeding it is a runtime
  /// refusal (`SFSpeechError` code 11), so a sixth claim evicts the oldest rather
  /// than throwing. The reservation is per-app and does not survive the process.
  /// **Serialized as a whole, because read/evict/reserve is a TRANSACTION.** Two callers share
  /// it now — a recording claiming the language it is about to transcribe, and the settings page
  /// claiming one it is about to download — and pressing Download does not stop the record key
  /// working. Both suspend three times inside here, so without the lock both can act on the same
  /// five-slot reading, both decide to evict, or one reserve into a table the other just filled
  /// and take Apple's refusal while capacity was recoverable. Whoever loses fails silently: no
  /// preview, or a download that did not happen.
  ///
  /// The lock is held ACROSS the suspensions. An actor would not do — see `LocaleReservations`
  /// for why reentrancy makes actor isolation the wrong tool for this specific job.
  ///
  /// **Reserving and registering the USE are ONE step, both under the lock.** A claim taken and
  /// then evicted before it is consumed is worth nothing, and the lock cannot stay held across a
  /// 30-second download, so the registration is what protects it afterwards. Registering after
  /// unlocking would leave the claim reading as unused for exactly as long as it takes the next
  /// caller through the lock to evict it — the same defect as no registration at all, only
  /// harder to see. Doing both here means no caller can forget the pairing.
  ///
  /// **Every caller must pair this with `LocaleReservations.shared.endUse`**, and release the
  /// system reservation only when that returns zero.
  package static func reserveLocale(_ locale: Locale) async throws {
    await LocaleReservations.shared.acquire()
    do {
      try await performReservation(locale)
    } catch {
      await LocaleReservations.shared.release()
      throw error
    }
    await LocaleReservations.shared.release()
  }

  /// Reserve AND register a long-lived use, in ONE locked step. **Caller MUST pair this with
  /// `endUse`.**
  ///
  /// **Two entry points, because one of them cannot be balanced safely.** `prepare()` leaves
  /// through five exits (three guards, a catch, and the end), so making IT register a use meant
  /// balancing all five — and the version that tried leaked one registration per prepared
  /// language, monotonically, until the registry considered everything in use and the eviction
  /// protection silently degraded to its fallback. Splitting the API makes that leak
  /// unexpressible rather than handled: `reserveLocale` registers nothing and needs no pairing,
  /// and only a caller with a clear end (a session, a download) takes the registering variant.
  ///
  /// Registration stays INSIDE the lock, which is the whole reason this is not two calls: between
  /// an unlocked reserve and a later register, the claim reads as unused and the next caller
  /// through the lock can evict it.
  ///
  /// A claim taken by `reserveLocale` may therefore be evicted before it is used. That is
  /// acceptable: it is a warm-up optimisation, and every consumer that actually depends on it
  /// takes it again here.
  package static func acquireLocaleForSession(_ locale: Locale) async throws {
    await LocaleReservations.shared.acquire()
    do {
      try await performReservation(locale)
      await LocaleReservations.shared.beginUse(locale.identifier(.bcp47))
    } catch {
      await LocaleReservations.shared.release()
      throw error
    }
    await LocaleReservations.shared.release()
  }

  /// The transaction itself. Runs only under `LocaleReservations`' lock.
  private static func performReservation(_ locale: Locale) async throws {
    let wanted = locale.identifier(.bcp47)
    let already = await AssetInventory.reservedLocales
    if already.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
    if already.count >= AssetInventory.maximumReservedLocales {
      // Never evict a claim someone is still using. Apple's inventory knows only "reserved or
      // not", so this asks the one thing that knows "still needed" — otherwise the sixth
      // download can take the language the current recording is transcribing, and the preview
      // dies with a missing-asset error that reads as a missing download.
      let candidates = await LocaleReservations.shared.evictable(
        from: already.map { $0.identifier(.bcp47) })
      if let victim = candidates.first {
        _ = await AssetInventory.release(reservedLocale: Locale(identifier: victim))
      }
    }
    // The Bool matters, but it is NOT a success flag, and reading it as one was a
    // defect of its own. Measured against the real API: reserving a locale that is
    // already reserved returns FALSE, not true. So false means "did not newly
    // reserve", which covers both a genuine refusal and the entirely healthy case
    // where the claim was already held — including where the early-return check
    // above missed it because Apple reports an equivalent identifier variant.
    //
    // Treating false as failure would disable the preview on a machine that has
    // exactly the reservation it needs. Treating it as success would restore the
    // original defect: `prepare()` reporting ready for a locale never claimed, then
    // being CACHED, so every later recording reuses a broken recognizer and the
    // failure surfaces far away as a missing-asset complaint.
    //
    // Ask the authority instead of inferring from the return value.
    if try await AssetInventory.reserve(locale: locale) { return }
    let nowReserved = await AssetInventory.reservedLocales
    guard nowReserved.contains(where: { $0.identifier(.bcp47) == wanted }) else {
      throw LivePreviewError.localeUnavailable
    }
  }

  /// Turn our ISO 639-1 language code into one of the recognizer's locales, or nil
  /// if it cannot transcribe that language at all.
  ///
  /// **The equivalence is Apple's, not ours.** Our setting stores a bare code
  /// ("en", "de") while the recognizer offers 54 full locales ("en-US", "en-GB"),
  /// so something has to bridge them. Measured on this machine before adopting it:
  /// en -> en-US, de -> de-DE, ja -> ja-JP, zh -> zh-CN, hi -> hi-IN, sv -> sv-SE,
  /// and nil for a code Apple does not know. A hand-rolled filter over
  /// `supportedLocales` was written first and thrown away: it would have had to
  /// guess at regional equivalence the vendor already answers authoritatively.
  static func resolveLocale(code: String) async -> Locale? {
    await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: code))
  }

  // MARK: - Session

  /// One live preview session and everything it owns.
  ///
  /// Held by the caller, never by the actor, so a session can only ever be torn
  /// down by whoever started it. `fedAnyAudio` is a reference box because feeding
  /// happens on the actor while the value lives with the caller.
  struct Session: Sendable {
    let token: UInt64
    fileprivate let analyzer: SpeechAnalyzer
    fileprivate let continuation: AsyncStream<AnalyzerInput>.Continuation
    fileprivate let collector: Task<Void, Never>
    fileprivate let converter: AVAudioConverter?
    fileprivate let sourceFormat: AVAudioFormat
    fileprivate let targetFormat: AVAudioFormat
    fileprivate let fedAnyAudio: FedFlag
  }

  /// Mutable "did any audio reach the analyzer" flag, per session.
  final class FedFlag: @unchecked Sendable {
    private(set) var value = false
    fileprivate func set() { value = true }
  }

  /// `LivePreviewEngine`'s session-opening entry point.
  ///
  /// Thin on purpose. `startSession` keeps returning the concrete `Session` value
  /// so this file's own callers and tests are unaffected; this only boxes it in the
  /// handle the coordinator can hold without naming Apple.
  func openSession(
    lookups: WordCorrector.Lookups?,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> any LivePreviewEngineSession {
    // **Re-assert the reservation here, not only in `prepare()`.**
    //
    // A prepared engine is CACHED and reused for every later recording without preparing
    // again (`LivePreviewCoordinator.ensurePrepared` returns early on a key match), so a claim
    // taken once has to survive arbitrarily long. It does not: reserving evicts the
    // oldest claim when Apple's five slots are full, and the language-pack installer takes a
    // slot too, so downloading a language can evict the very locale this engine is previewing.
    //
    // Losing it is silent HERE and surfaces far away as "No GeneralASR asset for language
    // <x>", which reads as a missing download and sends the investigation the wrong way — see
    // the note on `reserveLocale`, where that cost three rounds on #1988. The engine now
    // guarantees its own precondition instead of trusting that nothing disturbed it, which
    // covers every way a claim can be lost rather than only the one we found.
    //
    // Cheap: `acquireLocaleForSession` returns immediately when the claim is already held, so the
    // steady state is one inventory read per recording and no eviction.
    // Reserving also REGISTERS this session's use, atomically, so the claim cannot be evicted
    // between being taken and being used. Released in `ApplePreviewSessionHandle.end()`, which
    // the coordinator always calls — and if some path ever fails to, `evictable(from:)` fails
    // soft rather than refusing every future download.
    try await Self.acquireLocaleForSession(locale)
    let tag = locale.identifier(.bcp47)
    do {
      let session = try await startSession(lookups: lookups, onText: onText)
      return ApplePreviewSessionHandle(recognizer: self, session: session, reservedTag: tag)
    } catch {
      await Self.endUse(tag)
      throw error
    }
  }

  /// Give up one consumer's claim, releasing the system reservation only when nobody is left.
  ///
  /// **The zero check is the point.** A recording ending must not drop a claim a download is
  /// still using, and vice versa — they legitimately overlap on the same language.
  static func endUse(_ tag: String) async {
    await LocaleReservations.shared.acquire()
    let remaining = await LocaleReservations.shared.endUse(tag)
    if remaining == 0 {
      _ = await AssetInventory.release(reservedLocale: Locale(identifier: tag))
    }
    await LocaleReservations.shared.release()
  }

  /// Open a session. `onText` is called on every result with the text the user
  /// should now see; it is invoked from the collector task and must be cheap.
  ///
  /// If the returned session is already superseded by the time `start` completes,
  /// it is torn down here rather than returned, so a start that lost a race leaks
  /// nothing and the caller gets a clear failure.
  /// `lookups` is this session's Custom Words snapshot, passed IN rather than read
  /// from a stored property. Review found the stored-property version racy — the
  /// coordinator installed it through an unstructured `Task`, so a session opened
  /// straight after preparation could capture `nil` and show mangled names for the
  /// first recording. Making it a parameter removes the race by construction
  /// rather than ordering two awaits, which is the same lesson the `Session` value
  /// above already encodes: shared mutable state on this actor is the bug.
  func startSession(
    lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void
  ) async throws -> Session {
    guard let target = targetFormat, let source = sourceFormat else {
      throw LivePreviewError.notPrepared
    }
    currentToken &+= 1
    let token = currentToken

    // A fresh converter per session, so no resampler tail crosses a boundary and
    // leaks the previous dictation's audio into this one.
    //
    // A nil converter must mean ONE thing: the formats match and no conversion is
    // needed. `AVAudioConverter(from:to:)` is failable, so folding its failure into
    // the same nil makes an unconvertible pair indistinguishable from an identical
    // one, and `feed` would then hand the analyzer a source-format buffer it did
    // not ask for. Refusing the session is the honest outcome — the caller degrades
    // to "preview not ready" and the dictation itself is untouched.
    let converter: AVAudioConverter?
    if source == target {
      converter = nil
    } else if let made = AVAudioConverter(from: source, to: target) {
      converter = made
    } else {
      throw LivePreviewError.audioFormatUnavailable
    }
    let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    // **Bounded, because an unbounded queue makes a limb able to hurt the heart.**
    // The default policy is `.unbounded`: if Apple's analyzer stalls or falls behind
    // real time, the feed loop keeps handing it a chunk every 100 ms forever and the
    // preview grows without limit, putting memory pressure on the dictation it is
    // supposed to be decorating. `.bufferingNewest` caps it and drops the OLDEST
    // audio, which is the right thing to lose here: the pill shows a tail, so a gap
    // in the middle of a stalled stretch costs the user nothing they can see, while
    // stopping the preview outright would.
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
      bufferingPolicy: .bufferingNewest(Self.maxQueuedChunks))
    let analyzer = SpeechAnalyzer(modules: [module])
    // The session owns the vocabulary it started with.
    let collector = Self.collect(from: module, lookups: lookups, onText: onText)

    // Finishing the stream and cancelling the collector is not enough: the analyzer
    // holds its own analysis and model resources and needs an explicit end, or a
    // rapid stop-start loop accumulates abandoned ones. `cancelAndFinishNow` rather
    // than `finalizeAndFinishThroughEndOfInput` because this session is being thrown
    // away — there is no result anyone will read, and finalizing an analyzer that
    // never received input does not return (trap 2).
    func discard() async {
      continuation.finish()
      collector.cancel()
      await analyzer.cancelAndFinishNow()
    }

    do {
      try await analyzer.start(inputSequence: stream)
    } catch {
      await discard()
      throw error
    }
    // Superseded while `start` was suspended: this session's resources are ours
    // alone, so close them rather than handing back something whose every later
    // call would be rejected.
    guard token == currentToken else {
      await discard()
      throw LivePreviewError.superseded
    }
    return Session(
      token: token, analyzer: analyzer, continuation: continuation, collector: collector,
      converter: converter, sourceFormat: source, targetFormat: target,
      fedAnyAudio: FedFlag())
  }

  /// Accumulate results into the text a user would actually be looking at.
  ///
  /// **APPLE'S RESULTS ARE PER-SEGMENT, NOT CUMULATIVE, AND ASSUMING OTHERWISE
  /// DELETES THE USER'S WORDS ON SCREEN.** After roughly a second of silence the
  /// analyzer closes a segment and opens a new one whose first result carries only
  /// that new segment — observed going from 309 characters to the single character
  /// "." in one millisecond, then rebuilding. Treating each result as the whole
  /// transcript wipes the pill at every pause. The founder found this in the first
  /// live trial; it is the single most important line in this file.
  ///
  /// What a user sees is finished segments plus the one in flight, so that is what
  /// is assembled.
  ///
  /// `lookups` is this session's Custom Words snapshot, applied HERE because this
  /// is already off the main actor and already the place the retention bound runs.
  /// `WordCorrector.correct(_:using:)` is a documented pure function, safe to call
  /// off any actor, and `Lookups` is `Sendable`, so the snapshot crosses the
  /// boundary as a value rather than as a reference the main actor keeps mutating.
  private static func collect(
    from transcriber: DictationTranscriber, lookups: WordCorrector.Lookups?,
    onText: @escaping @Sendable (String) -> Void
  ) -> Task<Void, Never> {
    Task {
      var committed = ""
      var inFlight = ""
      let corrector = WordCorrector()
      // A thrown error ends the stream. The text already on screen stays on
      // screen: a preview that freezes mid-sentence is a far better failure than
      // one that blanks, and the dictation itself is unaffected either way.
      do {
        for try await result in transcriber.results {
          let piece = String(result.text.characters)
          if result.isFinal {
            // Bounded HERE, where the text is built. Accumulating the whole
            // transcript and trimming downstream would keep every word of a
            // 60-minute dictation alive and copy all of it across an actor
            // boundary several times a second.
            committed = LivePreviewTextBound.apply(committed + piece)
            inFlight = ""
          } else {
            // Bounded on STORAGE, not only on emission. Apple can keep returning
            // non-final results for a long uninterrupted stretch, and an unbounded
            // `inFlight` violates the retention invariant for as long as that
            // lasts even though every emitted string is trimmed.
            inFlight = LivePreviewTextBound.apply(piece)
          }
          // Bounded on BOTH sides of correction, and neither is redundant.
          //
          // BEFORE caps the SCAN: the bound keeps the tail, so correcting first
          // would scan the whole retained transcript several times a second to
          // produce a string whose head is then thrown away.
          //
          // AFTER caps the RESULT: correction EXPANDS text. An alias is usually
          // shorter than the canonical it maps to, so a passage full of them can
          // cross the retention limit that the pre-bound appeared to guarantee.
          // Review caught this, and the first bound is exactly what made the
          // invariant look already held.
          //
          // Applied to the assembled string rather than to each incoming piece
          // because a custom term can span the segment join: Apple closes a
          // segment mid-name often enough that per-piece correction would miss
          // exactly the proper nouns this exists for (#1988 — partial hypotheses
          // are least stable on proper nouns, which is the whole reason the issue
          // asks for the dictionary on the preview pass).
          onText(
            LivePreviewTextBound.apply(
              Self.corrected(
                LivePreviewTextBound.apply(committed + inFlight),
                corrector: corrector, lookups: lookups)))
        }
      } catch {}
    }
  }

  /// Apply this session's Custom Words snapshot, or return `text` untouched.
  ///
  /// A limb inside a limb: correction failing must never cost the user the words
  /// already on screen, so an empty vocabulary short-circuits and anything else
  /// falls through to the uncorrected text rather than blanking the pill.
  private static func corrected(
    _ text: String, corrector: WordCorrector, lookups: WordCorrector.Lookups?
  ) -> String {
    guard let lookups, !text.isEmpty else { return text }
    return corrector.correct(text, using: lookups).corrected
  }

  /// Feed newly captured 16 kHz mono samples into `session`.
  ///
  /// Never throws: a preview that cannot convert a buffer shows slightly less text,
  /// which is not worth propagating. A superseded session is dropped rather than
  /// fed, because the feed loop is cancelled asynchronously and a call already in
  /// flight when the next recording begins would otherwise push the previous
  /// dictation's audio into the new stream.
  func feed(_ samples: [Float], session: Session) {
    guard session.token == currentToken, !samples.isEmpty else { return }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: session.sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channel = buffer.floatChannelData else { return }
    samples.withUnsafeBufferPointer { src in
      guard let base = src.baseAddress else { return }
      channel[0].update(from: base, count: samples.count)
    }

    let toSend: AVAudioPCMBuffer
    if let converter = session.converter {
      guard let converted = Self.convert(buffer, using: converter, to: session.targetFormat)
      else { return }
      toSend = converted
    } else {
      toSend = buffer
    }
    session.fedAnyAudio.set()
    nonisolated(unsafe) let unsafeBuffer = toSend
    session.continuation.yield(AnalyzerInput(buffer: unsafeBuffer))
  }

  /// Close `session` and release its analyzer. Safe to call twice.
  ///
  /// Needs no token check at all, which is the point of the value-owned design: the
  /// resources closed here belong to this session and to nothing else, so a late
  /// teardown from an abandoned recording cannot reach the live one.
  func endSession(_ session: Session) async {
    session.continuation.finish()
    // Only FINALIZE when the analyzer actually received input — see trap 2. A
    // finalize on an empty analyzer never returns, which would leak this task for
    // the life of the process.
    //
    // But it must still be ENDED either way. The silent-recording path (press,
    // say nothing, release) reaches here with nothing fed, and leaving the analyzer
    // un-ended leaks its analysis and model resources exactly as an abandoned start
    // does. Review named that leak on the discard path; this is its twin, and a fix
    // that landed on only one of two symmetric sites would be the partial port this
    // codebase keeps relearning.
    if session.fedAnyAudio.value {
      // `try?` here was the FIFTH member of the abandoned-analyzer class, and the
      // one that survived a sweep I called complete — because that sweep
      // enumerated CONSTRUCTION sites and their exits, and this is a different
      // axis: an ENDING call that can itself fail. A throwing finalize leaves the
      // analyzer exactly as un-ended as never calling one, and stopping a
      // recording is the moment the parent task is being cancelled, which is when
      // it is most likely to throw. Cancel is the fallback because it does not
      // throw, so the class closes here rather than recursing.
      do {
        try await session.analyzer.finalizeAndFinishThroughEndOfInput()
      } catch {
        await session.analyzer.cancelAndFinishNow()
      }
    } else {
      await session.analyzer.cancelAndFinishNow()
    }
    session.collector.cancel()
  }

  // MARK: - Conversion

  /// One `AVAudioConverter` pass over one input buffer.
  ///
  /// Returns `.noDataNow` when the input is exhausted, never `.endOfStream`:
  /// `.endOfStream` retires the converter permanently, so the buffer after it
  /// would silently produce nothing for the rest of the dictation.
  private static func convert(
    _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to target: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 1024)
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      return nil
    }
    var supplied = false
    var error: NSError?
    nonisolated(unsafe) let input = buffer
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return input
    }
    guard status != .error, out.frameLength > 0 else { return nil }
    return out
  }
}

/// Carries one Apple session so the coordinator can feed and end it without naming
/// `SpeechAnalyzer` or holding Apple's `Session` value itself.
///
/// A struct, not an actor, and that preserves the property the `Session` design
/// exists for: it stores the session VALUE and the actor that owns the work, adding
/// no state of its own. There is nothing here for a stale call to overwrite, which
/// is the whole reason session resources stopped living on the actor.
@available(macOS 26.0, *)
struct ApplePreviewSessionHandle: LivePreviewEngineSession {
  let recognizer: ApplePreviewRecognizer
  let session: ApplePreviewRecognizer.Session
  /// The claim this session depends on, released back to the eviction pool when it ends.
  let reservedTag: String

  func feed(_ samples: [Float]) async {
    await recognizer.feed(samples, session: session)
  }

  func end() async {
    await recognizer.endSession(session)
    // After the analyzer is finished, never before: until then this locale's assets are still
    // being read and evicting the claim would break the recording in flight.
    await ApplePreviewRecognizer.endUse(reservedTag)
  }
}

/// Apple's answer to "can this language be previewed here".
///
/// Both refusals live together because they are the same question asked twice: this
/// engine cannot run below macOS 26, and above it cannot run in a language Apple
/// does not transcribe. Neither is a fact about the live preview FEATURE, which is
/// exactly why they moved off the coordinator — a downloadable engine has no OS
/// floor and its own language set, and a coordinator that assumed Apple's rules
/// would silently disable it on macOS 14 through 25.
package enum ApplePreviewEngineResolver {

  /// Apple's engine as the app shell consumes it. One value carrying both halves,
  /// so the pill's geometry check and the recording's resolution can never be wired
  /// from different sources.
  package static let route = LivePreviewEngineRoute(
    telemetryEngineID: "apple",
    isSupportedOnThisSystem: { isSupportedOnThisSystem },
    resolve: { mode in await resolve(mode) }
  )

  /// Whether this Mac can run Apple's preview engine at all.
  ///
  /// Synchronous and separate from `resolve` because the overlay needs the answer
  /// while deciding pill geometry, where there is nothing to await. Same OS check,
  /// asked from the one place that knows why it applies.
  package static var isSupportedOnThisSystem: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  /// Stable identity for this engine in a `LivePreviewEngineKey`.
  static let engineID = "apple"

  /// Resolve the user's language setting to an Apple engine, or to the sentence
  /// explaining why not.
  static func resolve(_ mode: LanguageMode) async -> LivePreviewEngineResolution {
    guard #available(macOS 26.0, *) else {
      return .blocked(.unsupportedSystem)
    }
    let code = languageCode(for: mode)
    // Both the setting and the tag derived from it. "Why is there no preview in my
    // language" is answerable from this one line: it separates a user on Auto,
    // where we guess, from one who locked a language Apple cannot transcribe, and
    // those have different answers.
    await log("resolving language, mode=\(mode) code=\(code)")
    guard let locale = await ApplePreviewRecognizer.resolveLocale(code: code) else {
      await log("no recognizer locale for language=\(code)")
      return .blocked(.unsupportedLanguage)
    }
    let tag = locale.identifier(.bcp47)

    // Refuse HERE rather than letting `prepare()` fetch it (#2080). Apple supports the language
    // but this Mac does not have its model, and downloading ~140 MB is the user's decision, taken
    // on the Live Preview settings page. Reported by name so the pill can say which language,
    // rather than a generic sentence that leaves the user hunting.
    let installedTags = await DictationTranscriber.installedLocales.map {
      $0.identifier(.bcp47)
    }
    guard
      let readyTag = satisfyingTag(
        requestedCode: code, resolvedTag: tag, installedTags: installedTags)
    else {
      // Name the LANGUAGE for a locked code and the exact REGION for a full one, matching what
      // the user actually has to go and install.
      let name = ApplePackCatalog.localizedName(
        for: Locale(identifier: code).region == nil ? code : tag)
      await log("pack not installed for \(tag); user must install it")
      return .blocked(.installRequired(languageName: name))
    }

    let readyLocale = Locale(identifier: readyTag)
    return .ready(
      LivePreviewEngineCandidate(
        key: LivePreviewEngineKey(engine: engineID, commitment: readyTag),
        makeEngine: { ApplePreviewRecognizer(locale: readyLocale) }
      ))
  }

  /// Which installed pack satisfies this request, if any — and therefore which locale the engine
  /// commits to. Pure, so the regional behaviour below is testable without Apple's inventory.
  ///
  /// **A bare code draws a RANDOM REGION on every call.** Measured: `fr` resolved to fr-CH, then
  /// fr-CA, then fr-BE across three runs (FACT: apple-api-semantics-measured). Locked language
  /// mode sends a bare catalogue code, so it lotteries.
  ///
  /// That used to cost quality only, because `prepare()` downloaded whichever variant the draw
  /// named. #2080 made pack installation the user's deliberate action, which turned the same
  /// instability into a FUNCTIONAL BREAK: download the French the pill asked for, and the next
  /// recording draws a different French and asks again. The user would have to install every
  /// variant to make their own language work.
  ///
  /// So a bare code accepts ANY installed variant of that language and USES it. That also pins
  /// `commitment`, so the cached engine stops being rebuilt with a different regional model on
  /// random recordings. A code that carries a REGION (Auto sends the full system locale) still
  /// requires that exact tag: the region is the whole point there — measured, a `zh-TW` Mac
  /// reduced to a bare code gets Simplified characters for a Traditional reader.
  ///
  /// This does NOT fix the underlying product gap: a locked language still gets an arbitrary
  /// region's model, and the real fix is regional rows in the 100-code catalogue, which changes
  /// a user-visible list and the paste engines too (FACT: not-done). It restores the property
  /// that installing the language once is enough.
  package static func satisfyingTag(
    requestedCode: String,
    resolvedTag: String,
    installedTags: [String]
  ) -> String? {
    guard Locale(identifier: requestedCode).region == nil else {
      return installedTags.first { $0 == resolvedTag }
    }
    let language = Locale(identifier: resolvedTag).language.languageCode?.identifier
    // Sorted so the same inputs always yield the same locale. An unstable choice here would
    // reintroduce the churn this exists to remove, just one level further in.
    return
      installedTags
      .filter { Locale(identifier: $0).language.languageCode?.identifier == language }
      .sorted()
      .first
  }

  /// The language tag to ask Apple for: a bare ISO 639-1 code when the user locked
  /// one, the FULL system locale under Auto.
  ///
  /// **Apple's recognizer must commit to one language before it hears anything, so
  /// Auto has no answer to give it.** The system language is the honest guess: it
  /// is what the user's Mac is set to, and being wrong costs a preview rather than
  /// a transcript. This lives with Apple's engine rather than with the feature
  /// because it is a workaround for a limitation only this engine has — an engine
  /// that detects language itself must not inherit the guess.
  ///
  /// **Auto passes region and script through, because reducing to the language code
  /// silently picks the wrong regional model. MEASURED against the real resolver,
  /// all three columns**: a `zh-TW` Mac resolved to `zh-CN`, Simplified characters
  /// for a Traditional reader; `pt-BR` to `pt-PT`; `fr-CA` to `fr-CH`, Canadian
  /// French landing on Swiss; and every `en-GB`/`en-IN`/`en-AU` to `en-US`. Passing
  /// the full locale gives each of those its own model.
  ///
  /// The obvious risk of doing this — a full locale Apple cannot resolve returning
  /// nil where the bare code would have worked, disabling the preview for whole
  /// regions — was measured across 21 locales and does NOT occur: every case
  /// resolved as well or better, and the three that returned nil (`nn-NO`,
  /// `sr-Latn-RS`, `az-Cyrl-AZ`) return nil for the bare code too. `ca-ES-valencia`
  /// degrades gracefully to `ca-ES`.
  ///
  /// Locked mode still passes a bare code because our language catalogue holds bare
  /// ISO 639-1 codes, so a user who explicitly picks Chinese gets `zh-CN`. Giving
  /// locked mode regional variants means adding them to that catalogue, which is a
  /// product decision about a user-visible list, not this function.
  package static func languageCode(for mode: LanguageMode) -> String {
    switch mode {
    case .locked(let code): return code
    case .auto: return Locale.current.identifier(.bcp47)
    }
  }

  private static func log(_ message: String) async {
    await AppLogger.shared.log("LIVE_PREVIEW \(message)", category: "LivePreview")
  }
}

/// Why a preview is not running. Kept separate from the recognizer so the
/// non-macOS-26 paths, which cannot even name `SpeechAnalyzer`, can still report.
enum LivePreviewError: Error {
  case audioFormatUnavailable
  case notPrepared
  /// The session was replaced by a newer one before it finished opening.
  case superseded
  /// The locale could not be claimed for this process, so nothing can transcribe
  /// in it. Distinct from "Apple does not support this language" — this one is
  /// worth retrying on the next recording.
  case localeUnavailable
}
