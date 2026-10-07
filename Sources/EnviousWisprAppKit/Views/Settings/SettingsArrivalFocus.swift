import AppKit
import SwiftUI

// Focus after a Settings search arrival (#3482 plan §3.4, decision Q1(a) of the chunk 5 plan
// review). After the scroll, the ring and the announcement:
//  - VoiceOver focus moves to the arrived place;
//  - keyboard focus moves there only when the place is a real control that already takes it
//    (a toggle, a picker, a button, a text field); a heading, a card or a status line gets no
//    keyboard focus, and nothing gains a tab stop;
//  - the search field never keeps focus after the dropdown closes.
// Registrations sit on rows and containers, which are not controls, so the actual controls of the
// shared components carry explicit adapters that find their place through the nearest enclosing
// registration (`settingsArrivalRegisteredID`), never through an id the page repeats.

/// What an arrival may do to focus at a place.
enum SettingsArrivalFocusKind: Equatable, Sendable {
  /// A real control: keyboard focus where the system gives it to that control, and VoiceOver focus.
  case control
  /// A heading, card, row or status line: VoiceOver focus only.
  case readOnly
}

/// Which adapters exist for each registered place. A control beats a read-only registration of
/// the same place.
struct SettingsArrivalFocusKey: PreferenceKey {
  static let defaultValue: [SettingsMapID: SettingsArrivalFocusKind] = [:]
  static func reduce(
    value: inout [SettingsMapID: SettingsArrivalFocusKind],
    nextValue: () -> [SettingsMapID: SettingsArrivalFocusKind]
  ) {
    for (id, kind) in nextValue() where value[id] != .control { value[id] = kind }
  }
}

/// One focus move, asked of the adapters of one place. Only adapters of `kind` act, so a place
/// with a control is focused through the control and never also through its row.
struct SettingsArrivalFocusRequest: Equatable, Sendable {
  let token: Int
  let target: SettingsMapID
  let kind: SettingsArrivalFocusKind
}

extension EnvironmentValues {
  /// The place registered by the nearest enclosing mapped registration; nil outside one and inside
  /// an exempt region. Adapters find their place here.
  @Entry var settingsArrivalRegisteredID: SettingsMapID? = nil
  /// The focus move in flight, if any (one shot: the first adapter to act reports it taken).
  @Entry var settingsArrivalFocusRequest: SettingsArrivalFocusRequest? = nil
  /// Asked by an adapter just before it acts: whether the request is still the owner's live one
  /// and its arrival still current (no navigation since, page and tab showing). False outside an
  /// arrival owner, so a request reaching an adapter by any other path moves nothing.
  @Entry var settingsArrivalFocusIsCurrent: @MainActor (SettingsArrivalFocusRequest) -> Bool = {
    _ in false
  }
  /// An adapter reports that it acted on the request; the arrival owner then drops the request.
  @Entry var settingsArrivalFocusTaken: @MainActor (SettingsArrivalFocusRequest) -> Void = { _ in }
  /// Takes keyboard focus out of the search field. The default resigns a text editor in the key
  /// window; a window that owns its search focus state can supply a more exact one.
  @Entry var settingsArrivalReleaseSearchFocus: @MainActor () -> Void = {
    SettingsArrivalFocusPlanner.resignTextEntry()
  }
}

extension EnvironmentValues {
  /// Full Keyboard Access, when a test pins it; nil reads the machine's setting. It decides whether
  /// a toggle, picker, button or tab takes keyboard focus.
  @Entry var settingsArrivalFullKeyboardAccess: Bool? = nil
}

/// The focus decision, pure so every case is tested without a window.
enum SettingsArrivalFocusPlanner {
  /// What one arrival does. The search field is always released; the request is nil when no
  /// adapter exists for the place, which leaves focus nowhere rather than in the search field.
  struct Move: Equatable {
    let releaseSearch: Bool
    let request: SettingsArrivalFocusRequest?
  }

  static func plan(
    target: SettingsMapID, token: Int, kinds: [SettingsMapID: SettingsArrivalFocusKind]
  ) -> Move {
    Move(
      releaseSearch: true,
      request: kinds[target].map {
        SettingsArrivalFocusRequest(token: token, target: target, kind: $0)
      })
  }

  /// Whether a pending move may still run: it is for the arrival this scroll owner handled last,
  /// and that arrival's destination (page, tab, Dictionary tab) is still on screen.
  static func mayMove(pendingToken: Int, handledToken: Int?, showing: Bool) -> Bool {
    showing && handledToken == pendingToken
  }

  /// Whether keyboard focus may be asked of a control. A text field, or the keybind recorder, takes
  /// it always; a toggle, picker, button or tab takes it only with Full Keyboard Access on. Asking
  /// one that cannot makes SwiftUI hand focus back to the search field (seen live, for the Dictation
  /// tab strip), so it is not asked, whether the control is focused by this adapter or by its owner.
  static func mayAskKeyboardFocus(takesFocusAlways: Bool, fullKeyboardAccess: Bool) -> Bool {
    takesFocusAlways || fullKeyboardAccess
  }

  /// The default release: resign the key window's text editor (the search field's), and nothing
  /// else, so a control that already holds focus keeps it.
  @MainActor
  static func resignTextEntry() {
    guard let window = NSApp.keyWindow, let editor = window.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return }
    window.makeFirstResponder(nil)
  }
}

extension View {
  /// This view IS a control (a toggle, a picker, a button, a text field): a search arrival at its
  /// place gives it keyboard focus, where the system allows that for it, and VoiceOver focus. It
  /// never makes the view focusable, so it adds no tab stop.
  ///
  /// - Parameters:
  ///   - place: the place this control stands for when it is not the one its nearest enclosing
  ///     registration names (a card's Change button stands for the card).
  ///   - enabled: false makes the adapter inert, for one segment of several that is the entry point.
  ///   - perform: for a control whose owner already holds its keyboard focus state (a text
  ///     field's `@FocusState`, a tab strip's focused tab): the owner moves keyboard focus itself.
  ///   - textEntry: this control takes keyboard focus without Full Keyboard Access (a text field, or the
  ///     keybind recorder). Left false for a toggle, picker, button or tab: they are asked only with it on.
  ///   - voiceOver: false when the control's owner also holds its VoiceOver focus state and moves
  ///     that itself in `perform`.
  func settingsArrivalFocusControl(
    place: SettingsMapID? = nil, enabled: Bool = true, voiceOver: Bool = true,
    textEntry: Bool = false, perform: (@MainActor () -> Void)? = nil
  ) -> some View {
    modifier(
      SettingsArrivalFocusAdapter(
        kind: .control, place: place, enabled: enabled, voiceOver: voiceOver,
        textEntry: textEntry, perform: perform))
  }

  /// A button inside a registered panel that has no place of its own: it must not claim the
  /// panel's place for itself (the panel is focused through its own read-only adapter).
  func settingsArrivalWithoutInheritedPlace() -> some View {
    transformEnvironment(\.settingsArrivalRegisteredID) { $0 = nil }
  }

  /// A registered place that is not itself a control. Added by the registration funnel, outside
  /// the environment it provides, so it names its place itself.
  func settingsArrivalFocusReadOnly(place: SettingsMapID) -> some View {
    modifier(
      SettingsArrivalFocusAdapter(
        kind: .readOnly, place: place, enabled: true, voiceOver: true, textEntry: false,
        perform: nil))
  }
}

struct SettingsArrivalFocusAdapter: ViewModifier {
  let kind: SettingsArrivalFocusKind
  let place: SettingsMapID?
  let enabled: Bool
  let voiceOver: Bool
  let textEntry: Bool
  let perform: (@MainActor () -> Void)?

  @Environment(\.settingsArrivalRegisteredID) private var registered
  @Environment(\.settingsArrivalFocusRequest) private var request
  @Environment(\.settingsArrivalFocusTaken) private var taken
  @Environment(\.settingsArrivalFocusIsCurrent) private var isCurrent
  @Environment(\.settingsArrivalFullKeyboardAccess) private var fullKeyboardAccess
  @FocusState private var keyboardFocused: Bool
  @AccessibilityFocusState private var voiceOverFocused: Bool

  private var target: SettingsMapID? { place ?? registered }

  func body(content: Content) -> some View {
    let published = enabled ? target : nil
    let kind = kind
    return focusBound(content)
      // A transform, not `.preference(value:)`: it adds this place to what the views inside already
      // published, where an empty or outer value replaced it (measured with a probe).
      .transformPreference(SettingsArrivalFocusKey.self) { value in
        if let published, value[published] != .control { value[published] = kind }
      }
      .onChange(of: request, initial: true) { _, new in act(on: new) }
  }

  /// An owner that moves keyboard focus itself (`perform`) keeps its own focus state; otherwise
  /// this adapter binds the control, never making a view focusable that was not.
  @ViewBuilder
  private func focusBound(_ content: Content) -> some View {
    switch (kind == .control && perform == nil, voiceOver) {
    case (true, true): content.focused($keyboardFocused).accessibilityFocused($voiceOverFocused)
    case (true, false): content.focused($keyboardFocused)
    case (false, true): content.accessibilityFocused($voiceOverFocused)
    case (false, false): content
    }
  }

  private func act(on request: SettingsArrivalFocusRequest?) {
    guard enabled, let request, let target, request.target == target, request.kind == kind,
      isCurrent(request)
    else { return }
    if kind == .control,
      SettingsArrivalFocusPlanner.mayAskKeyboardFocus(
        takesFocusAlways: textEntry,
        fullKeyboardAccess: fullKeyboardAccess ?? NSApp.isFullKeyboardAccessEnabled)
    {
      if let perform { perform() } else { keyboardFocused = true }
    }
    // VoiceOver moves its cursor when asked; with it off there is nothing to move.
    if voiceOver, NSWorkspace.shared.isVoiceOverEnabled { voiceOverFocused = true }
    taken(request)
  }
}
