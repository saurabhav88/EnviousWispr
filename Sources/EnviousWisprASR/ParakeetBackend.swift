@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprFluidAudioBridge
@preconcurrency import FluidAudio

// Disambiguate from FluidAudio.ASRResult — we always mean our own type.
public typealias ASRResult = EnviousWisprCore.ASRResult

/// Parakeet v3 ASR backend using FluidAudio/CoreML.
///
/// This is the primary (default) backend. Parakeet v3 provides:
/// - ~110x real-time factor on Apple Silicon
/// - Built-in punctuation and capitalization
/// - 25 European language support
public actor ParakeetBackend: ASRBackend {
  public private(set) var isReady = false

  private var fluidAsrManager: AsrManager?
  private var fluidModels: AsrModels?

  // Streaming ASR state
  private var streamingManager: SlidingWindowAsrManager?
  private var streamingStartTime: CFAbsoluteTime = 0

  public var supportsStreaming: Bool { true }

  /// Total download size shown in the progress detail (#1339). The pinned
  /// Parakeet v3 set (4 model dirs + vocab + loose json/txt) measures
  /// 483,256,769 bytes — byte-verified in `workers/parakeet-mirror/
  /// expected-manifest.json` (in-repo since #1348 PR-2a; the bundled
  /// `parakeet-delivery-manifest.json` derives from it).
  static let totalDownloadMB = 483

  public init() {}

  public func prepare() async throws {
    try await prepare(cacheOnly: false, progressCallback: nil)
  }

  public func prepare(progressCallback: ProgressCallback?) async throws {
    try await prepare(cacheOnly: false, progressCallback: progressCallback)
  }

  /// #1348 Phase 2: whether this process may let FluidAudio touch the
  /// network. Cache-only is the delivery-managed invariant — the host admits
  /// verified bytes into FluidAudio's default cache and the service ONLY
  /// loads them; a cache miss must throw typed (`DownloadError.modelMissing`
  /// for model dirs, `AsrModelsError.modelNotFound` for the vocab), never
  /// silently re-enter the borrowed downloader. With offline armed, ModelHub
  /// throws before its purge/re-download recovery branch, so a corrupt cache
  /// can never trigger a network repair from this process (#1981). Deterministic
  /// last-writer per prepare (the XPC handler serializes loads and unloads the
  /// previous backend first), so flipping the delivery flag works without a
  /// service restart. `internal` for the legacy-after-cache-only unit test.
  static func configureOfflineMode(cacheOnly: Bool) {
    ModelHub.offlineMode = cacheOnly
  }

  /// Prepare with optional progress reporting.
  /// The callback is called from FluidAudio's download thread — caller must marshal to MainActor.
  ///
  /// FluidAudio's progress system (ModelHub/ProgressReporter):
  /// - Repo loads declare a 0.5 download-phase weight, so `fractionCompleted`
  ///   range is [0.0, 0.5] = download (byte-weighted), [0.5, 1.0] = CoreML
  ///   compilation; the cached fast path emits 0.5 with `.downloading(0, 0)`
  ///   and completion emits 1.0 with `.compiling(modelName: "")`.
  /// - Downloads only happen on the legacy path's first load — cached files
  ///   skip straight to compilation. We map directly from FluidAudio's fraction.
  ///
  /// Stall detection is host-side (#1339): the kernel's session detector and
  /// the sessionless warm-up guard watch the shared progress file this
  /// callback feeds.
  ///
  /// `cacheOnly` (#1348 Phase 2): load the host-admitted cache with
  /// FluidAudio's own offline switch armed — zero network in this process.
  /// The legacy path (`cacheOnly: false`) stays byte-identical for the
  /// staged-rollout window (D5 §5), minus the deleted inert checksum no-op.
  public func prepare(cacheOnly: Bool, progressCallback: ProgressCallback?) async throws {
    let handler = Self.makeLoadProgressHandler(progressCallback)

    Self.configureOfflineMode(cacheOnly: cacheOnly)
    do {
      let loadedModels: AsrModels
      if cacheOnly {
        // Delivery-managed: the default cache was admitted by the host's hash
        // gate before this call; offlineMode (armed above) turns any gap
        // into a typed throw the host maps to its repair path.
        loadedModels = try await AsrModels.loadFromCache(version: .v3, progressHandler: handler)
      } else {
        loadedModels = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
      }
      self.fluidModels = loadedModels

      let manager = AsrManager(config: .default)
      // Vendor API: models load via loadModels(_:) after construction.
      try await manager.loadModels(loadedModels)
      self.fluidAsrManager = manager
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // #1525 PR I-B: unlike `transcribe`'s catch below, a non-recognized error
      // here does NOT stay raw — model loading's own genuinely-non-vendor
      // errors (a plain CocoaError/CoreML error from inside AsrModels'
      // own loading calls) are still model-load failures, not a different
      // physical class, so they normalize to `.unknownLoadFailure` too.
      throw ParakeetModelLoadSentryError(normalizingLoadError: error)
    }

    isReady = true
  }

  /// The production vendor-progress → app-callback mapping, extracted from
  /// `prepare` unchanged so the mapping itself is directly testable — one
  /// owner, identical control flow (#1981 chunk 2; the test feeds real
  /// `DownloadProgress` values through THIS function, not a copy).
  static func makeLoadProgressHandler(
    _ progressCallback: ProgressCallback?
  ) -> ProgressHandler? {
    progressCallback.map {
      callback -> ProgressHandler in
      { progress in
        let phase: String
        let detail: String

        switch progress.phase {
        case .listing:
          // Single authority for this token: the host-side stall guard keys
          // its listing-stall gate on it (ModelLoadStallPolicy, #1339).
          phase = ModelLoadStallPolicy.listingPhase
          detail = ""
        case .downloading:
          phase = "Downloading model files..."
          // #1339: honest byte counter. The real payload is ~483MB of
          // already-compiled Core ML artifacts (445MB encoder weights); the
          // old "23 MB" label was the decoder file alone. Fraction [0, 0.5]
          // is FluidAudio's byte-weighted download half.
          let downloadPct = min(progress.fractionCompleted * 2.0, 1.0)
          let downloadedMB = Int(downloadPct * Double(Self.totalDownloadMB))
          detail =
            "\(downloadedMB) MB of \(Self.totalDownloadMB) MB (\(Int(downloadPct * 100))%)"
        case .compiling(let modelName):
          // Single authority for this token too (#1388): the host-side
          // watcher's install OBSERVATION keys on it for the warm-up success
          // telemetry (install duration + longest internal silence).
          phase = ModelLoadStallPolicy.installPhase
          detail = modelName
        }
        callback(progress.fractionCompleted, phase, detail)
      }
    }
  }

  public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    guard isReady, let manager = fluidAsrManager else { throw ASRError.notReady }

    let startTime = CFAbsoluteTimeGetCurrent()
    // Vendor API: the caller owns decoder state (fresh per one-shot batch decode;
    // upstream's ChunkProcessor also makes fresh state per chunk internally); there
    // is no `source:` parameter.
    //
    // #1678: the language hint IS now passed, and passing it arms TWO vendor
    // mechanisms rather than one — `TdtDecoderV3.swift:129` computes top-K only
    // when `language != nil`, so nil switched off both:
    //
    //   1. `TokenLanguageFilter` — replaces a wrong-SCRIPT top-1 candidate with
    //      the best right-script one. Purpose-built for exactly the reported
    //      symptom: a German dictation coming back in Cyrillic or Greek.
    //   2. `applyEnglishBlocklist` — a French-tuned token list that was applied
    //      to all 21 non-English Latin languages and measurably corrupted German
    //      (25/120 clips, median WER 0.0% -> 2.9%).
    //
    // The hint was parked because of (2). That kept (1) — the defence the user
    // actually needs — switched off with it. (2) is scoped to French as of fork
    // pin `bf9fe27f` and re-measured at 0/120, so (1) is now reachable at no
    // measured cost.
    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let languageHint = Self.fluidLanguage(for: options.language)
    #if DEBUG
      // #1707 Phase 2: the real shared-engine call boundary for the overlap
      // Live UAT oracle (§3.2a-i) — `defer` closes the interval on every
      // exit (success or either catch), and the entry suspension (if this
      // call is the classified "held" one) happens BEFORE the real call, so
      // a genuinely NEW session's decode can reach and enter this SAME
      // boundary while the first is suspended here.
      let batchDecodeFaultRole = await enterBatchDecodeFaultBoundary()
      defer { exitBatchDecodeFaultBoundary(role: batchDecodeFaultRole) }
    #endif
    do {
      let fluidResult = try await manager.transcribe(
        audioSamples, decoderState: &decoderState, language: languageHint)
      let elapsed = CFAbsoluteTimeGetCurrent() - startTime

      return ASRResult(
        text: fluidResult.text,
        // #1678: nil, and do NOT reintroduce a literal here.
        //
        // Parakeet has no language detection. FluidAudio's own result type
        // declares no language field, so there is nothing to report even if we
        // wanted to — nil is the honest value, and a lock is INTENT, never a
        // measurement. Writing the locked code here would make this field
        // indistinguishable from a real detection and promote it past
        // `DictationLanguageResolver`'s precedence-2 guard, which exists
        // precisely to refuse an engine that reports a constant.
        //
        // This was `"en"` from the first scaffold, coexisting with our own "25
        // European languages" claim, and it was never true for a non-English
        // take. It reached casing until #1785 / PR #1802, where German on the
        // default engine was recased with English rules. Its remaining
        // consumers were RECORDS rather than behaviour — History's transcript
        // language and the `"language"` telemetry property — which is why every
        // fast-engine dictation was reported as English. Consumers already
        // handle nil: the telemetry sink renders `unknown`, and
        // `RecoverySpoolReplayer` falls back to the locked code.
        //
        // The invariant, inlined so it travels with the code: this engine has no
        // language detection, the vendor's own result type declares no language
        // field, and the `language` parameter above is an INPUT that conditions
        // decoding — never an output to echo back here.
        language: nil,
        duration: fluidResult.duration,
        processingTime: elapsed,
        backendType: .parakeet,
        tokenTimingSummary: Self.tokenTimingSummary(from: fluidResult.tokenTimings)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // #1525 PR I-B: pin a stable identity for a recognized FluidAudio error;
      // a non-FluidAudio error (e.g. a raw CoreML failure) stays raw and
      // unchanged, still bridging via today's default NSError path — it is a
      // different physical failure class this PR does not touch (§3.5:
      // com.apple.CoreML#0, confirmed live and unaffected).
      if let kind = classifyFluidAudioASRError(error) {
        throw ParakeetTranscriptionSentryError(mapping: kind)
      }
      throw error
    }
  }

  /// Languages Parakeet TDT v3 is DECLARED to transcribe, as the intersection of
  /// FluidAudio's `Language` enum with NVIDIA's model card for
  /// `parakeet-tdt-0.6b-v3` (#1678).
  ///
  /// The vendor enum carries 27 cases; the model card claims 25. The three extra
  /// cases below are usable by the script filter but are NOT claimed by the
  /// model, so offering them would promise transcription quality nobody has
  /// stated, let alone measured. Expressed as an exclusion rather than a
  /// hand-copied list of 25 so it cannot silently drift from the enum: a vendor
  /// adding a case appears here automatically and fails the count test below,
  /// which forces a decision instead of a silent widening.
  static let unclaimedByModelCard: Set<Language> = [.bosnian, .belarusian, .serbian]

  /// The language codes this engine may be locked to, for the settings picker.
  ///
  /// Deliberately `Set<String>` rather than the vendor's `Language`: the app
  /// layer must not import FluidAudio to render a list (dependency direction),
  /// and `Language` is a vendor type whose spelling is not our contract.
  ///
  /// Offering a code outside this set would be a silent failure — `fluidLanguage`
  /// would map it to nil, the decoder would fall back to Auto, and the user would
  /// see a lock they had set and were not getting.
  public static var lockableLanguageCodes: Set<String> {
    Set(Language.allCases.lazy.filter { !unclaimedByModelCard.contains($0) }.map(\.rawValue))
  }

  /// Our language code -> the vendor's `Language`, or nil for "no hint".
  ///
  /// nil means Auto and disables language conditioning in the decoder entirely,
  /// which is today's shipped behaviour and stays the default. An unrecognised
  /// or unclaimed code also returns nil: falling back to Auto is strictly safer
  /// than forcing a script the model was never declared to handle.
  static func fluidLanguage(for code: String?) -> Language? {
    guard let code, !code.isEmpty else { return nil }
    // Normalize `de-DE`/`de_AT` to `de`; the vendor's rawValues are bare ISO codes.
    let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(
      String.init)
    guard let base, let language = Language(rawValue: base),
      !unclaimedByModelCard.contains(language)
    else { return nil }
    return language
  }

  /// Numbers-only summary of FluidAudio token timings for tail-clip diagnostics (#1232).
  /// We keep only the count and the end time (ms) of the last token — never token text.
  /// Used to compute how far the decoded text reached vs the captured audio.
  private static func tokenTimingSummary(from timings: [TokenTiming]?) -> ASRTokenTimingSummary? {
    guard let timings else { return nil }
    let lastEndMs = timings.map(\.endTime).max().map { Int(($0 * 1000).rounded()) }
    return ASRTokenTimingSummary(tokenCount: timings.count, lastTokenEndMs: lastEndMs)
  }

  // MARK: - Streaming ASR

  public func startStreaming(options: TranscriptionOptions) async throws {
    guard isReady, let models = fluidModels else { throw ASRError.notReady }

    // Cancel any existing streaming session before starting a new one.
    // Prevents double-session state where the old manager is leaked.
    if let existing = streamingManager {
      await existing.cancel()
      streamingManager = nil
    }

    // #1678: the lock must reach BOTH decode paths. Wiring only the batch call
    // would give a locked user cross-alphabet protection on one path and not
    // the other, with nothing in the UI to say which they were on.
    let config = SlidingWindowAsrConfig.streaming
      .applying(language: Self.fluidLanguage(for: options.language))
    let manager = SlidingWindowAsrManager(config: config)
    do {
      // Vendor API: streaming starts via loadModels(_:) then startStreaming(source:).
      try await manager.loadModels(models)
      try await manager.startStreaming(source: .microphone)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // #1654: pin a stable identity before this leaves the service. A cancellation is
      // deliberately excluded above rather than classified — a cancelled stream is not a
      // failure and must never acquire a failure identity.
      throw Self.streamingThrowable(for: error, operation: .start)
    }
    self.streamingManager = manager
    self.streamingStartTime = CFAbsoluteTimeGetCurrent()
  }

  /// #1654: which streaming leg threw. Not cosmetic — it decides whether a bare vendor
  /// `ASRError` is allowed to become an identity at all.
  private enum StreamingLeg { case start, finalize }

  /// #1654: the one place a raw FluidAudio streaming error becomes what we throw.
  ///
  /// Order matters and is not arbitrary. `SlidingWindowAsrError` is checked first because
  /// it is the vendor's streaming-specific type. A bare `ASRError` is mapped ONLY on the
  /// start leg, where `SlidingWindowAsrManager` genuinely throws one; on finalize the
  /// vendor wraps every escaping error (`SlidingWindowAsrManager.swift:640`), so a bare
  /// `ASRError` arriving there is not something we have grounds to name. Calling it
  /// `startFailed` because that is the mapping in hand would be a reason whose name
  /// contradicts its producer.
  ///
  /// A foreign error is returned UNCHANGED — a raw CoreML or converter failure keeps its
  /// own identity rather than being relabelled as ours, exactly as the batch path leaves
  /// unrecognised errors alone.
  ///
  /// Returns the error to throw rather than an optional identity, deliberately. Cloud
  /// review's fourth finding needed a cancellation nested inside a vendor wrapper to come
  /// back out as a `CancellationError`, and an identity-returning function cannot express
  /// that — the caller would have thrown the raw wrapper, which the adapter's
  /// `catch is CancellationError` still cannot match. Both decisions (is this a
  /// cancellation, and what identity does it get) now live in ONE place, so the two catch
  /// sites cannot drift apart.
  private static func streamingThrowable(
    for error: any Error,
    operation: StreamingLeg
  ) -> any Error {
    // A cancellation must acquire no failure identity at ANY layer. The `catch is
    // CancellationError` arms at the call sites see only a BARE cancellation; this is the
    // nested case, where the vendor has wrapped it.
    if fluidAudioStreamingErrorWrapsCancellation(error) { return CancellationError() }
    if let kind = classifyFluidAudioStreamingError(error) {
      return ParakeetStreamingSentryError(mapping: kind)
    }
    switch operation {
    case .start: return ParakeetStreamingSentryError(mappingStartFailure: error) ?? error
    case .finalize: return error
    }
  }

  public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    guard let manager = streamingManager else { throw ASRError.streamingNotSupported }
    await manager.streamAudio(buffer)
  }

  public func finalizeStreaming() async throws -> ASRResult {
    guard let manager = streamingManager else { throw ASRError.streamingNotSupported }
    defer { streamingManager = nil }

    let finalizeStart = CFAbsoluteTimeGetCurrent()
    let text: String
    do {
      text = try await manager.finish()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // #1654: same identity pass as the start leg. See `streamingThrowable` for why a
      // bare `ASRError` is deliberately NOT named here.
      throw Self.streamingThrowable(for: error, operation: .finalize)
    }
    let finalizeEnd = CFAbsoluteTimeGetCurrent()

    let totalElapsed = finalizeEnd - streamingStartTime
    let finalizeElapsed = finalizeEnd - finalizeStart

    return ASRResult(
      text: text,
      // #1678: nil for the same reason as the batch path above — Parakeet does
      // not detect a language, so it must not assert one.
      language: nil,
      duration: totalElapsed,
      processingTime: finalizeElapsed,
      backendType: .parakeet
    )
  }

  public func cancelStreaming() async {
    if let manager = streamingManager {
      await manager.cancel()
      streamingManager = nil
    }
  }

  public func unload() async {
    if let streaming = streamingManager {
      await streaming.cancel()
      streamingManager = nil
    }
    await fluidAsrManager?.cleanup()
    fluidAsrManager = nil
    fluidModels = nil
    isReady = false
  }

  #if DEBUG
    // MARK: #1707 Phase 2 — batch-decode fault oracle (shared-backend overlap
    // Live UAT, §3.2a-i). One armed trial at a time by construction (a DEBUG
    // test seam, never a concurrent-scenario primitive). The first real
    // `transcribe(...)` call after arming is classified `held` (suspends
    // until released); a SECOND call arriving while the trial is still
    // active is classified `newSession` (records timestamps, does not
    // suspend) — this is what lets a Live UAT test prove genuine overlap at
    // the real shared-engine boundary.

    private enum BatchDecodeFaultRole {
      case none
      case held(trialID: String)
      case newSession(trialID: String)
    }

    private var armedBatchDecodeTrialID: String?
    private var batchDecodeHeldClassified = false
    private var batchDecodeHoldContinuation: CheckedContinuation<Void, Never>?

    /// A forgotten release cannot wedge the ASR service process — bounded by
    /// this safety unhold, well past any realistic Live UAT test duration.
    private static let batchDecodeFaultSafetyUnholdSec: Double = 30.0

    /// Arms a one-shot hold for the NEXT `manager.transcribe(...)` call this
    /// actor issues. `package` access: callable from `ASRServiceHandler` in
    /// the sibling `EnviousWisprASRService` target (same package,
    /// `Package.swift`), mirroring `ASRManagerProxy`'s existing `package`
    /// DEBUG methods.
    package func armBatchDecodeHold(trialID: String) {
      armedBatchDecodeTrialID = trialID
      batchDecodeHeldClassified = false
      BatchDecodeFaultSnapshotFile.shared.write(BatchDecodeFaultSnapshotState(trialID: trialID))
    }

    /// Releases a held decode, letting it proceed to the real
    /// `manager.transcribe(...)` call. No-op if `trialID` does not match the
    /// currently-armed trial or nothing is currently held.
    package func releaseBatchDecode(trialID: String) {
      guard armedBatchDecodeTrialID == trialID else { return }
      batchDecodeHoldContinuation?.resume()
      batchDecodeHoldContinuation = nil
    }

    /// Clears all armed/held state and the shared snapshot file, so a
    /// forgotten trial from one Live UAT scenario cannot leak into the next.
    package func clearBatchDecodeFault() {
      batchDecodeHoldContinuation?.resume()
      batchDecodeHoldContinuation = nil
      armedBatchDecodeTrialID = nil
      batchDecodeHeldClassified = false
      BatchDecodeFaultSnapshotFile.shared.clear()
    }

    private func enterBatchDecodeFaultBoundary() async -> BatchDecodeFaultRole {
      guard let trialID = armedBatchDecodeTrialID else { return .none }
      let now = Date().timeIntervalSince1970
      var snapshot =
        BatchDecodeFaultSnapshotFile.shared.read().flatMap { $0.trialID == trialID ? $0 : nil }
        ?? BatchDecodeFaultSnapshotState(trialID: trialID)
      guard !batchDecodeHeldClassified else {
        snapshot.newSessionEntryEpochSec = now
        BatchDecodeFaultSnapshotFile.shared.write(snapshot)
        return .newSession(trialID: trialID)
      }
      batchDecodeHeldClassified = true
      snapshot.heldDecodeEntryEpochSec = now
      BatchDecodeFaultSnapshotFile.shared.write(snapshot)
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        batchDecodeHoldContinuation = cont
        Task { [weak self] in
          try? await Task.sleep(for: .seconds(Self.batchDecodeFaultSafetyUnholdSec))
          await self?.autoReleaseBatchDecodeHoldIfStillHeld(trialID: trialID)
        }
      }
      return .held(trialID: trialID)
    }

    private func exitBatchDecodeFaultBoundary(role: BatchDecodeFaultRole) {
      let now = Date().timeIntervalSince1970
      switch role {
      case .none:
        return
      case .held(let trialID):
        guard var snapshot = BatchDecodeFaultSnapshotFile.shared.read(),
          snapshot.trialID == trialID
        else { return }
        snapshot.heldDecodeCompletionEpochSec = now
        BatchDecodeFaultSnapshotFile.shared.write(snapshot)
      case .newSession(let trialID):
        guard var snapshot = BatchDecodeFaultSnapshotFile.shared.read(),
          snapshot.trialID == trialID
        else { return }
        snapshot.newSessionCompletionEpochSec = now
        BatchDecodeFaultSnapshotFile.shared.write(snapshot)
      }
    }

    private func autoReleaseBatchDecodeHoldIfStillHeld(trialID: String) {
      guard armedBatchDecodeTrialID == trialID, batchDecodeHoldContinuation != nil else { return }
      batchDecodeHoldContinuation?.resume()
      batchDecodeHoldContinuation = nil
    }
  #endif
}
