import AppKit
import EnviousWisprCore
import SwiftUI

/// A meeting's title, renamed in place (#3147 PR4A, plan §3.6, founder 2026-11-12): on the
/// Meetings card and the after-view header. A pencil appears beside the title on hover and on
/// keyboard focus, the pointer becomes a text cursor, and the tooltip says "Rename meeting".
/// Clicking the title or the pencil (or the owner's Rename in More, through `beginRequest`)
/// opens the field: Return saves, Escape cancels, an empty name restores the untitled label.
///
/// **One owner**: `MeetingCoordinator.rename(meetingID:title:)` trims, caps at 120 characters
/// and waits for commit settlement. Its Bool is the only success signal: the field closes only
/// when the rename was saved; a refusal or failed write keeps the typed name and offers Try
/// again. The title shown is always the record's, never an optimistic copy.
///
/// **Every control here is a sibling** of the owner's Open button, never inside it, so each
/// keeps its own click, keyboard focus and VoiceOver action.
struct MeetingInlineTitle: View {
  let meetingID: UUID
  var font: Font = .stRowTitle
  /// Set to true by the owner (Rename in More) to open the field; reset here.
  var beginRequest: Binding<Bool> = .constant(false)

  @Environment(MeetingCoordinator.self) private var meetings
  @State private var edit = MeetingAfterPresentation.TitleEdit()
  @State private var hovering = false
  @State private var pushedCursor = false
  @FocusState private var fieldFocused: Bool
  @FocusState private var controlFocused: Bool

  private typealias P = MeetingAfterPresentation

  var body: some View {
    Group {
      if let record = meetings.record(id: meetingID) {
        let card = P.card(P.CardInputs(record: record))
        if !card.canRename {
          titleText(card.title)
        } else if edit.isEditing {
          editor(record: record, shownTitle: card.title)
        } else {
          idle(card.title, storedTitle: record.title)
        }
      }
    }
    .onChange(of: beginRequest.wrappedValue) { _, requested in
      guard requested else { return }
      beginRequest.wrappedValue = false
      begin(storedTitle: meetings.record(id: meetingID)?.title)
    }
    .onDisappear { popCursor() }
  }

  private func titleText(_ title: String) -> some View {
    Text(verbatim: title)
      .font(font)
      .foregroundStyle(.stTextPrimary)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  private func idle(_ title: String, storedTitle: String?) -> some View {
    HStack(spacing: DesignSpacing.xs) {
      Button {
        begin(storedTitle: storedTitle)
      } label: {
        titleText(title)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($controlFocused)
      .help(Text(verbatim: P.renameHelp))
      .accessibilityLabel(Text(verbatim: title))
      .accessibilityHint(Text(verbatim: P.renameHelp))
      .onHover { inside in
        if inside { pushCursor() } else { popCursor() }
      }

      Button {
        begin(storedTitle: storedTitle)
      } label: {
        Image(systemName: "pencil")
          .font(.stHelper)
          .frame(minWidth: 22, minHeight: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.stTextSecondary)
      .help(Text(verbatim: P.renameHelp))
      .accessibilityLabel(Text(verbatim: P.renameHelp))
      // Kept in the layout so the title never shifts; shown on hover and keyboard focus.
      .opacity(hovering || controlFocused ? 1 : 0)
    }
    .onHover { hovering = $0 }
  }

  private func editor(record: MeetingRecord, shownTitle: String) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
      HStack(spacing: DesignSpacing.sm) {
        TextField(
          String(
            localized: "Meeting name", comment: "EnviousMeet: the rename field's placeholder."),
          text: $edit.draft,
          prompt: Text(verbatim: shownTitle)
        )
        .font(font)
        .textFieldStyle(.plain)
        .settingsFieldChrome(focused: $fieldFocused)
        .disabled(edit.phase == .saving)
        .onSubmit { commit() }
        .onExitCommand { cancel() }
        .accessibilityLabel(Text(verbatim: P.renameHelp))
        if edit.phase == .saving {
          ProgressView().controlSize(.small)
        }
      }
      if edit.phase == .failed {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
          Text(verbatim: P.renameFailedLine)
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
  }

  private func begin(storedTitle: String?) {
    popCursor()
    edit.begin(storedTitle: storedTitle)
    fieldFocused = true
  }

  private func cancel() {
    edit.cancel()
    if !edit.isEditing { controlFocused = true }
  }

  private func commit() {
    let stored = meetings.record(id: meetingID)?.title
    switch edit.commit(storedTitle: stored) {
    case .unchanged, .busy:
      return
    case .rename(let title):
      let coordinator = meetings
      let id = meetingID
      Task {
        let saved = await coordinator.rename(meetingID: id, title: title)
        edit.finish(saved: saved)
        if saved { controlFocused = true } else { fieldFocused = true }
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
