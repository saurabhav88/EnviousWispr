import ApplicationServices
import Darwin
import EnviousWisprCore
import Foundation

/// Learns which tile is the user in a Zoom app call by opening Zoom's Participants panel, reading
/// the row Zoom marks `(me)`, and closing the panel again, all in one call (#4356). Run on the
/// capture lane in place of one copy, so it never overlaps a copy and leaves no panel state
/// behind between calls.
///
/// Observed live (Zoom 7.1.9, macOS 26, 2026-11-03, run
/// `20261103-152130-zoom-self-name-competitors-5184/receipt-press.md`): the meeting window's
/// `participant` toolbar button reads `Open participants panel, closed, N participants` and,
/// once pressed, `Close participants panel, opened, …` (English in every Zoom language); the
/// press returns in 14-27 ms, the `(me)` row's text exists 57-70 ms later, and the press brings
/// Zoom to the front (the session asks the user's app back; this type never activates, raises
/// or focuses anything itself).
///
/// It closes only a panel it saw closed before its own press, at most once, on the original
/// meeting window element; a panel the user closed during the poll is left alone. A user who
/// closes and reopens the panel between two reads cannot be told apart through this button.
package enum ZoomSelfProbe {
  /// What one call did.
  package struct Result: Sendable, Equatable {
    /// Why nothing was pressed; `nil` when the open press was sent.
    package enum Refusal: String, Sendable, Equatable {
      /// The window list, the meeting window or its button could not be read.
      case unreadable
      /// No meeting window, or it has no Participants button.
      case notFound
      /// Two meeting windows, or two Participants buttons.
      case ambiguous
      /// The button does not read closed: the panel is open (the user's) or in another state.
      case notInState = "not_in_state"
      /// Stopped before the press (dictation, trust, a new binding or admission closed).
      case skipped
      /// The press itself was refused.
      case pressFailed = "press_failed"
    }

    package let refusal: Refusal?
    /// The open press was sent (a press that could not complete counts: it may have happened).
    package let pressedOpen: Bool
    /// The one name a complete copy showed in exactly one bound `(me)` row.
    package let learned: String?
    /// After the close step: true when the button reads closed, false when it still reads open,
    /// nil when it could not be told (or nothing was opened).
    package let panelClosed: Bool?
    /// The probe saw the panel open and then closed by someone else, so it pressed nothing.
    package let userClosed: Bool
    package let elapsedMs: Int

    package static func refused(_ refusal: Refusal, elapsedMs: Int) -> Result {
      Result(
        refusal: refusal, pressedOpen: false, learned: nil, panelClosed: nil, userClosed: false,
        elapsedMs: elapsedMs)
    }
  }

  /// One press's answer.
  package enum PressAnswer: Sendable, Equatable {
    case done
    /// `cannotComplete` or a timeout: the action may still have happened.
    case indeterminate
    case refused
  }

  static let meetingWindowIdentifier = "zm.meeting.window.main"
  static let buttonIdentifier = "participant"
  static let closedPrefix = "Open participants panel, closed, "
  static let openPrefix = "Close participants panel, opened, "
  /// How long after the open press the probe keeps looking for the `(me)` row (the row's text
  /// existed 57-70 ms after the press in the live takes).
  static let pollDeadline: Duration = .milliseconds(600)
  static let pollInterval: Duration = .milliseconds(50)

  /// The transaction. `access` reads the app; `press` sends AXPress; `pause` waits between
  /// polls (the fake clock advances in tests). `shouldStop` is read right before the open press
  /// and between polls; after the press it only ends the poll early, never the close.
  package static func run<Element>(
    app: Element, access: CallAXTreeAccess<Element>, press: (Element) -> PressAnswer,
    pause: (Duration) -> Void, protectedRoles: Set<String>, shouldStop: () -> Bool,
    hostTime: () -> UInt64 = { 0 }
  ) -> Result {
    let start = access.now()
    func elapsed() -> Int {
      let d = start.duration(to: access.now()).components
      return Int(d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000)
    }
    let meeting: Element
    switch meetingWindow(app: app, access: access) {
    case .found(let window): meeting = window
    case .refused(let refusal): return .refused(refusal, elapsedMs: elapsed())
    }
    let opener: Element
    switch button(in: meeting, access: access) {
    case .found(let element, let label):
      guard label.hasPrefix(closedPrefix) else {
        return .refused(.notInState, elapsedMs: elapsed())
      }
      opener = element
    case .refused(let refusal): return .refused(refusal, elapsedMs: elapsed())
    }
    guard !shouldStop() else { return .refused(.skipped, elapsedMs: elapsed()) }
    guard press(opener) != .refused else { return .refused(.pressFailed, elapsedMs: elapsed()) }

    // Identity poll: one absolute deadline; no poll starts after it.
    let deadline = access.now().advanced(by: pollDeadline)
    var learned: String?
    var userClosed = false
    while access.now() < deadline, !shouldStop() {
      guard let window = current(meeting, app: app, access: access) else { break }
      // The button reads closed again: someone else closed it (the label already reads open
      // when the press returns, 5 of 5 live takes, receipt-press.md), so ownership ends here.
      if case .found(_, let label) = button(in: window, access: access),
        label.hasPrefix(closedPrefix)
      {
        userClosed = true
        break
      }
      let remaining = access.now().duration(to: deadline)
      var bounds = CallAXBounds.standard
      bounds.budget = min(bounds.budget, remaining)
      let copy = CallSpeakerCapture.capture(
        windows: [window], access: access, bounds: bounds, policy: .zoomApp,
        protectedRoles: protectedRoles, keepPage: { _ in false }, app: nil, hostTime: hostTime)
      if copy.completeness == .complete, let name = oneSelfRow(copy.windows) {
        learned = name
        break
      }
      let left = access.now().duration(to: deadline)
      guard left > .zero else { break }
      pause(min(pollInterval, left))
    }

    // Close: only the original window's button, only when it reads open, once.
    var panelClosed: Bool? = userClosed ? true : nil
    if !userClosed, let window = current(meeting, app: app, access: access),
      case .found(let element, let label) = button(in: window, access: access)
    {
      if label.hasPrefix(openPrefix) {
        _ = press(element)
        panelClosed = closedState(window, access: access)
      } else {
        panelClosed = label.hasPrefix(closedPrefix) ? true : nil
      }
    }
    return Result(
      refusal: nil, pressedOpen: true, learned: learned, panelClosed: panelClosed,
      userClosed: userClosed, elapsedMs: elapsed())
  }

  /// The name of the one bound participants-list row marked `(me)`, or `nil` when there is
  /// none or more than one row (a name the reader's helper would de-duplicate still counts
  /// twice here). Uses the reader's own row binding and `(me)` parsing.
  static func oneSelfRow(_ windows: [CallAXWindow]) -> String? {
    let rows = ZoomAppSpeakerReader.listEntries(windows.flatMap { $0.root.allNodes })
      .flatMap { $0.compactMap(ZoomAppSpeakerReader.selfName(fromParticipantEntry:)) }
    return rows.count == 1 ? rows[0] : nil
  }

  enum Lookup<Element> {
    case found(Element)
    case refused(Result.Refusal)
  }

  enum ButtonLookup<Element> {
    case found(Element, label: String)
    case refused(Result.Refusal)
  }

  static func windows<Element>(app: Element, access: CallAXTreeAccess<Element>) -> [Element]? {
    switch access.read(app, .windows) {
    case .elements(let list): list
    case .missing: []
    default: nil
    }
  }

  static func meetingWindow<Element>(app: Element, access: CallAXTreeAccess<Element>)
    -> Lookup<Element>
  {
    guard let list = windows(app: app, access: access) else { return .refused(.unreadable) }
    var meetings: [Element] = []
    for window in list {
      switch access.read(window, .identifier) {
      case .text(let id) where id == meetingWindowIdentifier: meetings.append(window)
      case .failed: return .refused(.unreadable)
      default: break
      }
    }
    switch meetings.count {
    case 0: return .refused(.notFound)
    case 1: return .found(meetings[0])
    default: return .refused(.ambiguous)
    }
  }

  /// The original meeting window when the app still shows that same element; `nil` when it is
  /// gone, replaced or unreadable.
  static func current<Element>(
    _ original: Element, app: Element, access: CallAXTreeAccess<Element>
  ) -> Element? {
    windows(app: app, access: access)?.first { access.same($0, original) }
  }

  /// The one direct-child `AXButton` with identifier `participant`, and its description.
  static func button<Element>(in window: Element, access: CallAXTreeAccess<Element>)
    -> ButtonLookup<Element>
  {
    guard case .elements(let children) = access.read(window, .children) else {
      return .refused(.unreadable)
    }
    var found: [(Element, String)] = []
    for child in children {
      let answers = access.readMany(child, [.role, .identifier, .description])
      guard answers.count == 3 else { return .refused(.unreadable) }
      guard case .text("AXButton") = answers[0], case .text(buttonIdentifier) = answers[1]
      else {
        if case .failed = answers[0] { return .refused(.unreadable) }
        if case .failed = answers[1] { return .refused(.unreadable) }
        continue
      }
      guard case .text(let label) = answers[2] else { return .refused(.unreadable) }
      found.append((child, label))
    }
    switch found.count {
    case 0: return .refused(.notFound)
    case 1: return .found(found[0].0, label: found[0].1)
    default: return .refused(.ambiguous)
    }
  }

  static func closedState<Element>(_ window: Element, access: CallAXTreeAccess<Element>) -> Bool? {
    guard case .found(_, let label) = button(in: window, access: access) else { return nil }
    if label.hasPrefix(closedPrefix) { return true }
    if label.hasPrefix(openPrefix) { return false }
    return nil
  }

  // MARK: - Live

  /// The transaction against the Zoom app `pid`, with the live tree access (0.1 s messaging
  /// timeout on every element, `CallSpeakerCapture.liveAccess`) and a real AXPress.
  package static func live(
    pid: pid_t, protectedRoles: Set<String>, shouldStop: () -> Bool
  ) -> Result {
    run(
      app: AXUIElementCreateApplication(pid), access: CallSpeakerCapture.liveAccess,
      press: livePress,
      pause: {
        let c = $0.components
        Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
      },
      protectedRoles: protectedRoles, shouldStop: shouldStop, hostTime: { mach_absolute_time() })
  }

  static func livePress(_ element: AXUIElement) -> PressAnswer {
    guard AXUIElementSetMessagingTimeout(element, CallSpeakerCapture.messagingTimeout) == .success
    else { return .refused }
    switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
    case .success: return .done
    case .cannotComplete: return .indeterminate
    default: return .refused
    }
  }
}
