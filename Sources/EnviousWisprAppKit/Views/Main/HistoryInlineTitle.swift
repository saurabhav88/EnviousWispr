import AppKit
import SwiftUI

/// A History title renamed in place: meetings (#3147 PR4A, plan §3.6, founder 2026-11-12) and
/// imported transcripts (#4611). A pencil appears beside the title on hover and on keyboard
/// focus, the pointer becomes a text cursor, and the tooltip names the rename. Clicking the
/// title or the pencil (or the owner's Rename in More, through `beginRequest`) opens the field:
/// Return saves, Escape cancels, an empty name restores the default title.
///
/// **One owner per kind**, behind `rename`: `MeetingCoordinator.rename(meetingID:title:)` or
/// `TranscriptCoordinator.renameTitle(id:title:)`, which trim, cap at 120 characters and save.
/// Its Bool is the only success signal: the field closes only when the rename was saved; a
/// refusal or failed write keeps the typed name and offers Try again. The title shown is
/// always the stored one, never an optimistic copy. This view knows neither coordinator.
///
/// **Every control here is a sibling** of the owner's Open button, never inside it, so each
/// keeps its own click, keyboard focus and VoiceOver action.
struct HistoryInlineTitle: View {
  /// The record the title belongs to; another id resets the field.
  let identity: UUID
  /// The title shown, as the owner computes it (default title included).
  let title: String
  /// False shows the title only (no stored record to rename).
  let canRename: Bool
  /// "Rename meeting" / "Rename transcript": tooltip and VoiceOver label.
  let renameHelp: String
  /// The field's placeholder name: "Meeting name" / "Transcript name".
  let fieldLabel: String
  /// The stored custom name (nil for the default title), read when the field opens and when
  /// it saves, so a change made meanwhile is compared against the latest value.
  let storedTitle: @MainActor () -> String?
  /// Saves the typed name; true only when it was saved.
  let rename: @MainActor (String) async -> Bool
  var font: Font = .stRowTitle
  var truncation: Text.TruncationMode = .tail
  /// Set to true by the owner (Rename in More) to open the field; reset here.
  var beginRequest: Binding<Bool> = .constant(false)
  var searchQuery = ""
  /// Mirrors whether the field is open, so an owner whose surface opens on a click (the
  /// Transcripts card) can make that click save the name instead (#4611).
  var isEditing: Binding<Bool> = .constant(false)
  /// The timestamp of the click that saved by clicking away. The owner compares it with the
  /// click it is handling, so that same click never also opens the card (#4611).
  var clickAwayStamp: Binding<TimeInterval?> = .constant(nil)

  @State private var edit = HistoryTitleEdit()
  @State private var hovering = false
  @State private var pushedCursor = false
  /// Bumped when the title shows another record, so a rename that answers later leaves it alone.
  @State private var presentation = 0
  /// Watches clicks while the field is open, so a click anywhere else saves (#4611).
  @State private var clickAway = ClickAwayMonitor()
  /// The field's painted box, the area a click must hit to count as inside.
  @State private var fieldAnchor = HistoryMenuAnchorHolder()
  @Environment(\.historyClickMonitor) private var clickMonitor
  @FocusState private var fieldFocused: Bool
  @FocusState private var controlFocused: TitleControl?

  private enum TitleControl: Hashable { case title, pencil }

  var body: some View {
    Group {
      if !canRename {
        titleText(title)
      } else if edit.isEditing {
        editor(shownTitle: title)
      } else {
        idle(title)
      }
    }
    .onChange(of: beginRequest.wrappedValue) { _, requested in
      guard requested else { return }
      beginRequest.wrappedValue = false
      guard canRename else { return }
      begin()
    }
    .onDisappear { popCursor() }
    .onChange(of: edit.isEditing) { _, open in isEditing.wrappedValue = open }
    .onChange(of: identity) {
      // Another record's title: a rename still in flight finishes into the old state only.
      presentation += 1
      edit = HistoryTitleEdit()
      popCursor()
    }
  }

  private func titleText(_ title: String) -> some View {
    HistoryParagraphText.searchText(title, query: searchQuery)
      .font(font)
      .foregroundStyle(.stTextPrimary)
      .lineLimit(1)
      .truncationMode(truncation)
  }

  private func idle(_ title: String) -> some View {
    HStack(spacing: DesignSpacing.xs) {
      Button {
        begin()
      } label: {
        titleText(title)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($controlFocused, equals: .title)
      .help(Text(verbatim: renameHelp))
      .accessibilityLabel(Text(verbatim: title))
      .accessibilityHint(Text(verbatim: renameHelp))
      .onHover { inside in
        if inside { pushCursor() } else { popCursor() }
      }

      Button {
        begin()
      } label: {
        Image(systemName: "pencil")
          .font(.stHelper)
          .frame(minWidth: 22, minHeight: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .focused($controlFocused, equals: .pencil)
      .foregroundStyle(.stTextSecondary)
      .help(Text(verbatim: renameHelp))
      .accessibilityLabel(Text(verbatim: renameHelp))
      // Kept in the layout so the title never shifts; shown on hover and keyboard focus.
      .opacity(hovering || controlFocused != nil ? 1 : 0)
    }
    .onHover { hovering = $0 }
  }

  private func editor(shownTitle: String) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
      HStack(spacing: DesignSpacing.sm) {
        TextField(fieldLabel, text: $edit.draft, prompt: Text(verbatim: shownTitle))
          .font(font)
          .textFieldStyle(.plain)
          // Bound before the chrome, as every `settingsFieldChrome` field is: without it
          // `fieldFocused` drove nothing, so the field never took the keyboard (#4611).
          .focused($fieldFocused)
          .settingsFieldChrome(focused: $fieldFocused)
          .background(HistoryMenuAnchor(holder: fieldAnchor))
          .disabled(edit.phase == .saving)
          .onSubmit { commit() }
          .onExitCommand { cancel() }
          .accessibilityLabel(Text(verbatim: renameHelp))
        if edit.phase == .saving {
          ProgressView().controlSize(.small)
        }
      }
      if edit.phase == .failed {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
          Text(verbatim: Self.renameFailedLine)
            .font(.stHelper)
            .foregroundStyle(.stError)
            .fixedSize(horizontal: false, vertical: true)
          Button {
            commit()
          } label: {
            Text("Try again", comment: "Meetings: saves the meeting's new name again.")
          }
          .buttonStyle(.link)
          Button {
            cancel()
          } label: {
            Text("Cancel", comment: "EnviousMeet: keeps the meeting as it is.")
          }
          .buttonStyle(.link)
        }
      }
    }
    .onChange(of: fieldFocused) { _, focused in
      // Clicking away saves, as Return does; a failed name waits for Try again or Cancel.
      if !focused, edit.phase == .editing { commit() }
    }
    // A click on a part that takes no keyboard (the card, the page) does not move the focus,
    // so the field would stay open and the click would open the card (founder, #4611). A click
    // that starts outside the field saves when the button comes up, before the click's own
    // action runs; the owner sees `clickAwayStamp` and does not open.
    .onAppear {
      clickAway.start(monitor: clickMonitor, field: fieldAnchor) { stamp in
        guard edit.phase == .editing else { return }
        clickAwayStamp.wrappedValue = stamp
        commit()
      }
    }
    .onDisappear { clickAway.stop() }
  }

  static var renameFailedLine: String {
    String(
      localized: "The new name couldn't be saved.",
      comment:
        "Meetings: renaming a meeting failed; the typed name stays so the user can try again.")
  }

  private func begin() {
    popCursor()
    edit.begin(storedTitle: storedTitle())
    fieldFocused = true
  }

  private func cancel() {
    edit.cancel()
    if !edit.isEditing { controlFocused = .title }
  }

  private func commit() {
    switch edit.commit(storedTitle: storedTitle()) {
    case .unchanged, .busy:
      return
    case .rename(let typed):
      let save = rename
      let shown = presentation
      Task {
        let saved = await save(typed)
        guard shown == presentation else { return }
        edit.finish(saved: saved)
        if saved { controlFocused = .title } else { fieldFocused = true }
      }
    }
  }

  private func pushCursor() {
    guard !pushedCursor else { return }
    NSCursor.iBeam.push()
    pushedCursor = true
  }

  private func popCursor() {
    guard pushedCursor else { return }
    NSCursor.pop()
    pushedCursor = false
  }
}

extension HistoryInlineTitle {
  /// Whether a card holding this title may open on the click it is handling (#4611, founder):
  /// never while the field is open, and never on the release that saved by clicking away,
  /// compared by timestamp so the save finishing first cannot let that same click open it.
  @MainActor
  static func cardMayOpen(titleEditing: Bool, clickAwayStamp: TimeInterval?) -> Bool {
    guard !titleEditing else { return false }
    if let clickAwayStamp, NSApp.currentEvent?.timestamp == clickAwayStamp { return false }
    return true
  }
}

/// The inline title's edit steps (plan §3.6): Return saves, Escape cancels, an empty name
/// restores the default title, and a failed save keeps the typed name and offers Try again.
struct HistoryTitleEdit: Equatable {
  enum Phase: Equatable {
    case idle
    case editing
    /// The rename was sent; the field waits for its answer.
    case saving
    /// The rename failed; the typed name stays.
    case failed
  }

  private(set) var phase: Phase = .idle
  var draft = ""

  var isEditing: Bool { phase != .idle }

  /// Opens the field with the stored name (empty for the default title).
  mutating func begin(storedTitle: String?) {
    guard phase == .idle else { return }
    draft = storedTitle ?? ""
    phase = .editing
  }

  /// Escape: back to the shown title, nothing written. Ignored while a rename is in flight,
  /// so its answer still lands.
  mutating func cancel() {
    guard phase != .saving else { return }
    phase = .idle
    draft = ""
  }

  enum Commit: Equatable {
    /// Nothing changed (same name, or a second Return while saving): close without writing.
    case unchanged
    /// Send this name to the owner's rename; an empty name clears the title.
    case rename(String)
    /// A rename is already in flight.
    case busy
  }

  /// Return (or Try again). The owner trims and caps; this only decides whether to call.
  mutating func commit(storedTitle: String?) -> Commit {
    switch phase {
    case .idle: return .unchanged
    case .saving: return .busy
    case .editing, .failed: break
    }
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if typed == (storedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
      phase = .idle
      draft = ""
      return .unchanged
    }
    phase = .saving
    return .rename(typed)
  }

  /// The rename's answer: success closes the field, failure keeps the typed name.
  mutating func finish(saved: Bool) {
    guard phase == .saving else { return }
    if saved {
      phase = .idle
      draft = ""
    } else {
      phase = .failed
    }
  }
}

/// A click outside the rename field while it is open (#4611). Installed while the field is
/// shown and removed with it. The click itself still goes where it was aimed; `onClickAway`
/// runs first, on the button's release, so the save starts before a card treats the click as
/// Open, and a drag that starts inside the field (selecting text) never counts.
@MainActor
private final class ClickAwayMonitor {
  private var monitor: (any HistoryClickMonitoring)?
  private var token: Any?
  private var pressStartedOutside = false

  func start(
    monitor: (any HistoryClickMonitoring)?, field: HistoryMenuAnchorHolder,
    onClickAway: @escaping @MainActor (TimeInterval) -> Void
  ) {
    stop()
    guard let monitor else { return }
    self.monitor = monitor
    token = monitor.install { [weak self, weak field] event in
      guard let self else { return }
      switch event.type {
      case .leftMouseDown:
        self.pressStartedOutside = !Self.isInside(event, field: field?.view)
      case .leftMouseUp:
        if self.pressStartedOutside { onClickAway(event.timestamp) }
        self.pressStartedOutside = false
      default:
        break
      }
    }
  }

  func stop() {
    if let token { monitor?.remove(token) }
    token = nil
    monitor = nil
    pressStartedOutside = false
  }

  /// True only for a click in this field's own window, inside its painted box. Another window,
  /// a sheet or the History menu panel is outside.
  private static func isInside(_ event: NSEvent, field: NSView?) -> Bool {
    guard let field, let window = field.window, event.window === window else { return false }
    return field.bounds.contains(field.convert(event.locationInWindow, from: nil))
  }
}

/// Every left-button press and release in the process, passed on unchanged (#4611). The live
/// monitor lives in `EnviousWisprDesktopEffects` (`scripts/check-dependency-direction.sh` keeps
/// the AppKit registration there), so no test installs one on the developer's desktop.
@MainActor
package protocol HistoryClickMonitoring: AnyObject {
  /// Calls `handler` for every left mouse down and up. Returns the framework's token, or nil
  /// when AppKit refused.
  func install(_ handler: @escaping @MainActor (NSEvent) -> Void) -> Any?
  func remove(_ token: Any)
}

extension EnvironmentValues {
  /// History's click watcher, injected with the app's homes. Nil (a preview, a test): clicking
  /// away from a rename field does not save it; Return and losing focus still do.
  @Entry var historyClickMonitor: (any HistoryClickMonitoring)? = nil
}
