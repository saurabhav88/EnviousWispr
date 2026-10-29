import AVFoundation
import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// PR10 of #763 — behavior tests for `RecordingStarter`.
///
/// `start()` and `toggle(source:)` dispatch `.preWarm` and `.toggleRecording`
/// against real pipelines whose deep behavior depends on a live audio path;
/// end-to-end correctness is covered by founder / automated UAT (§11/§12 of
/// the PR10 plan). These tests verify what is mechanically verifiable in a
/// unit context without booting AVAudioEngine + ASR:
///   - construction does not crash;
///   - `start()` and `toggle(source:)` return cleanly when the active
///     pipeline is already active (early-return guard);
///   - both code paths clear `lastRecordingResult.polishError` on a new
///     start (idle → active transition);
///   - `isProcessing` is false when both pipelines are idle;
///   - `isProcessing` flips with `activeBackendType` reads.
@MainActor
@Suite struct RecordingStarterStartPathTests {

  private struct Fixture {
    let starter: RecordingStarter
    let finalizer: RecordingFinalizer
    let kernelDriver: KernelDictationDriver
    let whisperKernelDriver: KernelDictationDriver
    let asr: RouterTestASRManager
    let audio: RouterTestAudioCapture
    let permissions: PermissionsService
    let lockBox: TestRecordingLockedBox
    let lastRecordingResult: LastRecordingResult
    let overlay: OverlayDirector
    /// The overlay's fake host, held so a case can press the button a user sees.
    let overlayHost: WindowlessOverlayHost
    let settings: SettingsManager
    /// What the recovery notice's Discard button reached, and whether the notice
    /// was still up when it did (#2292 C4b).
    let discards: DiscardProbe
    /// #2648: the real claim the starter was wired to, so an admission row can
    /// hold it as another workload before pressing record.
    let engineLease: EngineLease
    /// #3973 C1: the waiting-press owner, its log and its clock.
    let pendingRequests: PendingDictationRequests
    let turnLog: TurnLogSink
    let turnClock: TurnClock
    /// #3973 C1: the real lifecycle owner, when the fixture was asked for one (`withLifecycle`).
    let lifecycle: DictationLifecycleCoordinator?
  }

  /// What the pill is showing, as a person would describe it (#2292 C6).
  ///
  /// These replace `overlay.currentIntent`, a projection of reducer state that
  /// this chunk deletes. They read the RENDER model, so they answer what reached
  /// the screen rather than what the reducer decided — the two differ when a
  /// render is refused or deferred, and for a suite asking "what did the start
  /// path put in front of the user" the rendered answer is the one that matters.
  ///
  /// The cold-boot predicate asserts the ENGINE NAME too. It lives in the
  /// notice's secondary line, which is the text the user actually reads, and
  /// `currentIntent == .cachingModel(engineLabel:)` was the only thing checking
  /// the label at all — through a value nobody sees.
  private static func showsColdBoot(_ overlay: OverlayDirector, engine: String) -> Bool {
    guard case .notice(let notice)? = overlay.renderModel.state.presentation?.content else {
      return false
    }
    return notice.kind == .warmingUp
      && notice.secondaryText == DictationNarrator.coldStartSubtitle(engineLabel: engine)
  }

  private static func showsRecoveryOffer(_ overlay: OverlayDirector) -> Bool {
    guard case .notice(let notice)? = overlay.renderModel.state.presentation?.content else {
      return false
    }
    return notice.kind == .recovery
  }

  /// #2648 — the shared-resource refusal, read as the sentence a person sees.
  ///
  /// A `.warning` intent renders as a `.notification` notice whose `text` IS
  /// `DictationNarrator.copy(for:)` (`PillCatalog.swift:210-216`), so comparing
  /// against the narrator asserts the rendered sentence without freezing a
  /// second copy of the words in this file.
  private static func showsSharedEngineBusy(
    _ overlay: OverlayDirector, holder: SharedEngineHolder
  ) -> Bool {
    guard case .notice(let notice)? = overlay.renderModel.state.presentation?.content else {
      return false
    }
    return notice.text == DictationNarrator.copy(for: .sharedEngineBusy(holder: holder))
  }

  /// #4069: the "dictation is off during meetings" refusal, read as the sentence a person sees.
  private static func showsDictationOffDuringMeeting(_ overlay: OverlayDirector) -> Bool {
    guard case .notice(let notice)? = overlay.renderModel.state.presentation?.content else {
      return false
    }
    return notice.text == DictationNarrator.copy(for: .dictationOffDuringMeeting)
  }

  private static func showsRecording(_ overlay: OverlayDirector) -> Bool {
    if case .recording? = overlay.renderModel.state.presentation?.content { return true }
    return false
  }

  /// Records Discard presses and what the overlay was showing at the instant of
  /// each, so a case can pin OWNER-BEFORE-DISMISS rather than merely both.
  /// Lets a fixture closure reach the fixture it is part of (#3973 C1).
  @MainActor
  private final class FixtureBox {
    var fixture: Fixture?
  }

  @MainActor
  private final class DiscardProbe {
    var count = 0
    var noticeWasStillUp: [Bool] = []
  }

  private static func makeFixture(
    accessibilityRefresh: (@MainActor () -> Void)? = nil,
    releaseDuringRecoveryArm: Bool = false,
    isRecovering: Bool = false,
    recoveringDuringArm: Bool = false,
    micStatus: AVAuthorizationStatus = .authorized,
    micPrompt: MicPromptStub? = nil,
    duringRecoveryArm: (@MainActor () -> Void)? = nil,
    onRecoveryArm: (@MainActor (ASRBackendType) -> Void)? = nil,
    withLifecycle: Bool = false
  ) -> Fixture {
    // The overlay used to post an `NSAccessibility` notification against
    // `NSApp.mainWindow` on every `.recording` push, and `NSApp` is an
    // implicitly-unwrapped optional that crashes the test process when accessed
    // before `NSApplication.shared` has been touched.
    //
    // **The headless director cannot do that** — its announcement seam goes
    // nowhere — so this initialisation is no longer load-bearing for the overlay.
    // It stays because other AppKit reads on the `start()` paths still need it,
    // and removing it on the strength of one resolved cause is how the next
    // crash gets attributed to the wrong change.
    _ = NSApplication.shared
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let pipeline = DictationRuntimeFixtures.makeParakeetDriver(
      audioCapture: audio, asrManager: asr, store: store)
    let whisperKernelDriver = DictationRuntimeFixtures.makeWhisperPipeline(
      audioCapture: audio, store: store)
    // #959: isolate each fixture's settings in its own UserDefaults suite so a
    // test that changes `modelUnloadPolicy` (e.g. `warmRespawnRequiresNeverPolicy`)
    // cannot pollute `UserDefaults.standard` for sibling tests. A fresh suite has
    // no `modelUnloadPolicy` key, so it defaults to `.never` (SettingsDefaultValues).
    let settings = SettingsManager(
      defaults: TestDefaults.suite("ew-test-\(UUID().uuidString)")!)
    let (overlay, overlayHost) = OverlayTestDouble.headlessDirectorWithHost()
    let permissions: PermissionsService
    if let micPrompt {
      permissions = PermissionsService(
        microphoneReader: { micPrompt.status },
        microphoneRequester: { await micPrompt.request() })
    } else {
      permissions = PermissionsService(microphoneReader: { micStatus })
    }
    let lockBox = TestRecordingLockedBox()
    let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { lockBox.isLocked },
      set: { lockBox.isLocked = $0 }
    )
    let hcr = HeartControlRecovery(
      hideOverlay: { overlay.dismissCurrent(.announced) },
      setLocked: { locked in lockAccess.set(locked) },
      backend: { asr.activeBackendType.rawValue }
    )
    let engineLease = EngineLease()
    let engineAdmission = EngineAdmissionAccess.live(lease: engineLease, as: .dictation)
    // #3973 C1: one request owner shared by the starter and the finalizer, as in production.
    let turnLog = TurnLogSink()
    let turnClock = TurnClock()
    let pendingRequests = PendingDictationRequests(
      access: engineAdmission, now: { turnClock.now }, log: { turnLog.append($0) })
    let finalizer = RecordingFinalizer(
      kernelDriver: pipeline,
      whisperKernelDriver: whisperKernelDriver,
      asrManager: asr,
      recordingOverlay: overlay,
      heartControlRecovery: hcr,
      recordingLockedAccess: lockAccess,
      languageSuggestionPresenter: nil,
      pendingRequests: pendingRequests
    )
    let lastRecordingResult = LastRecordingResult()
    let discards = DiscardProbe()
    // `recovering` is a captured var both the arm closure (mutates) and the gate
    // closure (reads) share — lets a test flip recovery ON during the arm await
    // (#1063 PR2: the post-arm re-check). Both run on the MainActor.
    var recovering = isRecovering
    // #1063 PR1: when asked, the injected recovery-arm closure simulates the
    // user RELEASING PTT while the key store is being awaited — it records a
    // user-stop on the finalizer (so `lastUserStopAccess.read() > pttStart`)
    // and returns no directive. The default closure is the recovery-off no-op.
    // #1063 PR2: when `recoveringDuringArm`, it flips recovery ON during the arm
    // and returns a directive (so `config.recoverySessionID` is set), simulating
    // launch recovery starting mid-`start()`.
    let makeRecoveryDirective:
      @MainActor (SettingsManager, ASRBackendType, Bool) async -> (
        recoverySessionID: String, payload: Data
      )? = { _, backend, _ in
        onRecoveryArm?(backend)
        duringRecoveryArm?()
        if releaseDuringRecoveryArm { await finalizer.userStop() }
        if recoveringDuringArm {
          recovering = true
          return (UUID().uuidString, Data())
        }
        return nil
      }
    // #3973 C1: production's lifecycle owner, installed, releasing into the fixture's lease, so a
    // row can follow the starter's real token hand-off to the session's accepted terminal.
    let lifecycle: DictationLifecycleCoordinator?
    if withLifecycle {
      let hotkey = HotkeyService(effects: RecordingDesktopHotkeyEffects())
      let coordinator = DictationLifecycleCoordinator(
        kernelDriver: pipeline,
        whisperKernelDriver: whisperKernelDriver,
        recordingOverlay: overlay,
        hotkeyService: hotkey,
        settingsSync: PipelineSettingsSync(
          kernelDriver: pipeline, whisperKernelDriver: whisperKernelDriver, audioCapture: audio,
          asrManager: asr, hotkeyService: hotkey, ollamaRemotenessLookup: { _ in nil }),
        audioCapture: audio,
        transcriptCoordinator: TranscriptCoordinator(store: store),
        settings: settings,
        lastRecordingResult: lastRecordingResult,
        languageSuggestionPresenter: nil,
        recordingLockedAccess: lockAccess,
        releaseEngineClaim: { [engineLease] token in engineLease.release(token) })
      coordinator.install()
      lifecycle = coordinator
    } else {
      lifecycle = nil
    }
    let starter = RecordingStarter(
      audioCapture: audio,
      asrManager: asr,
      kernelDriver: pipeline,
      whisperKernelDriver: whisperKernelDriver,
      settings: settings,
      permissions: permissions,
      recordingOverlay: overlay,
      heartControlRecovery: hcr,
      recordingLockedAccess: lockAccess,
      lastUserStopAccess: finalizer.lastUserStopAccess,
      lastRecordingResult: lastRecordingResult,
      dictationLifecycleCoordinator: lifecycle,
      accessibilityRefresh: accessibilityRefresh,
      recovery: RecordingStarter.RecoveryAccess(
        makeDirective: makeRecoveryDirective,
        cleanupArm: { _ in },
        isRecovering: { recovering },
        signalPendingLiveStart: {},
        discardActive: {
          discards.count += 1
          discards.noticeWasStillUp.append(Self.showsRecoveryOffer(overlay))
        }),
      // #2648: a REAL lease, not the always-allow seam. The admission rows hold
      // it as another workload and assert both start routes refuse, which a seam
      // that always says yes could not show.
      engineAdmission: engineAdmission,
      pendingRequests: pendingRequests
    )
    return Fixture(
      starter: starter,
      finalizer: finalizer,
      kernelDriver: pipeline,
      whisperKernelDriver: whisperKernelDriver,
      asr: asr,
      audio: audio,
      permissions: permissions,
      lockBox: lockBox,
      lastRecordingResult: lastRecordingResult,
      overlay: overlay,
      overlayHost: overlayHost,
      settings: settings,
      discards: discards,
      engineLease: engineLease,
      pendingRequests: pendingRequests,
      turnLog: turnLog,
      turnClock: turnClock,
      lifecycle: lifecycle
    )
  }

  @Test func isProcessingFalseWhenBothPipelinesIdle() {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    #expect(fx.starter.isProcessing == false)
    fx.asr.activeBackendType = .whisper
    #expect(fx.starter.isProcessing == false)
  }

  @Test func toggleClearsPriorPolishErrorOnIdleToActiveTransition() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.lastRecordingResult.polishError = "previous error"
    // Both pipelines start in .idle, so this is the "starting a new
    // recording" branch — polishError must be cleared before dispatch.
    // The dispatch itself may fail in the unit context (no audio); that
    // does not affect the pre-dispatch reset.
    await fx.starter.toggle(source: .toolbar)
    #expect(fx.lastRecordingResult.polishError == nil)
  }

  @Test func startClearsPriorPolishErrorOnEntry() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.lastRecordingResult.polishError = "previous error"
    // start()'s prologue (overlay show, polish-error reset, AX refresh)
    // runs before the prewarm await. The await may resolve to an error
    // or never (no live audio); the prologue resets we care about
    // already happened.
    _ = await fx.starter.start()
    #expect(fx.lastRecordingResult.polishError == nil)
  }

  @Test("raw no-microphone prewarm error surfaces distinct copy")
  func rawNoMicrophonePrewarmErrorSurfacesDistinctCopy() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.audio.preWarmError = AudioError.noBuiltInMicrophoneFound

    _ = await fx.starter.start()

    #expect(fx.kernelDriver.state == .error(.noMicrophoneFound))
  }

  @Test(
    "a prewarm failure while mic permission is denied surfaces the actionable permission notice, not the generic capture error (cloud review P2 #1563)"
  )
  func permissionDeniedPrewarmSurfacesPermissionNotice() async {
    // Mic permission is denied; the prewarm error itself is a generic capture
    // failure (not a no-device error). #1558: permission is the real,
    // user-actionable cause and must win — the user should see "Microphone
    // access is off.", never the generic "Audio capture error. Try again."
    let fx = Self.makeFixture(micStatus: .denied)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.audio.preWarmError = NSError(domain: "SomeGenericCapture", code: 99)

    _ = await fx.starter.start()

    #expect(fx.kernelDriver.state == .error(.permissionDenied))
  }

  /// The old `toggleAndStartBothRefreshAccessibilityStatus` had ZERO `#expect` —
  /// it only checked crash-freedom, so deleting the AX re-arm block from
  /// `start()`/`toggle()` left it green. This injects a counting spy and asserts
  /// each path refreshes accessibility exactly once. The engine MUST be marked
  /// ready (`isModelLoaded = true`) — otherwise both paths return at the
  /// cold-engine guard BEFORE the AX block and the spy never increments.
  @Test(
    "start() and toggle() each refresh accessibility exactly once",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/904",
      "AX re-arm on start/toggle was unverified (zero-assertion test)"
    )
  )
  func startAndToggleEachRefreshAccessibilityOnce() async {
    let counter = AXRefreshCounter()
    let fx = Self.makeFixture(accessibilityRefresh: { counter.count += 1 })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // → readiness .ready, so start/toggle pass the cold-engine guard
    #expect(fx.kernelDriver.engineReadiness == .ready)

    _ = await fx.starter.start()
    #expect(counter.count == 1)  // start() refreshed once

    await fx.starter.toggle(source: .toolbar)
    #expect(counter.count == 2)  // toggle() refreshed once more
  }

  // #879 — cold-boot press safety. The matcher-set boundary is `.ready` vs
  // not-ready (`.notReady` / `.warming`). A press on a not-ready engine must
  // mint NO recording session (no audio captured → none discarded) and show
  // the cold-boot pill; a press on a ready engine must skip the cold branch
  // entirely.
  @Test func coldPressMintsNoSessionAndShowsCachingPill() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false  // → readiness .notReady
    #expect(fx.kernelDriver.engineReadiness == .notReady)

    _ = await fx.starter.start()

    // No session minted: the kernel never left idle.
    #expect(fx.kernelDriver.state == .idle)
    // The honest cold-boot pill is shown (engine-named), not a recording pill.
    #expect(
      Self.showsColdBoot(fx.overlay, engine: "Parakeet"),
      "the honest cold-boot pill, naming the engine, is what the user must see")
  }

  // #1063 PR2 — the recovery hold. A press (PTT or toggle) while the crash-recovery
  // limb backfills behind the blocking pill mints NO session and shows the
  // "recovering" pill instead, mirroring the cold-press contract.
  @Test func pressWhileRecoveringMintsNoSessionAndShowsRecoveringPill() async {
    // The engine is not-ready by default; the recovery gate must still win over
    // the cold-press gate (it is checked first), so the pill is the recovery one.
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet

    _ = await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle, "no session minted while recovering")
    #expect(
      Self.showsRecoveryOffer(fx.overlay),
      "recovery hold takes precedence over the cold-engine pill")
  }

  /// **Discard reaches the recovery owner, and the answered notice goes.**
  ///
  /// REPRODUCIBLE: crash recovery holds the engine, the user presses Record, sees
  /// the recovery notice, and presses Discard. Before C4b this travelled out
  /// through a settable overlay sink to a router holding a WEAK recovery target,
  /// so an unset target left a rendered button that reached nobody. The action is
  /// now required at the presentation that draws it.
  ///
  /// Runs in both lanes. The starter presents internally and returns no receipt,
  /// so this sends Discard to the presentation currently published by the hosted
  /// root. Staleness is not this case's subject; receipt-scoped tests own that.
  ///
  /// What is unique to this case is that the STARTER supplies a real discard; the
  /// ORDERING claim it also makes is covered by `PillRequestParityTests`
  /// `discardRunsBeforeDismissal`, which builds its own request.
  @Test func discardInvokesRecoveryOwner() async throws {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet
    _ = await fx.starter.start()

    try fx.overlayHost.sendCurrentUserActionThroughRoot(.discardRecovery)

    #expect(fx.discards.count == 1, "Discard reached nobody")
    #expect(
      fx.discards.noticeWasStillUp == [true],
      "the notice was dismissed before its owner was told to discard")
    #expect(
      fx.overlay.renderModel.state.presentation == nil,
      "the notice the user already answered is still on screen")
  }

  /// **The recovery notice's sink must answer ONLY to Discard** (#2356).
  ///
  /// The presentation carries one button today, so this is a filter standing in
  /// front of a door nobody else knocks on — and that is exactly why nothing
  /// reached it: dropping the `guard case .discardRecovery` and firing on ANY
  /// action left every suite green, measured.
  ///
  /// It is worth a row rather than a comment because of what the failure would
  /// be if a second button were ever added to this notice: pressing it would
  /// SILENTLY discard the recording the user was being offered back. A destructive
  /// action reached through the wrong button is the shape that has to fail loudly
  /// the day it is written, not the day someone notices their recording is gone.
  ///
  /// Nothing is fabricated here. The action sent is a real member of `PillAction`
  /// travelling the real root; the claim is that this sink ignores it.
  @Test func onlyDiscardReachesTheRecoveryOwner() async throws {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet
    _ = await fx.starter.start()

    try fx.overlayHost.sendCurrentUserActionThroughRoot(.lockLanguage)

    #expect(
      fx.discards.count == 0,
      "a button that is not Discard discarded the recovering recording")
    #expect(
      Self.showsRecoveryOffer(fx.overlay),
      "the recovery notice was dismissed by an action it does not own")
  }

  @Test func toggleWhileRecoveringMintsNoSessionAndShowsRecoveringPill() async {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(Self.showsRecoveryOffer(fx.overlay), "the recovery pill is not on screen")
  }

  // #1063 PR2 (Codex code-diff r2 P2) — recovery can START during `start()`'s
  // prewarm/arm awaits (the top-of-method gate read false). The post-arm re-check
  // must catch it and mint no session, so a new recording can't contend with the
  // recovery replay on the shared engine.
  @Test func startRechecksRecoveryAfterArmAndBails() async {
    let fx = Self.makeFixture(recoveringDuringArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // ready → top gate passes, recovery flips on during arm

    _ = await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle, "no session minted — recovery started during the arm")
    #expect(Self.showsRecoveryOffer(fx.overlay), "the recovery pill is not on screen")
  }

  @Test func toggleRechecksRecoveryAfterArmAndBails() async {
    let fx = Self.makeFixture(recoveringDuringArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(Self.showsRecoveryOffer(fx.overlay), "the recovery pill is not on screen")
  }

  @Test func coldToggleMintsNoSessionAndShowsCachingPill() async {
    // The toggle-hotkey / menu / toolbar START path must follow the same
    // no-session-on-cold contract as the PTT path (Codex #879 review).
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = false  // → readiness .notReady
    #expect(fx.kernelDriver.engineReadiness == .notReady)

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(
      Self.showsColdBoot(fx.overlay, engine: "Parakeet"),
      "the honest cold-boot pill, naming the engine, is what the user must see")
  }

  @Test func warmPressSkipsColdBranch() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // → readiness .ready
    #expect(fx.kernelDriver.engineReadiness == .ready)

    _ = await fx.starter.start()

    // A ready press must take the WARM path, which shows the recording overlay.
    // The old test only checked the cold-boot pill's ABSENCE — a broken warm
    // path that returned early without recording also has no cold pill and
    // stayed green. Asserting the positive recording intent reddens that
    // early-return mutation while still proving the cold branch was skipped.
    guard Self.showsRecording(fx.overlay) else {
      Issue.record(
        "warm press must show the recording overlay; got \(String(describing: fx.overlay.renderModel.state.presentation?.content))"
      )
      return
    }
  }

  @Test func lastUserStopAccessIsThreadedFromFinalizer() async {
    // Starter holds a snapshot of Finalizer's lastUserStopAccess closure.
    // After Finalizer marks a timestamp via cancel/userStop, Starter's
    // wedge guard must observe the same value.
    let fx = Self.makeFixture()
    #expect(fx.starter.lastUserStopAccess.read() == nil)
    await fx.finalizer.userStop()
    #expect(fx.starter.lastUserStopAccess.read() != nil)
  }

  // NOTE: a behavioral test for the post-preWarm
  // `userStoppedDuringPreWarm` guard (Codex final-review P1 on the
  // cutover) is hard to schedule reliably — `RouterTestAudioCapture.preWarm`
  // completes synchronously, so a concurrent `userStop()` may land after
  // `.toggleRecording` already dispatched. The existing
  // `lastUserStopAccessIsThreadedFromFinalizer` test pins the wiring of
  // the closure; the guard itself mirrors the post-toggle check at
  // lines 162-165 (covered by behavioral observation in Live UAT).

  /// #1063 PR1 (Codex code-diff r2 P2): the recovery-arm `await` widened the
  /// pre-session window in `start()`. Unlike the pre-warm guard above, this one
  /// IS deterministically schedulable — the arm closure is injected, so it can
  /// record the user-stop mid-arm. A release landing in that window must tear
  /// down the prewarmed engine (`abortPreWarm`), not merely hide the overlay,
  /// and must mint no session. A bare hide/unlock would leave the mic engine hot.
  @Test func pttReleaseDuringRecoveryArmAbortsPrewarmAndMintsNoSession() async {
    let fx = Self.makeFixture(releaseDuringRecoveryArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // ready → passes cold + pre-warm guards, reaches the arm
    #expect(fx.kernelDriver.engineReadiness == .ready)

    _ = await fx.starter.start()

    // The prewarmed engine was torn down (not just the overlay hidden).
    #expect(fx.audio.abortPreWarmCallCount >= 1)
    // No session minted — the kernel never left idle.
    #expect(fx.kernelDriver.state == .idle)
    // Lock released so a subsequent press is not wedged.
    #expect(fx.lockBox.isLocked == false)
  }

  /// #1063 PR1 (Codex code-diff r3 P1): the toggle path also awaits the recovery
  /// arm. A stop/cancel landing in that window must NOT start a fresh recording —
  /// the post-arm guard reads the user-stop timestamp and bails before
  /// dispatching `.toggleRecording`, so the kernel never leaves idle.
  @Test func toggleStopDuringRecoveryArmMintsNoSession() async {
    let fx = Self.makeFixture(releaseDuringRecoveryArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true  // ready → passes the cold guard, reaches the arm
    #expect(fx.kernelDriver.engineReadiness == .ready)

    await fx.starter.toggle(source: .toggleHotkey)

    // No session minted — the kernel never left idle.
    #expect(fx.kernelDriver.state == .idle)
  }

  // MARK: - #1631 outcome mapping

  /// The mapping is a closed set of two inputs, so it is tested directly rather
  /// than by racing the kernel's spawned forward task into `.error` — a race the
  /// fixture has no seam to win deterministically.
  @Test("outcome is .recording only when the pipeline is active AND a session continues")
  func startOutcomeClosedSet() {
    #expect(
      RecordingStartOutcome.make(pipelineActive: true, continuingSessionID: "S1")
        == .recording("S1"))
    // Active but no continuing session: an exit is already latched.
    #expect(
      RecordingStartOutcome.make(pipelineActive: true, continuingSessionID: nil) == .noRecording)
    // Inactive covers the immediate-error case: PipelineState.error is not isActive.
    #expect(
      RecordingStartOutcome.make(pipelineActive: false, continuingSessionID: "S1") == .noRecording)
    #expect(
      RecordingStartOutcome.make(pipelineActive: false, continuingSessionID: nil) == .noRecording)
  }

  // MARK: - #1925 postcondition decision

  /// Extracted as a pure function so this is tested directly rather than by
  /// racing a live driver into each of the four states. Only ONE combination
  /// stamps a wedge: nothing active, no terminal result reached by any
  /// mechanism, and the user did not stop it themselves.
  @Test("the wedge postcondition fires only when truly nothing happened")
  func postConditionWedgeClosedSet() {
    // Active: never a wedge, regardless of the other two inputs.
    #expect(
      !RecordingStarter.shouldStampPostConditionWedge(
        pipelineActive: true, hasTerminalResult: false, userStoppedDuringStart: false))
    // Concluded by any mechanism (error, advisory, or any other real ending):
    // not a wedge. This is the #1925 fix — the old check only recognized
    // `.error` here.
    #expect(
      !RecordingStarter.shouldStampPostConditionWedge(
        pipelineActive: false, hasTerminalResult: true, userStoppedDuringStart: false))
    // The user stopped it themselves during start: not a wedge, a real no-op.
    #expect(
      !RecordingStarter.shouldStampPostConditionWedge(
        pipelineActive: false, hasTerminalResult: false, userStoppedDuringStart: true))
    // Nothing active, nothing concluded, no user stop: the one true wedge.
    #expect(
      RecordingStarter.shouldStampPostConditionWedge(
        pipelineActive: false, hasTerminalResult: false, userStoppedDuringStart: false))
  }

  #if DEBUG

    /// The helper test above proves the mapping. These prove the two PRODUCTION
    /// guards actually call it — a helper nothing routes through is not a fix.
    @Test("an already-active Parakeet session reports its continuing id")
    func parakeetAlreadyActiveReportsRecording() async throws {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      fx.kernelDriver.kernelForTesting.testForceState(.live)
      let expected = try #require(fx.kernelDriver.continuingSessionID)

      let outcome = await fx.starter.start()

      switch outcome {
      case .recording(let sessionID): #expect(sessionID == expected)
      case .noRecording: Issue.record("expected the already-active Parakeet session")
      }
    }

    @Test("an already-active Whisper session reports its continuing id")
    func whisperAlreadyActiveReportsRecording() async throws {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .whisper
      fx.whisperKernelDriver.kernelForTesting.testForceState(.live)
      let expected = try #require(fx.whisperKernelDriver.continuingSessionID)

      let outcome = await fx.starter.start()

      switch outcome {
      case .recording(let sessionID): #expect(sessionID == expected)
      case .noRecording: Issue.record("expected the already-active Whisper session")
      }
    }

  #endif

  @Test("a press while recovery holds the engine reports no recording")
  func recoveryHoldReportsNoRecording() async {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet
    let outcome = await fx.starter.start()
    #expect(outcome == .noRecording)
  }

  @Test("a release during the recovery arm reports no recording")
  func releaseDuringArmReportsNoRecording() async {
    let fx = Self.makeFixture(releaseDuringRecoveryArm: true)
    fx.asr.activeBackendType = .parakeet
    let outcome = await fx.starter.start()
    #expect(outcome == .noRecording)
  }


  // MARK: - #3960 a microphone macOS never asked about

  /// The microphone status and the macOS prompt, both under the test's control.
  /// `request()` waits for the test's answer the way the real prompt waits for
  /// the user; an answer given before the request arrives is kept, so no test
  /// depends on when the ask task first runs. The fixture's permission closures
  /// are not actor-isolated, hence the lock.
  final class MicPromptStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: AVAuthorizationStatus
    private var _requestCount = 0
    private var pending: CheckedContinuation<Bool, Never>?
    private var queuedAnswer: Bool?

    init(status: AVAuthorizationStatus) { _status = status }

    var status: AVAuthorizationStatus {
      get { lock.withLock { _status } }
      set { lock.withLock { _status = newValue } }
    }
    var requestCount: Int { lock.withLock { _requestCount } }

    func request() async -> Bool {
      await withCheckedContinuation { continuation in
        let answer: Bool? = lock.withLock {
          _requestCount += 1
          if let queuedAnswer {
            self.queuedAnswer = nil
            return queuedAnswer
          }
          pending = continuation
          return nil
        }
        if let answer { continuation.resume(returning: answer) }
      }
    }

    /// Answers the prompt the way macOS does: the status changes, then the
    /// request returns.
    func answer(allow: Bool) {
      let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
        _status = allow ? .authorized : .denied
        guard let pending else {
          queuedAnswer = allow
          return nil
        }
        self.pending = nil
        return pending
      }
      continuation?.resume(returning: allow)
    }
  }

  @Test("a press with the microphone never asked asks and records nothing")
  func neverAskedPressAsksAndMintsNothing() async {
    let prompt = MicPromptStub(status: .notDetermined)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    let outcome = await fx.starter.start()

    #expect(outcome == .noRecording)
    #expect(fx.starter.microphoneAskTask != nil, "the press asked macOS")
    #expect(fx.kernelDriver.state == .idle, "no session while macOS is asking")
    #expect(!Self.showsRecording(fx.overlay), "no recording pill under the prompt")
    #expect(fx.lockBox.isLocked == false)
    guard case .granted(let token) = fx.engineLease.admit(.fileImport) else {
      Issue.record("the press held the engine claim across the prompt")
      return
    }
    fx.engineLease.release(token)
    prompt.answer(allow: true)
    await fx.starter.microphoneAskTask?.value
    #expect(prompt.requestCount == 1)
  }

  @Test("a toggle start with the microphone never asked asks and records nothing")
  func neverAskedToggleAsksAndMintsNothing() async {
    let prompt = MicPromptStub(status: .notDetermined)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = .whisper
    fx.asr.isModelLoaded = true

    await fx.starter.toggle(source: .toolbar)

    #expect(fx.starter.microphoneAskTask != nil, "the toggle asked macOS")
    #expect(fx.whisperKernelDriver.state == .idle)
    #expect(!Self.showsRecording(fx.overlay))
    prompt.answer(allow: true)
    await fx.starter.microphoneAskTask?.value
    #expect(prompt.requestCount == 1)
  }

  @Test("presses while the prompt is up neither ask again nor record")
  func pressesWhilePromptIsUpAreIgnored() async {
    let prompt = MicPromptStub(status: .notDetermined)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    _ = await fx.starter.start()
    let second = await fx.starter.start()
    await fx.starter.toggle(source: .toolbar)
    // A status change while the prompt is still up must not open a way past it.
    prompt.status = .authorized
    let third = await fx.starter.start()

    #expect(second == .noRecording)
    #expect(third == .noRecording)
    #expect(fx.kernelDriver.state == .idle)
    prompt.answer(allow: true)
    await fx.starter.microphoneAskTask?.value
    #expect(prompt.requestCount == 1, "one prompt for every press made while it was up")
  }

  @Test(
    "Don't Allow shows the access-off notice on the selected engine",
    arguments: [ASRBackendType.parakeet, .whisper])
  func refusalShowsAccessOffNotice(backend: ASRBackendType) async {
    let prompt = MicPromptStub(status: .notDetermined)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = backend
    fx.asr.isModelLoaded = true
    let selected = backend == .whisper ? fx.whisperKernelDriver : fx.kernelDriver

    _ = await fx.starter.start()
    prompt.answer(allow: false)
    await fx.starter.microphoneAskTask?.value

    #expect(selected.state == .error(.permissionDenied))
  }

  @Test("Allow shows nothing, and the next press goes past the ask")
  func allowShowsNothingAndNextPressProceeds() async {
    let prompt = MicPromptStub(status: .notDetermined)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    _ = await fx.starter.start()
    prompt.answer(allow: true)
    await fx.starter.microphoneAskTask?.value
    #expect(fx.kernelDriver.state == .idle, "Allow publishes nothing")

    // The next press reaches the engine: a prewarm failure is the observable
    // proof that it went past the ask.
    fx.audio.preWarmError = NSError(domain: "SomeGenericCapture", code: 99)
    _ = await fx.starter.start()
    #expect(prompt.requestCount == 1, "an answered microphone is not asked again")
    #expect(fx.kernelDriver.state == .error(.micWouldNotOpen))
  }

  @Test("an authorized microphone is never asked")
  func authorizedMicrophoneIsNeverAsked() async {
    let prompt = MicPromptStub(status: .authorized)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.audio.preWarmError = NSError(domain: "SomeGenericCapture", code: 99)

    _ = await fx.starter.start()

    #expect(prompt.requestCount == 0)
    #expect(fx.starter.microphoneAskTask == nil)
    #expect(fx.kernelDriver.state == .error(.micWouldNotOpen))
  }

  // MARK: - #2648 shared-resource admission

  /// **This is the pair the whole safety promise rests on.** `RecordingStarter`
  /// has exactly two non-private methods that begin a recording. These rows cover
  /// both; a third route needs its own row here.
  ///
  /// A pair is the dangerous number: gating one reads exactly like gating both
  /// (`workflow-process.md`
  /// RULE: fix-the-path-that-runs-first-not-the-one-you-were-reading), and the
  /// first draft of this feature gated a facade the hotkey does not even call.

  @Test func pttStartIsRefusedWhileAnotherWorkloadHoldsTheResource() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard case .granted = fx.engineLease.admit(.fileImport) else {
      Issue.record("the fixture's lease was already held")
      return
    }

    let outcome = await fx.starter.start()

    #expect(outcome == .noRecording)
    #expect(fx.kernelDriver.state == .idle, "a refused press must mint no session")
    #expect(
      Self.showsSharedEngineBusy(fx.overlay, holder: .fileImport),
      "the refusal must reach the user, naming the job to wait for")
  }

  @Test func toggleStartIsRefusedWhileAnotherWorkloadHoldsTheResource() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard case .granted = fx.engineLease.admit(.fileImport) else {
      Issue.record("the fixture's lease was already held")
      return
    }

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle, "a refused press must mint no session")
    #expect(Self.showsSharedEngineBusy(fx.overlay, holder: .fileImport))
  }

  // MARK: - #3973 C1 A press waits for a meeting's turn

  /// Observe the public press task's return, not its earlier terminal log (#4157).
  /// A failed wait leaves cancellation and bounded drainage to the task's owner.
  private static func completed(
    _ task: Task<Void, Never>, timeout: Duration = .seconds(5)
  ) async -> Bool {
    let signal = TurnLogSink()
    let observer = Task { @MainActor in
      await task.value
      signal.append("returned")
    }
    let returned = await signal.waitFor(containing: "returned", after: 0, timeout: timeout)
    if returned {
      await observer.value
    } else {
      observer.cancel()
    }
    return returned
  }

  @Test(.tags(.harnessContract))
  func completionWaitRejectsAnUnfinishedTask() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    let task = Task { @MainActor in
      for await _ in stream {}
    }

    #expect(await Self.completed(task, timeout: .milliseconds(1)) == false)
    continuation.finish()
    #expect(await Self.completed(task))
  }

  /// Holds the fixture's lease as a meeting, starts `press` in a task, and returns once the
  /// press has reserved the next turn (the request owner's `waiting` line is written in the
  /// same main-actor step as the reservation, and this resumes only after the press parks).
  private static func parkPress(
    _ fx: Fixture, _ press: @escaping @MainActor () async -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> (meeting: EngineLease.Token, task: Task<Void, Never>)? {
    guard case .granted(let meeting) = fx.engineLease.admit(.meeting) else {
      Issue.record("the fixture's lease was already held", sourceLocation: sourceLocation)
      return nil
    }
    let waitingLines = fx.turnLog.count(containing: "event=waiting")
    let task = Task { @MainActor in await press() }
    guard await fx.turnLog.waitFor(containing: "event=waiting", after: waitingLines) else {
      Issue.record("the press never parked", sourceLocation: sourceLocation)
      task.cancel()
      fx.engineLease.release(meeting)
      #expect(
        await Self.completed(task), "cleanup did not drain the press", sourceLocation: sourceLocation)
      return nil
    }
    #expect(
      fx.engineLease.hasPendingReservation, "a parked press holds the next turn",
      sourceLocation: sourceLocation)
    return (meeting, task)
  }

  /// Both routes wait while a meeting holds the engine, keep any fresh meeting claim out, and
  /// go on to the start boundary (the recovery arm, the last step before the driver) after the
  /// meeting gives the engine back. Replaces #4052's refusal for this holder.
  @Test(arguments: [false, true])
  func aPressWaitsForTheMeetingTurnThenStarts(useToggle: Bool) async {
    var arms: [ASRBackendType] = []
    var givenBack = 0
    let fx = Self.makeFixture(onRecoveryArm: { arms.append($0) })
    fx.pendingRequests.onTurnGivenBackUnused = { givenBack += 1 }
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard
      let parked = await Self.parkPress(
        fx,
        {
          if useToggle {
            await fx.starter.toggle(source: .toggleHotkey)
          } else {
            _ = await fx.starter.start()
          }
        })
    else { return }

    #expect(!Self.showsSharedEngineBusy(fx.overlay, holder: .meeting), "a meeting no longer refuses")
    #expect(arms.isEmpty, "nothing starts while the meeting holds the engine")

    fx.turnClock.advance(milliseconds: 1_250)
    #expect(fx.engineLease.release(parked.meeting))
    // The meeting's next operation cannot claim in the release's own step: the press owns it.
    guard case .refused(by: .dictation) = fx.engineLease.admit(.meeting) else {
      Issue.record("a fresh meeting claim got past a waiting dictation")
      return
    }
    await parked.task.value

    #expect(arms == [.parakeet], "the press reached the start boundary once")
    #expect(fx.kernelDriver.state.isActive, "the waited-for press minted a recording session")
    #expect(givenBack == 0, "a press that records leaves the unload timers to its session")
    #expect(fx.turnLog.outcomes == ["admitted waitMs=1250"])
    #expect(!fx.engineLease.hasPendingReservation)
  }

  /// A press ended AFTER its turn was granted, while its start-up is still suspended in the
  /// recovery arm, mints nothing: its identity outlives the wait. Two routes: the user's stop
  /// reaching the request owner, and a newer push-to-talk press cancelling the older task.
  @Test(arguments: ["cancelPending", "taskCancel"])
  func aPressEndedDuringStartUpMintsNothing(route: String) async {
    let box = FixtureBox()
    var arms = 0
    var givenBack = 0
    let fx = Self.makeFixture(onRecoveryArm: { _ in
      arms += 1
      if route == "cancelPending" {
        box.fixture?.pendingRequests.cancelPending()
      } else {
        withUnsafeCurrentTask { $0?.cancel() }
      }
    })
    box.fixture = fx
    fx.pendingRequests.onTurnGivenBackUnused = { givenBack += 1 }
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard let parked = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }

    #expect(fx.engineLease.release(parked.meeting))
    await parked.task.value

    #expect(arms == 1, "the press reached its start-up after the wait")
    #expect(fx.kernelDriver.state == .idle, "an ended press minted a session")
    #expect(fx.engineLease.isBusy == false, "the granted token went back")
    #expect(givenBack == 1, "the unused turn re-armed dictation's unload timers")
  }

  /// Every way a user ends a waiting press: the request ends at once, and the meeting's later
  /// release starts nothing, arms no recovery and leaves no claim, reservation or waiter.
  @Test(arguments: ["release", "cancel", "secondToggle", "taskCancel"])
  func anEndedPressNeverStartsLate(route: String) async {
    var arms = 0
    let fx = Self.makeFixture(onRecoveryArm: { _ in arms += 1 })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    let useToggle = route == "secondToggle"
    guard
      let parked = await Self.parkPress(
        fx,
        {
          if useToggle {
            await fx.starter.toggle(source: .toggleHotkey)
          } else {
            _ = await fx.starter.start()
          }
        })
    else { return }

    switch route {
    case "release": await fx.finalizer.userStop()
    case "cancel": await fx.finalizer.cancel(trigger: .shortcut)
    case "secondToggle": await fx.starter.toggle(source: .toggleHotkey)
    default: parked.task.cancel()
    }
    let returned = await Self.completed(parked.task)
    #expect(returned, "the ended press did not return")
    guard returned else {
      parked.task.cancel()
      fx.engineLease.release(parked.meeting)
      #expect(await Self.completed(parked.task), "cleanup did not drain the press")
      return
    }
    #expect(fx.turnLog.outcomes.count == 1)
    #expect(fx.turnLog.outcomes.first?.hasPrefix("cancelled") == true)
    #expect(!fx.engineLease.hasPendingReservation, "the reservation was withdrawn")

    #expect(fx.engineLease.release(parked.meeting))
    #expect(fx.engineLease.isBusy == false, "the meeting's release handed the engine to nobody")
    #expect(arms == 0, "an ended press started late")
    #expect(fx.kernelDriver.state == .idle)
  }

  /// The meeting's release and the user's stop land in the same main-actor turn: the hand-off
  /// gives the press its token, the stop ends the request, and the token goes straight back.
  @Test func aStopCrossingTheHandOffStartsNothingAndFreesTheEngine() async {
    var arms = 0
    let fx = Self.makeFixture(onRecoveryArm: { _ in arms += 1 })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard let parked = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }

    #expect(fx.engineLease.release(parked.meeting))
    #expect(fx.engineLease.currentHolder == .dictation, "the hand-off happened in the release")
    #expect(fx.pendingRequests.cancelPending(), "the stop reached the request before it resumed")
    await parked.task.value

    #expect(arms == 0)
    #expect(fx.engineLease.isBusy == false, "the crossed token was released")
    #expect(fx.turnLog.outcomes.count == 1)
    #expect(fx.turnLog.outcomes.first?.hasPrefix("cancelled") == true)
  }

  /// A newer press supersedes the waiting one; only the newer one starts.
  @Test func aNewerPressSupersedesTheWaitingOne() async {
    var arms = 0
    let fx = Self.makeFixture(onRecoveryArm: { _ in arms += 1 })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard let first = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }
    let waitingLines = fx.turnLog.count(containing: "event=waiting")
    let second = Task { @MainActor in _ = await fx.starter.start() }
    guard await fx.turnLog.waitFor(containing: "event=waiting", after: waitingLines) else {
      Issue.record("the newer press never parked")
      first.task.cancel()
      second.cancel()
      fx.engineLease.release(first.meeting)
      #expect(await Self.completed(first.task), "cleanup did not drain the older press")
      #expect(await Self.completed(second), "cleanup did not drain the newer press")
      return
    }
    let returned = await Self.completed(first.task)
    #expect(returned, "the superseded press did not return")
    guard returned else {
      first.task.cancel()
      second.cancel()
      fx.engineLease.release(first.meeting)
      #expect(await Self.completed(first.task), "cleanup did not drain the older press")
      #expect(await Self.completed(second), "cleanup did not drain the newer press")
      return
    }
    #expect(fx.turnLog.outcomes.first?.hasPrefix("superseded") == true)
    #expect(fx.engineLease.hasPendingReservation, "the older press's cleanup kept the newer turn")

    #expect(fx.engineLease.release(first.meeting))
    await second.value
    #expect(arms == 1)
    #expect(fx.turnLog.outcomes.count == 2)
    #expect(fx.turnLog.outcomes.last?.hasPrefix("admitted") == true)
  }

  /// Quit: the waiting press ends, and a press after that is refused without waiting.
  @Test func quitEndsTheWaitingPressAndRefusesNewOnes() async {
    var arms = 0
    let fx = Self.makeFixture(onRecoveryArm: { _ in arms += 1 })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard let parked = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }

    fx.pendingRequests.endForQuit()
    let returned = await Self.completed(parked.task)
    #expect(returned, "quit did not finish the waiting press")
    guard returned else {
      parked.task.cancel()
      fx.engineLease.release(parked.meeting)
      #expect(await Self.completed(parked.task), "cleanup did not drain the press")
      return
    }
    // The engine is free now, so only the closure can refuse these.
    #expect(fx.engineLease.release(parked.meeting))
    let outcome = await fx.starter.start()
    #expect(outcome == .noRecording)
    await fx.starter.toggle(source: .toggleHotkey)
    #expect(arms == 0)
    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.engineLease.isBusy == false)
    #expect(fx.turnLog.outcomes.map { $0.split(separator: " ").first.map(String.init) } == [
      "cancelled"
    ])
  }

  /// The real hand-off (#3973 C1): a press that waited behind a meeting mints a genuine session
  /// and the STARTER transfers the reserved token to the installed lifecycle owner. The lease stays
  /// with dictation after the starter returns (a meeting or import cannot claim), a published
  /// terminal state and the other backend's terminal leave it alone, and the minting backend's
  /// accepted terminal releases it once, after which meeting work can claim again.
  @Test(arguments: [false, true])
  func theWaitedForTokenLivesUntilTheSessionsAcceptedTerminal(useToggle: Bool) async {
    let fx = Self.makeFixture(withLifecycle: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard
      let parked = await Self.parkPress(
        fx,
        {
          if useToggle {
            await fx.starter.toggle(source: .toggleHotkey)
          } else {
            _ = await fx.starter.start()
          }
        })
    else { return }
    #expect(fx.engineLease.release(parked.meeting))
    await parked.task.value

    #expect(fx.kernelDriver.state.isActive, "the waited-for press minted a session")
    #expect(fx.engineLease.currentHolder == .dictation, "the session kept the reserved token")
    for holder in [SharedEngineHolder.meeting, .fileImport] {
      guard case .refused(by: .dictation) = fx.engineLease.admit(holder) else {
        Issue.record("\(holder) claimed the engine under a live dictation")
        return
      }
    }
    fx.kernelDriver.onStateChange?(.idle)
    #expect(fx.engineLease.currentHolder == .dictation, "a published state released the token")
    fx.whisperKernelDriver.onSessionTerminalAccepted?("someone-elses-take")
    #expect(fx.engineLease.currentHolder == .dictation, "the other backend's terminal released it")

    let epoch = fx.engineLease.admissionEpoch
    fx.kernelDriver.onSessionTerminalAccepted?("take-1")
    #expect(fx.engineLease.isBusy == false, "the accepted terminal released the token")
    fx.kernelDriver.onSessionTerminalAccepted?("take-1")
    #expect(fx.engineLease.admissionEpoch == epoch, "nothing else was granted or released twice")
    guard case .granted(let meeting) = fx.engineLease.admit(.meeting) else {
      Issue.record("meeting work could not resume after the dictation ended")
      return
    }
    fx.engineLease.release(meeting)
  }

  /// Engine facts are read after the wait, not before it: a gate that now fails refuses, and a
  /// backend switched during the wait is the one the press starts on.
  @Test func theResumedPressReadsFreshEngineFacts() async {
    var arms: [ASRBackendType] = []
    let fx = Self.makeFixture(onRecoveryArm: { arms.append($0) })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard let parked = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }
    fx.starter.isSelectedModelInstalled = { false }
    #expect(fx.engineLease.release(parked.meeting))
    await parked.task.value
    #expect(arms.isEmpty, "the removed model's gate refused after the wait")
    #expect(fx.engineLease.isBusy == false)

    // Readiness read after the wait: the model unloaded while the press waited.
    fx.starter.isSelectedModelInstalled = { true }
    guard let cold = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }
    fx.asr.isModelLoaded = false
    #expect(fx.engineLease.release(cold.meeting))
    await cold.task.value
    #expect(arms.isEmpty, "a press on an engine that went cold during the wait recorded")
    #expect(
      Self.showsColdBoot(fx.overlay, engine: fx.kernelDriver.engineDisplayName),
      "the fresh readiness read sent the press to the cold-engine notice")

    // Backend read after the wait: the user switched dictation to Whisper while it waited.
    fx.asr.isModelLoaded = true
    guard let again = await Self.parkPress(fx, { _ = await fx.starter.start() }) else { return }
    fx.settings.selectedBackend = .whisper
    fx.asr.activeBackendType = .whisper
    #expect(fx.engineLease.release(again.meeting))
    await again.task.value
    #expect(!arms.contains(.parakeet), "the press kept the backend it saw before the wait")
    #expect(
      arms == [.whisper]
        || Self.showsColdBoot(fx.overlay, engine: fx.whisperKernelDriver.engineDisplayName),
      "the press acted on Whisper, the backend after the wait")
  }

  /// A refused press must not disturb the claim it lost to. Releasing someone
  /// else's claim would be worse than refusing wrongly: the import would keep
  /// running while a dictation walked into the same inference slot.
  @Test func aRefusedPressLeavesTheResourceWithItsHolder() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    _ = fx.engineLease.admit(.fileImport)

    _ = await fx.starter.start()
    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.engineLease.isBusy)
    #expect(fx.engineLease.currentHolder == .fileImport)
  }

  /// The refusal is a refusal, not a wedge: once the other workload finishes,
  /// the very next press gets past this gate.
  @Test func bothRoutesGetPastTheGateOnceTheResourceIsFree() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard case .granted(let importToken) = fx.engineLease.admit(.fileImport) else {
      Issue.record("the fixture's lease was already held")
      return
    }
    _ = await fx.starter.start()
    #expect(Self.showsSharedEngineBusy(fx.overlay, holder: .fileImport))

    #expect(fx.engineLease.release(importToken))
    fx.lastRecordingResult.polishError = "from the previous take"
    _ = await fx.starter.start()

    // The oracle is a POSITIVE signal from past the gate, not the absence of the
    // pill. The refusal pill stays on screen until something replaces it, so
    // "the busy pill is gone" would be asserting that a later step happened to
    // draw over it. Clearing the previous take's polish error is the first thing
    // both routes do AFTER the claim, so it says the press got through.
    #expect(
      fx.lastRecordingResult.polishError == nil,
      "a press after the release was still refused for a job that has finished")
  }

  /// The same row for the OTHER route. The first draft covered `start()` only,
  /// which is the pair trap this whole gate exists inside: one route passing
  /// reads exactly like both passing.
  @Test func theToggleRouteGetsPastTheGateOnceTheResourceIsFree() async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    guard case .granted(let importToken) = fx.engineLease.admit(.fileImport) else {
      Issue.record("the fixture's lease was already held")
      return
    }
    await fx.starter.toggle(source: .toggleHotkey)
    #expect(Self.showsSharedEngineBusy(fx.overlay, holder: .fileImport))

    #expect(fx.engineLease.release(importToken))
    fx.lastRecordingResult.polishError = "from the previous take"
    await fx.starter.toggle(source: .toggleHotkey)

    // Same positive oracle as the PTT row above, and for the same reason.
    #expect(
      fx.lastRecordingResult.polishError == nil,
      "the toggle route was still refused for a job that has finished")
  }

  // **Stopping is never refused — and this suite cannot stage it.** A toggle that
  // would STOP a running dictation must not consult the claim at all, because
  // the running session IS the holder: a lease-first toggle would refuse the
  // user's own stop and leave the recording running with no way to end it. The
  // guard for that is structural (the claim sits inside `isStartingFromIdle`),
  // and staging it needs a driver in `.recording`, which `KernelDictationDriver`
  // exposes no seam for — `state` is computed (`:739`). Asserting it here would
  // need a fake driver, which would test the fake.
  //
  // It is covered as Live UAT instead, on the real app: start a dictation, press
  // the toggle, confirm it stops. Named here so the gap is visible rather than
  // absent (#2648).

  /// Ordering, asserted rather than described: recovery refuses FIRST on both
  /// routes, so the user keeps the pill that carries Discard even though the
  /// replay is also holding the shared claim.
  @Test func recoveryRefusalWinsOverTheClaimOnBothRoutes() async {
    for useToggle in [false, true] {
      let fx = Self.makeFixture(isRecovering: true)
      fx.asr.activeBackendType = .parakeet
      fx.asr.isModelLoaded = true
      // The replay holds the claim too, which is what a real replay does.
      _ = fx.engineLease.admit(.crashRecovery)

      if useToggle {
        await fx.starter.toggle(source: .toggleHotkey)
      } else {
        _ = await fx.starter.start()
      }

      #expect(
        Self.showsRecoveryOffer(fx.overlay),
        "the \(useToggle ? "toggle" : "PTT") route showed the generic refusal instead of Discard")
    }
  }

  /// **The leak row.** A start that claims the resource and then aborts before
  /// minting anything has to hand it back, or the next press is refused for a
  /// dictation that never happened — a limb permanently blocking the heart path.
  ///
  /// `recoveringDuringArm` drives the abort through a real gate: recovery starts
  /// during the recovery-arm await, and the post-arm re-check bails after the
  /// claim was already taken.
  @Test func aStartThatAbortsAfterClaimingHandsTheResourceBack() async {
    let fx = Self.makeFixture(recoveringDuringArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    _ = await fx.starter.start()

    #expect(fx.kernelDriver.state == .idle, "the fixture must actually abort for this row to mean anything")
    #expect(fx.engineLease.isBusy == false, "an aborted start left the shared resource claimed")
  }

  @Test func aToggleThatAbortsAfterClaimingHandsTheResourceBack() async {
    let fx = Self.makeFixture(recoveringDuringArm: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    await fx.starter.toggle(source: .toggleHotkey)

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.engineLease.isBusy == false, "an aborted toggle left the shared resource claimed")
  }

  /// A press refused by RECOVERY must not take the claim on its way out either.
  /// Recovery is refused one gate earlier precisely so its own pill, with its
  /// Discard button, is what the user sees.
  @Test func aRecoveryRefusalNeverTouchesTheSharedResource() async {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true

    _ = await fx.starter.start()

    #expect(Self.showsRecoveryOffer(fx.overlay), "recovery owns this refusal, not the shared claim")
    #expect(fx.engineLease.isBusy == false)
  }


  // MARK: - #4069 Turn off dictation during meetings

  /// A start press while the switch is on and a meeting captures records nothing, says why,
  /// and is refused before the microphone ask and the engine claim. One route per engine.
  @Test(arguments: [false, true])
  func meetingPolicyRefusesBeforeTheMicrophoneAndTheClaim(useToggle: Bool) async {
    let prompt = MicPromptStub(status: .notDetermined)
    let fx = Self.makeFixture(micPrompt: prompt)
    fx.asr.activeBackendType = useToggle ? .whisper : .parakeet
    fx.asr.isModelLoaded = true
    fx.starter.isDictationOffForMeeting = { true }

    if useToggle {
      await fx.starter.toggle(source: .toggleHotkey)
    } else {
      #expect(await fx.starter.start() == .noRecording)
    }

    #expect(fx.kernelDriver.state == .idle)
    #expect(fx.whisperKernelDriver.state == .idle)
    #expect(Self.showsDictationOffDuringMeeting(fx.overlay))
    #expect(fx.starter.microphoneAskTask == nil, "a refused press never asks for the microphone")
    #expect(prompt.requestCount == 0)
    #expect(fx.engineLease.admissionEpoch == 0, "a refused press never claims the engine")
  }

  /// Recovery's notice carries Discard, the only way out of a stuck replay, so it wins.
  @Test(arguments: [false, true])
  func recoveryRefusalWinsOverTheMeetingPolicy(useToggle: Bool) async {
    let fx = Self.makeFixture(isRecovering: true)
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.starter.isDictationOffForMeeting = { true }

    if useToggle {
      await fx.starter.toggle(source: .toggleHotkey)
    } else {
      _ = await fx.starter.start()
    }

    #expect(Self.showsRecoveryOffer(fx.overlay))
    #expect(Self.showsDictationOffDuringMeeting(fx.overlay) == false)
  }

  /// The switch is read at each press: turning it off lets the very next press past the gate.
  @Test(arguments: [false, true])
  func theMeetingPolicyIsReadAtEachPress(useToggle: Bool) async {
    let fx = Self.makeFixture()
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    var off = true
    fx.starter.isDictationOffForMeeting = { off }
    func press() async {
      if useToggle {
        await fx.starter.toggle(source: .toggleHotkey)
      } else {
        _ = await fx.starter.start()
      }
    }

    fx.lastRecordingResult.polishError = "from the previous take"
    await press()
    #expect(Self.showsDictationOffDuringMeeting(fx.overlay))
    #expect(fx.lastRecordingResult.polishError != nil, "the refused press stopped at the gate")

    off = false
    await press()
    // Same positive oracle as the shared-claim rows: clearing the previous take's polish error
    // happens only past every early gate.
    #expect(
      fx.lastRecordingResult.polishError == nil,
      "a press after the switch was turned off was still refused")
  }

  /// Entry-only (plan §5): a press admitted before the meeting began capturing goes on even
  /// when capture starts during its own start-up. Staged on the recovery-arm await: capture
  /// begins there, and so does a launch recovery, whose post-arm re-check is the positive
  /// signal that the press went on past the arm toward minting a session.
  @Test func aPressAdmittedBeforeCaptureIsNotRecalled() async {
    var capturing = false
    var reads = 0
    let fx = Self.makeFixture(
      recoveringDuringArm: true, duringRecoveryArm: { capturing = true })
    fx.asr.activeBackendType = .parakeet
    fx.asr.isModelLoaded = true
    fx.starter.isDictationOffForMeeting = {
      reads += 1
      return capturing
    }

    _ = await fx.starter.start()

    #expect(capturing, "capture began during the recovery arm")
    #expect(reads == 1, "the meeting policy is read once, at the press")
    #expect(Self.showsRecoveryOffer(fx.overlay), "the press reached the post-arm re-check")
    #expect(Self.showsDictationOffDuringMeeting(fx.overlay) == false)
  }

  #if DEBUG
    /// A start press joining a session already running is never refused. `start()` only: a
    /// STOP toggle cannot be staged here (see the note above the recovery-precedence rows), so
    /// Live UAT checks it: dictation running, meeting capturing, switch on, toggle stops it.
    @Test func aRunningSessionIsNeverRefusedByTheMeetingPolicy() async throws {
      let fx = Self.makeFixture()
      fx.asr.activeBackendType = .parakeet
      fx.starter.isDictationOffForMeeting = { true }
      fx.kernelDriver.kernelForTesting.testForceState(.live)
      let expected = try #require(fx.kernelDriver.continuingSessionID)

      let outcome = await fx.starter.start()

      #expect(outcome == .recording(expected))
      #expect(Self.showsDictationOffDuringMeeting(fx.overlay) == false)
    }
  #endif

}

/// Counts accessibility-refresh invocations for #904. A `@MainActor` reference
/// type because the seam closure is `@MainActor` (implicitly `Sendable` in
/// Swift 6) and the `@MainActor` suite supplies it.
@MainActor
private final class AXRefreshCounter {
  var count = 0

}

/// #3973 C1: the request owner's log, read per test (a per-instance sink, never the shared
/// logger), with a wait for a line that the subject itself writes.
@MainActor
final class TurnLogSink {
  private(set) var lines: [String] = []
  private var waiters: [(needle: String, after: Int, continuation: CheckedContinuation<Bool, Never>)] = []

  func append(_ line: String) {
    lines.append(line)
    let ready = waiters.filter { count(containing: $0.needle) > $0.after }
    waiters.removeAll { count(containing: $0.needle) > $0.after }
    ready.forEach { $0.continuation.resume(returning: true) }
  }

  func count(containing needle: String) -> Int { lines.filter { $0.contains(needle) }.count }

  /// Each terminal line as `<outcome> waitMs=<n>`.
  var outcomes: [String] {
    lines.compactMap { line in
      guard let range = line.range(of: "outcome="),
        let end = line.range(of: " startMs=", range: range.upperBound..<line.endIndex)
      else { return nil }
      return String(line[range.upperBound..<end.lowerBound])
    }
  }

  /// True once more than `after` lines contain `needle`; false at the deadline (5 s by default) so a test
  /// that never gets there fails instead of hanging.
  func waitFor(containing needle: String, after: Int, timeout: Duration = .seconds(5)) async -> Bool {
    guard count(containing: needle) <= after else { return true }
    return await withCheckedContinuation { continuation in
      waiters.append((needle, after, continuation))
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: timeout)  // deadline-fallback: bounds the signal wait
        guard let self,
          let index = self.waiters.firstIndex(where: { $0.needle == needle && $0.after == after })
        else { return }
        self.waiters.remove(at: index).continuation.resume(returning: false)
      }
    }
  }
}

/// #3973 C1: a manual monotonic clock for the request owner's wait times.
@MainActor
final class TurnClock {
  private(set) var now = ContinuousClock.now
  func advance(milliseconds: Int) { now = now.advanced(by: .milliseconds(milliseconds)) }
}
