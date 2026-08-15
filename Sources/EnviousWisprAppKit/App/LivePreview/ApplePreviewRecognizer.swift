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

  private let locale: Locale

  private var targetFormat: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var sourceFormat: AVAudioFormat?

  private var module: DictationTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var collector: Task<Void, Never>?
  private var fedAnyAudio = false
  /// Bumped by every `startSession`. `endSession` refuses to tear down anything but
  /// the session it was given, so a late teardown from an abandoned recording can
  /// never close the analyzer the user is currently talking to. Without this the
  /// two calls are merely serialized by the actor, not ORDERED, and a fast
  /// stop-then-start could run them in the wrong order.
  private var sessionToken: UInt64 = 0

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
    try await warmAnalyzer.prepareToAnalyze(in: target)
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
    _ = try await AssetInventory.reserve(locale: locale)
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

  /// Open a session and return its token, which `endSession` requires.
  ///
  /// `onText` is called on every result with the text the user should now see; it
  /// is invoked from this actor's context and must be cheap.
  @discardableResult
  func startSession(onText: @escaping @Sendable (String) -> Void) async throws -> UInt64 {
    guard let target = targetFormat, let source = sourceFormat else {
      throw LivePreviewError.notPrepared
    }
    sessionToken &+= 1
    let token = sessionToken
    fedAnyAudio = false
    // A fresh converter per session, so no resampler tail crosses a boundary and
    // leaks the previous dictation's audio into this one.
    converter = source == target ? nil : AVAudioConverter(from: source, to: target)

    let fresh = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    module = fresh
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    continuation = cont
    let analyzer = SpeechAnalyzer(modules: [fresh])
    self.analyzer = analyzer
    collector = Self.collect(from: fresh, onText: onText)
    try await analyzer.start(inputSequence: stream)
    return token
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
            inFlight = piece
          }
          onText(LivePreviewTextBound.apply(committed + inFlight))
        }
      } catch {}
    }
  }

  /// Feed newly captured 16 kHz mono samples for the session identified by `token`.
  ///
  /// Never throws: a preview that cannot convert a buffer shows slightly less text,
  /// which is not worth propagating. The token is the same guard `endSession` uses,
  /// and for the same reason — the feed loop is cancelled asynchronously, so a call
  /// already in flight when the next recording begins would otherwise push the
  /// previous dictation's audio into the new session's analyzer.
  func feed(_ samples: [Float], token: UInt64) {
    guard token == sessionToken else { return }
    guard let cont = continuation, let source = sourceFormat, !samples.isEmpty else { return }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channel = buffer.floatChannelData else { return }
    samples.withUnsafeBufferPointer { src in
      guard let base = src.baseAddress else { return }
      channel[0].update(from: base, count: samples.count)
    }

    let toSend: AVAudioPCMBuffer
    if let converter, let target = targetFormat {
      guard let converted = Self.convert(buffer, using: converter, to: target) else { return }
      toSend = converted
    } else {
      toSend = buffer
    }
    fedAnyAudio = true
    nonisolated(unsafe) let unsafeBuffer = toSend
    cont.yield(AnalyzerInput(buffer: unsafeBuffer))
  }

  /// Close the session identified by `token` and release its analyzer.
  ///
  /// A token that is not the current one is a teardown arriving from a recording
  /// that has already been superseded, so it does nothing. Safe to call when no
  /// session is open, and safe to call twice.
  func endSession(token: UInt64) async {
    guard token == sessionToken else { return }

    // **Everything this teardown touches is captured BEFORE the await.** An actor
    // is reentrant at a suspension point, so while `finalizeAndFinishThroughEndOfInput`
    // is running the next recording can enter `startSession` and replace
    // `analyzer`, `collector` and `continuation` with its own. Resuming here and
    // clearing the FIELDS would then silence the session the user is currently
    // talking to. Checking the token only on entry, as the first version did, does
    // not help: it was still true when checked. Review caught this.
    let endingAnalyzer = analyzer
    let endingCollector = collector
    let endingContinuation = continuation
    let hadAudio = fedAnyAudio

    endingContinuation?.finish()
    // Only finalize when the analyzer actually received input — see trap 2. A
    // finalize on an empty analyzer never returns, which would leak this task for
    // the life of the process.
    if hadAudio, let endingAnalyzer {
      try? await endingAnalyzer.finalizeAndFinishThroughEndOfInput()
    }
    endingCollector?.cancel()

    // Only now touch shared state, and only if this is still the current session.
    guard token == sessionToken else { return }
    continuation = nil
    fedAnyAudio = false
    collector = nil
    analyzer = nil
    module = nil
    converter = nil
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
}
