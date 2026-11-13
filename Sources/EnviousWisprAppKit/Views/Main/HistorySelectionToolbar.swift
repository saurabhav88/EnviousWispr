import EnviousWisprCore
import SwiftUI

/// The bar shown in History's selection mode (#3147 §3.4): how many items are ticked, Select all
/// matching, and the bulk deletions with their confirmations. What a deletion left behind (items
/// skipped or failed, still ticked) is said here.
struct HistorySelectionToolbar: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  let selection: HistorySelection

  @State private var pendingKind: HistoryDeleteKind?
  /// The global Delete all history (#2807), kept from the old sidebar: every tab, text and audio.
  @State private var confirmingDeleteAll = false

  var body: some View {
    let count = selection.selectedIDs.count
    WrappingHStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(HistorySelectionCopy.selectedCount(tab: tab, count: count))
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
        Text(HistorySelectionCopy.detail(count: count, lastDeletion: selection.lastDeletion))
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      Button(action: selectAllMatching) {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Select all matching",
            comment:
              "History selection: ticks every item in this tab under its search and filters, on every page."
          ), size: .medium)
      }
      .settingsButton(.outlined, size: .medium, isEnabled: selection.isDeleting == false)
      if HistorySelectionCopy.offersRecordingsOnly(tab) {
        Button(role: .destructive) {
          pendingKind = .recordingsOnly
        } label: {
          EnviousButtonLabel(
            verbatim: HistorySelectionCopy.deleteButton(tab: tab, kind: .recordingsOnly), size: .medium)
        }
        .settingsButton(.outlined, size: .medium, isEnabled: count > 0 && selection.isDeleting == false)
      }
      Button(role: .destructive) {
        pendingKind = .textAndRecordings
      } label: {
        EnviousButtonLabel(
          verbatim: HistorySelectionCopy.deleteButton(tab: tab, kind: .textAndRecordings), size: .medium)
      }
      .settingsButton(.destructive, size: .medium, isEnabled: count > 0 && selection.isDeleting == false)
      if selection.isDeleting {
        ProgressView().controlSize(.small)
      }
      // #3147 PR2: the old sidebar's global delete lives beside the bulk deletions. "history",
      // because it is GLOBAL while this tab can be filtered or searched (#2807).
      Button(role: .destructive) {
        confirmingDeleteAll = true
      } label: {
        EnviousButtonLabel("Delete all history", size: .medium, systemImage: "trash")
      }
      .settingsButton(.outlined, size: .medium, isEnabled: selection.isDeleting == false)
    }
    .padding(12)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
    .alert(
      pendingKind.map { HistorySelectionCopy.confirmTitle(tab: tab, kind: $0, count: count) } ?? "",
      isPresented: Binding(
        get: { pendingKind != nil }, set: { if $0 == false { pendingKind = nil } }),
      presenting: pendingKind
    ) { kind in
      Button(HistorySelectionCopy.confirmButton(tab: tab, kind: kind), role: .destructive) {
        delete(kind)
      }
      Button(
        String(localized: "Cancel", comment: "History selection: keeps the selected items."),
        role: .cancel
      ) {}
    } message: { kind in
      Text(HistorySelectionCopy.confirmMessage(tab: tab, kind: kind))
    }
    .alert("Delete all history?", isPresented: $confirmingDeleteAll) {
      Button("Cancel", role: .cancel) {}
      Button("Delete all", role: .destructive) {
        selection.clear()
        // #4075 S1: admitted behind earlier History commands; a failure shows its alert.
        Task { await coordinator.deleteAll() }
      }
    } message: {
      // The coordinator owns this sentence (#2087): the global count, hidden rows included.
      Text(coordinator.deleteAllConfirmationMessage)
    }
  }

  /// Ticks every item the tab matches, from the coordinator's full list, not the drawn page.
  private func selectAllMatching() {
    selection.select(Set(coordinator.matchingHistoryItems(in: tab).map(\.id)))
  }

  private func delete(_ kind: HistoryDeleteKind) {
    pendingKind = nil
    Task { await selection.deleteSelected(kind: kind, coordinator: coordinator) }
  }
}

/// Selection mode's words as plain values: one whole sentence per count and tab (#3142).
enum HistorySelectionCopy {
  /// Imported transcripts have no recording of their own, so their tab offers only one delete.
  static func offersRecordingsOnly(_ tab: HistoryTab) -> Bool { tab != .transcripts }

  static func selectedCount(tab: HistoryTab, count: Int) -> String {
    switch (tab, count == 1) {
    case (.dictations, true):
      String(localized: "1 dictation selected", comment: "History selection: one item ticked.")
    case (.dictations, false):
      String(
        localized: "\(String(count)) dictations selected",
        comment: "History selection: how many dictations are ticked. Never 1.")
    case (.transcripts, true):
      String(localized: "1 transcript selected", comment: "History selection: one item ticked.")
    case (.transcripts, false):
      String(
        localized: "\(String(count)) transcripts selected",
        comment: "History selection: how many transcripts are ticked. Never 1.")
    case (.meetings, true):
      String(localized: "1 meeting selected", comment: "History selection: one item ticked.")
    case (.meetings, false):
      String(
        localized: "\(String(count)) meetings selected",
        comment: "History selection: how many meetings are ticked. Never 1.")
    }
  }

  /// The line under the count: what the last deletion left, or how to tick items.
  static func detail(count: Int, lastDeletion: HistorySelection.DeletionSummary?) -> String {
    if let lastDeletion, lastDeletion.kept > 0 {
      return lastDeletion.kept == 1
        ? String(
          localized: "1 item couldn't be deleted and is still selected. Try again.",
          comment: "History selection: one item of a bulk deletion was not removed.")
        : String(
          localized:
            "\(String(lastDeletion.kept)) items couldn't be deleted and are still selected. Try again.",
          comment: "History selection: how many items of a bulk deletion were not removed. Never 1."
        )
    }
    if let lastDeletion, lastDeletion.removed > 0 {
      return lastDeletion.removed == 1
        ? String(
          localized: "1 item deleted.",
          comment: "History selection: a bulk deletion removed one item.")
        : String(
          localized: "\(String(lastDeletion.removed)) items deleted.",
          comment: "History selection: how many items a bulk deletion removed. Never 1.")
    }
    return String(
      localized: "Tick items, or Shift-click for a range.",
      comment: "History selection: how to choose items.")
  }

  static func deleteButton(tab: HistoryTab, kind: HistoryDeleteKind) -> String {
    switch (tab, kind) {
    case (_, .recordingsOnly):
      String(
        localized: "Delete recordings only",
        comment: "History selection: deletes the audio, keeps the text.")
    case (.dictations, .textAndRecordings):
      String(
        localized: "Delete text and recordings",
        comment: "History selection: deletes the ticked dictations, text and audio.")
    case (.transcripts, .textAndRecordings):
      String(
        localized: "Delete transcripts",
        comment: "History selection: deletes the ticked transcripts.")
    case (.meetings, .textAndRecordings):
      String(
        localized: "Delete meetings", comment: "History selection: deletes the ticked meetings.")
    }
  }

  static func confirmButton(tab: HistoryTab, kind: HistoryDeleteKind) -> String {
    switch kind {
    case .recordingsOnly:
      String(
        localized: "Delete recordings",
        comment: "History selection: confirms deleting only the audio.")
    case .textAndRecordings:
      deleteButton(tab: tab, kind: kind)
    }
  }

  static func confirmTitle(tab: HistoryTab, kind: HistoryDeleteKind, count: Int) -> String {
    switch (tab, kind, count == 1) {
    case (.dictations, .textAndRecordings, true):
      String(localized: "Delete 1 dictation?", comment: "History selection: confirmation title.")
    case (.dictations, .textAndRecordings, false):
      String(
        localized: "Delete \(String(count)) dictations?",
        comment: "History selection: confirmation title. Never 1.")
    case (.dictations, .recordingsOnly, true):
      String(
        localized: "Delete the recording of 1 dictation?",
        comment: "History selection: confirmation title for deleting only audio.")
    case (.dictations, .recordingsOnly, false):
      String(
        localized: "Delete the recordings of \(String(count)) dictations?",
        comment: "History selection: confirmation title for deleting only audio. Never 1.")
    case (.transcripts, _, true):
      String(localized: "Delete 1 transcript?", comment: "History selection: confirmation title.")
    case (.transcripts, _, false):
      String(
        localized: "Delete \(String(count)) transcripts?",
        comment: "History selection: confirmation title. Never 1.")
    case (.meetings, .textAndRecordings, true):
      String(localized: "Delete 1 meeting?", comment: "History selection: confirmation title.")
    case (.meetings, .textAndRecordings, false):
      String(
        localized: "Delete \(String(count)) meetings?",
        comment: "History selection: confirmation title. Never 1.")
    case (.meetings, .recordingsOnly, true):
      String(
        localized: "Delete the recording of 1 meeting?",
        comment: "History selection: confirmation title for deleting only audio.")
    case (.meetings, .recordingsOnly, false):
      String(
        localized: "Delete the recordings of \(String(count)) meetings?",
        comment: "History selection: confirmation title for deleting only audio. Never 1.")
    }
  }

  static func confirmMessage(tab: HistoryTab, kind: HistoryDeleteKind) -> String {
    switch (tab, kind) {
    case (.dictations, .textAndRecordings):
      String(
        localized: "Their text and recordings are removed from this Mac. This can't be undone.",
        comment: "History selection: what deleting dictations removes.")
    case (.dictations, .recordingsOnly):
      String(
        localized: "The text stays in History. Only the audio is removed from this Mac.",
        comment: "History selection: what deleting dictation recordings removes.")
    case (.transcripts, _):
      String(
        localized:
          "They are removed from History. Your original files are never deleted. This can't be undone.",
        comment: "History selection: what deleting imported transcripts removes.")
    case (.meetings, .textAndRecordings):
      String(
        localized:
          "Their notes, transcripts, summaries and recordings are removed from this Mac. This can't be undone.",
        comment: "History selection: what deleting meetings removes.")
    case (.meetings, .recordingsOnly):
      String(
        localized:
          "Notes, transcripts and summaries stay. Only the audio is removed from this Mac.",
        comment: "History selection: what deleting meeting recordings removes.")
    }
  }
}
