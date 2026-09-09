@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprFluidAudioBridge
@preconcurrency import FluidAudio
import os

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
  /// #1908 round 10: which generation `streamingManager` was published
  /// under, so `reclaimIfPublished(generation:)` can tell "the exact
  /// attempt that just lost the deadline race" from "an unrelated newer
  /// attempt that happens to be current" before cancelling anything.
  private var publishedStreamingGeneration: UInt64?
  /// #1908 Codex review: bumped by every `startStreaming()` attempt (as its
  /// FIRST statement, before any suspension — round 8 finding: capturing it
  /// AFTER the "cancel existing" await let a second, concurrent
  /// `startStreaming()` call run to completion and publish in the gap, so
  /// the first call's late continuation then captured a NEWER generation
  /// than it should have and overwrote the second call's just-published
  /// stream), by `cancelStreaming()`, and by `unload()`. Checked by
  /// `startStreaming()` after every suspension point, right before it would
  /// act on anything the awaited call returned. FluidAudio's
  /// `loadModels`/`startStreaming` calls do not observe `Task.isCancelled`,
  /// so a superseded attempt keeps running in the background; without these
  /// checks its late completion would publish a stale manager over whatever
  /// a newer session already started. Same fresh-instance/publish-only-if-
  /// current shape as `ASRManager.performLoad`'s `loadGeneration` guard.
  ///
  /// `nonisolated`, lock-backed rather than a plain actor-isolated `var`:
  /// `cancelInFlightStreamingStart()` invalidates THIS attempt's generation
  /// synchronously from `ASRManager`'s `@MainActor`, inside
  /// `withMainActorOrderedDeadline`'s `onTimeout` — which the primitive's own
  /// contract (`TaskTimeout.swift`) requires to stay synchronous and
  /// non-suspending, so it cannot `await` into this actor to bump an
  /// isolated var. Without this, an abandoned attempt's late vendor
  /// completion still passes this actor's OWN generation check (nothing
  /// here was told the manager gave up) and leaks a live streaming session
  /// until the next `startStreaming()`/`unload()` call reclaims it.
  private nonisolated let streamingGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

  /// Reserve this attempt's identity. Callable from any actor/isolation —
  /// `startStreaming(options:)` calls it as its own first statement (this
  /// actor); `ASRManager.startStreaming()` calls it from `@MainActor`,
  /// synchronously, before entering `startStreaming(options:generation:)`,
  /// so it can hand the reserved number to `cancelInFlightStreamingStart()`.
  nonisolated func reserveStreamingGeneration() -> UInt64 {
    streamingGeneration.withLock {
      $0 &+= 1
      return $0
    }
  }

  /// Invalidate a specific in-flight attempt's generation without acquiring
  /// this actor — the whole point (see the property doc above). Bumping
  /// unconditionally (not "only if it still matches `generation`") would let
  /// a call racing in from ANOTHER caller silently invalidate itself too;
  /// comparing first keeps this a no-op once a newer attempt already holds
  /// the counter.
  ///
  /// #1908 round 10 (cloud review P2): the bump alone is NOT enough at the
  /// deadline edge. `withMainActorOrderedDeadline` races the OPERATION's own
  /// `claim()` (won by publishing `self.streamingManager = manager` and
  /// returning up through `ASRManager.startStreaming()`) against the
  /// TIMER's `claim()` (won by calling `cancelInFlightStreamingStart()`,
  /// which reaches here) — and the timer can still win that OUTER race
  /// after the backend has ALREADY published. At that point bumping the
  /// counter invalidates nothing retroactively: `streamingManager` is
  /// already set, `ASRManager.isStreaming` gets forced `false` by
  /// `cancelInFlightStreamingStart()`, and `cancelStreaming()` (guarded on
  /// `isStreaming`) now returns early without ever touching the backend —
  /// so a live microphone/CoreML streaming session stays open until some
  /// UNRELATED later call (`startStreaming()`'s own preamble, or `unload()`)
  /// happens to reclaim it, which under `modelUnloadPolicy = .never` may
  /// never come. So: after invalidating, also fire an unstructured
  /// actor-isolated task that reclaims the manager IF it is still the one
  /// published under this exact generation — never a newer one, which is
  /// what `publishedStreamingGeneration` is for.
  ///
  /// #1908 round 12 (cloud review P2): RETURNS that task rather than firing
  /// it detached. A caller that can itself `await` (`ASRManager.cancelStreaming()`,
  /// unlike the synchronous `onTimeout` this exists for) MUST await the
  /// SAME task, not race it with its own separate reclaim attempt — two
  /// concurrent calls to `reclaimIfPublished` for one generation are
  /// harmlessly idempotent (the second sees nothing left to clear), but
  /// "harmless" here meant the awaited one could see nothing to reclaim and
  /// return immediately while the detached one was still mid-`manager.cancel()`
  /// — the caller believed cancellation was complete while a live
  /// microphone/CoreML session was still tearing down. `@discardableResult`
  /// so the synchronous `onTimeout` caller (which cannot await regardless)
  /// keeps compiling unchanged.
  @discardableResult
  nonisolated func invalidateStreamingGeneration(_ generation: UInt64) -> Task<Void, Never>? {
    let invalidated = streamingGeneration.withLock { current -> Bool in
      guard current == generation else { return false }
      current &+= 1
      return true
    }
    guard invalidated else { return nil }
    return Task { await self.reclaimIfPublished(generation: generation) }
  }

  /// Cancel and clear `streamingManager` ONLY if it is still the exact
  /// instance published under `generation` — a NEWER attempt's own publish
  /// (which sets `publishedStreamingGeneration` to its own, different,
  /// value) must never be touched by an older attempt's late reclaim.
  ///
  /// Not `private` (round 11): `ASRManager.cancelStreaming()` now calls this
  /// directly on the exact backend/generation its own `streamingStartBackendAttempt`
  /// names, rather than a blind `activeBackend.cancelStreaming()` that could
  /// hit a replacement stream (round 7's lesson, applied to the explicit-cancel path too).
  func reclaimIfPublished(generation: UInt64) async {
    guard publishedStreamingGeneration == generation, let manager = streamingManager else { return }
    streamingManager = nil
    publishedStreamingGeneration = nil
    await manager.cancel()
  }

  public var supportsStreaming: Bool { true }

  /// Total download size shown in the progress detail (#1339). The pinned
  /// Parakeet v3 set (4 model dirs + vocab + loose json/txt) measures
  /// 483,256,769 bytes — byte-verified in `workers/parakeet-mirror/
  /// expected-manifest.json` (in-repo since #1348 PR-2a; the bundled
  /// `parakeet-delivery-manifest.json` derives from it).
  static let totalDownloadMB = 483

  public init() {}

  /// FluidAudio's SHARED per-repo cache — the directory EnviousWispr does NOT
  /// own and must never write in (#2483).
  ///
  /// **Named for what it is, not as a default.** It was `defaultModelDirectory`,
  /// and that name is how it ended up as the fallback in three separate places;
  /// each of those was a route back into the shared tree. Nothing may use this as
  /// a fallback. It survives for exactly one purpose: it is the ORACLE for
  /// `ParakeetInstallLocation.repoFolderName`, because its last path component is
  /// the vendor's own `Repo.folderName`, and a test reads it at runtime so our
  /// constant cannot drift from the directory the loader reconstructs.
  public static var vendorSharedDirectory: URL {
    AsrModels.defaultCacheDirectory(for: .v3)
  }

  /// #2697: the protocol's directory-less overloads REFUSE.
  ///
  /// They used to resolve a location themselves, which is how a caller that
  /// never passed one still got a model — from a directory nobody had verified.
  /// `ASRManager` reaches the real `prepare(cacheOnly:modelDirectory:)` for every
  /// production load, so these two are only reachable by a caller that has not
  /// said where the model lives, and the honest answer to that is an error.
  public func prepare() async throws {
    throw ParakeetModelDirectoryUnsetError()
  }

  public func prepare(progressCallback: ProgressCallback?) async throws {
    throw ParakeetModelDirectoryUnsetError()
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
  /// - Parameter modelDirectory: the repo-shaped directory to load from or
  ///   download into. Both vendor entry points below normalise a repo-shaped
  ///   path identically (`AsrModels.load(from:)` re-derives it through
  ///   `repoPath`, and `download(to:)` derives its own parent), so passing
  ///   a repo-shaped path here behaves identically either way.
  public func prepare(
    cacheOnly: Bool, modelDirectory: URL, progressCallback: ProgressCallback?
  ) async throws {
    let handler = Self.makeLoadProgressHandler(progressCallback)

    Self.configureOfflineMode(cacheOnly: cacheOnly)
    do {
      let loadedModels: AsrModels
      if cacheOnly {
        // Delivery-managed: the default cache was admitted by the host's hash
        // gate before this call; offlineMode (armed above) turns any gap
        // into a typed throw the host maps to its repair path.
        loadedModels = try await AsrModels.load(
          from: modelDirectory, version: .v3, progressHandler: handler)
      } else {
        loadedModels = try await AsrModels.downloadAndLoad(
          to: modelDirectory, version: .v3, progressHandler: handler)
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

  /// Protocol path: self-reserves a generation. Other than `ASRManager`
  /// (which needs the generation BEFORE calling in, so it can hand it to
  /// `cancelInFlightStreamingStart()` — see `startStreaming(options:generation:)`
  /// below), any caller (tests included) can use this directly.
  public func startStreaming(options: TranscriptionOptions) async throws {
    try await startStreaming(options: options, generation: reserveStreamingGeneration())
  }

  /// #1908 round 8: takes an ALREADY-RESERVED generation rather than
  /// reserving its own, so the caller (`ASRManager.startStreaming()`) can
  /// reserve synchronously before entering this call and remember which
  /// generation this attempt owns — the whole point being that
  /// `cancelInFlightStreamingStart()` needs that number to invalidate
  /// exactly this attempt if the caller gives up while this call is still
  /// suspended below.
  ///
  /// Reserving happens as the LITERAL FIRST STATEMENT of whichever caller
  /// does it (this method's own preamble here, or `startStreaming(options:)`
  /// above), before any suspension. Reserving after the "cancel existing"
  /// await below (the original #1908 shape) let a concurrent, newer
  /// `startStreaming` call run its own full attempt and publish in the gap
  /// while this one was still suspended at that await; this call would then
  /// capture a generation NEWER than the one it should have raced against
  /// and go on to overwrite the newer call's just-published stream.
  /// Capturing first means whichever call's synchronous prefix runs first
  /// (actor isolation guarantees only one runs at a time until it suspends)
  /// gets the strictly-earlier number, and every check below then correctly
  /// recognizes a call that started before a newer one as superseded.
  func startStreaming(options: TranscriptionOptions, generation myGeneration: UInt64) async throws {
    guard isReady, let models = fluidModels else { throw ASRError.notReady }

    // Cancel any existing streaming session before starting a new one.
    // Prevents double-session state where the old manager is leaked.
    if let existing = streamingManager {
      streamingManager = nil
      publishedStreamingGeneration = nil
      await existing.cancel()
    }
    guard streamingGeneration.withLock({ $0 == myGeneration }) else { throw CancellationError() }

    // #1678: the lock must reach BOTH decode paths. Wiring only the batch call
    // would give a locked user cross-alphabet protection on one path and not
    // the other, with nothing in the UI to say which they were on.
    let config = SlidingWindowAsrConfig.streaming
      .applying(language: Self.fluidLanguage(for: options.language))
    let manager = SlidingWindowAsrManager(config: config)
    do {
      // Vendor API: streaming starts via loadModels(_:) then startStreaming(source:).
      try await manager.loadModels(models)
      guard streamingGeneration.withLock({ $0 == myGeneration }) else {
        await manager.cancel()
        throw CancellationError()
      }
      try await manager.startStreaming(source: .microphone)
    } catch is CancellationError {
      await manager.cancel()
      throw CancellationError()
    } catch {
      // #1654: pin a stable identity before this leaves the service. A cancellation is
      // deliberately excluded above rather than classified — a cancelled stream is not a
      // failure and must never acquire a failure identity.
      await manager.cancel()
      throw Self.streamingThrowable(for: error, operation: .start)
    }
    // #1908: a caller that abandoned this attempt (deadline expiry, via
    // `cancelInFlightStreamingStart()` -> `invalidateStreamingGeneration()`)
    // or a newer session's own `startStreaming()` bumps `streamingGeneration`
    // — never publish over whatever either of them set up in the meantime.
    // Cancel what THIS attempt built instead of leaking it.
    //
    // #1908 round 11: the check and the publish happen INSIDE one lock
    // acquisition (`withLockUnchecked`, not the two-step
    // "check-then-assign" the earlier rounds used) so
    // `invalidateStreamingGeneration`'s own lock-protected bump — which
    // fires from a different, `nonisolated` execution context and can
    // otherwise interleave in the gap between a passed check and the
    // property writes that follow it — cannot land between this check and
    // this publish. `withLockUnchecked` (not `withLock`) because the
    // closure captures and mutates actor-isolated `self` state, which is
    // safe here precisely because this whole method is already
    // actor-isolated and the closure never escapes or crosses an actual
    // concurrency boundary — it runs synchronously, inline, on this call.
    let published = streamingGeneration.withLockUnchecked { current -> Bool in
      guard current == myGeneration else { return false }
      self.streamingManager = manager
      // #1908 round 10: recorded so a LATE invalidation of this exact
      // generation (the deadline's timer winning the outer `claim()` race
      // just after this closure runs, before the caller ever observes
      // success) can still find and reclaim this manager — see
      // `reclaimIfPublished(generation:)`.
      self.publishedStreamingGeneration = myGeneration
      self.streamingStartTime = CFAbsoluteTimeGetCurrent()
      return true
    }
    guard published else {
      await manager.cancel()
      throw CancellationError()
    }
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
    // #1908 round 10: identity-checked, not unconditional — a reclaim task
    // (`reclaimIfPublished`) or a newer `startStreaming()` call could have
    // already replaced `streamingManager` by the time this `defer` runs
    // (both cross a suspension point above); clearing unconditionally could
    // wipe a manager that is not this call's own.
    defer {
      if streamingManager === manager {
        streamingManager = nil
        publishedStreamingGeneration = nil
      }
    }

    // Snapshot before the suspension below — a reclaim task or a newer
    // start could otherwise overwrite `streamingStartTime` while this
    // awaits, corrupting THIS call's own elapsed-time math.
    let streamStart = streamingStartTime
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

    let totalElapsed = finalizeEnd - streamStart
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
    // #1908: bump UNCONDITIONALLY, including when `streamingManager` is still
    // nil — this is also the abandon signal for an in-flight `startStreaming()`
    // that has not published anything yet (`ASRManager.cancelInFlightStreamingStart()`
    // reaches here even while `isStreaming` is false).
    _ = reserveStreamingGeneration()
    if let manager = streamingManager {
      streamingManager = nil
      publishedStreamingGeneration = nil
      await manager.cancel()
    }
  }

  public func unload() async {
    // #1908: same reason as `cancelStreaming()` — an in-flight `startStreaming()`
    // must not publish over an unload that already ran.
    _ = reserveStreamingGeneration()
    if let streaming = streamingManager {
      streamingManager = nil
      publishedStreamingGeneration = nil
      await streaming.cancel()
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
