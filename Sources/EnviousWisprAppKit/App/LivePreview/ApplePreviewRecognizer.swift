@preconcurrency import AVFoundation
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
actor ApplePreviewRecognizer {

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

  /// Claim the locale, install its assets if missing, and resolve the audio
  /// format. Throws so the caller can degrade; it is never called from the heart.
  func prepare() async throws {
    try await Self.reserveLocale(locale)

    let probe = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
      // The bytes come from Apple and are shared with the system's own dictation,
      // so a user who already dictates in this language has paid for them already.
      // We ship none of them.
      try await request.downloadAndInstall()
    }

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
  private static func reserveLocale(_ locale: Locale) async throws {
    let wanted = locale.identifier(.bcp47)
    let already = await AssetInventory.reservedLocales
    if already.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
    if already.count >= AssetInventory.maximumReservedLocales, let victim = already.first {
      _ = await AssetInventory.release(reservedLocale: victim)
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

  /// Open a session. `onText` is called on every result with the text the user
  /// should now see; it is invoked from the collector task and must be cheap.
  ///
  /// If the returned session is already superseded by the time `start` completes,
  /// it is torn down here rather than returned, so a start that lost a race leaks
  /// nothing and the caller gets a clear failure.
  func startSession(onText: @escaping @Sendable (String) -> Void) async throws -> Session {
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
    let collector = Self.collect(from: module, onText: onText)

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
  private static func collect(
    from transcriber: DictationTranscriber, onText: @escaping @Sendable (String) -> Void
  ) -> Task<Void, Never> {
    Task {
      var committed = ""
      var inFlight = ""
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
          onText(LivePreviewTextBound.apply(committed + inFlight))
        }
      } catch {}
    }
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
      try? await session.analyzer.finalizeAndFinishThroughEndOfInput()
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
