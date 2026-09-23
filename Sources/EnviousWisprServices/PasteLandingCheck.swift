import ApplicationServices
import EnviousWisprCore
import Foundation

/// What a key paste was OBSERVED to do to the focused field (#3106, step 1: observation only).
///
/// **An observation of field state, never proof that the payload landed.** `changed` means the field
/// is not what it was; `unchanged` means it is byte-identical; `unknown` means we could not tell.
/// Nothing may act on it in step 1: no clipboard, overlay or destination write depends on it.
package enum PasteLandingObserved: Sendable, Equatable {
  case changed(Reason)
  case unchanged(Reason)
  case unknown(Reason)

  /// The closed reason vocabulary, one per row of the plan's verdict table (§3.2). The raw values
  /// are the log and telemetry strings.
  package enum Reason: String, Sendable, CaseIterable {
    case appTerminated = "app_terminated"
    case appSwitched = "app_switched"
    case prepareBudget = "prepare_budget"
    case beforeUnreadable = "before_unreadable"
    case noObserver = "no_observer"
    case textDiffers = "text_differs"
    case notifiedValue = "notified_value"
    case notifiedFocus = "notified_focus"
    case elementDestroyed = "element_destroyed"
    case selectionUnavailable = "selection_unavailable"
    case identicalSelection = "identical_selection"
    case fieldIdentical = "field_identical"
    case noFocus = "no_focus"
    case afterUnreadable = "after_unreadable"
  }

  /// `changed`, `unchanged` or `unknown`: the `observed` field of the log line and the event.
  package var observed: String {
    switch self {
    case .changed: "changed"
    case .unchanged: "unchanged"
    case .unknown: "unknown"
    }
  }

  package var reason: Reason {
    switch self {
    case .changed(let reason), .unchanged(let reason), .unknown(let reason): reason
    }
  }
}

/// Everything the verdict is decided from, gathered by the check's lifecycle. Immutable: the
/// classifier reads nothing live.
package struct PasteLandingFacts: Sendable, Equatable {

  /// The focused field immediately before our write.
  package enum Before: Sendable, Equatable {
    /// A readable field: its whole text, and what was selected in it.
    case field(text: String, selection: Selection)
    /// The application answered that nothing is focused.
    case noFocus
    /// The focus query failed, the field is secure, its text could not be read, or it is over the
    /// read limit. Distinct from `noFocus`: a failed question is not the answer "nothing".
    case unreadable
  }

  /// The selection in the before-image.
  package enum Selection: Sendable, Equatable {
    /// The selected text, possibly empty (a caret).
    case text(String)
    /// The host would not say what is selected.
    case unavailable
  }

  /// The focused field at resolution.
  package enum After: Sendable, Equatable {
    /// The same element as before is still focused. `text` is nil when it could not be read.
    case sameElement(text: String?)
    /// A different element is focused.
    case otherElement
    /// The application answered that nothing is focused.
    case noFocus
    /// The focus query failed.
    case queryFailed
  }

  package let targetTerminated: Bool
  /// The target is still running, and the frontmost process at resolution is not the one that was
  /// frontmost before the write.
  package let frontmostChanged: Bool
  /// The one cumulative preparation budget ran out at any depth.
  package let prepareBudgetExhausted: Bool
  package let before: Before
  /// Every notification the check required was registered.
  package let observerComplete: Bool
  /// Which notifications arrived during the watch.
  package let notifications: Set<PastedRegionAXNotification>
  package let after: After
  /// What we pasted, compared with the before-image's selection.
  package let payload: String

  package init(
    targetTerminated: Bool = false,
    frontmostChanged: Bool = false,
    prepareBudgetExhausted: Bool = false,
    before: Before,
    observerComplete: Bool = true,
    notifications: Set<PastedRegionAXNotification> = [],
    after: After,
    payload: String
  ) {
    self.targetTerminated = targetTerminated
    self.frontmostChanged = frontmostChanged
    self.prepareBudgetExhausted = prepareBudgetExhausted
    self.before = before
    self.observerComplete = observerComplete
    self.notifications = notifications
    self.after = after
    self.payload = payload
  }
}

/// One observation of one key paste (#3106 step 1): prepared and armed immediately before the
/// write, committed only when that write succeeded, then resolved once, against the original
/// target, into a `PasteLandingObserved` and one DEBUG log line. It observes; nothing it concludes
/// writes to the clipboard, the overlay or the destination.
///
/// Lifecycle: `prepare` (a factory: before-image, target window, armed observer, all under one
/// `PasteLandingPrepareBudget`) → `commit()` | `cancelUnlessCommitted()` → `resolve()`. Every
/// terminal path invalidates exactly the registration that succeeded and any scheduled deadline;
/// a generation guard makes callbacks queued before that do nothing. Two checks never supersede
/// each other in step 1.
@MainActor
package final class PasteLandingCheck {

  package let context: Context
  private let application: AXUIElement
  /// The field focused before the write, compared by `CFEqual` at resolution.
  private let element: AXUIElement?
  private let before: PasteLandingFacts.Before
  private let frontmostBefore: pid_t?
  private let manualAX: Bool
  private let hostExposedFocus: Bool
  package let targetWindow: PasteLandingTargetWindow
  /// The destination's class, from the bundle id and manual-accessibility answer snapshotted at
  /// prepare: a later take, focus change or frontmost app cannot change it (#3106, for telemetry).
  package var appClass: TelemetryService.LearnFromEditsTelemetry.AppClass {
    PasteLandingAppClass.classify(
      bundleIdentifier: context.bundleID, isManualAccessibilityHost: manualAX)
  }
  private let ax: any PastedRegionAXOperations
  private let scheduler: any PastedRegionScheduling
  private let log: @MainActor (String) -> Void

  fileprivate(set) var beforeMs = 0
  fileprivate var prepareBudgetExhausted = false
  private var registration: (any PastedRegionAXRegistration)?
  private var observerComplete = false
  /// What ended the watch: the FIRST notification (armed or committed) or the deadline, whichever
  /// came first. Latched: anything later is ignored, so neither a later notification of higher
  /// table priority nor one after the deadline can change the verdict.
  private enum Trigger: Equatable {
    case notification(PastedRegionAXNotification)
    case deadline
  }
  private var trigger: Trigger?
  /// Bumped on every terminal transition: a callback carrying an older value does nothing.
  private var generation = 0
  package private(set) var phase: Phase = .armed
  private var committedAtMs = 0
  private var deadline: (any PastedRegionScheduledWork)?
  /// Resumed by the first notification or the deadline, whichever comes first.
  private var wake: CheckedContinuation<Void, Never>?
  private var resolution: Task<PasteLandingObserved, Never>?
  package private(set) var result: PasteLandingObserved?

  fileprivate init(
    context: Context, application: AXUIElement, element: AXUIElement?,
    before: PasteLandingFacts.Before, frontmostBefore: pid_t?, manualAX: Bool,
    hostExposedFocus: Bool, targetWindow: PasteLandingTargetWindow,
    ax: any PastedRegionAXOperations, scheduler: any PastedRegionScheduling,
    log: @escaping @MainActor (String) -> Void
  ) {
    self.context = context
    self.application = application
    self.element = element
    self.before = before
    self.frontmostBefore = frontmostBefore
    self.manualAX = manualAX
    self.hostExposedFocus = hostExposedFocus
    self.targetWindow = targetWindow
    self.ax = ax
    self.scheduler = scheduler
    self.log = log
  }

  /// Registers the notifications before the write. A partial registration is kept, so a terminal
  /// transition invalidates exactly what succeeded; the verdict sees it as incomplete.
  fileprivate func arm(budget: PasteLandingPrepareBudget) {
    let generation = self.generation
    registration = ax.registerLanding(
      pid: context.pid, element: element, application: application, admit: budget.admit,
      handler: { [weak self] notification in self?.notified(notification, generation: generation) })
    let required = Self.requiredNotifications(hasElement: element != nil)
    observerComplete = registration.map { required.isSubset(of: $0.registeredNotifications) } ?? false
  }

  private func notified(_ notification: PastedRegionAXNotification, generation: Int) {
    guard generation == self.generation, phase == .armed || phase == .committed,
      trigger == nil
    else { return }
    trigger = .notification(notification)
    if phase == .committed { wakeUp() }
  }

  /// The write succeeded: the check may now resolve. Idempotent; a cancelled check stays cancelled.
  package func commit() {
    guard phase == .armed else { return }
    phase = .committed
    committedAtMs = scheduler.nowMs
    let generation = self.generation
    deadline = scheduler.schedule(afterMs: PastedRegionTiming.settleMs) { [weak self] in
      guard let self, generation == self.generation, self.trigger == nil else { return }
      self.trigger = .deadline
      self.wakeUp()
    }
  }

  /// Every exit that is not a successful write. Idempotent; a committed check is left alone.
  package func cancelUnlessCommitted() {
    guard phase == .armed else { return }
    phase = .cancelled
    tearDown()
  }

  /// The verdict, once. Nil for a check that was never committed. Concurrent callers share one
  /// resolution, one verdict and one log line.
  package func resolve() async -> PasteLandingObserved? {
    if let result { return result }
    guard phase == .committed else { return nil }
    if let resolution { return await resolution.value }
    let task = Task { @MainActor in await self.runResolution() }
    resolution = task
    return await task.value
  }

  private func runResolution() async -> PasteLandingObserved {
    // Ends at the first notification or the deadline, whichever came first; either may already
    // have happened, including a notification that arrived between arm and commit.
    if trigger == nil {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        wake = continuation
      }
    }
    let observed = Self.classify(finalFacts())
    result = observed
    phase = .resolved
    tearDown()
    log(logLine(observed))
    report(observed)
    return observed
  }

  private func wakeUp() {
    let continuation = wake
    wake = nil
    continuation?.resume()
  }

  /// The final bounded read: the target's life, the frontmost process, and the focused field.
  private func finalFacts() -> PasteLandingFacts {
    let terminated = !ax.isProcessRunning(context.pid)
    let switched = !terminated && ax.frontmostPID() != frontmostBefore
    let budget = PasteLandingPrepareBudget(scheduler: scheduler, ax: ax)
    let after: PasteLandingFacts.After
    switch Self.focus(of: application, pid: context.pid, ax: ax, budget: budget) {
    case nil, .unreadable?:
      after = .queryFailed
    case .noFocus?:
      after = .noFocus
    case .element(let focused)?:
      if let element, CFEqual(focused, element) {
        // Only a field whose before-image was READABLE is read again: a secure field (or one that
        // could not be read) is never read at resolution either, and its verdict cannot use it.
        if case .field = before,
          case .text(let text)? = PastedRegionObserver.readWholeText(
            of: focused, ax: ax, admit: budget.admit)
        {
          after = .sameElement(text: text)
        } else {
          after = .sameElement(text: nil)
        }
      } else {
        after = .otherElement
      }
    }
    return PasteLandingFacts(
      targetTerminated: terminated, frontmostChanged: switched,
      prepareBudgetExhausted: prepareBudgetExhausted, before: before,
      observerComplete: observerComplete, notifications: latchedNotifications, after: after,
      payload: context.payload)
  }

  /// The one notification that ended the watch, or none when the deadline did.
  private var latchedNotifications: Set<PastedRegionAXNotification> {
    if case .notification(let notification) = trigger { return [notification] }
    return []
  }

  /// Invalidates the registration and the deadline, and silences every callback already queued.
  private func tearDown() {
    generation += 1
    registration?.invalidate()
    registration = nil
    deadline?.cancel()
    deadline = nil
    wakeUp()
  }

  /// The one `paste.landing_observed` row for this check, from the resolution that set `result`, so
  /// repeated or concurrent `resolve()` calls cannot emit twice. After the log line and after the
  /// verdict is fixed: it reports and decides nothing (plan §3.5).
  private func report(_ observed: PasteLandingObserved) {
    TelemetryService.shared.pasteLandingObserved(
      takeID: context.takeID, tier: context.tier.rawValue, observed: observed.observed,
      reason: observed.reason.rawValue, appClass: appClass.rawValue,
      hostExposedFocus: hostExposedFocus, targetWindow: targetWindow.rawValue,
      beforeMs: beforeMs, resolveMs: scheduler.nowMs - committedAtMs)
  }

  /// Shape only: no text, selection, window title or take id (plan §3.4).
  private func logLine(_ observed: PasteLandingObserved) -> String {
    "PASTE_LANDING tier=\(context.tier.rawValue) observed=\(observed.observed) "
      + "reason=\(observed.reason.rawValue) app=\(context.bundleID ?? "unknown") "
      + "host_exposed_focus=\(hostExposedFocus) manual_ax=\(manualAX) "
      + "target_window=\(targetWindow.rawValue) before_ms=\(beforeMs) "
      + "resolve_ms=\(scheduler.nowMs - committedAtMs)"
  }

  /// The verdict table, first match wins (plan §3.2). Rows are evaluated in the order listed there.
  ///
  /// Text is compared as UTF-16 code units, never with `String ==`: Swift equates canonically
  /// equivalent strings (a precomposed "é" and "e" plus a combining accent), which would call a
  /// field "identical" after a paste changed its bytes.
  nonisolated package static func classify(_ facts: PasteLandingFacts) -> PasteLandingObserved {
    // Rows 1, 2, 3a: the observation itself is void.
    if facts.targetTerminated { return .unknown(.appTerminated) }
    if facts.frontmostChanged { return .unknown(.appSwitched) }
    if facts.prepareBudgetExhausted { return .unknown(.prepareBudget) }

    // Row 3: without a readable before-image nothing can be compared, so neither `changed` nor
    // `unchanged` may be claimed.
    let beforeText: String?
    let selection: PasteLandingFacts.Selection?
    switch facts.before {
    case .unreadable: return .unknown(.beforeUnreadable)
    case .field(let text, let sel):
      beforeText = text
      selection = sel
    case .noFocus:
      beforeText = nil
      selection = nil
    }

    // Row 4.
    guard facts.observerComplete else { return .unknown(.noObserver) }

    // Row 5: the same element, readable at the end, and different.
    if let beforeText, case .sameElement(let afterText?) = facts.after,
      !identical(afterText, beforeText)
    {
      return .changed(.textDiffers)
    }
    // Row 6: the field said its value changed.
    if facts.notifications.contains(.valueChanged) { return .changed(.notifiedValue) }
    // Rows 7b, 7c: focus and lifetime, not value.
    if facts.notifications.contains(.focusedElementChanged) { return .unknown(.notifiedFocus) }
    if facts.notifications.contains(.elementDestroyed) { return .unknown(.elementDestroyed) }

    // Rows 7, 7a, 8: the identical-field path. The selection guards apply only here.
    if let beforeText, let selection, case .sameElement(let afterText?) = facts.after,
      identical(afterText, beforeText)
    {
      switch selection {
      case .unavailable: return .unknown(.selectionUnavailable)
      case .text(let selected) where identical(selected, facts.payload):
        // Pasting over a selection that already holds the payload leaves the field identical
        // whether or not the paste arrived.
        return .unknown(.identicalSelection)
      case .text: return .unchanged(.fieldIdentical)
      }
    }

    // Row 9: nothing focused before, nothing at the end, and no focus notification (row 7b).
    if case .noFocus = facts.before, case .noFocus = facts.after {
      return .unchanged(.noFocus)
    }

    // Row 11: final text unreadable, focus moved, or anything else.
    return .unknown(.afterUnreadable)
  }

  /// Byte identity in UTF-16 code units.
  nonisolated private static func identical(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
  }
}

// MARK: - Preparation primitives (#3106 step 1, chunk 2)

/// The ONE cumulative time budget for everything the landing check reads and registers before the
/// paste is written.
///
/// Before each Accessibility call, `admit(_:)` is asked with the exact handle that call messages:
/// it refuses when the budget is spent, and otherwise installs the REMAINING time as that handle's
/// messaging timeout, so no call ever receives a fresh full bound. A refusal is remembered, and
/// every later call is refused too.
@MainActor
package final class PasteLandingPrepareBudget {

  /// Why a call was refused. Kept apart from any Accessibility answer, so a spent budget is never
  /// mistaken for an unreadable field.
  package enum Refusal: Sendable, Equatable {
    /// The cumulative budget ran out.
    case exhausted
    /// The remaining time could not be installed on the handle, so the call would be unbounded.
    case timeoutNotInstalled
  }

  /// The whole preparation may take this long. The same 0.5 s that bounds the paste path's own
  /// focused-element query and the learn watcher's capture (`PasteService.axMessagingTimeoutSeconds`),
  /// but spent ONCE across every call instead of once per call: a healthy host answers in
  /// milliseconds, so this is a failure bound, not a latency target.
  package static let defaultMs = Int(PasteService.axMessagingTimeoutSeconds * 1000)

  private let totalMs: Int
  private let startMs: Int
  private let scheduler: any PastedRegionScheduling
  private let ax: any PastedRegionAXOperations
  package private(set) var refusal: Refusal?

  package init(
    totalMs: Int = PasteLandingPrepareBudget.defaultMs,
    scheduler: any PastedRegionScheduling, ax: any PastedRegionAXOperations
  ) {
    self.totalMs = totalMs
    self.scheduler = scheduler
    self.ax = ax
    self.startMs = scheduler.nowMs
  }

  /// Milliseconds spent since the budget was created: the log's `before_ms`.
  package var elapsedMs: Int { scheduler.nowMs - startMs }

  /// Whether the next Accessibility call on `handle` may run. Installs the remaining time on that
  /// exact handle first.
  package func admit(_ handle: AXUIElement) -> Bool {
    guard refusal == nil else { return false }
    let remainingMs = totalMs - elapsedMs
    guard remainingMs > 0 else {
      refusal = .exhausted
      return false
    }
    guard ax.setMessagingTimeout(handle, seconds: Double(remainingMs) / 1000) else {
      refusal = .timeoutNotInstalled
      return false
    }
    return true
  }
}

/// The focused element as the landing check may use it (#3106).
package enum PasteLandingFocus {
  case element(AXUIElement)
  /// The application answered that nothing is focused.
  case noFocus
  /// The query failed, or the element's owner is another process or cannot be read.
  case unreadable
}

/// Whether the field captured when the recording started is in the window that is focused now
/// (#3106): the one fact knowable BEFORE the write that the paste would go to a different window
/// of the same application.
package enum PasteLandingTargetWindow: String, Sendable, CaseIterable {
  case same
  case different
  /// No captured field, a stale one, an absent or non-element answer, a failed call, or a refusal
  /// by the budget.
  case unknown
}

@MainActor
extension PasteLandingCheck {

  /// The focused element of `application` (owned by `pid`), read through the budget. Nil when the
  /// budget refused a call.
  ///
  /// The element's own process is checked, as `PasteService.focusedElement` does: an element
  /// another process owns, or one whose owner cannot be read, is `unreadable`, never `noFocus`.
  /// Only a genuine "nothing is focused" answer may later support an `unchanged/no_focus` verdict.
  package static func focus(
    of application: AXUIElement, pid: pid_t, ax: any PastedRegionAXOperations,
    budget: PasteLandingPrepareBudget
  ) -> PasteLandingFocus? {
    guard budget.admit(application) else { return nil }
    switch ax.focusedElement(ofApplication: application) {
    case .noFocus: return .noFocus
    case .queryFailed: return .unreadable
    case .element(let element):
      guard budget.admit(element) else { return nil }
      guard let owner = ax.pid(of: element), owner == pid else { return .unreadable }
      return .element(element)
    }
  }

  /// `same` or `different` only when BOTH windows are read as elements; `unknown` otherwise.
  package static func targetWindow(
    captured: AXUIElement?, application: AXUIElement, ax: any PastedRegionAXOperations,
    budget: PasteLandingPrepareBudget
  ) -> PasteLandingTargetWindow {
    guard let captured, budget.admit(captured),
      case .window(let capturedWindow) = ax.window(of: captured),
      budget.admit(application),
      case .window(let focusedWindow) = ax.focusedWindow(of: application)
    else { return .unknown }
    return CFEqual(capturedWindow, focusedWindow) ? .same : .different
  }

  /// The notifications a landing check needs: value-changed and destroyed on the field plus
  /// focus-changed on the application, or only focus-changed when nothing was focused.
  package static func requiredNotifications(hasElement: Bool) -> Set<PastedRegionAXNotification> {
    hasElement ? [.valueChanged, .elementDestroyed, .focusedElementChanged] : [.focusedElementChanged]
  }
}

// MARK: - Lifecycle (#3106 step 1, chunk 3)

extension PasteLandingCheck {

  /// The only tiers a check may be prepared for: the three key pastes (plan §3.3).
  package static let observedTiers: Set<PasteTier> = [.cgEvent, .appleScript, .menuPaste]

  /// What the caller knows about the paste being observed.
  package struct Context: Sendable {
    package let tier: PasteTier
    package let pid: pid_t
    /// Carried on `paste.landing_observed`; never logged. The same type as
    /// `KernelTelemetryState.takeID`, snapshotted before the delivery awaits.
    package let takeID: String?
    /// LOCAL log only; never telemetry.
    package let bundleID: String?
    package let payload: String

    package init(tier: PasteTier, pid: pid_t, takeID: String?, bundleID: String?, payload: String) {
      self.tier = tier
      self.pid = pid
      self.takeID = takeID
      self.bundleID = bundleID
      self.payload = payload
    }
  }

  /// Where a check is in its one lifecycle.
  package enum Phase: Sendable, Equatable {
    case armed, committed, cancelled, resolved
  }

  /// The selected text of `text` for a UTF-16 `range`, or `.unavailable` for any range that is
  /// negative, overflowing, out of bounds, or splits a character's scalars. Never clamped.
  nonisolated package static func selection(
    in text: String, range: PastedRegionSelectedRange
  ) -> PasteLandingFacts.Selection {
    guard case .range(let location, let length) = range, location >= 0, length >= 0 else {
      return .unavailable
    }
    let (end, overflow) = location.addingReportingOverflow(length)
    let units = text.utf16
    guard !overflow, end <= units.count else { return .unavailable }
    let lower = units.index(units.startIndex, offsetBy: location)
    let upper = units.index(units.startIndex, offsetBy: end)
    guard lower.samePosition(in: text.unicodeScalars) != nil,
      upper.samePosition(in: text.unicodeScalars) != nil
    else { return .unavailable }
    return .text(String(text[lower..<upper]))
  }

  /// Prepares and arms a check, synchronously, immediately before the write. Nil for a tier this
  /// check does not observe. `capturedTarget` is the element captured when the recording started.
  package static func prepare(
    _ context: Context, capturedTarget: AXUIElement?,
    ax: any PastedRegionAXOperations, scheduler: any PastedRegionScheduling,
    log: (@MainActor (String) -> Void)? = nil
  ) -> PasteLandingCheck? {
    guard observedTiers.contains(context.tier) else { return nil }
    let budget = PasteLandingPrepareBudget(scheduler: scheduler, ax: ax)
    let application = ax.applicationElement(pid: context.pid)
    let frontmostBefore = ax.frontmostPID()
    // Read, never enabled: the check does not change the destination to improve an observation.
    let manualAX = budget.admit(application) && ax.supportsManualAccessibility(application)

    var element: AXUIElement?
    let before: PasteLandingFacts.Before
    switch focus(of: application, pid: context.pid, ax: ax, budget: budget) {
    case nil, .unreadable?:
      before = .unreadable
    case .noFocus?:
      before = .noFocus
    case .element(let focused)?:
      element = focused
      before = beforeImage(of: focused, ax: ax, budget: budget)
    }
    let targetWindow = targetWindow(
      captured: capturedTarget, application: application, ax: ax, budget: budget)

    let check = PasteLandingCheck(
      context: context, application: application, element: element, before: before,
      frontmostBefore: frontmostBefore, manualAX: manualAX,
      hostExposedFocus: capturedTarget != nil, targetWindow: targetWindow,
      ax: ax, scheduler: scheduler, log: log ?? Self.debugLog)
    check.arm(budget: budget)
    check.beforeMs = budget.elapsedMs
    check.prepareBudgetExhausted = budget.refusal == .exhausted
    return check
  }

  /// Secure, unreadable, over-limit or refused text is `unreadable`; otherwise the whole text and
  /// what was selected in it.
  private static func beforeImage(
    of element: AXUIElement, ax: any PastedRegionAXOperations, budget: PasteLandingPrepareBudget
  ) -> PasteLandingFacts.Before {
    guard budget.admit(element) else { return .unreadable }
    if SelectionReader.isSecureField(ax.subrole(of: element)) { return .unreadable }
    guard case .text(let text)? = PastedRegionObserver.readWholeText(
      of: element, ax: ax, admit: budget.admit)
    else { return .unreadable }
    guard budget.admit(element) else { return .field(text: text, selection: .unavailable) }
    return .field(text: text, selection: selection(in: text, range: ax.selectedRange(of: element)))
  }

  /// The production DEBUG sink. Release builds log nothing.
  private static let debugLog: @MainActor (String) -> Void = { line in
    #if DEBUG
      Task { await AppLogger.shared.log(line, level: .info, category: "PasteLanding") }
    #endif
  }
}
