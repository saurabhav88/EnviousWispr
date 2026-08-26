import AppKit
import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import SwiftUI

/// Owns the presentation TRANSACTION (#2292, chunk C4b).
///
/// It invokes the reducer, drives the host, and owns **exactly one** expiry and
/// **exactly one** active action binding. Everything it holds is either a
/// collaborator or a single-valued piece of transaction state; if this type ever
/// grows a per-kind field collection it has become the thing the migration is
/// removing.
///
/// **The production authority for every overlay presentation transaction.** The
/// composition root owns one director and injects one retained host, both for
/// the app's lifetime.
///
/// Two earlier versions of this paragraph were false in opposite directions —
/// one said the panel owned this type, the next said only tests instantiated it
/// — which is the shape of comment this migration keeps finding: confident,
/// plausible, and describing code that does not exist. This one is checkable:
/// `WisprBootstrapper` holds the single construction.
@MainActor
final class OverlayDirector {

  private var reducer: OverlayReducer
  private let host: any OverlayWindowHosting
  private let model: OverlayRenderModel

  /// The ONE dismissal clock. The director owns no timer and no dwell window of
  /// its own; `PillExpiryClock` owns both, and a second clock has nowhere to
  /// live.
  private let expiryClock: PillExpiryClock

  /// **Which recording pill the user has chosen, read fresh per recording.**
  ///
  /// A CLOSURE and not a stored value: the director is constructed once and lives
  /// for the application's lifetime, so an immutable pair would freeze the choice
  /// at launch — Phase 4's picker would appear to work, change nothing, and only
  /// take effect after a relaunch. That is a seam that looks correct and is not,
  /// which is worse than an obviously missing one.
  ///
  /// Read ONCE PER FRESH RECORDING and never on a same-id morph, matching the
  /// discipline capability already follows and for the same reason: an `NSPanel`
  /// cannot grow mid-recording without a rebuild, and a rebuild is the #930
  /// flicker. A live pill must not change design because the user opened Settings
  /// mid-dictation.
  private let selections: @MainActor () -> PillDesignSelections

  /// How a bounded bridge reconciliation reaches the next run-loop turn.
  private let scheduleReconciliation: (@escaping () -> Void) -> Void

  /// **A closed state machine, not a latch.** It means "a continuation chain is
  /// queued OR EXECUTING": true from the moment the first continuation is queued,
  /// true throughout that chain including while a queued closure runs and the
  /// queue is empty, and false only after a pass observes an unchanged slot
  /// revision. A flag that only ever gets set is
  /// a permanent mute wearing coalescing's name — the same shape this whole phase
  /// exists to remove, one layer down.
  private var reconciliationPending = false

  /// The ONE active action binding. The shipped panel keeps eight `set*Handler`
  /// closures alive for the app's lifetime whether or not the pill that uses
  /// them is showing; this holds the binding for the presentation that is
  /// actually on screen and drops it when that presentation goes.
  private var activeBinding:
    (id: PresentationID, deliver: (PillAction) -> Void, onExpire: (() -> Void)?)?

  /// Custody of the cancelled-transcript payload.
  ///
  /// **The director owns it, not the action.** `.pasteEscapeRecovery` carries
  /// the transcript ID as a LOOKUP KEY; the payload itself is held here and
  /// taken once. A one-shot take is what makes a stale Undo press safe — the
  /// second press finds nothing rather than pasting twice.
  private var escapeRecoveryPayload: (id: UUID, payload: CancelUndoPayload)?

  /// Send an effect to whoever owns it.
  ///
  /// **The chip's expiry belongs to the presentation that raised it, when that
  /// presentation supplied a callback.** A `PillRequest.languageChip` carries a
  /// non-optional `onExpire`, so discarding it would make the type's own contract
  /// a lie: the caller is required to hand one over and would never be called.
  /// Every other effect, and the chip's expiry when no typed request is bound,
  /// goes to the composition root exactly as before.
  ///
  /// **Scoped by the BINDING's own lifetime, not by a match against the current
  /// presentation** — and the first version got that wrong in a way its test
  /// caught. Expiry is reported at exactly the moment the presentation goes
  /// away: by the time this runs the reducer has already emptied
  /// `state.current`, so `binding.id == reducer.state.current?.id` compares
  /// against `nil` and can never pass. The callback was silently dropped and the
  /// effect broadcast instead, which is the behaviour the guard existed to
  /// prevent.
  ///
  /// The binding is the correct scope on its own: it is replaced when identity
  /// changes and cleared when the slot empties (see `apply`), and effects are
  /// routed BEFORE either happens. So a binding holding an `onExpire` belongs to
  /// the presentation whose expiry is being reported.
  /// **`.recordingStateChanged` goes to the bridge, and it is not optional.**
  /// It reached Live Preview through the composition root's effect sink before
  /// C2; the bridge now owns that channel, so the preview starts and stops with
  /// the recording pill without the heart path learning it exists (#1988).
  /// Removing the router's branch without adding this one would leave the
  /// preview never told a recording began — a user-visible dead feature.
  private func route(_ effect: PillEffect) {
    switch effect {
    case .recordingStateChanged(let isRecording):
      livePreview.recordingDidChange(isRecording)

    case .languageChipExpired:
      // **Exhaustive since C4b, with no sink behind it.** Every chip carries an
      // `onExpire` on its own request, so a missing owner is a wiring defect
      // rather than a case to route elsewhere — and there is nowhere else: the
      // output router is deleted.
      guard let onExpire = activeBinding?.onExpire else {
        assertionFailure(
          "languageChipExpired reached a presentation with no typed onExpire owner")
        return
      }
      onExpire()
    }
  }

  /// Posting the spoken announcement, injectable so a guard can observe it.
  ///
  /// `NSAccessibility.post` writes to the system and returns nothing, so without
  /// a seam the only assertion available is "the code that would have posted was
  /// reached" — which is the marker-beside-the-subject defect this repo already
  /// ranks. The default IS the real post, so a caller that forgets it still
  /// announces.
  private let announce: @MainActor (OverlayAnnouncement) -> Void

  /// **ONE construction, however many presentations ask before it is ready**,
  /// owned by `OverlayFirstRenderGate` rather than by a director-held flag.
  /// `lazy var` is required, not stylistic: the closures below capture `self`,
  /// and a stored property's initializer expression cannot — `self` is not
  /// fully formed until every stored property is set, so construction is
  /// deferred to first access, which is always after `init` completes.
  private lazy var firstRenderGate = OverlayFirstRenderGate(
    schedule: firstRenderSchedule,
    construct: { [unowned self] in makeRootHostingView() },
    didBecomeReady: { [weak self] root in
      self?.commitLatestFirstRender(root)
    })

  /// Requests root construction at the next main run-loop idle turn, ahead
  /// of any real presentation (#2377 Phase 6 C4). Registers an idle observer
  /// and returns immediately — construction happens later, when that
  /// observer fires. A no-op if the gate is already scheduled or ready,
  /// whichever caller got there first: `firstRenderGate`'s own idle-state
  /// guard is what makes that safe, not anything here.
  ///
  /// `idleScheduler` is a MECHANISM default, the same shape as
  /// `firstRenderSchedule`/`scheduleReconciliation` above: production always
  /// wants a real `CFRunLoopObserver`, which a synchronous unit test cannot
  /// observe firing without spinning the actual run loop. A test substitutes
  /// a manual scheduler here; the one production call site
  /// (`WisprBootstrapper.applicationDidFinishLaunching()`) stays a bare,
  /// zero-argument `recordingOverlay.prewarmFirstRender()`.
  func prewarmFirstRender(
    idleScheduler: @escaping OverlayFirstRenderGate.Schedule =
      OverlayFirstRenderGate.idleScheduler()
  ) {
    firstRenderGate.scheduleIfNeeded(using: idleScheduler)
  }

  /// Builds the retained root view. Called at most once per launch, from the
  /// gate's own scheduled task — never directly.
  private func makeRootHostingView() -> NSView {
    // #2377 Phase 6: DEBUG-only measurement of root construction, the cost this
    // phase moves. The gate calls this once, so the marker is naturally a
    // singleton.
    #if DEBUG
      let constructStart = OverlayFirstRenderMarkers.capture(.rootConstructStart)
    #endif
    let view = NSHostingView(
      rootView: OverlayRootView(
        model: model,
        sendEvent: { [weak self] event in self?.handle(event, binding: .none) }))
    #if DEBUG
      let constructEnd = OverlayFirstRenderMarkers.capture(.rootConstructEnd)
    #endif
    #if DEBUG
      // HELD, not emitted. Writing here would put the marker's own cost inside
      // the keypress interval in the baseline bundle and outside it in the
      // prewarmed one — see `OverlayFirstRenderMarkers.hold`. Two single-
      // capture calls, never one variadic call: a variadic argument list
      // allocates its own temporary array at THIS call site before `hold`
      // runs, which is the same asymmetric cost one level up.
      OverlayFirstRenderMarkers.hold(constructStart)
      OverlayFirstRenderMarkers.hold(constructEnd)
    #endif
    return view
  }

  /// Carries one `present` call's result from wherever that call terminates back
  /// to the caller — and is reachable from nothing else.
  ///
  /// **Never resolved twice, and never resolved on the caller's behalf by a
  /// LATER transaction.** A result held past its own call belongs to whoever
  /// touched it last, and both ways of managing that shipped a defect in turn:
  /// left armed, a recording resolved a CARD's caller with the recording's
  /// outcome; flushed on entry, a request that `admit` went on to REFUSE had
  /// already told a pending caller its card never appeared — while that card
  /// rendered anyway, with buttons whose target its presenter had never been
  /// told to record.
  ///
  /// **Several relays CAN be pending at once for the SAME presentation id**,
  /// held in `PendingFirstAcceptance.relays` while the first-render gate has
  /// not yet constructed: two calls that both morph the one recording pill
  /// before it has ever been drawn each get their own relay, and each must
  /// hear the SAME verdict once the pill actually reaches the screen —
  /// `onResult` promises exactly one answer describing whether the caller's
  /// own presentation id was shown, and answering early or not at all is a
  /// broken promise either way, not a simplification.
  ///
  /// One-shot: `resolve` after the first is a no-op, so a path that both rolls
  /// back and reports cannot report twice.
  private final class PresentationRelay {
    private var deliver: ((Bool) -> Void)?

    /// Set by `render` when it hands the presentation to a later run loop, so
    /// `present` can tell "the host has not been asked yet" from "the host was
    /// never going to be asked, because the plan changed nothing".
    private(set) var isDeferred = false

    init(_ deliver: @escaping (Bool) -> Void) { self.deliver = deliver }

    func markDeferred() { isDeferred = true }

    /// Rebind once the receipt exists, which is only after admission.
    func redirect(to deliver: @escaping (Bool) -> Void) { self.deliver = deliver }

    func disarm() { deliver = nil }

    func resolve(_ presented: Bool) {
      guard let deliver else { return }
      self.deliver = nil
      deliver(presented)
    }
  }

  /// The occupant the host is currently showing, so a morph can be told from a
  /// fresh presentation. The host needs that distinction to decide whether to
  /// re-anchor or preserve the live frame, and it is the CALLER's fact.
  private var presentedID: PresentationID?

  /// How the FIRST render reaches the next run loop — the seam
  /// `OverlayFirstRenderGate` schedules through.
  ///
  /// **A seam, not a branch, and the same shape `scheduler` already uses for
  /// expiry.** The production value is `DispatchQueue.main.async`, which is the
  /// crash fix; a synchronous test double lets the forty existing director cases
  /// keep asserting in one step instead of every one of them becoming `async`
  /// for a property only one of them is about.
  ///
  /// **`Task { @MainActor }` IS NOT A SUBSTITUTE** and the shipped panel says so
  /// at its own call site: `Task` may execute immediately when already on the
  /// main actor, which is precisely the case that crashes. Written here because
  /// this is the line someone will try to modernise.
  ///
  /// A plain stored property, not `lazy`: it captures no `self`, so it needs
  /// none of the deferred-construction treatment `firstRenderGate` requires,
  /// and the gate reads it at ITS OWN `init`, which runs at first access —
  /// after the director's `init` has already set this.
  private let firstRenderSchedule: OverlayFirstRenderGate.Schedule

  private let position: () -> OverlayPillPosition

  /// The once-per-session accessibility-toast policy.
  ///
  /// **Owned HERE, not by the caller.** Threading it through
  /// `DictationLifecycleCoordinator` put that type at 12 collaborators against a
  /// ceiling of 11 — a ceiling whose purpose is exactly to catch a coordinator
  /// accumulating other people's policies. The decision is about PRESENTING.
  private let accessibilityEligibility: OverlayAccessibilityEligibility

  /// Live Preview's whole surface, supplied at CONSTRUCTION (#2292 C2).
  ///
  /// **It used to arrive afterwards through `setLivePreviewProviders`, and the
  /// defaults were the OFF answers** — so a composition root that forgot the
  /// installer got a director that silently reported the feature disabled rather
  /// than failing. `LivePreviewInstaller` now returns a `LivePreviewBridge` and
  /// this is required, so forgetting it does not compile.
  ///
  /// Atomicity is untouched, and it never depended on how these arrived:
  /// `presentRecording` reads capability and selections at presentation time and
  /// resolves them once into a design, so the definition's geometry comes from
  /// that captured pair.
  private let livePreview: LivePreviewBridge

  /// What the accessibility notice's Grant button does.
  ///
  /// **Injected, because the notice has no call site that knows about
  /// permissions.** `DictationLifecycleCoordinator` raises it from the pipeline
  /// funnel and `PermissionsService` is nowhere in its world. Before C2 this
  /// travelled out through the router's settable, weak `permissions` target;
  /// that route could be unset and the button would render and reach nobody,
  /// which is the failure this whole phase exists to make unspellable.
  private let grantAccessibility: () -> Void

  init(
    host: any OverlayWindowHosting,
    position: @escaping () -> OverlayPillPosition = { .top },
    model: OverlayRenderModel = OverlayRenderModel(),
    scheduler: OverlayScheduler = .live,
    announce: @escaping @MainActor (OverlayAnnouncement) -> Void = OverlayDirector.postAnnouncement,
    accessibilityEligibility: OverlayAccessibilityEligibility = .init(warningDismissed: { false }),
    // **Neither of these defaults, and that is the point of C2.** A default here
    // has no token at the call site, so no sweep can find a caller that meant to
    // pass one and did not — the omission compiles and the feature is silently
    // dead. `.disabled` and a no-op grant both still EXIST for tests that are
    // about neither; choosing one is now visible in the source.
    livePreview: LivePreviewBridge,
    grantAccessibility: @escaping () -> Void,
    // **No default either, for the reason directly above** (#2375 C3a). This is
    // the seam Phase 4 replaces: a settings-backed snapshot at this same
    // construction point, changing this closure's BODY and nothing else. A
    // default would let a caller silently inherit the constant, so Phase 4 would
    // end up editing the default instead of the seam — a seam that looks
    // installed and is not.
    selections: @escaping @MainActor () -> PillDesignSelections,
    makeID: @escaping () -> PresentationID = { PresentationID() },
    firstRenderSchedule: @escaping OverlayFirstRenderGate.Schedule = { work in
      DispatchQueue.main.async(execute: work)
    },
    // A MECHANISM default, unlike the two above: production always wants the next
    // main-run-loop turn, and a test wants to execute the queued continuation
    // itself so the bound is asserted without a sleep.
    scheduleReconciliation: @escaping (@escaping () -> Void) -> Void = { work in
      DispatchQueue.main.async(execute: work)
    }
  ) {
    self.firstRenderSchedule = firstRenderSchedule
    self.selections = selections
    self.scheduleReconciliation = scheduleReconciliation
    self.host = host
    self.announce = announce
    self.accessibilityEligibility = accessibilityEligibility
    self.livePreview = livePreview
    self.grantAccessibility = grantAccessibility
    self.position = position
    self.model = model
    self.expiryClock = PillExpiryClock(
      schedule: scheduler, publishDwell: { [weak model] in model?.markDwellStarted($0) })
    self.reducer = OverlayReducer(makeID: makeID)
  }

  /// **The previous mechanism resolved a caller left waiting when the
  /// director itself went away before its deferred first render fired —
  /// `self` going `nil` inside a `[weak self]` scheduled block.** The gate
  /// owns no relay to resolve on that path (`pendingFirstAcceptance` lives
  /// here, not on the gate), so this director going away is the only place
  /// left that can settle those callers. Preserves the old promise: a caller
  /// hears `false` rather than nothing.
  deinit {
    MainActor.assumeIsolated {
      pendingFirstAcceptance?.relays.forEach { $0.resolve(false) }
    }
  }

  var renderModel: OverlayRenderModel { model }

  // **`currentIntent` was DELETED** (#2292 C6). It was a PROJECTION invented so a
  // presenter could ask "is my own thing on screen" — and it had to project,
  // because a feature never sets `pipelineIntent`, so the bare pipeline value
  // answered `.hidden` while a card was up and left every button on that card a
  // no-op. C3 moved admission into `present`, so no presenter asks any more.
  //
  // What replaced it, per question: what the user sees is `renderModel`; whether
  // a feature may take the slot is `featureSlotIsAvailable`; whether a caller
  // still owns its presentation is `isCurrent(_:)`.

  /// The production announcement, lifted verbatim from the sixteen identical
  /// `NSAccessibility.post` calls the panel makes — same element, same
  /// notification, same user-info keys. The only per-case value was the
  /// priority, which the plan now carries.
  static func postAnnouncement(_ announcement: OverlayAnnouncement) {
    let priority: NSAccessibilityPriorityLevel = announcement.isHighPriority ? .high : .medium
    NSAccessibility.post(
      element: NSApp.mainWindow as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: announcement.text,
        .priority: priority.rawValue as NSNumber,
      ])
  }

  // MARK: - The transaction

  /// What an event installs for the presentation it produces.
  ///
  /// **An explicit two-case input, not an optional** (#2292 C5c). An
  /// `((PillAction) -> Void)?` let a call site that SHOULD carry a handler
  /// compile silently without one — the omission read as absence rather than as
  /// a choice. `.none` has to be written down.
  ///
  /// The binding arrives WITH the event for the reason a separate `bind(for:)`
  /// call was removed: that made binding a post-publication operation, so the
  /// caller had to bind after the presentation existed, an ordering nothing
  /// enforced, and a window in which the pill was on screen with no handler.
  private enum BindingInput {
    case none
    case install(deliver: (PillAction) -> Void, onExpire: (() -> Void)?)
  }

  private func handle(
    _ event: OverlayEvent, binding: BindingInput, relay: PresentationRelay? = nil
  ) {
    if case .pipeline(.recording) = event {
      // **The wrong ORDER is what this refuses, not the wrong event.** A bare
      // event carries no providers and resolves no design or position.
      //
      // `assertionFailure` rather than a precondition: this is a programming
      // invariant, caught in Debug and in CI, and trapping a user's Release build
      // over a first-frame defect is worse than the defect.
      //
      // In Release the assertion compiles away. A live recording may still morph
      // using its preserved design, captured position and already-installed
      // providers; a fresh recording is refused by the reducer and shows nothing.
      // The caller sweep remains load-bearing because the assertion is
      // diagnostic, not a Release defence.
      assertionFailure(
        "use presentRecording(...) — a recording's providers and its resolved design "
          + "must be installed in the same operation that presents it")
    }
    apply(reducer.reduce(event), binding: binding, relay: relay)
  }

  /// Present the recording pill with its providers and its resolved design
  /// installed in ONE operation.
  ///
  /// **The accepted definition, captured position and recording providers are
  /// installed together.**
  /// Splitting them across `setRecordingProviders`
  /// and `send` made a wrong first frame expressible, so this is the only way to
  /// express the right one.
  ///
  /// A MORPH keeps the design it was created with. The shipped panel reads the
  /// preview setting once at creation and its width is fixed for that panel's
  /// life, because an `NSPanel` cannot grow mid-recording without a rebuild and a
  /// rebuild is the #930 flicker. Re-resolving here on every audio tick would
  /// resize a live pill the moment the user changed the setting.
  /// **No binding parameter: a recording pill draws no buttons** (#2292 C5c), so
  /// there was never a handler to install. Private now — `present(.recording(_:))`
  /// is the only way in.
  private func presentRecording(
    audioLevel: Float,
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval?,
    isRecordingLocked: Bool,
    relay: PresentationRelay? = nil
  ) {
    // **The lock is a show-time value, not a later morph.** The shipped
    // `show(intent:isRecordingLocked:)` takes it in the same call and commits it
    // before drawing, and the reducer's own born-locked rule says why: applied
    // in the SAME transaction rather than rendered unlocked and morphed a frame
    // later. Leaving it to a separate `send(.lockStateChanged(_:))` at the call
    // site makes forgetting it possible, and forgetting it loses hands-free lock
    // silently.
    //
    // The plan is discarded deliberately: it either reports no change, or a
    // morph that the recording plan below supersedes. What matters is the STATE
    // it sets, which the born-locked rule and the morph path both read.
    _ = reducer.reduce(.lockStateChanged(isRecordingLocked))

    switch reducer.prepareRecording(audioLevel: audioLevel) {
    case .refused(let plan):
      // A feature holds the slot, or nothing changed.
      apply(plan, binding: .none, effectsAlreadyDelivered: true, relay: relay)

    case .morphed(let plan):
      // **A same-id morph skips RESOLVE ENTIRELY.** The live pill keeps its
      // design, so there is nothing to read and nothing that could change: no
      // capability read, no selections read, no position read. This is the
      // shipped `presentedID == presentation.id` branch keeping its meaning.
      guard let presentation = plan.presentation else {
        apply(plan, binding: .none, effectsAlreadyDelivered: true, relay: relay)
        return
      }
      // A morph keeps the live pill's design and position: nothing was resolved,
      // so there is nothing new to install.
      guard let design = presentation.recordingDesign else {
        assertionFailure("a morphed recording carries no design")
        return
      }
      // **The position comes off the PUBLISHED frame, not from staged state.**
      // A morph is the same pill, so the frame on screen already carries the
      // position this pill was composed with — and reading it there means the
      // leaf and the host cannot consume positions taken at two moments.
      guard let position = model.state.recording?.position else {
        assertionFailure("a morphed recording has no published frame")
        return
      }
      installRecordingProviders(
        for: presentation, design: design, position: position,
        audioLevelProvider: audioLevelProvider,
        recordingElapsedProvider: recordingElapsedProvider)
      apply(plan, binding: .none, effectsAlreadyDelivered: true, relay: relay)

    case .prepared(let token):
      // ---- RESOLVE ----------------------------------------------------------
      // **The effect goes out BEFORE capability is read, not merely before the
      // render**, and that ordering is the reason this whole boundary exists.
      // `LivePreviewCoordinator` applies its model-removal suppression inside
      // `setRecording`, so a capability read that beats the effect can pick the
      // 400-point design for a pill whose preview is about to resolve DISABLED —
      // a preview-sized window with no preview in it.
      for effect in token.effects {
        route(effect)
      }

      // Capability, selections and position: read ONCE, here, together.
      let capabilityHasWords = livePreview.isEnabledForGeometry()
      let resolution = selections().resolve(capabilityHasWords: capabilityHasWords)
      let at = position()

      let entry = PillCatalog.entry(
        for: .recording(audioLevel: token.audioLevel, design: resolution.design), id: token.id)
      // **Both guards run BEFORE COMMIT.** An earlier version validated the
      // accepted design AFTER committing, so on failure the corrupt state had
      // already landed and the guard could only report it. Reconciling the bridge
      // here also covers the nil-definition case, which previously returned
      // leaving Live Preview told a recording had started.
      guard let definition = entry.definition,
        let acceptedDesign = definition.recordingDesign
      else {
        assertionFailure("the catalog's recording arm returned no recording definition")
        reconcileRecordingBridge()
        return
      }

      // ---- COMMIT -----------------------------------------------------------
      guard let plan = reducer.commitRecording(token, definition: definition) else {
        // **DISCARDED, and the discard is not an error.** A newer overlay event
        // reentered synchronously between PREPARE and COMMIT and is already
        // authoritative, so retrying would install an older pill over a newer
        // one. Nothing is committed, rendered, announced or armed.
        //
        // But RESOLVE already routed `.recordingStateChanged(true)`, so Live
        // Preview has been told a recording started with nothing behind it. That
        // is the leak this reconciliation closes, and it retries only the BRIDGE.
        reconcileRecordingBridge()
        return
      }

      // **From the ACCEPTED definition's design, never from `resolution`.**
      // They are equal today, but passing `resolution.design` would reintroduce a
      // second answer beside the definition that actually committed.
      installRecordingProviders(
        for: definition, design: acceptedDesign, position: at,
        audioLevelProvider: audioLevelProvider,
        recordingElapsedProvider: recordingElapsedProvider)
      apply(plan, binding: .none, effectsAlreadyDelivered: true, relay: relay)
    }
  }

  /// The provider install, shared by the morph and commit paths so the two cannot
  /// drift in what they hand the render model.
  private func installRecordingProviders(
    for presentation: PillDefinition,
    design: RecordingPillDesign,
    position: OverlayPillPosition,
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval?
  ) {
    model.setRecordingProviders(
      audioLevel: audioLevelProvider,
      recordingElapsed: recordingElapsedProvider,
      livePreview: livePreview.display,
      design: design,
      position: position,
      onContentHeightChange: { [weak self] height in
        // The preview pill grows a line at a time as words wrap. Keyed to the
        // presentation it was installed for, so a late callback from a finished
        // dictation cannot resize the pill that replaced it.
        //
        // **Width comes from the design CAPTURED in this transaction, never
        // re-read** (#2375 C3b). Reading it back off the render model is what
        // made this a second consumer of the geometry override, so a change to
        // that override silently moved a live pill's growth width.
        guard let self, self.presentedID == presentation.id, design.canHoldWords
        else { return }
        self.host.resizeCurrentPresentation(to: CGSize(width: design.width, height: height))
      })
  }

  /// Tell Live Preview what the reducer now says, and keep telling it until the
  /// slot stops moving (#2375 C3a).
  ///
  /// **Bounded, and the bound is the point.** Routing calls back into the same
  /// boundary that created the prepare/commit hazard, so reading the answer
  /// before the call proves nothing about the answer after it — but "repeat until
  /// stable" is a proof obligation dressed as an algorithm, and an unbounded
  /// synchronous loop would spin on the RECORDING path, which `CLAUDE.md` says
  /// must work every time it physically can.
  ///
  /// Neither escape is acceptable here: a silent give-up leaves Live Preview
  /// wrong with nothing reporting it, and a `fatalError` turns a rare reentrancy
  /// into a crash mid-dictation. So: at most TWO synchronous attempts, then
  /// exactly one continuation onto the next turn, which schedules its own
  /// successor only if the world moved again. It yields under sustained churn
  /// rather than spinning, and it never abandons reconciliation.
  ///
  /// Every attempt is mint-free, render-free, announcement-free and expiry-free.
  private func reconcileRecordingBridge() {
    var attempts = 0
    while attempts < 2 {
      attempts += 1
      let before = reducer.recordingReconciliationSnapshot
      route(.recordingStateChanged(before.isRecording))
      // **Converged. The flag is NOT touched here, and that is deliberate.** It
      // means "a continuation chain is queued or executing", and this synchronous
      // pass may be
      // running while one already is — a second discard can arrive inside a
      // route. Clearing a flag this pass did not set would let the next caller
      // enqueue a duplicate, which is the one thing the flag exists to prevent.
      if reducer.recordingReconciliationSnapshot.revision == before.revision { return }
    }
    scheduleReconciliationContinuation()
  }

  /// One continuation, coalesced. A call arriving while one is pending does not
  /// enqueue another; the pending one reads the LATEST snapshot when it runs, so
  /// a late continuation is harmless by construction — the danger is never a
  /// wrong value, only a suppressed one.
  ///
  /// **`reconciliationPending` means a continuation chain is queued or executing.**
  /// While a queued closure runs, the queue is empty and the flag is still true —
  /// "queued" alone would be a claim the implementation does not make. One place
  /// sets it and one place clears it. An earlier version had three sites
  /// touching it, two of which could clear a flag they had not set: the
  /// synchronous pass above, and the continuation clearing it before recursing
  /// into that pass — which can route, reenter, discard, and reach here again
  /// with the guard open.
  private func scheduleReconciliationContinuation() {
    guard !reconciliationPending else { return }
    reconciliationPending = true
    enqueueReconciliationPass()
  }

  /// The chain re-enqueues through here rather than through the guard above, so
  /// the flag stays true for the whole chain and is cleared only by the pass that
  /// finds the world has stopped moving.
  private func enqueueReconciliationPass() {
    // **Weak capture**, so teardown cancels the remaining work rather than having
    // a pending reconciliation extend the director's lifetime.
    scheduleReconciliation { [weak self] in
      guard let self else { return }
      let before = self.reducer.recordingReconciliationSnapshot
      self.route(.recordingStateChanged(before.isRecording))
      if self.reducer.recordingReconciliationSnapshot.revision == before.revision {
        self.reconciliationPending = false
        return
      }
      self.enqueueReconciliationPass()
    }
  }

  /// Present the accessibility notice, showing the toast or falling back to the
  /// clipboard hint — **and announcing the accessibility sentence either way.**
  ///
  /// That last part is the whole reason this is one method rather than a
  /// conditional at the call site. The shipped panel posts the accessibility
  /// announcement BEFORE its eligibility branch, so a user on VoiceOver hears
  /// "Accessibility permission needed for auto-paste" even on the runs where the
  /// toast is suppressed and the clipboard hint is drawn instead. Routing the
  /// suppressed case through `.pipeline(.clipboardFallback)` would announce
  /// "Text copied to clipboard" — a different sentence, and a silent change in
  /// what a blind user is told, smuggled in by a refactor.
  ///
  /// **Preserved deliberately, not endorsed.** Whether it is right that the
  /// spoken sentence keeps explaining the permission while the visible one
  /// switches to the actionable hint is a real question, and it is filed rather
  /// than answered here: a migration that quietly changes behaviour is a worse
  /// defect than the behaviour.
  /// Eligibility is asked through a CLOSURE so the reducer's dedup guard runs
  /// FIRST. Asking eagerly spends the session's one showing on a push that is
  /// then dropped, and the next genuine ask is refused.
  ///
  /// **Grant, THEN dismiss, and the order is the shipped one.** The router this
  /// replaces ran `permissions?.requestAccessibilityAccess()` followed by
  /// `overlay?.dismissSilently()`. Requesting and leaving the notice on screen
  /// is a pill the user already answered; dismissing first would race the
  /// system prompt against the pill's own teardown.
  private func presentAccessibilityNotice(relay: PresentationRelay? = nil) {
    apply(
      reducer.reduceAccessibilityNotice(showingToast: { [accessibilityEligibility] in
        accessibilityEligibility.claim()
      }),
      binding: .install(
        deliver: { [weak self] action in
          guard let self else { return }
          guard case .grantAccessibility = action else {
            assertionFailure("the accessibility notice emitted a non-Grant action")
            return
          }
          self.grantAccessibility()
          self.dismissSilently()
        }, onExpire: nil),
      relay: relay)
  }

  /// Empty the slot WITHOUT announcing "Recording complete".
  ///
  /// **The shipped `hide()` and `show(intent: .hidden)` are not the same
  /// operation and the difference is audible.** `.hidden` announces; `hide()`
  /// posts nothing, and `LanguageSuggestionPresenter.hideOverlay` carries a
  /// comment saying so — added by a prior review round because a chip dismissal
  /// announcing a completed recording is a false statement to a VoiceOver user.
  ///
  /// Silence is a parameter of APPLYING rather than a different plan, so the
  /// reducer stays a pure function of its events and the choice is visible at
  /// both call sites.
  private func dismissSilently() {
    apply(reducer.reduce(.pipeline(.hidden)), binding: .none, announcing: false)
  }

  /// Undo a plan whose presentation the host refused.
  ///
  /// **`.pipeline(.hidden)` is the right event for a refused FEATURE too**, not
  /// only for a refused pipeline pill. It empties `state.current` whatever
  /// occupies it and returns `pipelineIntent` to `.hidden`, which is exactly the
  /// two pieces of state a refusal leaves lying: the occupant `currentIntent`
  /// reads, and the intent the dedup guard compares a retry against.
  ///
  /// Re-entrant into `apply` by design and it terminates: the hidden plan
  /// carries no presentation, so `render` takes its early return and cannot
  /// refuse a second time.
  private func rollBackRefusedPresentation() {
    apply(reducer.reduce(.pipeline(.hidden)), binding: .none, announcing: false)
  }

  // MARK: - Applying a plan

  private func apply(
    _ plan: OverlayPlan, binding: BindingInput, announcing: Bool = true,
    effectsAlreadyDelivered: Bool = false, relay: PresentationRelay? = nil
  ) {
    // **Effects run FIRST, and that half IS load-bearing rather than tidy.**
    // recordingIntentObserver fired at the top of `show(intent:)`, before any
    // panel work, so Live Preview has frozen its enabled-for-geometry answer by
    // the time the first frame is sized. Running effects last, which the first
    // version did, can size that frame from the live setting instead.
    //
    // The announcement used to sit here too, matching the shipped panel. It now
    // runs at the END, once the window has accepted the presentation — see the
    // note at that call for why mirroring the shipped order was wrong.
    if !effectsAlreadyDelivered {
      for effect in plan.effects {
        route(effect)
      }
    }
    // The expiry rules — a dwell starts when the pill is VISIBLE, a cancel takes
    // effect immediately, one armed timer at a time — are owned by
    // `PillExpiryClock`. The director decides WHAT the plan is and hands the
    // command over; it holds no timer of its own.
    let armExpiry = expiryClock.prepare(plan.expiryCommand) { [weak self] id, target in
      switch target {
      case .presentation: self?.handle(.expiryFired(id), binding: .none)
      case .inPanelNotice: self?.handle(.inPanelNoticeExpiryFired(id), binding: .none)
      }
    }
    // **Which of `PillExpiryClock`'s three meanings this plan carries, kept
    // explicit rather than folded into the returned closure.** `.unchanged`
    // and `.cancel` both hand back an indistinguishable no-op — `.cancel`'s
    // real effect already ran INSIDE `prepare` above — so a coalescing
    // decision (preserve a still-pending arm vs. clear it vs. replace it)
    // cannot be read back out of `armExpiry` itself; it has to travel
    // alongside it. `PillExpiryClock.swift:66` owns which case means what.
    let expiryUpdate: PendingExpiryUpdate
    switch plan.expiryCommand {
    case .unchanged: expiryUpdate = .preserve
    case .cancel: expiryUpdate = .clear
    case .arm: expiryUpdate = .replace(armExpiry)
    }

    // **FAIL CLOSED: the recovery pill needs a payload the intent cannot carry.**
    // `OverlayIntent` is `Sendable` and the paste target is a pair of main-actor
    // AX handles, so the typed `.escapeRecovery` request stores the payload and the intent
    // carries only the id. A bare `send(.pipeline(.escapeRecovery(id)))` finds
    // none, and the shipped panel drew NOTHING in that case while still
    // announcing -- the announcement is true, because the row is saved, and an
    // offer to Paste that points at no target is not.
    //
    // No caller reaches this today. It is preserved because a bare call still
    // COMPILES, and this branch has already shipped one defect of exactly that
    // shape: `actions: nil` compiled and left Grant and Discard unbound.
    //
    // Rolled back rather than left claiming the slot, so the fail-closed rule
    // and C7's "a presentation nobody can see leaves no owner" hold together.
    if case .escapeRecovery(let offeredID)? = plan.presentation?.content,
      escapeRecoveryPayload?.id != offeredID
    {
      if announcing, let announcement = plan.announcement { announce(announcement) }
      rollBackRefusedPresentation()
      return
    }

    if plan.didChange {
      // **Custody ends on ANY replacement, not only on an empty slot.** Clearing
      // it only when the slot emptied left a cancelled transcript held while a
      // DIFFERENT pill was showing — the payload outliving the offer to restore
      // it, which is the same defect the id gate exists to prevent, one level up.
      if case .escapeRecovery(let id)? = plan.presentation?.content,
        escapeRecoveryPayload?.id == id
      {
        // The pill still on screen is the one whose payload we hold.
      } else {
        escapeRecoveryPayload = nil
      }

      // The binding for the NEW presentation is installed BEFORE the model is
      // published, so the pill is never on screen without its handler.
      //
      // A binding belongs to one presentation identity. A same-ID plan is a
      // morph of that presentation; replacement or dismissal ends its binding.
      if let presentation = plan.presentation {
        switch binding {
        case .install(let deliver, let onExpire):
          activeBinding = (id: presentation.id, deliver: deliver, onExpire: onExpire)
        case .none:
          if activeBinding?.id != presentation.id { activeBinding = nil }
        }
      } else {
        activeBinding = nil
      }

      // **The providers belong to a RECORDING, so they end when the recording
      // does — and a replacement ends it just as surely as an empty slot.**
      // Releasing them only when the slot emptied left a finished dictation's
      // closures being polled fifty times a second behind whatever pill replaced
      // it, which is the same lifetime defect as the payload custody above.
      // A same-id morph keeps them: an audio tick is the SAME recording.
      if case .recording? = plan.presentation?.content {
        // Still the recording pill. Its providers are still its own.
      } else {
        model.clearRecordingProviders()
      }

      // ONE publication carries the whole frame: the presentation, the lock, the
      // resolved notice copy and the providers reach the root together, so no
      // leaf can be built from a new presentation and an outgoing lock.
      model.publish(plan.presentation)
      // **`render` now owns acceptance, refusal, rollback, expiry-start and
      // announcement together — see `finishRender`.** `RenderSubmission` has
      // only two cases because a QUEUED render and a REFUSED one both need the
      // relay left to a LATER resolution and neither is this call's business:
      // a queued render resolves when `commitLatestFirstRender` eventually
      // runs, and a refused one is resolved by `finishRender` itself before
      // this call returns. Only `.queued` needs this call to stop — a refusal
      // has already rolled back and answered by the time control gets here.
      let submission = render(
        plan.presentation, relay: relay, expiryUpdate: expiryUpdate,
        announcement: announcing ? plan.announcement : nil)
      if submission == .queued { return }
    }

    // **A plan that changes NOTHING still announces, and that is shipped.**
    // `show(intent: .hidden)` posts in its arm whether or not a panel existed,
    // so emptying an already-empty slot is audible. Every plan that DOES change
    // something announces through `onPresented` above instead, which is what
    // ties the sentence to the presentation actually reaching the screen.
    //
    // The EFFECT ordering that was load-bearing is untouched: effects still run
    // first, before the geometry read, which is the constraint Live Preview's
    // first frame actually depends on.
    if !plan.didChange {
      // Nothing is being rendered, so there is no "it landed" signal to wait
      // for — the pill this dwell belongs to is already on screen. That is also
      // the honest answer for a caller asking whether its request reached the
      // screen: it did, and a no-change plan did not take it down.
      armExpiry()
    }
    if !plan.didChange, announcing, let announcement = plan.announcement {
      announce(announcement)
    }

    if let action = plan.deliverAction {
      if let binding = activeBinding, binding.id == reducer.state.current?.id {
        binding.deliver(action)
      } else {
        // **Loud, not silent.** The reducer only emits `deliverAction` for the
        // CURRENT presentation, so arriving here without a matching binding is
        // an invariant failure, not a race. Dropping it quietly would lose a
        // button press with nothing anywhere to say so.
        assertionFailure(
          "an action for the live presentation had no binding — the request that "
            + "produced it did not carry its handler")
      }
    }

  }

  /// **Discharges the obligation `OverlayContent.recording` records**: the
  /// non-preview recording pill is 185 points wide in a reserved 92-point
  /// interaction frame, and the Live Preview variant is 400 wide and
  /// content-sized from its first frame so it does not visibly snap once the
  /// real height is measured.
  ///
  /// The DIRECTOR decides it and the reducer cannot, because whether preview is
  /// on arrives as a PROVIDER rather than as an event — putting it in the reducer
  /// would mean the reducer reading a closure, which stops it being a function of
  /// its events. Every other presentation takes its own width and reserved height
  /// unchanged.
  private func geometry(
    for presentation: PillDefinition
  ) -> (width: OverlayWidth, fixedHeight: CGFloat?) {
    // **THE RECORDING SPECIAL CASE IS GONE, AND THAT IS G3 CLOSED** (#2375 C3b).
    //
    // It substituted the layout bundle's width and height for the definition's,
    // and its own comment said why: the reducer "cannot know which layout is in
    // force", so its 185/92 was ignored. Two authorities for one geometry, the
    // correct-looking one discarded, documented as though it were a design.
    //
    // A recording definition now carries its RESOLVED design's own width and
    // height, so there is one answer and this function returns it like every
    // other pill's. C3a proved the deletion was a no-op by asserting the adapter
    // and the definition agreed for both designs; that assertion is deleted with
    // the adapter, because once there is nothing to disagree with it asserts
    // nothing.
    return (presentation.requestedWidth, presentation.reservesFixedHeight)
  }

  /// Push the model's new occupant to the window.
  ///
  /// **SETTING THE MODEL FIRST IS NOT ENOUGH, AND THIS COMMENT USED TO SAY IT
  /// WAS.** It claimed the retained root has already rendered the new content by
  /// the time the host measures it. SwiftUI applies a published change on its own
  /// schedule, so the host measured the OUTGOING pill — the exact failure the old
  /// sentence was written to rule out, and one that only live UAT found: the pill
  /// sat 124.5 points left of centre for 0.52 s after a recording ended, and
  /// rested 10.5 points left permanently.
  ///
  /// **`OverlayWindowHost.resolvedSize` flushes the pending layout, and THAT is
  /// what makes the measurement current.** The model is still set first, because
  /// the flush needs the new content to be pending; the two are a pair and
  /// neither works alone. Do not treat the flush as redundant on the strength of
  /// the ordering here — that reasoning is what this comment previously invited.
  ///
  /// Returns `false` ONLY when the host refused a presentation it was asked to
  /// show. Emptying the slot always succeeds, so the caller reads a `false` as
  /// "the occupant this plan installed is not on screen and never will be".
  private static func isRecording(_ presentation: PillDefinition) -> Bool {
    if case .recording = presentation.content { return true }
    return false
  }

  /// `.queued` means no host verdict exists yet and `apply` must return.
  /// `.completed` means this call has already hidden, or `finishRender` has
  /// accepted or refused the host command and settled every relay.
  private enum RenderSubmission {
    case completed
    case queued
  }

  /// **Which of `PillExpiryClock`'s three prepared meanings a coalescing
  /// update carries.** `expiryClock.prepare` always returns a callable
  /// closure, but `.unchanged`'s and `.cancel`'s are both indistinguishable
  /// no-ops — see the comment where this is built, in `apply`. `.preserve`
  /// and `.clear` collapse to the same "call nothing" outcome wherever there
  /// is no PRIOR pending state to preserve FROM (the immediate, gate-ready
  /// render path); they diverge only while coalescing an update onto an
  /// already-pending first render.
  private enum PendingExpiryUpdate {
    case preserve
    case clear
    case replace(() -> Void)

    var resolvedStart: (() -> Void)? {
      guard case .replace(let start) = self else { return nil }
      return start
    }
  }

  /// **Everything a still-unbuilt first render owes once it lands**, coalesced
  /// from however many presentations arrived while the gate had not yet
  /// constructed. Typed because `.unchanged` must retain a previously prepared
  /// arm, `.cancel` must clear it, and `.arm` must replace it.
  private struct PendingFirstAcceptance {
    let id: PresentationID
    var relays: [PresentationRelay]
    var expiryStart: (() -> Void)?
    var announcement: OverlayAnnouncement?
  }

  /// The ONE slot for construction-pending presentations, keyed by id so a
  /// same-id morph coalesces and a different-id supersession resolves the
  /// outgoing owner `false`. `nil` whenever nothing is waiting on the gate —
  /// which is always, once `firstRenderGate.readyRoot` exists.
  private var pendingFirstAcceptance: PendingFirstAcceptance?

  @discardableResult
  private func render(
    _ presentation: PillDefinition?,
    relay: PresentationRelay? = nil,
    expiryUpdate: PendingExpiryUpdate = .preserve,
    announcement: OverlayAnnouncement? = nil
  ) -> RenderSubmission {
    guard let presentation else {
      // A `.hidden` plan still owes whatever was waiting on a construction
      // that will now never show it — resolved here rather than left for
      // `commitLatestFirstRender` to find later, so a caller hears its
      // verdict as soon as the answer is known instead of whenever the gate
      // next happens to fire.
      //
      // **Take the slot and settle every OTHER consequence before resolving
      // any relay.** `resolve(false)` runs arbitrary caller code, and a
      // reentrant `present` from inside that callback must see the hide
      // already applied and the slot already empty — not this call's own
      // stale view of either, which it would otherwise overwrite on return.
      let detached = pendingFirstAcceptance?.relays ?? []
      pendingFirstAcceptance = nil
      presentedID = nil
      host.hide()
      // **A dismissal still announces "Recording complete" and still owes
      // whatever expiry command this plan carried** — `.hidden` has no
      // presentation but is not exempt from either
      // (`OverlayReducer.swift`'s own `OverlayPlan.announcement` doc comment
      // states this explicitly, and `silentDismissalSaysNothing` proves it).
      expiryUpdate.resolvedStart?()
      if let announcement { announce(announcement) }
      detached.forEach { $0.resolve(false) }
      return .completed
    }
    // **THE FIRST PRESENTATION IS DEFERRED ONE RUN LOOP, AND THIS IS A CRASH
    // FIX RATHER THAN A COMPENSATION.** `MenuBarController.toggleRecordingAction`
    // reaches here while the status-item MENU DISMISS ANIMATION is still
    // running, and building the `NSHostingView` during that animation causes a
    // re-entrant `NSWindow` layout cycle and SIGABRT. The shipped panel carried
    // that reason in a comment at its `DispatchQueue.main.async`, including the
    // warning that `Task { @MainActor }` is NOT equivalent because it may run
    // immediately when already on the main actor — which is exactly the shape
    // the menu action uses.
    //
    // **C5 deleted this on the stated ground that the four rebuild mechanisms
    // "existed for ONE reason: every transition destroyed the window and built
    // another". That was true of three of them and FALSE of this one.** The
    // deferral is about WHEN a hosting view is first constructed, which a
    // retained window makes rarer and does not make safe. Cloud review caught it
    // as a P1 after four local rounds passed it.
    //
    // ONLY the first: the retained panel means every later presentation morphs a
    // view that already exists, and the shipped code was synchronous on that
    // path too. `DispatchQueue.main.async` rather than `Task`, for the reason
    // above, spelled out so it is not "modernised" back.
    if let root = firstRenderGate.readyRoot {
      return finishRender(
        presentation, root: root, relays: relay.map { [$0] } ?? [],
        expiryStart: expiryUpdate.resolvedStart, announcement: announcement)
    }

    coalescePendingFirstAcceptance(
      id: presentation.id, relay: relay, expiryUpdate: expiryUpdate,
      announcement: announcement)
    firstRenderGate.scheduleIfNeeded()
    return .queued
  }

  /// Folds a new presentation into whatever is already pending, per the
  /// coalescing rule the render gate cannot own itself (it knows nothing of
  /// presentation identity — see `OverlayFirstRenderGate`'s own doc comment):
  /// a different id resolves the outgoing relays `false` and starts a fresh
  /// slot; the same id keeps every relay accumulated so far, since each one
  /// promises its own caller exactly one verdict once the SAME presentation
  /// id actually reaches the screen.
  private func coalescePendingFirstAcceptance(
    id: PresentationID,
    relay: PresentationRelay?,
    expiryUpdate: PendingExpiryUpdate,
    announcement: OverlayAnnouncement?
  ) {
    // Set before scheduling, not after: an injected IMMEDIATE scheduler can
    // resolve this same call stack, and `present(_:onResult:)` reads
    // `isDeferred` to decide whether the receipt exists yet to rebind to.
    relay?.markDeferred()

    if var pending = pendingFirstAcceptance, pending.id == id {
      if let relay { pending.relays.append(relay) }
      switch expiryUpdate {
      case .preserve: break
      case .clear: pending.expiryStart = nil
      case .replace(let start): pending.expiryStart = start
      }
      // A nil announcement does not erase one already pending; only a later
      // non-nil announcement replaces it.
      if let announcement { pending.announcement = announcement }
      pendingFirstAcceptance = pending
      return
    }

    // **THE REPLACEMENT MUST BE INSTALLED BEFORE ANY OUTGOING RELAY RUNS.**
    // `resolve(false)` calls arbitrary caller code synchronously, and a
    // `.notPresented` callback presenting AGAIN is a real, reachable shape —
    // that reentrant call reads `pendingFirstAcceptance` too. Resolving
    // first would let it install its own slot, which this function would then
    // silently clobber with its previously computed replacement.
    let outgoing = pendingFirstAcceptance?.relays ?? []
    let expiryStart: (() -> Void)?
    switch expiryUpdate {
    case .preserve, .clear: expiryStart = nil
    case .replace(let start): expiryStart = start
    }
    pendingFirstAcceptance = PendingFirstAcceptance(
      id: id, relays: relay.map { [$0] } ?? [], expiryStart: expiryStart,
      announcement: announcement)

    // The replacement is authoritative before arbitrary caller code runs.
    outgoing.forEach { $0.resolve(false) }
  }

  /// The render gate's readiness callback: bind whatever is currently pending
  /// to the just-built root, provided the presentation that pending state was
  /// FOR is still the one actually published.
  private func commitLatestFirstRender(_ root: NSView) {
    // **Take the slot before resolving anything it holds** — same reentrancy
    // reason as `coalescePendingFirstAcceptance` and `render`'s dismissal
    // branch: `resolve(false)` runs arbitrary caller code, which must see an
    // already-empty slot rather than one this function would otherwise
    // overwrite on return.
    guard let pending = pendingFirstAcceptance else { return }
    pendingFirstAcceptance = nil

    guard let presentation = model.state.presentation, pending.id == presentation.id else {
      // Either nothing is on screen any more, or the pending id and the
      // published one disagree — a presentation superseded while
      // construction was in flight. The replacement (if any) does its own
      // render through the now-ready gate; this stale slot only owes its
      // own callers `false`.
      pending.relays.forEach { $0.resolve(false) }
      return
    }
    _ = finishRender(
      presentation, root: root, relays: pending.relays,
      expiryStart: pending.expiryStart, announcement: pending.announcement)
  }

  /// Host acceptance, refusal rollback, expiry start, announcement and every
  /// retained relay's resolution — all in one place, so the queued path
  /// (`commitLatestFirstRender`) and the immediate path (`render`, once the
  /// gate is ready) run identically once a root view exists.
  @discardableResult
  private func finishRender(
    _ presentation: PillDefinition, root: NSView, relays: [PresentationRelay],
    expiryStart: (() -> Void)?, announcement: OverlayAnnouncement?
  ) -> RenderSubmission {
    if performRender(presentation, rootView: root) {
      expiryStart?()
      if let announcement { announce(announcement) }
      relays.forEach { $0.resolve(true) }
    } else {
      // **A REFUSED PRESENTATION MUST NOT LEAVE AN OWNER BEHIND.** Clearing
      // `presentedID` and the window says nothing to the reducer, the model,
      // the binding or the armed expiry, all of which still name an occupant
      // that is not on screen. Two consequences, both shipped defects rather
      // than theory: `currentIntent` reads `reducer.state.current`, so the
      // Bluetooth presenter's handshake confirms an invisible card and acts on
      // its buttons; and `pipelineIntent` still holds the refused intent, so
      // the dedup guard drops the RETRY as a repeat and the pill never
      // recovers once a screen comes back.
      //
      // Rolled back through the same silent-dismiss path a real dismissal
      // takes, so "nothing is on screen" has ONE definition rather than a
      // second, partial one written here. Silent because nothing appeared:
      // announcing a dismissal for a pill a VoiceOver user was never told
      // about is a false statement in the other direction.
      //
      // **Rollback FIRST, then the verdict.** The rollback dismisses through
      // `apply(.hidden)`, which renders nil, which SUCCEEDS — and it carries
      // no relay, so it cannot answer for the presentation it is undoing.
      // Resolving on a bare render outcome instead would report `true` for
      // the very pill the host had just refused.
      rollBackRefusedPresentation()
      relays.forEach { $0.resolve(false) }
    }
    return .completed
  }

  /// The synchronous half, so the deferred first call and every later one run
  /// exactly the same code rather than two copies that can drift.
  private func performRender(_ presentation: PillDefinition, rootView: NSView) -> Bool {
    // **`isFresh` means NOTHING IS SHOWING, not "a different occupant".** The
    // comment here used to say the opposite and the code matched it, which made
    // every recording -> processing -> warning step a fresh presentation: the
    // host recentred the panel and `beginFresh` dropped the `.user` anchor, so a
    // pill the user had dragged snapped back to centre the moment its content
    // changed. That is #2195 arriving through the identity gate, and this repo
    // already records the rule it breaks --
    // `pill-position-behavior.md` RULE: continuing-panel-vs-fresh-panel: an
    // inherited-frame transition is the SAME logical presentation, and
    // continuing state must never be reset as fresh or drag and setting changes
    // are erased.
    //
    // The reducer mints a new `PresentationID` for every occupant, so identity
    // could never express "is a pill already up". `presentedID == nil` can: it is
    // cleared by `render(nil)` on every hide and on a refused presentation, which
    // is exactly the shipped `inheritedFrame == nil` test in the new vocabulary.
    // **AND A RECORDING IS ALWAYS A NEW LIFECYCLE**, which `presentedID == nil`
    // alone does not say. The shipped `transitionToRecordingNow` re-anchored
    // explicitly and recorded why: a taller pill sitting lower — the #1480
    // Bluetooth card — hands its origin to the recording that replaces it and
    // drops the pill to MID-SCREEN. That was found by #1480's live UAT, not by
    // review, which is the kind of finding a reading does not produce.
    //
    // C12 fixed freshness-from-identity and introduced this in the same edit:
    // keying only on "nothing showing" made a recording that replaces a feature
    // pill a continuation of it. Found by reading the deleted file's recorded
    // lessons against the new module rather than by another review round.
    //
    // A CONTINUING recording is excluded by the id check: the reducer keeps one
    // identity across audio-level morphs, so a tick is not a new lifecycle and
    // must not re-anchor.
    let isFresh =
      presentedID == nil || (Self.isRecording(presentation) && presentedID != presentation.id)
    presentedID = presentation.id
    let recordingGeometry = geometry(for: presentation)
    // **One position per presentation, not two reads of a provider.** The
    // recording position was captured when the pill was composed; re-reading here
    // could compose against one edge and place against another.
    let anchor: OverlayPillPosition
    if case .recording = presentation.content {
      // Read from the frame ALREADY PUBLISHED for this presentation. `apply`
      // publishes before it renders, so the matching frame exists by now; a
      // mismatch means the host is being asked to place a pill nobody published.
      let frame = model.state
      guard frame.presentation?.id == presentation.id, let recording = frame.recording else {
        assertionFailure("the recording host has no matching published frame")
        return false
      }
      anchor = recording.position
    } else {
      anchor = position()
    }
    // #2377 Phase 6, C1 repair: DEBUG-only presentation-intent tagging around
    // the ONE call to `host.present`. The Host has no way to know why it was
    // asked to present — `OverlayWindowHosting` is deliberately minimal — but
    // this Director already classifies every presentation via `isRecording`
    // (the same call `isFresh` above uses). Setting the ambient intent here,
    // for the duration of this synchronous call, is what lets the marker the
    // Host emits inside `present` say which presentation it belongs to,
    // without widening the production seam to carry a measurement-only
    // concept. See `OverlayFirstRenderMarkers.withPresentationIntent`.
    #if DEBUG
      let presented = OverlayFirstRenderMarkers.withPresentationIntent(
        Self.isRecording(presentation) ? .recording : .other
      ) {
        host.present(
          rootView,
          width: recordingGeometry.width,
          fixedHeight: recordingGeometry.fixedHeight,
          isFresh: isFresh,
          position: anchor)
      }
    #else
      let presented = host.present(
        rootView,
        width: recordingGeometry.width,
        fixedHeight: recordingGeometry.fixedHeight,
        isFresh: isFresh,
        position: anchor)
    #endif
    if !presented {
      // The host refused — no screen, or a presentation it could not size — and
      // it returns BEFORE touching the panel, so a window that was already up
      // stays up. The model has already published the new occupant by now, so
      // leaving it would show the NEW content in the OUTGOING pill's frame.
      // Clear the claim AND take the window down.
      presentedID = nil
      host.hide()
      return false
    }
    return true
  }

  // **The eight `*ForTesting` hatches were DELETED** (#2292 C6), and with them
  // the director suite's `#if DEBUG` wrapper — which existed only because those
  // accessors did, and which kept 39 cases out of the Release lane.
  //
  // Each read became the observation it was standing in for: what is drawn
  // (`renderModel`), whether a request was accepted (the receipt), whether it
  // still owns the slot (`isCurrent`), what the host was ASKED for (the fake
  // host's own record), or a reducer claim asserted in `OverlayReducerTests`.
  //
  // Two of them had no user-visible consequence at all and their cases now
  // assert the effect instead: a binding that outlives its pill shows up as a
  // callback firing for a pill nobody can see, and a payload that outlives its
  // offer shows up as Undo restoring a finished dictation.
}

// MARK: - The typed façade (#2292 Phase 1, chunk C1)

/// The final caller-facing surface, implemented by translating each typed
/// request into the transaction that already runs.
///
/// **Nothing in production calls this yet, and that is the chunk boundary rather
/// than an oversight.** C1 is a semantic no-op port: the façade exists and its
/// parity tests exercise it, while the old ingress stays the sole production
/// path. C3 and C4 bring the first real callers; C5 migrates the rest and
/// deletes the old ingress. A temporary production caller here would be a
/// forwarding shim, which is precisely what this refactor refuses to ship.
///
/// It lives in this file rather than beside the protocol because every method
/// reads the director's private state, and file-scoped `private` is what keeps
/// that state private instead of widening it for a translation layer.
extension OverlayDirector: OverlayPresenting {

  var featureSlotIsAvailable: Bool { reducer.state.featureSlotIsAvailable }

  @discardableResult
  func present(
    _ request: PillRequest,
    onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt? {
    // Captured synchronously. `firstRenderSchedule` hands its block to
    // `DispatchQueue.main.async`, so it cannot run until this call stack
    // unwinds — the branches below are reached with the receipt already in hand
    // rather than racing it.
    var synchronousOutcome: Bool?
    let relay = PresentationRelay { synchronousOutcome = $0 }

    guard let receipt = admit(request, relay: relay) else {
      // **A REFUSED REQUEST ANSWERS FOR ITSELF AND FOR NOTHING ELSE.** Nothing
      // was handed to the host and nothing was superseded, so a presentation
      // already waiting for its run loop still renders and still reports through
      // its own relay. Answering on its behalf here is what put a Bluetooth card
      // on screen with buttons its presenter had never recorded a target for.
      relay.disarm()
      onResult(.notPresented)
      return nil
    }

    if let synchronousOutcome {
      onResult(synchronousOutcome ? .presented(receipt) : .notPresented)
      return receipt
    }

    if relay.isDeferred {
      // The host has not been asked yet. Rebind to the real caller now that the
      // receipt exists; the deferred block holding this relay delivers the
      // verdict on whichever of its three terminals it reaches.
      relay.redirect(to: { presented in
        onResult(presented ? .presented(receipt) : .notPresented)
      })
      return receipt
    }

    // Nothing rendered and nothing deferred: the plan changed nothing, which
    // means the pill this receipt names is already on screen. That IS presented.
    relay.disarm()
    onResult(.presented(receipt))
    return receipt
  }

  @discardableResult
  func present(_ request: PillRequest) -> PillReceipt? {
    // No relay: this form owns no result. A caller waiting on a deferred verdict
    // is answered by that deferral's own block, which reports `.notPresented`
    // through its identity gate if this request supersedes it.
    admit(request, relay: nil)
  }

  private func admit(_ request: PillRequest, relay: PresentationRelay?) -> PillReceipt? {
    // Captured BEFORE the request runs, so the guard at the end can tell an
    // accepted presentation from an unchanged slot.
    let incumbentID = reducer.state.current?.id
    switch request {
    case .recording(let input):
      presentRecording(
        audioLevel: input.audioLevel,
        audioLevelProvider: input.audioLevelProvider,
        recordingElapsedProvider: input.recordingElapsedProvider,
        isRecordingLocked: input.isLocked,
        relay: relay)
    case .processing(let phase):
      handle(.pipeline(.processing(phase: phase)), binding: .none, relay: relay)
    case .clipboardFallback:
      handle(.pipeline(.clipboardFallback), binding: .none, relay: relay)
    case .warning(let reason):
      handle(.pipeline(.warning(reason: reason)), binding: .none, relay: relay)
    case .error(let reason):
      handle(.pipeline(.error(reason: reason)), binding: .none, relay: relay)
    case .advisory(let reason):
      handle(.pipeline(.advisory(reason: reason)), binding: .none, relay: relay)
    case .interruption(let reason):
      handle(.pipeline(.interruption(reason: reason)), binding: .none, relay: relay)
    case .cachingModel(let engineLabel):
      handle(.pipeline(.cachingModel(engineLabel: engineLabel)), binding: .none, relay: relay)
    case .engineReady:
      handle(.pipeline(.engineReady), binding: .none, relay: relay)
    case .recoverySucceeded:
      handle(.pipeline(.recoverySucceeded), binding: .none, relay: relay)
    case .importStatus(let message):
      handle(.importStatus(message: message), binding: .none, relay: relay)

    case .accessibilityNotice:
      presentAccessibilityNotice(relay: relay)
    // **Discard, THEN dismiss, and the order is the shipped one.** The router this
    // replaces ran `recovery?.discardActiveRecovery()` followed by
    // `overlay?.dismissSilently()`; calling the owner and leaving the notice on
    // screen is a pill the user already answered.
    case .recoveryNotice(let onDiscard):
      handle(
        .pipeline(.recoveringLastRecording),
        binding: .install(
          deliver: { [weak self] action in
            guard case .discardRecovery = action else { return }
            onDiscard()
            self?.dismissSilently()
          },
          onExpire: nil),
        relay: relay)
    // **The chip travels as a PIPELINE intent, and the Bluetooth card does not.**
    // The shipped path routes the chip through the pipeline, so it sets
    // `pipelineIntent` and arbitrates against the pipeline the way the presenter
    // expects; the card is a feature and leaves `pipelineIntent` alone.
    //
    // Until C5c both spellings existed — `OverlayIntent` and a separate
    // `OverlayRequest` each declared `passiveChip` and `bluetoothAwareness`, and
    // sending either through the other enum COMPILED. That is why the type is
    // gone: one vocabulary means there is no wrong enum to send through.
    case .languageChip(let payload, let onLock, let onDismiss, let onExpire):
      // **Admission lives HERE, beside the state change** (#2292 C3). It used
      // to live in the presenter, which read the current intent and compared
      // it — one decision with two authorities, and only this one reports
      // actual acceptance. A refusal returns nil below and the presenter
      // commits nothing.
      guard featureSlotIsAvailable else { return nil }
      // **Expiry rides the same binding as the buttons, and arrives in the
      // same call** (#2292 C5c). It was previously assigned after the fact,
      // because the binding did not exist until the event had been sent — a
      // window in which the chip was on screen with an owner for its buttons
      // and none for its expiry. Expiry is not an action (nobody pressed
      // anything), so it cannot travel through `deliver`; it is a second slot
      // on the same binding and dies with the same presentation.
      handle(
        .pipeline(.passiveChip(payload: payload)),
        binding: .install(
          deliver: { action in
            switch action {
            case .lockLanguage: onLock()
            case .dismissChip: onDismiss()
            default: break
            }
          },
          onExpire: onExpire),
        relay: relay)
    case .bluetoothAwareness(let onAcknowledge, let onClose, let onOpenSettings):
      // Same admission transaction as `.languageChip` above. C3b moves the
      // Bluetooth presenter onto the receipt; the guard belongs here from the
      // moment either feature uses it, so the two cannot drift.
      guard featureSlotIsAvailable else { return nil }
      handle(
        .bluetoothAwareness,
        binding: .install(
          deliver: { action in
            switch action {
            case .acknowledgeBluetoothAwareness: onAcknowledge()
            case .closeBluetoothAwareness: onClose()
            case .openBluetoothSettings: onOpenSettings()
            default: break
            }
          },
          onExpire: nil),
        relay: relay)
    // **Take, DISMISS, then forward — matching the shipped order.**
    // `EscapeRecoveryWiring` dismisses before pasting for ONE stated reason: a
    // spoken "overlay hidden" arriving after the restore is noise on top of the
    // outcome the user asked for. That is a real VoiceOver experience, not a
    // theoretical one.
    //
    // No second reason is claimed. `EscapeRecoveryWiring.pasteAction` copies to
    // the clipboard and dispatches a keystroke; it raises no pill, so "a pill
    // raised by onPaste would be destroyed by a later dismissal" describes
    // nothing this code does today.
    //
    // The take comes first so a stale press finds nothing and neither dismisses
    // nor pastes.
    case .escapeRecovery(let payload, let onPaste):
      // **Custody lives HERE now, and nowhere else** (#2292 C4a). It used to be
      // reachable through two public doors — `presentEscapeRecovery` and
      // `takeEscapeRecoveryPayload` — with the take performed by a wiring
      // helper outside the director. Both are deleted: the payload is stored by
      // the only call that can put a pill on screen, and taken by the only
      // binding that pill can raise.
      escapeRecoveryPayload = (id: payload.transcriptID, payload: payload)
      handle(
        .pipeline(.escapeRecovery(transcriptID: payload.transcriptID)),
        binding: .install(
          deliver: { [weak self] action in
            guard case .pasteEscapeRecovery(let transcriptID) = action,
              let self,
              let held = self.escapeRecoveryPayload,
              held.id == transcriptID
            else { return }
            // Take, DISMISS, then forward — the shipped order, and the
            // dismissal is load-bearing for a VoiceOver user: a spoken "overlay
            // hidden" arriving after the restore is noise on top of the outcome
            // they asked for.
            self.escapeRecoveryPayload = nil
            self.dismissSilently()
            onPaste(held.payload)
          },
          onExpire: nil),
        relay: relay)
    }

    // **A refused request returns nil, not the incumbent's receipt.** The slot
    // holds ONE presentation, so after a refusal `reducer.state.current` is
    // whatever was already there — and handing that back tells the caller its
    // request was accepted while naming a pill it does not own. A feature owner
    // would then believe `isCurrent` about someone else's presentation and
    // dismiss it.
    //
    // Recording is the exception and it is not a refusal: a recording morph
    // keeps the identity it was created with, so the incumbent id IS the id this
    // request now owns.
    //
    // **BUT THE EXCEPTION IS ABOUT A MORPH, AND THE ID ALONE CANNOT TELL A MORPH
    // FROM A REQUEST THAT NEVER COMMITTED.** Three recording paths reach here
    // having installed nothing: a refusal because a feature holds the slot, a
    // discard because a newer event won between PREPARE and COMMIT, and the
    // catalog returning no definition. On all three the occupant is somebody
    // else's pill, so an unconditional receipt hands the recording caller an
    // error or a Bluetooth card to call `isCurrent` about and dismiss — which is
    // the exact harm the paragraph above describes, arriving through the one
    // branch written to skip it.
    //
    // Ask what the slot HOLDS rather than which request asked. A morph and a
    // fresh commit both leave a recording current; nothing that failed to commit
    // does.
    guard let current = reducer.state.current else { return nil }
    if case .recording = request {
      guard case .recording = current.content else { return nil }
      return PillReceipt(presentationID: current.id)
    }
    guard current.id != incumbentID else { return nil }
    return PillReceipt(presentationID: current.id)
  }

  func update(_ update: PillUpdate) {
    switch update {
    case .recordingLock(let isLocked):
      handle(.lockStateChanged(isLocked), binding: .none)
    case .inPanelNotice(let reason, let dismissAfter):
      handle(.inPanelNotice(reason, dismissAfter: dismissAfter), binding: .none)
    }
  }

  func dismissCurrent(_ mode: PillDismissal) {
    switch mode {
    case .announced: handle(.pipeline(.hidden), binding: .none)
    case .silent: dismissSilently()
    }
  }

  func dismissIfCurrent(_ receipt: PillReceipt) {
    guard isCurrent(receipt) else { return }
    dismissCurrent(.silent)
  }

  func isCurrent(_ receipt: PillReceipt) -> Bool {
    reducer.state.current?.id == receipt.presentationID
  }
}
