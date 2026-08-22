import AppKit
import SwiftUI
import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

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
  private let schedule: OverlayScheduler

  /// The ONE armed expiry. Replacing it cancels whatever was armed, which is
  /// what makes a stale dismissal structurally impossible rather than merely
  /// guarded against.
  private var armedExpiry: OverlayScheduledWork?

  /// The ONE active action binding. The shipped panel keeps eight `set*Handler`
  /// closures alive for the app's lifetime whether or not the pill that uses
  /// them is showing; this holds the binding for the presentation that is
  /// actually on screen and drops it when that presentation goes.
  private var activeBinding: (id: PresentationID, deliver: (OverlayAction) -> Void)?

  /// Custody of the cancelled-transcript payload.
  ///
  /// **The director owns it, not the action.** `.pasteEscapeRecovery` carries
  /// the transcript ID as a LOOKUP KEY; the payload itself is held here and
  /// taken once. A one-shot take is what makes a stale Undo press safe — the
  /// second press finds nothing rather than pasting twice.
  private var escapeRecoveryPayload: (id: UUID, payload: CancelUndoPayload)?

  /// Required, immutable, and injected. It was a settable `var` for one round —
  /// one more mutable handler field on the type whose whole purpose is to have
  /// fewer, and one where a caller that forgot to wire it would silently discard
  /// effects a feature depends on.
  private let deliverEffect: (OverlayEffect) -> Void

  /// The handler for the two buttons that belong to the APP rather than to a
  /// presentation — Grant and Discard.
  ///
  /// **Required, with no default, and my argument for a default was wrong on the
  /// facts.** I claimed sixteen test constructions would need editing; there are
  /// THREE — one shared headless factory and two retained-window cases — because
  /// the rest go through that factory. A no-op default is a fresh structural
  /// omission path introduced by the fix for an omission, which is not a trade
  /// worth making for three lines.
  private let deliverAppAction: (OverlayAction) -> Void

  /// Posting the spoken announcement, injectable so a guard can observe it.
  ///
  /// `NSAccessibility.post` writes to the system and returns nothing, so without
  /// a seam the only assertion available is "the code that would have posted was
  /// reached" — which is the marker-beside-the-subject defect this repo already
  /// ranks. The default IS the real post, so a caller that forgets it still
  /// announces.
  private let announce: @MainActor (OverlayAnnouncement) -> Void

  /// **ONE hosting view for THIS DIRECTOR's lifetime**, created lazily and
  /// reused. The model is observable, so the same view re-renders rather than
  /// being rebuilt — the SwiftUI half of the same claim the retained `NSPanel`
  /// makes about the window. "For the app's lifetime" is a property of the
  /// COMPOSITION ROOT holding the director, not something this file can promise.
  ///
  /// The view sends whole events and supplies the presentation's own ID; this
  /// closure no longer looks one up. It used to read `reducer.state.current?.id`
  /// at press time, which relabels a click on an outgoing pill with its
  /// SUCCESSOR's identity — so the staleness check below passes it through and
  /// the wrong pill's handler runs.
  private lazy var rootHostingView: NSView = NSHostingView(
    rootView: OverlayRootView(
      model: model,
      sendEvent: { [weak self] event in self?.send(event, actions: nil) }))

  /// The occupant the host is currently showing, so a morph can be told from a
  /// fresh presentation. The host needs that distinction to decide whether to
  /// re-anchor or preserve the live frame, and it is the CALLER's fact.
  private var presentedID: PresentationID?

  private let position: () -> OverlayPillPosition

  /// The once-per-session accessibility-toast policy.
  ///
  /// **Owned HERE, not by the caller.** Threading it through
  /// `DictationLifecycleCoordinator` put that type at 12 collaborators against a
  /// ceiling of 11 — a ceiling whose purpose is exactly to catch a coordinator
  /// accumulating other people's policies. The decision is about PRESENTING.
  private let accessibilityEligibility: OverlayAccessibilityEligibility

  /// Live Preview's two APP-LIFETIME providers.
  ///
  /// **Installed once, not passed per call, and the lifetimes are why.** The
  /// shipped panel already draws this line: `setLivePreviewProviders` is called
  /// ONCE from `LivePreviewInstaller` at boot, while the audio level and elapsed
  /// providers arrive with every `show`. One pair belongs to the app, the other
  /// to a dictation.
  ///
  /// Atomicity is untouched: `presentRecording` still RESOLVES the layout by
  /// calling `livePreviewEnabled()` at present time, so the geometry comes from
  /// the setting at the moment the pill appears rather than from whenever these
  /// were installed. That was the property the layout value exists to hold, and
  /// it is a property of WHEN the closure is called, not of how it arrived.
  ///
  /// The defaults are the OFF answers, so a composition root that forgets the
  /// installer gets the ordinary pill rather than a crash — which is what the
  /// shipped panel does too. `LivePreviewInstaller` is the only caller.
  private var livePreviewEnabled: () -> Bool = { false }
  private var livePreviewDisplay: () -> LivePreviewDisplay = { .off }

  func setLivePreviewProviders(
    enabled: @escaping () -> Bool, display: @escaping () -> LivePreviewDisplay
  ) {
    livePreviewEnabled = enabled
    livePreviewDisplay = display
  }

  init(
    host: any OverlayWindowHosting,
    deliverEffect: @escaping (OverlayEffect) -> Void,
    deliverAppAction: @escaping (OverlayAction) -> Void,
    position: @escaping () -> OverlayPillPosition = { .top },
    model: OverlayRenderModel = OverlayRenderModel(),
    scheduler: OverlayScheduler = .live,
    announce: @escaping @MainActor (OverlayAnnouncement) -> Void = OverlayDirector.postAnnouncement,
    accessibilityEligibility: OverlayAccessibilityEligibility = .init(warningDismissed: { false }),
    makeID: @escaping () -> PresentationID = { PresentationID() }
  ) {
    self.host = host
    self.deliverEffect = deliverEffect
    self.deliverAppAction = deliverAppAction
    self.announce = announce
    self.accessibilityEligibility = accessibilityEligibility
    self.position = position
    self.model = model
    self.schedule = scheduler
    self.reducer = OverlayReducer(makeID: makeID)
  }

  var renderModel: OverlayRenderModel { model }

  /// The last pipeline intent, for the two features that arbitrate against it.
  ///
  /// **Not what is DRAWN, and the difference is deliberate.** A suppressed
  /// accessibility toast draws the clipboard hint while this stays
  /// `.accessibilityToast`, exactly as the shipped `currentIntent` does —
  /// `showClipboardFallback()` never wrote to it either.
  ///
  /// `LanguageSuggestionPresenter` asks only whether it is `.hidden` and
  /// `BluetoothAwarenessPresenter` only whether it is `.bluetoothAwareness`, so
  /// neither can tell those two apart in any case. Both take it as a closure, so
  /// neither changes at the cutover; only the closure bodies do.
  var currentIntent: OverlayIntent {
    // **A feature that OCCUPIES the slot has to say so.** `BluetoothAwareness`
    // is a `.featureRequest`, so it never touches `pipelineIntent` — and
    // `BluetoothAwarenessPresenter` confirms its own card by asking this for
    // `.bluetoothAwareness` before it will act on any of its buttons. Returning
    // the bare pipeline intent left that handshake permanently failing and every
    // button on the card a no-op, with nothing failing anywhere.
    if case .bluetoothAwareness? = reducer.state.current?.content {
      return .bluetoothAwareness
    }
    return reducer.state.pipelineIntent
  }

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

  /// `actions` is the handler for the presentation this event PRODUCES, and it
  /// arrives with the request rather than after it.
  ///
  /// A separate `bind(for:)` call made binding a post-publication operation: the
  /// caller had to bind after the presentation existed, an ordering nothing
  /// enforced, and a window in which the pill was on screen with no handler. A
  /// request carries its own handler or it has none by construction.
  /// **No default.** `actions` defaulting to nil let a call site that SHOULD
  /// carry a handler compile silently without one, which defeats the entire
  /// point of making the binding arrive with the request: the omission has to be
  /// visible at the call site, not inferred from its absence.
  func send(_ event: OverlayEvent, actions: ((OverlayAction) -> Void)?) {
    if case .pipeline(.recording) = event {
      // **The wrong ORDER is what this refuses, not the wrong event.** A caller
      // that sends first and installs providers afterwards renders one frame
      // from whatever the model last held — the previous dictation's layout, or
      // the `.compact(.top)` default on the first recording of the session — and
      // a later mutation of the model is not published, so the wrong frame is
      // also the final one.
      //
      // `assertionFailure` rather than a precondition: this is a programming
      // invariant, caught in Debug and in CI, and trapping a user's Release build
      // over a first-frame defect is worse than the defect.
      //
      // **In Release this does NOT refuse.** `assertionFailure` compiles away and
      // the call falls through to render with the layout the model already holds
      // — correct for a morph, stale-but-plausible for a fresh recording. The
      // step-4 caller sweep must therefore leave no such call; the assertion
      // catches one during development, it does not defend against one shipping.
      assertionFailure(
        "use presentRecording(...) — a recording's providers and layout must be "
          + "installed in the same operation that presents it")
    }
    apply(reducer.reduce(event), actions: actions)
  }

  /// Present the recording pill with its providers and its layout installed in
  /// ONE operation.
  ///
  /// **Five things travel together and the shipped code installs them together.**
  /// See `OverlayRecordingLayout`. Splitting them across `setRecordingProviders`
  /// and `send` made a wrong first frame expressible, so this is the only way to
  /// express the right one.
  ///
  /// A MORPH keeps the layout it was created with. The shipped panel reads the
  /// preview setting once at creation and its width is fixed for that panel's
  /// life, because an `NSPanel` cannot grow mid-recording without a rebuild and a
  /// rebuild is the #930 flicker. Re-resolving here on every audio tick would
  /// resize a live pill the moment the user changed the setting.
  func presentRecording(
    audioLevel: Float,
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval?,
    isRecordingLocked: Bool,
    actions: ((OverlayAction) -> Void)?
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
    let plan = reducer.reduce(.pipeline(.recording(audioLevel: audioLevel)))

    // **The effect goes out BEFORE the layout is resolved, not merely before the
    // render.** Moving effects to the top of `apply` was half the fix: this
    // method reads `livePreviewEnabled()` on its way to a layout, and that read
    // happens before `apply` is ever called. `LivePreviewCoordinator` applies its
    // model-removal suppression inside `setRecording`, so a geometry read that
    // beats the effect can pick the 400-point preview layout for a pill whose
    // preview is about to resolve DISABLED — a preview-sized window with no
    // preview in it.
    for effect in plan.effects {
      deliverEffect(effect)
    }

    guard let presentation = plan.presentation else {
      // The reducer refused — a feature holds the slot, or nothing changed.
      apply(plan, actions: actions, effectsAlreadyDelivered: true)
      return
    }

    let layout: OverlayRecordingLayout
    if presentedID == presentation.id {
      layout = model.recordingLayout
    } else {
      let at = position()
      layout = livePreviewEnabled() ? .preview(position: at) : .compact(position: at)
      // Read HERE, at present time — see `livePreviewEnabled`'s note.
    }

    model.setRecordingProviders(
      audioLevel: audioLevelProvider,
      recordingElapsed: recordingElapsedProvider,
      livePreview: livePreviewDisplay,
      layout: layout,
      onContentHeightChange: { [weak self] height in
        // The preview pill grows a line at a time as words wrap. Keyed to the
        // presentation it was installed for, so a late callback from a finished
        // dictation cannot resize the pill that replaced it.
        guard let self, self.presentedID == presentation.id,
          self.model.recordingLayout.usesPreview
        else { return }
        self.host.resizeCurrentPresentation(
          to: CGSize(width: self.model.recordingLayout.width, height: height))
      })

    apply(plan, actions: actions, effectsAlreadyDelivered: true)
  }

  /// Take custody of a cancelled-transcript payload and present its pill.
  ///
  /// The id comes from the PAYLOAD. An earlier signature took it separately, so
  /// two ids could disagree and the pill would offer to restore a transcript the
  /// custody did not hold — an unrepresentable state made representable by an
  /// extra parameter.
  /// **Takes its handler.** Without one this method presented a pill whose Undo
  /// button had nothing bound, so the first press hit the invariant assertion —
  /// I broke Undo outright with the change that made binding atomic, and the
  /// suite could not see it because no test pressed the button on a pill
  /// presented through this entry point.
  func presentEscapeRecovery(
    _ payload: CancelUndoPayload, actions: @escaping (OverlayAction) -> Void
  ) {
    escapeRecoveryPayload = (id: payload.transcriptID, payload: payload)
    send(.pipeline(.escapeRecovery(transcriptID: payload.transcriptID)), actions: actions)
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
  func presentAccessibilityNotice() {
    apply(
      reducer.reduceAccessibilityNotice(showingToast: { [accessibilityEligibility] in
        accessibilityEligibility.claim()
      }), actions: deliverAppAction)
  }

  /// The crash-recovery notice, which offers Discard.
  ///
  /// A named method rather than a bare `send`, for the same reason
  /// `presentAccessibilityNotice` is one: its button's handler belongs to the app
  /// and no call site has it. `RecordingStarter` raises this notice and knows
  /// nothing about the recovery coordinator.
  func presentRecoveryNotice() {
    send(.pipeline(.recoveringLastRecording), actions: deliverAppAction)
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
  func dismissSilently() {
    apply(reducer.reduce(.pipeline(.hidden)), actions: nil, announcing: false)
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
    apply(reducer.reduce(.pipeline(.hidden)), actions: nil, announcing: false)
  }

  /// Take the payload for `transcriptID`, once. Returns nil if it was already
  /// taken or if a different transcript now owns the slot.
  func takeEscapeRecoveryPayload(matching transcriptID: UUID) -> CancelUndoPayload? {
    guard let held = escapeRecoveryPayload, held.id == transcriptID else { return nil }
    escapeRecoveryPayload = nil
    return held.payload
  }

  // MARK: - Applying a plan

  private func apply(
    _ plan: OverlayPlan, actions: ((OverlayAction) -> Void)? = nil, announcing: Bool = true,
    effectsAlreadyDelivered: Bool = false
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
        deliverEffect(effect)
      }
    }
    switch plan.expiryCommand {
    case .unchanged:
      break
    case .cancel:
      armedExpiry?.cancel()
      armedExpiry = nil
    case .arm(let id, let seconds, let target):
      armedExpiry?.cancel()
      armedExpiry = schedule.after(seconds) { [weak self] in
        // The id is captured, never re-read: a timer fires for the presentation
        // it was armed for or it is dropped. The reducer's own identity gate
        // makes a late arrival inert. The TARGET says what ends — the whole
        // presentation, or only the #1060 banner inside a live recording.
        switch target {
        case .presentation: self?.send(.expiryFired(id), actions: nil)
        case .inPanelNotice: self?.send(.inPanelNoticeExpiryFired(id), actions: nil)
        }
      }
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
      // **A MORPH KEEPS ITS BINDING.** The first version replaced the binding
      // with whatever this call carried, so any same-id update with no handler —
      // an audio-level tick, which arrives many times a second — silently
      // dropped the live pill's buttons. Only a CHANGE OF IDENTITY clears it.
      if let presentation = plan.presentation {
        if let actions {
          activeBinding = (id: presentation.id, deliver: actions)
        } else if activeBinding?.id != presentation.id {
          activeBinding = nil
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

      model.presentation = plan.presentation
      if !render(plan.presentation) {
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
        rollBackRefusedPresentation()
        // Nothing this plan installed survives, so an action addressed to it has
        // no target. Delivering it would hit the assertion below on a state the
        // rollback deliberately emptied.
        return
      }
    }

    // **Announced AFTER the window has taken the presentation, and the move is
    // the point.** The shipped panel posts at the top of each `apply(intent:)`
    // arm and draws after, which this deliberately no longer mirrors: that order
    // makes the announcement unconditional, so a presentation the host REFUSES
    // is still spoken. A VoiceOver user is then told a card appeared that is not
    // there, and told it in the one situation where they have no other way to
    // find out — the refusal is silent by design everywhere else.
    //
    // Reaching this line means the window accepted the plan, or the plan emptied
    // the slot, which always succeeds. A refusal returns above and never arrives.
    //
    // The EFFECT ordering that was load-bearing is untouched: effects still run
    // first, before the geometry read, which is the constraint Live Preview's
    // first frame actually depends on. Nothing depended on announcing before the
    // draw; a screen reader is not racing the window server.
    if announcing, let announcement = plan.announcement {
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
    for presentation: OverlayPresentation
  ) -> (width: OverlayWidth, fixedHeight: CGFloat?) {
    guard case .recording = presentation.content else {
      return (presentation.requestedWidth, presentation.reservesFixedHeight)
    }
    // **BOTH axes come from the layout, and the width is the one that is easy to
    // miss.** The shipped site reads `showsPreview ? previewPillWidth : 185` —
    // 400 against 185 — before it picks the sizing branch, so carrying only the
    // height still renders a preview pill at under half its intended width. The
    // reducer's own 185/92 is the compact answer and is deliberately ignored
    // here: the reducer cannot know which layout is in force.
    let layout = model.recordingLayout
    return (.fixed(layout.width), layout.fixedHeight)
  }

  /// Push the model's new occupant to the window.
  ///
  /// **The model is set BEFORE this runs**, so the retained root has already
  /// rendered the new content by the time the host measures it — a host that
  /// measured first would size the window to the OUTGOING pill.
  ///
  /// Returns `false` ONLY when the host refused a presentation it was asked to
  /// show. Emptying the slot always succeeds, so the caller reads a `false` as
  /// "the occupant this plan installed is not on screen and never will be".
  @discardableResult
  private func render(_ presentation: OverlayPresentation?) -> Bool {
    guard let presentation else {
      presentedID = nil
      host.hide()
      return true
    }
    // `isFresh` is a change of OCCUPANT, not the absence of a window: a morph
    // keeps the live frame, a genuinely new presentation re-anchors.
    let isFresh = presentedID != presentation.id
    presentedID = presentation.id
    let recordingGeometry = geometry(for: presentation)
    // **One position per presentation, not two reads of a provider.** The
    // recording layout captured the anchored edge when the pill was composed;
    // re-reading here lets a setting changed in between compose against one edge
    // and place against another, which is the same assembled-from-two-instants
    // defect the layout value exists to close.
    let anchor: OverlayPillPosition
    if case .recording = presentation.content {
      anchor = model.recordingLayout.position
    } else {
      anchor = position()
    }
    let presented = host.present(
      rootHostingView,
      width: recordingGeometry.width,
      fixedHeight: recordingGeometry.fixedHeight,
      isFresh: isFresh,
      position: anchor)
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

  #if DEBUG
    var presentedIDForTesting: PresentationID? { presentedID }
    var currentPresentationForTesting: OverlayPresentation? { reducer.state.current }
    var hasArmedExpiryForTesting: Bool { armedExpiry != nil }
    var hasActiveBindingForTesting: Bool { activeBinding != nil }
    var holdsEscapeRecoveryPayloadForTesting: Bool { escapeRecoveryPayload != nil }
    /// The window the director renders through, so a test can assert on the
    /// FRAME rather than on the argument it passed — the argument is the thing
    /// under test.
    ///
    /// Optional because the director now takes any `OverlayWindowHosting`: a
    /// test driving the windowless fake has no frame to assert on, and saying so
    /// in the type is better than a fake that answers with a plausible one.
    var hostForTesting: OverlayWindowHost? { host as? OverlayWindowHost }
    /// The LOGICAL intent, which is not always what is drawn: a suppressed
    /// accessibility toast draws the clipboard fallback and the intent stays
    /// `.accessibilityToast`.
    var pipelineIntentForTesting: OverlayIntent { reducer.state.pipelineIntent }
    /// The hands-free lock, which OUTLIVES any one presentation — so it is read
    /// from the reducer's state rather than from whatever is on screen.
    var isRecordingLockedForTesting: Bool { reducer.state.isLocked }
  #endif
}

/// A piece of scheduled work that can be cancelled.
///
/// A seam rather than a raw `Task` or `DispatchWorkItem` so a test can fire the
/// expiry deterministically. `testing-philosophy.md`
/// RULE: never-guess-when-the-subject-is-finished forbids waiting on a clock;
/// with this, a test does not wait at all — it fires the timer itself.
@MainActor
final class OverlayScheduledWork {
  private var cancelled = false
  private let body: () -> Void

  init(body: @escaping () -> Void) { self.body = body }

  func cancel() { cancelled = true }
  func fireForTesting() {
    guard !cancelled else { return }
    body()
  }
  var isCancelled: Bool { cancelled }
}

/// How the director arms its single expiry.
@MainActor
struct OverlayScheduler {
  let after: (Double, @escaping () -> Void) -> OverlayScheduledWork

  static let live = OverlayScheduler { seconds, body in
    let work = OverlayScheduledWork(body: body)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak work] in
      guard let work, !work.isCancelled else { return }
      body()
    }
    return work
  }

  /// Arms nothing. The test fires the returned handle itself, so no interval
  /// exists anywhere in the assertion.
  static func manual(_ armed: @escaping (OverlayScheduledWork) -> Void) -> OverlayScheduler {
    OverlayScheduler { _, body in
      let work = OverlayScheduledWork(body: body)
      armed(work)
      return work
    }
  }
}
