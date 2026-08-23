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
  /// **Built on first use, and whether it HAS been built is load-bearing** —
  /// which a `lazy var` cannot report, so the storage is explicit.
  ///
  /// Constructing this during the status-item menu dismiss animation is the
  /// SIGABRT `deferFirstRender` exists to avoid, so "is it built yet" is the
  /// exact condition the deferral keys on. A boolean set when a deferral was
  /// SCHEDULED is a different fact and was wrong twice over: a second event
  /// arriving before the queued block ran saw the flag already true and
  /// constructed synchronously, and a deferred request dropped by its identity
  /// gate left the flag true with nothing built, so the next presentation did
  /// the same. Cloud review caught both in one finding.
  private var builtRootView: NSView?

  private var rootHostingView: NSView {
    if let builtRootView { return builtRootView }
    let view = NSHostingView(
      rootView: OverlayRootView(
        model: model,
        sendEvent: { [weak self] event in self?.handle(event, binding: .none) }))
    builtRootView = view
    return view
  }

  /// The occupant the host is currently showing, so a morph can be told from a
  /// fresh presentation. The host needs that distinction to decide whether to
  /// re-anchor or preserve the live frame, and it is the CALLER's fact.
  private var presentedID: PresentationID?

  /// How the FIRST render reaches the next run loop.
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
  private let deferFirstRender: (@escaping () -> Void) -> Void

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
  /// `presentRecording` still RESOLVES the layout by calling
  /// `livePreview.isEnabledForGeometry()` at present time, so the geometry comes
  /// from the setting at the moment the pill appears. That is a property of WHEN
  /// the closure is called.
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
    makeID: @escaping () -> PresentationID = { PresentationID() },
    deferFirstRender: @escaping (@escaping () -> Void) -> Void = { work in
      DispatchQueue.main.async(execute: work)
    }
  ) {
    self.deferFirstRender = deferFirstRender
    self.host = host
    self.announce = announce
    self.accessibilityEligibility = accessibilityEligibility
    self.livePreview = livePreview
    self.grantAccessibility = grantAccessibility
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
    // **Every occupant that arrives WITHOUT setting `pipelineIntent` must be
    // projected here, and the rule is that sentence rather than a list.** A
    // feature takes the slot through `reduceFeature`, which never touches the
    // pipeline intent, so anything reaching the slot that way reports `.hidden`
    // unless it is named below.
    //
    // Bluetooth was named at the cutover and the language chip was not, which is
    // the same omission twice: `LanguageSuggestionPresenter` guards
    // `case .hidden` before showing a chip, so with its own chip already up it
    // read the slot as free — it could stack a second chip, and
    // `resetAllChipState()` left a visible one behind.
    //
    // IMPORT STATUS IS DELIBERATELY ABSENT. It is the one request with no
    // matching `OverlayIntent`, and the shipped panel did not set `currentIntent`
    // for it either, so reporting `.hidden` while a status pill shows is the
    // behaviour being preserved rather than a third omission.
    switch reducer.state.current?.content {
    case .bluetoothAwareness: return .bluetoothAwareness
    case .languageChip(let payload): return .passiveChip(payload: payload)
    default: return reducer.state.pipelineIntent
    }
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

  private func handle(_ event: OverlayEvent, binding: BindingInput) {
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
    apply(reducer.reduce(event), binding: binding)
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
  /// **No binding parameter: a recording pill draws no buttons** (#2292 C5c), so
  /// there was never a handler to install. Private now — `present(.recording(_:))`
  /// is the only way in.
  private func presentRecording(
    audioLevel: Float,
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval?,
    isRecordingLocked: Bool
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
    // method reads `livePreview.isEnabledForGeometry()` on its way to a layout, and
    // happens before `apply` is ever called. `LivePreviewCoordinator` applies its
    // model-removal suppression inside `setRecording`, so a geometry read that
    // beats the effect can pick the 400-point preview layout for a pill whose
    // preview is about to resolve DISABLED — a preview-sized window with no
    // preview in it.
    for effect in plan.effects {
      route(effect)
    }

    guard let presentation = plan.presentation else {
      // The reducer refused — a feature holds the slot, or nothing changed.
      apply(plan, binding: .none, effectsAlreadyDelivered: true)
      return
    }

    let layout: OverlayRecordingLayout
    if presentedID == presentation.id {
      layout = model.recordingLayout
    } else {
      let at = position()
      layout = livePreview.isEnabledForGeometry() ? .preview(position: at) : .compact(position: at)
      // Read HERE, at present time — see the `livePreview` note.
    }

    model.setRecordingProviders(
      audioLevel: audioLevelProvider,
      recordingElapsed: recordingElapsedProvider,
      livePreview: livePreview.display,
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

    apply(plan, binding: .none, effectsAlreadyDelivered: true)
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
  private func presentAccessibilityNotice() {
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
        }, onExpire: nil))
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
        route(effect)
      }
    }
    // **A DWELL STARTS WHEN THE PILL IS VISIBLE, NOT WHEN THE PLAN IS APPLIED.**
    // The shipped panel armed its auto-dismiss INSIDE the deferred creation,
    // after `showPanel`; arming here instead spends part of a transient pill's
    // dwell before anything is on screen. With the first render deferred a run
    // loop that is small, and it is not nothing: Escape Recovery draws a
    // COUNTDOWN RAIL from the same dwell, so a clock that starts early finishes
    // early and the rail disagrees with the pill it is drawn on.
    //
    // **Cancelling stays immediate.** A cancel is about the OUTGOING pill, which
    // is already gone; making it wait for the incoming one to land would leave a
    // dead timer live across the gap — the stale-dismissal defect `PresentationID`
    // exists to close.
    let armExpiry: () -> Void
    switch plan.expiryCommand {
    case .unchanged:
      armExpiry = {}
    case .cancel:
      armedExpiry?.cancel()
      armedExpiry = nil
      model.markDwellStarted(nil)
      armExpiry = {}
    case .arm(let id, let seconds, let target):
      armedExpiry?.cancel()
      armedExpiry = nil
      armExpiry = { [weak self] in
        guard let self else { return }
        // The picture and the timer start together. Published here rather than
        // beside `model.presentation` because THIS is the instant the dwell
        // begins, and a view drawing a countdown has no other way to know it.
        self.model.markDwellStarted(
          OverlayDwellWindow(id: id, startedAt: Date(), seconds: seconds))
        self.armedExpiry = self.schedule.after(seconds) { [weak self] in
          // The id is captured, never re-read: a timer fires for the presentation
          // it was armed for or it is dropped. The reducer's own identity gate
          // makes a late arrival inert. The TARGET says what ends — the whole
          // presentation, or only the #1060 banner inside a live recording.
          switch target {
          case .presentation: self?.handle(.expiryFired(id), binding: .none)
          case .inPanelNotice: self?.handle(.inPanelNoticeExpiryFired(id), binding: .none)
          }
        }
      }
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

      model.presentation = plan.presentation
      // **The announcement travels WITH the render**, so the deferred first
      // presentation announces when it lands and a refused one never does.
      let announceOnSuccess: () -> Void = { [weak self] in
        armExpiry()
        guard announcing, let announcement = plan.announcement else { return }
        self?.announce(announcement)
      }
      let outcome = render(plan.presentation, onPresented: announceOnSuccess)
      if outcome == .deferred { return }
      if outcome == .refused {
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
      // for — the pill this dwell belongs to is already on screen.
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
  private static func isRecording(_ presentation: OverlayPresentation) -> Bool {
    if case .recording = presentation.content { return true }
    return false
  }

  /// Three outcomes, because a DEFERRED first render is neither of the other
  /// two: nothing has been refused yet, and nothing is on screen yet. Collapsing
  /// it into `true` announced a presentation the host had not accepted — the C8
  /// defect reopening through the C15 deferral, caught by C8's own case.
  enum RenderOutcome { case presented, refused, deferred }

  @discardableResult
  private func render(
    _ presentation: OverlayPresentation?, onPresented: @escaping () -> Void = {}
  ) -> RenderOutcome {
    guard let presentation else {
      presentedID = nil
      host.hide()
      onPresented()
      return .presented
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
    // Keyed on the VIEW, not on a flag: every presentation arriving before the
    // view exists defers, however many that is. Each carries its own identity
    // gate, so a superseded one drops and the live one constructs; a request
    // cancelled that way leaves nothing built and the next one defers too.
    if builtRootView == nil {
      presentedID = presentation.id
      let deferredID = presentation.id
      deferFirstRender { [weak self] in
        guard let self else { return }
        // Identity gate, not a generation counter: a presentation superseded
        // while we waited is dropped, and the one that replaced it does its own
        // render. Same one-shot staleness rule `PresentationID` exists for.
        guard self.reducer.state.current?.id == deferredID else { return }
        if self.performRender(presentation) {
          onPresented()
        } else {
          self.rollBackRefusedPresentation()
        }
      }
      return .deferred
    }
    if performRender(presentation) {
      onPresented()
      return .presented
    }
    return .refused
  }

  /// The synchronous half, so the deferred first call and every later one run
  /// exactly the same code rather than two copies that can drift.
  private func performRender(_ presentation: OverlayPresentation) -> Bool {
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
    let isFresh = presentedID == nil || (Self.isRecording(presentation) && presentedID != presentation.id)
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

  var featureSlotIsAvailable: Bool { currentIntent == .hidden }

  @discardableResult
  func present(_ request: PillRequest) -> PillReceipt? {
    // Captured BEFORE the request runs, so the guard at the end can tell an
    // accepted presentation from an unchanged slot.
    let incumbentID = reducer.state.current?.id
    switch request {
    case .recording(let input):
      presentRecording(
        audioLevel: input.audioLevel,
        audioLevelProvider: input.audioLevelProvider,
        recordingElapsedProvider: input.recordingElapsedProvider,
        isRecordingLocked: input.isLocked)
    case .processing(let phase):
      handle(.pipeline(.processing(phase: phase)), binding: .none)
    case .clipboardFallback:
      handle(.pipeline(.clipboardFallback), binding: .none)
    case .warning(let reason):
      handle(.pipeline(.warning(reason: reason)), binding: .none)
    case .error(let reason):
      handle(.pipeline(.error(reason: reason)), binding: .none)
    case .advisory(let reason):
      handle(.pipeline(.advisory(reason: reason)), binding: .none)
    case .interruption(let reason):
      handle(.pipeline(.interruption(reason: reason)), binding: .none)
    case .cachingModel(let engineLabel):
      handle(.pipeline(.cachingModel(engineLabel: engineLabel)), binding: .none)
    case .engineReady:
      handle(.pipeline(.engineReady), binding: .none)
    case .recoverySucceeded:
      handle(.pipeline(.recoverySucceeded), binding: .none)
    case .importStatus(let message):
      handle(.featureRequest(.importStatus(message: message)), binding: .none)

    case .accessibilityNotice:
      presentAccessibilityNotice()
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
          onExpire: nil))
    // **The chip is a `.pipeline` intent, not a `.featureRequest`, and the two
    // spellings both exist.** `OverlayIntent` and `OverlayRequest` each declare
    // a `passiveChip` case; the shipped path routes it through the pipeline, so
    // it sets `pipelineIntent` and arbitrates against the pipeline the way the
    // presenter expects. Bluetooth is the mirror image and genuinely is a
    // `.featureRequest`. Sending either through the other enum compiles.
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
          onExpire: onExpire))
    case .bluetoothAwareness(let onAcknowledge, let onClose, let onOpenSettings):
      // Same admission transaction as `.languageChip` above. C3b moves the
      // Bluetooth presenter onto the receipt; the guard belongs here from the
      // moment either feature uses it, so the two cannot drift.
      guard featureSlotIsAvailable else { return nil }
      handle(
        .featureRequest(.bluetoothAwareness),
        binding: .install(
          deliver: { action in
            switch action {
            case .acknowledgeBluetoothAwareness: onAcknowledge()
            case .closeBluetoothAwareness: onClose()
            case .openBluetoothSettings: onOpenSettings()
            default: break
            }
          },
          onExpire: nil))
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
          onExpire: nil))
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
    guard let current = reducer.state.current else { return nil }
    if case .recording = request { return PillReceipt(presentationID: current.id) }
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
