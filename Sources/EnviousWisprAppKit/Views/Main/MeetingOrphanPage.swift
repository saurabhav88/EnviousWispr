import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// A meeting row whose meeting EnviousMeet does not hold (#4586 N6): its transcript, Copy, and a
/// More menu with Paste, Share, Save as… and Delete meeting. This page owns its delete: the
/// confirmation, the work in progress and the refusal. `MeetingCoordinator.deleteOrphan` carries
/// it out only when the meeting's folder is confirmed absent; otherwise the page says why. The
/// words it delivers come from the meeting page (`deliveryText`, `paste`, `save`), read when each
/// acts.
struct MeetingOrphanPage: View {
  let meetingID: UUID
  let row: Transcript
  let neighbors: HistoryNeighbors
  let mode: FileImportCoordinator.DocumentView
  let back: () -> Void
  /// The visible words of the CURRENT row, read at delivery.
  let deliveryText: @MainActor @Sendable () -> String?
  let paste: () -> Void
  /// Save as…, given the suggested file name.
  let save: (String) -> Void

  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Environment(PermissionsService.self) private var permissions
  @Environment(HistoryMenuPresenter.self) private var historyMenu
  @State private var moreAnchor = HistoryMenuAnchorHolder()
  @State private var confirmingDelete = false
  @State private var deleting = false
  @State private var refused = false
  /// Bumped when the page goes away, so a deletion that finishes later writes nothing here.
  @State private var presentation = 0

  private typealias P = MeetingAfterPresentation

  var body: some View {
    page
      .onDisappear { presentation += 1 }
      .confirmationDialog(
        Text(HistoryMeetingAfterView.confirmationTitle(.deleteMeeting)),
        isPresented: $confirmingDelete
      ) {
        Button(role: .destructive) {
          delete()
        } label: {
          Text("Delete", comment: "EnviousMeet: confirms a deletion.")
        }
      } message: {
        Text(verbatim: HistoryMeetingAfterView.confirmationMessage(.deleteMeeting))
      }
  }

  /// The shared page header and the transcript.
  private var page: some View {
    let projection = transcripts.meetingProjection(of: row)
    let canDeliver: Bool = {
      if case .visible = projection { return true }
      return false
    }()
    let polish = HistoryTranscriptPresentation.provenance(for: row)
    // The shared page header (founder, #4611), as on a meeting EnviousMeet holds. The title is
    // not renamable: there is no meeting folder to save a name to. No version switch and no
    // player: the founder removed the switch from meetings, and there is no recording to play.
    return VStack(spacing: 0) {
      HistoryDocumentHeader(
        tab: .meetings, back: back,
        facts: HistoryDocumentFacts(
          createdAt: row.createdAt,
          length: HistoryTranscriptPresentation.footerClock(seconds: row.duration),
          speakers: MeetingsPresentation.speakers(row.speakerAnalysis),
          engine: row.backendType.displayName,
          polishModel: polish.aiPolished ? polish.polishModel : nil),
        neighbors: neighbors, showsViewRow: false, timestamps: nil
      ) {
        Text(verbatim: P.fallbackTitle)
          .font(.stDayTitle)
          .foregroundStyle(.stTextPrimary)
      } actions: {
        HStack(spacing: DesignSpacing.md) {
          // Read at the press from the live row, never this page's snapshot.
          HistoryDocumentCopyButton(
            label: HistoryDocumentCopyButton.label(mode: mode), isEnabled: canDeliver
          ) { deliveryText() }
          HistoryDocumentMoreButton(anchor: moreAnchor) {
            guard let anchor = moreAnchor.view else { return }
            historyMenu.toggle(items: orphanMoreItems(canDeliver: canDeliver), from: anchor)
          }
        }
        .fixedSize()
      } picker: {
        EmptyView()
      } switches: {
        EmptyView()
      } below: {
        if refused {
          Text(
            "This meeting's files are still on this Mac but can't be read, so it can't be deleted here.",
            comment:
              "History: Delete was refused for a meeting whose folder exists but cannot be read."
          )
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, SettingsLayout.contentH)
      .padding(.top, DesignSpacing.xs)
      .padding(.bottom, DesignSpacing.lg)
      Divider().overlay(Color.stDivider)
      ScrollView {
        Group {
          switch projection {
          case .visible(let turns, _):
            MeetingAfterTurnList(
              rowID: row.id, turns: turns, rawText: row.text,
              speakerNames: row.speakerNames ?? [:], player: nil,
              renameSuggestions: SpeakerRenameSuggestions(row: row, roster: nil),
              highlightedTurnID: nil, activeTurnID: nil,
              language: row.language, mode: mode
            )
            .equatable()
            .font(.stCardText)
          case .everythingHidden:
            Text(MeetingHistoryPresentation.everythingHiddenMessage)
          case .unavailable:
            Text(MeetingHistoryPresentation.unavailableMessage)
          }
        }
        .font(.stBody)
        .foregroundStyle(.stTextBody)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.vertical, DesignSpacing.xl)
      }
    }
  }

  /// The orphan page's More menu: Paste, Share, Save as…, then Delete meeting (Paste first, as
  /// on every History page). Each reads the CURRENT row when it acts.
  private func orphanMoreItems(canDeliver: Bool) -> [HistoryMenuItem] {
    let title = P.fallbackTitle
    return [
      .init(
        id: "paste", title: EscapeRecoveryRowPresentation.pasteLabel,
        systemImage: "arrow.right.doc.on.clipboard",
        isEnabled: !permissions.accessibilityGranted || canDeliver, kind: .action { paste() }),
      .init(
        id: "share",
        title: String(localized: "Share", comment: "EnviousMeet: shares the visible transcript."),
        systemImage: "square.and.arrow.up", isEnabled: canDeliver,
        kind: .action {
          // The text is read when the receiving app asks for it, so a sheet left open never
          // hands over lines that were deleted or hidden meanwhile.
          HistoryDelivery.share(from: moreAnchor.view) { deliveryText() }
        }),
      .init(
        id: "save",
        title: String(
          localized: "Save as…",
          comment: "History meeting: saves the transcript and notes as a text file."),
        systemImage: "square.and.arrow.down", isEnabled: canDeliver,
        kind: .action { save(title) }),
      .divider("d1"),
      .init(
        id: "delete",
        title: String(
          localized: "Delete meeting",
          comment: "EnviousMeet: removes the meeting, its audio and its transcript."),
        systemImage: "trash", isEnabled: !deleting, isDestructive: true,
        kind: .action { confirmingDelete = true }),
    ]
  }

  /// Deletes a meeting whose folder is gone. EnviousMeet carries it out only when the folder is
  /// confirmed absent; otherwise the page says why.
  private func delete() {
    confirmingDelete = false
    guard !deleting else { return }
    deleting = true
    let shown = presentation
    let id = meetingID
    Task {
      let deleted = await meetings.deleteOrphan(meetingID: id)
      guard shown == presentation else { return }
      refused = !deleted
      deleting = false
    }
  }
}
