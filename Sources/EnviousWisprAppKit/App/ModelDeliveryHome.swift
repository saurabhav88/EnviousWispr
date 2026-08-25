import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
@preconcurrency import FluidAudio
import Foundation

/// App-owned home for the model-delivery layer (#1348 Phase 2): owns the
/// single `ModelDeliveryController`, the Parakeet registration built from the
/// bundled signed-app manifest (the trust root), the telemetry bridge onto
/// `model_delivery.*`, and the observable UI mirror the settings row renders
/// (one state stream, two renderers — D6). A narrow home in the #763
/// direction; the composition root holds it as one `let`.
@Observable @MainActor
public final class ModelDeliveryHome {
  public let controller = ModelDeliveryController()
  /// Nil when the bundled manifest failed to load — a can't-happen-in-release
  /// condition (unit-tested against the bundled resource); the Parakeet path
  /// then runs legacy delivery, never crashes.
  public private(set) var parakeetHandle: ParakeetDeliveryHandle?
  private var parakeetIdentity: ModelIdentity?
  private var parakeetRegistration: DeliveryRegistration?

  /// #1386 PR-2. Nil when the bundled multilingual manifest failed to load —
  /// unlike Parakeet there is NO legacy fallback behind it (PR-2 retired
  /// `WhisperKit.download()`), so a nil handle means the multilingual engine
  /// honestly reports "not installed" rather than fetching by an unverified
  /// route. Unit-tested against the bundled resource.
  public private(set) var whisperKitHandle: WhisperKitDeliveryHandle?
  public private(set) var whisperKitRegistration: DeliveryRegistration?

  /// #2108 (epic #2077 chunk 4). The SECOND artifact in the `whisperKit` family:
  /// the small multilingual model Live Preview offers as the universal
  /// alternative to Apple's engine, which needs macOS 26 and only recognises
  /// languages Apple has already installed.
  ///
  /// **Its install directory MUST differ from the transcription model's, and
  /// that directory — not the manifest's `installLocation` token — is what
  /// protects the data.** `CacheAdmission` treats an install directory as
  /// exhaustive truth and deletes every top-level entry the active manifest does
  /// not list, so pointing both registrations at one directory would make each
  /// admission delete the other model's files: a heart-path artifact destroyed
  /// from a limb. The manifest's token is documentary (`DeliveryManifest`
  /// decodes it as a free `String` and never resolves it to a path); this line
  /// is the authority.
  public private(set) var whisperPreviewHandle: WhisperKitDeliveryHandle?
  public private(set) var whisperPreviewRegistration: DeliveryRegistration?

  /// Observable mirror of the Parakeet delivery state for SwiftUI renderers.
  public private(set) var parakeetState: DeliveryState = .notReady

  /// Observable mirror of the PREVIEW model's delivery state (#2123).
  ///
  /// Lives here rather than on the settings page because the page is destroyed
  /// during navigation — the Apple-pack model is window-owned for exactly that
  /// reason — and a 217 MB download must not lose its progress because someone
  /// looked at another tab.
  public private(set) var whisperPreviewState: DeliveryState = .notReady

  /// **A SEPARATE apply guard, not a share of the Parakeet one.** Each mirror
  /// has its own sequencer, each starting at zero, so one shared "last applied"
  /// counter would let whichever model published first suppress the other's
  /// updates — a download that silently stopped reporting progress, which looks
  /// exactly like a stalled download.
  private var lastAppliedPreviewStateSeq: UInt64 = 0

  /// How many updates each mirror has APPLIED. Test seams, because "the mirror
  /// is wired to the right identity" is otherwise unobservable: both mirrors
  /// start `.notReady`, so comparing values cannot tell a working observer from
  /// a deleted one or one filtered on the wrong identity.
  package private(set) var previewStateUpdatesForTests = 0
  package private(set) var parakeetStateUpdatesForTests = 0

  /// The launch probe above has RUN TO COMPLETION.
  ///
  /// A test seam, and the only honest one for this question. A test that needs a
  /// baseline of `previewStateUpdatesForTests` must know the probe is finished,
  /// because the probe is what moves that counter — and it runs in an
  /// unstructured `Task` whose publish can land at any yield.
  ///
  /// **A quiet period is not a completion signal, which is what the first fix for
  /// this got wrong.** Waiting for the counter to stop changing looks like
  /// stability and is still a count: the counter is equally quiet when the task
  /// has not STARTED, or is suspended inside `attachPreviewObserver` or
  /// `recordFirstRunBaseline`, neither of which touches it. Set on the probe's
  /// exit path, this is a claim by the SUBJECT about the subject.
  package private(set) var previewLaunchProbeDidFinishForTests = false

  /// How many times the Parakeet Resume door has REFUSED on the family kill
  /// switch, from EITHER of its two checks. A test seam, and specifically a
  /// POSITIVE one: without it the flag-OFF arm could only assert two absences —
  /// no claim taken, no delivery reached — and an absence cannot distinguish
  /// "the guard refused" from "the door has not run yet", which is the vacuity
  /// this counter exists to remove.
  ///
  /// A flag that is off when the button is pressed takes the SYNCHRONOUS check,
  /// which returns before any `Task` is created, so the count is already correct
  /// when `resumeParakeetDownload()` returns and the flag-OFF arm needs no wait.
  /// The second check can only fire on a flag that flipped inside the window
  /// between the two, which no test stages today.
  package private(set) var parakeetResumeRefusalsForTests = 0
  /// Monotonic apply guard (EG-1 `installStateSeqApplied` precedent, made
  /// REAL per exhaustive r7 finding 7): the sequence is minted at observer-
  /// receive time (controller actor, in publish order) and a MainActor hop
  /// that lands out of order is dropped.
  private var lastAppliedStateSeq: UInt64 = 0
  /// D3 base prop, PER IDENTITY (#1363 §16.2): whether NO admitted cache
  /// existed at launch for each model — computed once during that model's
  /// observer wiring (before any warm-up can run) and flipped false on its
  /// first admission this session. Keyed by identity because EG-1 and Parakeet
  /// share ONE controller and ONE telemetry bridge; a single Bool would stamp
  /// EG-1's events with Parakeet's first-run truth. Missing key ⇒ false (a
  /// model whose baseline was never recorded is treated as not-first-run).
  private var firstRunByIdentity: [ModelIdentity: Bool] = [:]

  /// #1707 Phase 3 (§3.2, row 17) / #1741 Chunk 6 — the shared
  /// `EngineMutationScope` constructed once by the composition root (this
  /// type never references `EngineRecoveryGate` by concrete type). Guards
  /// Parakeet's Settings Download/Cancel — a separate guarded site from
  /// `ensureEngineWarm()`, since Parakeet delivery admission does not always
  /// route through it. Required at construction (no default) — replaces the
  /// old defaulted `tryBeginEngineMutation`/`endEngineMutation`/
  /// `wakeRecoveryIfOwed` closure triplet; the scope's own `onRefused`
  /// closure now owns refusal telemetry, so this home no longer emits it.
  let engineMutationScope: EngineMutationScope

  /// #1741 Chunk 6 — the ONLY seam this type exposes for the two bundled
  /// manifest loads below. Production ALWAYS passes `.main` (the signed
  /// app's own bundle stays the trust root, contract §4a — unchanged);
  /// `WisprBootstrapper` is the sole production construction site and does
  /// so explicitly. A unit-test process's own `Bundle.main` cannot see these
  /// resources (they ride the app target, not any framework/test bundle),
  /// so tests pass a bundle pointed at the SAME committed manifest files
  /// instead of a divergent fixture. Internal, not public — no other
  /// consumer needs it.
  /// - Parameter appSupportOverride: roots the metadata and WhisperKit install
  ///   directories somewhere other than the user's real Application Support.
  ///   Production never passes it. Tests do, because construction now runs a
  ///   no-fetch launch probe against those directories, and a suite that reads
  ///   the real ones has a fixture that changes depending on whether the machine
  ///   running it has ever used the feature. Parakeet's ASR cache is deliberately
  ///   NOT rerouted: it comes from `AsrModels.defaultCacheDirectory` and is not
  ///   part of what the probe touches.
  /// - Parameter deliveryFlagDefaults: where the delivery kill switches are read
  ///   from. Production never passes it, so both handles fall back to the shared
  ///   suite exactly as before. Tests pass an in-memory suite, because the guard
  ///   in `startPreviewDownload` reads this and the only alternative way to
  ///   exercise it would be writing an operational kill switch into the real
  ///   store on a developer's machine.
  init(
    engineMutationScope: EngineMutationScope, manifestBundle: Bundle,
    appSupportOverride: URL? = nil, deliveryFlagDefaults: UserDefaults? = nil
  ) {
    self.engineMutationScope = engineMutationScope
    let appSupportRoot =
      appSupportOverride
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    do {
      let manifest = try DeliveryManifest.loadBundled(
        resource: "parakeet-delivery-manifest", bundle: manifestBundle)
      let identity = manifest.identity
      let registration = DeliveryRegistration(
        manifest: manifest,
        installDirectory: AsrModels.defaultCacheDirectory(for: .v3),
        metadataDirectory:
          appSupportRoot
          .appendingPathComponent("EnviousWispr/ModelDelivery", isDirectory: true))
      parakeetIdentity = identity
      parakeetRegistration = registration
      // #2119: reclaim staging abandoned by a superseded revision of THIS model.
      Task { await controller.sweepSupersededStaging(registration) }
      // The kill-switch store is INJECTED, exactly as its two siblings below
      // are (`:whisperKitHandle`, `:whisperPreviewHandle`). Omitting it made
      // this handle resolve `nil` to the real operational suite, so no test
      // could exercise the family flag without writing a live delivery kill
      // switch onto a developer's machine (#2139). Production is unchanged:
      // the only caller that passes a non-nil value is the test suite.
      parakeetHandle = ParakeetDeliveryHandle(
        controller: controller, registration: registration, defaults: deliveryFlagDefaults)
      wireObservers(identity: identity)
    } catch {
      Task {
        await AppLogger.shared.log(
          "Model delivery manifest unavailable — Parakeet stays on the legacy path: \(error)",
          level: .info, category: "Delivery")
      }
    }

    // The multilingual (WhisperKit) registration, built beside the shared
    // controller (#1386 PR-2). It needs NO second telemetry observer: the
    // observers wired above are per-identity for Parakeet's mirror only, and the
    // event bridge below them is already generic across every identity.
    do {
      let manifest = try DeliveryManifest.loadBundled(
        resource: "whisperkit-delivery-manifest", bundle: manifestBundle)
      let appSupport = appSupportRoot
      let registration = DeliveryRegistration(
        manifest: manifest,
        installDirectory: appSupport.appendingPathComponent(
          "EnviousWispr/Models/whisper", isDirectory: true),
        metadataDirectory: appSupport.appendingPathComponent(
          "EnviousWispr/ModelDelivery", isDirectory: true))
      whisperKitRegistration = registration
      Task { await controller.sweepSupersededStaging(registration) }
      whisperKitHandle = WhisperKitDeliveryHandle(
        controller: controller, registration: registration, defaults: deliveryFlagDefaults)
      let home = self
      Task { await home.recordFirstRunBaseline(for: registration) }
    } catch {
      Task {
        await AppLogger.shared.log(
          "Multilingual delivery manifest unavailable — the engine will report not-installed: "
            + "\(error)",
          level: .info, category: "Delivery")
      }
    }

    // #2108: the Live Preview universal model. Registered here, beside the two
    // above, because this type is the single owner of "which models exist and
    // where they install"; a second home would create two answers to one
    // question. No telemetry observer for the same reason the block above needs
    // none — the observers are Parakeet-mirror-specific and the event bridge
    // below them is already generic across every identity.
    //
    // The first-run baseline IS recorded, like its siblings.
    //
    // An earlier version skipped it, reasoning that the call exists to notice a
    // model a user already had before delivery managed it — and nothing has ever
    // put this artifact on a user's disk. That reasoning was about the wrong
    // question. The field answers "was there NO admitted cache at launch", which
    // on a fresh install is TRUE and worth recording; and the read side treats a
    // MISSING key as `false`, so skipping does not leave the answer unknown, it
    // leaves it silently wrong. Every event from a user's first install would
    // have been stamped not-first-run. Cloud review caught it.
    do {
      let manifest = try DeliveryManifest.loadBundled(
        resource: "whisperkit-preview-delivery-manifest", bundle: manifestBundle)
      let appSupport = appSupportRoot
      let registration = DeliveryRegistration(
        manifest: manifest,
        // `whisper-preview`, deliberately a SIBLING of `whisper` and never that
        // directory. See the property's own doc for what sharing one would do.
        installDirectory: appSupport.appendingPathComponent(
          "EnviousWispr/Models/whisper-preview", isDirectory: true),
        // The SHARED metadata directory is safe: staging paths and admission
        // markers key on the full `ModelIdentity.cacheKey`, which includes the
        // variant, and the two manifests differ by variant. Only the install
        // directory is exhaustive.
        metadataDirectory: appSupport.appendingPathComponent(
          "EnviousWispr/ModelDelivery", isDirectory: true))
      whisperPreviewRegistration = registration
      Task { await controller.sweepSupersededStaging(registration) }
      whisperPreviewHandle = WhisperKitDeliveryHandle(
        controller: controller, registration: registration, defaults: deliveryFlagDefaults)
      let previewHome = self
      let previewIdentity = manifest.identity
      // The launch PROBE (#2123 whole-diff review).
      //
      // A model admitted in a PREVIOUS app session leaves this controller with no
      // in-memory entry, so there is nothing for a fresh observer to be told
      // about and the card reports "Not downloaded yet" — hiding Remove — for a
      // model that is on disk. `recordFirstRunBaseline` cannot fix that: it
      // records whether this is a first run, it does not publish a state. So the
      // launch path has to probe, and `admitIfComplete` is the safe one: it
      // reaches `startAttempt` with `fetchIfMissing: false`, so it can adopt what
      // is already complete and can never start a download.
      //
      // ONE ordered task because ONE ordering is load-bearing: the baseline must
      // be taken BEFORE the probe, since it records `!admitted` and the probe is
      // what changes `admitted`.
      //
      // Attach-before-probe is NOT load-bearing, and the first version of this
      // comment claimed it was. `ModelDeliveryController.addStateObserver`
      // replays the current state of every existing entry to a newly attached
      // observer, so a probe that publishes first is still delivered. Verified by
      // mutation: reversing these two lines leaves the suite green. Sequencing
      // them anyway costs nothing and reads in the order it happens.
      Task {
        await previewHome.attachPreviewObserver(identity: previewIdentity)
        await previewHome.recordFirstRunBaseline(for: registration)
        _ = await previewHome.controller.admitIfComplete(registration)
        previewHome.previewLaunchProbeDidFinishForTests = true
      }
    } catch {
      Task {
        await AppLogger.shared.log(
          "Live Preview model manifest unavailable — the universal preview engine will report "
            + "unavailable-in-this-build (#2123: NOT not-installed, since no download can "
            + "supply what this build never shipped): \(error)",
          level: .info, category: "Delivery")
      }
    }
  }

  /// Mirror the PREVIEW model's delivery state (#2123).
  ///
  /// **Called from the preview's own registration block, never from Parakeet's.**
  /// The first version nested this inside `wireObservers`, which only runs when
  /// the PARAKEET manifest loads — so a build where Parakeet failed to register
  /// and the preview succeeded would leave this mirror permanently unwired, and
  /// the picker would show a download that never appears to start. Two
  /// registrations, two independent wirings.
  ///
  /// `async` rather than spawning its own detached task, so the registration
  /// block reads as the sequence it is. NOT because a late attach would lose a
  /// publish — `addStateObserver` replays each existing entry's current state to
  /// a new observer, which is what makes attach order safe either way.
  private func attachPreviewObserver(identity: ModelIdentity) async {
    let home = self
    let sequencer = DeliveryStateSequencer()
    await controller.addStateObserver { observedIdentity, state in
      guard observedIdentity == identity else { return }
      // Minted on the controller actor in publish order, applied on the main
      // actor only if newer — the same discipline as the Parakeet mirror, with
      // its OWN counter. See `lastAppliedPreviewStateSeq`.
      let seq = sequencer.next()
      Task { @MainActor in
        guard seq > home.lastAppliedPreviewStateSeq else { return }
        home.lastAppliedPreviewStateSeq = seq
        home.whisperPreviewState = state
        home.previewStateUpdatesForTests += 1
      }
    }
  }

  private func wireObservers(identity: ModelIdentity) {
    let home = self
    let registration = parakeetRegistration
    let sequencer = DeliveryStateSequencer()
    Task {
      if let registration {
        let admitted = await controller.isAdmitted(registration)
        await MainActor.run { home.firstRunByIdentity[identity] = !admitted }
      }
      await controller.addStateObserver { observedIdentity, state in
        guard observedIdentity == identity else { return }
        // Mint the sequence HERE (publish order on the controller actor);
        // apply on MainActor only if newer than the last applied.
        let seq = sequencer.next()
        Task { @MainActor in
          guard seq > home.lastAppliedStateSeq else { return }
          home.lastAppliedStateSeq = seq
          home.parakeetState = state
          home.parakeetStateUpdatesForTests += 1
          if case .admitted = state { home.firstRunByIdentity[observedIdentity] = false }
        }
      }
      // First-run flip for EVERY identity (grounded r1 P3): the observer above
      // is Parakeet-filtered for its state mirror, so EG-1's `.admitted` would
      // never flip EG-1's first-run flag and EG-1 events would report
      // first_run=true for the whole process. This dedicated observer flips any
      // identity's flag on admission — idempotent and order-independent (once
      // false it stays false; `attempt_completed` is emitted before `.admitted`,
      // so the fetch-path funnel events still read the true baseline).
      await controller.addStateObserver { observedIdentity, state in
        guard case .admitted = state else { return }
        Task { @MainActor in home.firstRunByIdentity[observedIdentity] = false }
      }
      await controller.addEventObserver { observedIdentity, event in
        Task { @MainActor in
          ModelDeliveryTelemetryBridge.capture(
            event, identity: observedIdentity,
            firstRun: home.firstRunByIdentity[observedIdentity] ?? false)
        }
      }
    }
  }

  /// Record a model's first-run baseline BEFORE its first warm-up (#1363
  /// §16.2). EG-1 shares this home's controller + telemetry bridge, so its
  /// runtime calls this once at construction to seed its own first-run truth;
  /// the shared event observer above then stamps EG-1's `model_delivery.*`
  /// events with EG-1's baseline, never Parakeet's. Idempotent; a later
  /// `.admitted` for the identity flips it false via the state observer.
  public func recordFirstRunBaseline(for registration: DeliveryRegistration) async {
    let admitted = await controller.isAdmitted(registration)
    firstRunByIdentity[registration.manifest.identity] = !admitted
  }

  /// Settings-row Cancel (D6 state 11: acknowledgment is instant by design —
  /// the controller's cancel resolves only after the drain).
  public func cancelParakeetDownload() {
    guard let identity = parakeetIdentity else { return }
    Task { [weak self] in
      guard let self else { return }
      // #1707 Phase 3 (§3.2, row 17): hold a mutation claim for the FULL
      // cancel-drain.
      _ = await self.engineMutationScope.withClaim(site: "parakeetCancelDownload") {
        _ = await self.controller.cancel(identity)
      }
    }
  }

  // MARK: - #2123: the preview model's own controls

  /// Start, resume or retry the preview model's download — one method, because
  /// from the delivery layer's side those are the same operation and only the
  /// user-facing verb differs (the card decides which word to show).
  ///
  /// **No mutation claim, unlike Parakeet's.** That claim serializes changes to
  /// the ENGINE the heart transcribes with; this model is a display-only limb
  /// that the heart never loads, so taking the claim would let a preview
  /// download block a dictation from switching engines — the limb interfering
  /// with the heart, which is the one thing this feature must never do.
  /// **Honours the WhisperKit family kill switch** (#2137 cloud review). The
  /// primary WhisperKit download door guards `handle.isEnabled()` immediately
  /// before `ensureAvailable()` (`WhisperKitDeliveryWiring.swift:74,125`), because
  /// `ensureAvailable` does NOT enforce the flag itself. This door did not, so
  /// with `modelDelivery.whisper_kit.enabled` set false an operator had disabled
  /// the whole family and this path would still start a 217 MB fetch — bypassing
  /// the relaunch-free delivery rollback that flag exists to provide.
  ///
  /// The preview model IS in that family (same `whisper_kit` registration family,
  /// differing only by variant), so one flag correctly covers both.
  ///
  /// Adds a guard only to THIS door, because the other two doors already carry
  /// the family's answer and they do not agree with each other:
  ///
  /// - `cancelActiveFetch()` is NOT gated (`WhisperKitModelDelivery.swift:111`),
  ///   so Cancel stays reachable with the flag off. That is the right shape — a
  ///   kill switch on delivery must not strand a user mid-download with no way
  ///   to stop it, and cancelling starts no network work.
  /// - `remove()` IS gated and returns `false` without touching the controller
  ///   (`WhisperKitModelDelivery.swift:124`). That is deliberate and owned
  ///   there: the flag stands down the WHOLE delivery layer, deletions included
  ///   (EG-1 §16.6 precedent). So with the flag off the user genuinely CANNOT
  ///   remove the model, and the model staying on disk is the intended
  ///   consequence of an operator freezing delivery, not a defect here.
  ///
  /// Do not "fix" that asymmetry from this file. Changing `remove()` would
  /// change a shared primitive the main transcription model also uses, against
  /// its owner's stated intent.
  public func startPreviewDownload() {
    guard let handle = whisperPreviewHandle else { return }
    guard handle.isEnabled() else {
      // Logged rather than silent: a Download button that does nothing is
      // otherwise indistinguishable from a broken one, and the flag is remote,
      // so whoever debugs this will not know it was set.
      Task {
        await AppLogger.shared.log(
          "Preview download refused: the whisper_kit delivery kill switch is off "
            + "(modelDelivery.whisper_kit.enabled = false)",
          level: .info, category: "Delivery")
      }
      return
    }
    Task { _ = await handle.ensureAvailable() }
  }

  /// Called BEFORE the preview model's files are deleted, so whoever holds the
  /// loaded model can let go of it first.
  ///
  /// **Unlinking an open file does not reclaim its blocks.** macOS lets the
  /// delete succeed while a mapping is alive, and the space only returns when the
  /// last handle closes — so deleting under a loaded engine frees nothing until
  /// something drops it, and nothing would, if the user never records again.
  /// Reclaiming the disk is the entire point of this control, so the release is
  /// part of removal rather than a consequence of it.
  /// Awaited before the files are deleted, and its completion is the promise that
  /// nothing still holds the model. Async on purpose: a synchronous hook can only
  /// REQUEST a release, and a live session owns the engine until its own
  /// asynchronous teardown finishes.
  public var drainPreviewHoldersBeforeRemoval: (() async -> Void)?

  /// Called once the files are gone, so previews can run again.
  public var previewRemovalDidFinish: (() -> Void)?

  /// Delete the preview model and reclaim its ~217 MB.
  ///
  /// The controller's `remove` is already thorough and ordered correctly: it
  /// cancels anything in flight, deletes the admission MARKER FIRST so
  /// `isAdmitted()` goes false immediately, then the component roots, then
  /// staging. Nothing here re-implements that.
  ///
  /// **Two earlier versions of this comment were wrong, and the second was worse
  /// than the first, so the reasoning is recorded rather than the conclusion.**
  ///
  /// First it claimed the next recording would release the cached engine via
  /// `modelNotInstalled`. The bound is real — every recording resolves before it
  /// can reuse a cached engine, and the blocked path releases on ANY refusal —
  /// but naming one reason was wrong: the resolver checks heart contention FIRST,
  /// so a recording starting while the transcription engine streams refuses with
  /// `heartIsStreaming` instead.
  ///
  /// Then it claimed the disk space returns immediately. It does not. Unlinking
  /// a file that is open or memory-mapped succeeds, but its BLOCKS are not
  /// reclaimed until the last handle closes — and "the next recording" may never
  /// come, so a user who removes the model and stops using the app would free
  /// nothing at all. Reclaiming space is the whole point of this control, so it
  /// cannot depend on a later event.
  ///
  /// Hence `drainPreviewHoldersBeforeRemoval`, AWAITED before the delete: every
  /// holder lets go, then the files go. Awaited rather than merely called,
  /// because a synchronous hook can only request a release — a live session owns
  /// its engine until its own asynchronous teardown completes.
  /// The order removal actually executed in, for tests.
  ///
  /// A seam because the ORDER is the contract and nothing else can observe it.
  /// Asserting that removal "finished after the drain" stays green with the
  /// delete moved first, since the finish callback trails both either way —
  /// cloud review demonstrated exactly that against an earlier test of mine.
  package private(set) var removalStepsForTests: [String] = []

  /// The removal in flight, so a second press joins nothing rather than starting
  /// a competing delete.
  private var removalTask: Task<Void, Never>?

  /// The actual deletion, replaceable by tests.
  ///
  /// **Because the registration points at the REAL Application Support
  /// directory.** `manifestBundle` redirects only where manifests are READ from;
  /// the install root and the shared admission metadata are the user's own. A
  /// test that calls the real removal therefore deletes a developer's installed
  /// preview model when the suite runs — which is why the observer test above
  /// deliberately uses a non-destructive trigger, and why the removal tests must
  /// substitute this. Cloud review caught the regression.
  package var deletePreviewModelOverrideForTests: (() async -> Void)?

  public func removePreviewModel() {
    guard let handle = whisperPreviewHandle else { return }
    // **Single-flight the WHOLE operation, not just the drain.** Guarding only
    // the coordinator's drain let two presses share it and then run two deletes
    // and two finish callbacks — and one finish lifts the suppression while the
    // other removal is still going, reopening the window it exists to close.
    // The button stays on screen throughout, so a second press is ordinary.
    guard removalTask == nil else { return }
    removalStepsForTests = []
    let task = Task { [weak self] in
      // AWAIT the drain, do not merely request it. Every holder must be gone
      // before the unlink, or the blocks stay allocated behind an open mapping.
      await self?.drainPreviewHoldersBeforeRemoval?()
      self?.removalStepsForTests.append("drain")
      if let substitute = self?.deletePreviewModelOverrideForTests {
        await substitute()
      } else if await handle.remove() == false {
        // `remove()` refuses when the family kill switch is off and deletes
        // nothing (`WhisperKitModelDelivery.swift:124`, deliberate). Logged for
        // the same reason the download refusal is: the flag is set remotely, so
        // whoever reads the "Remove does nothing" report cannot otherwise tell a
        // stood-down delivery layer from a broken button.
        //
        // KNOWN LIMIT, deliberately not widened here: the user still sees no
        // explanation, only a Remove that leaves the model in place. Surfacing
        // one needs new user-facing copy and a new card state, which is a
        // product decision rather than a review fix.
        self?.removalStepsForTests.append("refused")
        await AppLogger.shared.log(
          "Preview removal deleted nothing: the whisper_kit delivery kill switch "
            + "is off (modelDelivery.whisper_kit.enabled = false)",
          level: .info, category: "Delivery")
      }
      self?.removalStepsForTests.append("delete")
      // Only now may a preview run again: until the marker is deleted, a
      // resolution would still read the model as admitted.
      //
      // Runs UNCONDITIONALLY, including on the refusal above, and that is not an
      // oversight. This signal means "no longer removing", never "removal
      // succeeded" — it clears `isRemovingModel` in the coordinator. Skipping it
      // on a refusal would leave that suppression latched forever and kill Live
      // Preview for the rest of the launch, trading a model that will not delete
      // for a feature that will not run.
      self?.previewRemovalDidFinish?()
      self?.removalStepsForTests.append("finish")
      self?.removalTask = nil
    }
    removalTask = task
  }

  /// Stop a download in flight. Safe when nothing is running: the controller
  /// reports `nothingToCancel` and no state moves.
  public func cancelPreviewDownload() {
    guard let handle = whisperPreviewHandle else { return }
    Task { await handle.cancelActiveFetch() }
  }

  /// Settings-row Resume / Try Again: re-enters the single door (resume-aware
  /// by construction — staged partials survive a cancel).
  ///
  /// **Honours the parakeet family kill switch** (#2139). `ensureAvailable()` does
  /// NOT enforce the flag — it is a straight pass-through to
  /// `ModelDeliveryController.ensureModelAvailable`, and the controller's flag
  /// snapshot drives revalidation, source selection and telemetry, never a
  /// refusal. So for FETCH the enforcement is caller-owned, and a door that omits
  /// the check does not weaken the flag, it ignores it. (Deletion is different and
  /// is guarded centrally inside `sweepSupersededStaging` — do not read this
  /// comment as a claim about the whole controller.)
  ///
  /// **Three delivery-managed doors reach a Parakeet fetch, and this was the only
  /// unguarded one.** Automatic warm-up checks `isEnabled()` immediately before
  /// its own `ensureAvailable()`; the one-shot load-miss `repair()` in the same
  /// warm-up runs under that call's own already-taken answer, deliberately, so it
  /// is not re-checked here or there; this door checked nothing at all, so an
  /// operator who had frozen delivery could still start a multi-gigabyte fetch
  /// from Settings.
  ///
  /// **What the flag does NOT do**, so nobody reads this guard as more than it is:
  /// it stands owned delivery down and hands Parakeet back to the legacy
  /// FluidAudio path, which fetches on its own (`parakeetCacheOnly = false`). It
  /// also does not stop an attempt already in flight — the controller snapshots
  /// flags once per attempt — so flipping it mid-download leaves the Settings row
  /// showing progress and Cancel, exactly as before.
  ///
  /// **Checked TWICE, and the pair is deliberate.**
  ///
  /// The synchronous check is the one that matters for the ordinary case: it
  /// refuses before any `Task` exists, so a refused download never takes an
  /// engine mutation claim and never serialises against a dictation's engine
  /// switch — the limb interfering with the heart, for work that was never going
  /// to happen.
  ///
  /// The re-read inside the `Task`, immediately before the claim, closes what the
  /// synchronous check alone leaves open: the flag is read on the main actor and
  /// the `Task` runs later, so an operator flip landing in that window would
  /// otherwise start the fetch on a stale answer. It NARROWS rather than closes —
  /// the controller snapshots flags once per attempt, so some window always
  /// remains between the last read and the bytes moving, and there is no site
  /// that removes it. It is here because it is three lines and the failure is
  /// SILENT: a fetch begins that an operator asked to stop, and nothing says so.
  ///
  /// `cancelParakeetDownload` is deliberately NOT gated, and must stay that way: a
  /// delivery kill switch must never strand someone mid-download with no way to
  /// stop it, and cancelling starts no network work. Same shape as
  /// `WhisperKitDeliveryHandle.cancelActiveFetch()`
  /// (`WhisperKitModelDelivery.swift:111`), which is ungated for that stated reason.
  public func resumeParakeetDownload() {
    guard let handle = parakeetHandle else { return }
    guard handle.isEnabled() else {
      parakeetResumeRefusalsForTests += 1
      // A DEBUG diagnostic, and it is worth being exact about that rather than
      // calling it "logging the refusal": `AppLogger.log` compiles to a no-op in
      // release, so this reaches a developer reproducing the report and never a
      // shipping user. It earns its place anyway — the flag is set remotely, so
      // whoever debugs this would otherwise have no way to tell a refused Resume
      // from a broken one.
      //
      // KNOWN LIMIT, deliberately not fixed here: in a shipping build the row
      // still offers Resume and pressing it now does nothing visible. Giving the
      // row a disabled state would be a user-facing change to a surface whose
      // whole point is that the flag ships absent, so it belongs to whoever
      // decides that, not to this internal rollback fix.
      Task {
        await AppLogger.shared.log(
          "Parakeet resume refused: the parakeet delivery kill switch is off "
            + "(modelDelivery.parakeet.enabled = false)",
          level: .info, category: "Delivery")
      }
      return
    }
    Task { [weak self] in
      guard let self else { return }
      // The re-read (see the doc comment above). Still BEFORE the claim, for the
      // same reason the synchronous one is: a refusal must not take the claim.
      guard handle.isEnabled() else {
        self.parakeetResumeRefusalsForTests += 1
        await AppLogger.shared.log(
          "Parakeet resume refused: the parakeet delivery kill switch went off "
            + "between the button and the download starting "
            + "(modelDelivery.parakeet.enabled = false)",
          level: .info, category: "Delivery")
        return
      }
      // #1707 Phase 3 (§3.2, row 17): hold a mutation claim for the FULL
      // download.
      _ = await self.engineMutationScope.withClaim(site: "parakeetResumeDownload") {
        _ = await handle.ensureAvailable()
      }
    }
  }
}

/// The ONE authority for user-facing delivery-failure copy (D6 states
/// 7/8/10/11 + the captive-portal sentence) — onboarding's friendly-error
/// mapping and the settings row both render from here, so the two surfaces
/// can never drift.
public enum ModelDeliveryCopy {
  public static func message(reason: DeliveryFailureClass, detail: String?) -> String {
    switch reason {
    case .sourceUnreachable, .sourceTimeout, .source5xx, .source4xx:
      return "Can't reach the download server. Check your connection and try again."
    case .insufficientDisk:
      return
        "Not enough free space to install the speech model. Free up about 1 GB and try again."
    case .integrityMismatch, .cacheRepairFailed:
      if detail == "intercepted_network" {
        return
          "If you are on hotel or public Wi-Fi, finish signing in to the network, then try again."
      }
      return
        "The download couldn't be verified. Try again, and if this keeps happening, contact support."
    case .cancelled:
      return "Download paused. Resume anytime."
    case .permissionDenied, .unknown:
      return
        "The download couldn't finish. Try again, and if this keeps happening, contact support."
    }
  }
}

/// Maps controller `DeliveryEvent`s 1:1 onto D3's `model_delivery.*` PostHog
/// events with the base properties (family/model_name/revision/variant come
/// from the identity; `schema_version`/`app_version` are constants of this
/// build). Sibling of `EGOneTelemetryBridge`.
@MainActor
enum ModelDeliveryTelemetryBridge {
  static func capture(_ event: DeliveryEvent, identity: ModelIdentity, firstRun: Bool) {
    var props: [String: String] = [
      "family": identity.family.rawValue,
      "model_name": identity.name,
      "revision": identity.revision,
      "variant": identity.variant,
      "first_run": String(firstRun),
      // D3 base prop; refined per event below (n/a where no source applies —
      // exhaustive r7 finding 8).
      "source_id": "n/a",
      "schema_version": "1",
    ]
    let name: String
    switch event {
    case .attemptStarted(let resumed):
      name = "attempt_started"
      props["resumed"] = String(resumed)
    case .attemptCompleted(
      let durationBucket, let bytesBucket, let sourcesUsed, let finalSourceID, let repaired):
      name = "attempt_completed"
      props["duration_bucket"] = durationBucket
      props["bytes_downloaded_bucket"] = bytesBucket
      props["sources_used"] = String(sourcesUsed)
      props["final_source_id"] = finalSourceID
      props["source_id"] = finalSourceID
      props["repaired_components_count"] = String(repaired)
    case .attemptFailed(let reason, let failingSourceID, let detail):
      name = "attempt_failed"
      props["reason"] = reason.rawValue
      if let failingSourceID {
        props["failing_source_id"] = failingSourceID
        props["source_id"] = failingSourceID
      }
      if let detail { props["detail"] = detail }
    // The two source ids are LOCAL-LOG ONLY (#2135) and are deliberately
    // dropped here: adding them would change this event's PostHog shape,
    // which this issue's subject is not.
    case .sourceFailover(let reason, _, _):
      name = "source_failover"
      props["reason"] = reason.rawValue
    case .validationRepair(let componentsCount, let trigger):
      name = "validation_repair"
      props["components_count"] = String(componentsCount)
      props["trigger"] = trigger.rawValue
    case .cancel(let phaseAtCancel, let resumable):
      name = "cancel"
      props["phase_at_cancel"] = phaseAtCancel
      props["resumable"] = String(resumable)
    case .flagActive(let flag, let value):
      name = "flag_active"
      props["flag"] = flag
      props["value"] = value
    case .admittedWithoutFetch(let reason):
      // #1363 Decision E: a model became available with no fetch (warm-relaunch
      // marker fast path or existing-file adoption). Distinct from
      // attempt_completed; "available in the field" = attempt_completed OR
      // admitted_without_fetch.
      name = "admitted_without_fetch"
      props["reason"] = reason.rawValue
    }
    TelemetryService.shared.modelDeliveryEvent(name: name, properties: props)
  }
}

/// Lock-protected monotonic counter for the state observer's apply guard —
/// minted on the controller actor's publish path, compared on MainActor.
// State-publication sequencing: canonical `DeliveryStateSequencer` lives in
// EnviousWisprModelDelivery (one type, all family projections).
