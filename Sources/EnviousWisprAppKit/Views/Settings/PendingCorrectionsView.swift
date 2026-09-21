import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

// MARK: - Learn from my edits: the Settings row's presentation (#996 §3.9)

/// What the "Learn from my edits" row shows, derived ONCE from the step 7 arm
/// selection and injected into the view. The row never reads Apple
/// Intelligence availability, the OS version or the qualification table
/// itself: a second read could disagree with the one the watcher acts on, and
/// then Settings would promise a feature the pipeline refuses (or the reverse).
///
/// Immutable on purpose. It is a picture of one selection result; a new
/// selection is a new value from the composition root (5h), not a mutation.
struct LearnFromEditsSettingsPresentation: Equatable, Sendable {
  /// Whether the toggle can be operated. A disabled row still shows the
  /// user's stored choice; it only says the feature cannot run on this Mac now.
  let isEnabled: Bool
  /// The one-line reason under the row when it is disabled; nil when enabled.
  let secondaryLine: String?

  /// §3.9, verbatim. Replaces "Edits stay on this Mac", which stopped being
  /// true the moment a remembered word could reach the user's cloud polish
  /// provider through `CustomVocabularyFormatter`.
  static let rowCopy =
    "When you fix a word in text EnviousWispr just pasted, it asks whether to remember the correction. "
    + "Suggestions you don't answer wait in Dictionary → Pending. "
    + "Remembered words work like your other custom words, including in cloud polish if you use it. "
    + "Nothing is sent to Envious Labs."

  init(selection: CorrectionJudgeArmSelection) {
    switch selection {
    case .arm:
      isEnabled = true
      secondaryLine = nil
    case .unavailable(.noQualifiedArm):
      isEnabled = false
      secondaryLine = "Not available on this version of macOS yet"
    case .unavailable(.afmUnavailableNoRulesFallback):
      isEnabled = false
      secondaryLine = "Turn on Apple Intelligence in System Settings to get suggestions"
    }
  }

  /// Before the composition root supplies a selection, the row is disabled:
  /// an unmeasured build has no qualified arm (`CorrectionJudgeArmSelection
  /// .qualified` is empty), and "not composed yet" must never read as "on".
  static let unwired = LearnFromEditsSettingsPresentation(selection: .unavailable(.noQualifiedArm))
}

private struct LearnFromEditsPresentationKey: EnvironmentKey {
  static let defaultValue = LearnFromEditsSettingsPresentation.unwired
}

/// Resolves a proposal's `sourceBundleID` to the name a person knows the app
/// by. The default knows nothing, and a row then shows its time alone rather
/// than a raw bundle identifier or an invented "Unknown app". Composition
/// (the real lookup) is 5h's.
private struct PendingSourceAppNameKey: EnvironmentKey {
  static let defaultValue: @MainActor (String) -> String? = { _ in nil }
}

extension EnvironmentValues {
  var learnFromEditsPresentation: LearnFromEditsSettingsPresentation {
    get { self[LearnFromEditsPresentationKey.self] }
    set { self[LearnFromEditsPresentationKey.self] = newValue }
  }

  var pendingSourceAppName: @MainActor (String) -> String? {
    get { self[PendingSourceAppNameKey.self] }
    set { self[PendingSourceAppNameKey.self] = newValue }
  }
}

// MARK: - Pending tab presentation (#996 §3.1 step 11)

/// What the Pending tab draws, computed from the coordinator's live ledger at
/// the moment the view asks. Pure: the view hands it the ledger state, the
/// open proposals, the toggle and a clock, and gets back one of five contents
/// and the badge count. Nothing here is stored; there is exactly one proposal
/// list and it lives in `CorrectionProposalStore`.
enum PendingCorrectionsPresentation {
  struct Row: Equatable, Identifiable {
    let id: UUID
    let original: String
    let corrected: String
    let state: CorrectionCardState
    /// The app the fix was typed in, when the resolver knows its name.
    let sourceApp: String?
    /// "2 hours ago", "yesterday": relative to the clock the view was given.
    let relativeTime: String
    /// `accepting`: an attempt is in flight (or awaits reconciliation), so the
    /// buttons are disabled; the row stays visible and counted.
    let isResolving: Bool
  }

  enum Content: Equatable {
    /// No coordinator in the environment: the feature is not composed in this
    /// build path (previews, an unwired Settings window). Not an empty ledger.
    case notComposed
    /// The toggle is off. The records are kept; they are simply not shown.
    case hidden
    /// The ledger could not be trusted; nothing can be resolved from here.
    case untrusted(CorrectionLedgerUntrustedKind)
    /// A trusted ledger with nothing open.
    case empty
    case rows([Row])
  }

  /// §3.1 step 11, verbatim.
  static let emptyCopy =
    "Nothing waiting. When you fix a word EnviousWispr just pasted, the suggestion shows here if you don't answer it right away."

  /// The mock's page description (founder-approved mock, 19 Sep 2026).
  static let description = "Spelling fixes from your edits. Nothing is saved until you accept."

  /// The two storage banners, the words file's approved sentences with the
  /// noun swapped (founder 2026-09-20, "B": copy the custom-words process).
  /// `WordsLoadFailureBanner` in `YourWordsView.swift` holds the originals.
  ///
  /// Shown once after a launch that found a damaged file, moved it aside and
  /// started fresh (`CorrectionProposalCoordinator.recoveredAtLaunch`).
  static let recoveredCopy =
    "Your waiting suggestions file was damaged and moved aside for recovery. EnviousWispr started with an empty list."
  /// The file could not be read (permissions, I/O); nothing was moved and
  /// nothing can be resolved here.
  static let unreadableCopy =
    "Your waiting suggestions couldn't be read this time. Nothing was changed or deleted. Try relaunching."
  /// A save (or a recovery move) landed but could not be confirmed durable:
  /// the file may carry the change, so this line claims nothing about the
  /// data, only that confirmation is missing. The next Accept, Reject or
  /// launch retries the confirmation. Copy approved by the founder 2026-09-20.
  static let durabilityCopy =
    "Your latest change to waiting suggestions couldn't be confirmed as saved. Try relaunching."

  /// The sentence for an untrusted ledger, by what is true of each kind.
  static func untrustedCopy(for kind: CorrectionLedgerUntrustedKind) -> String {
    switch kind {
    case .durabilityUnconfirmed: return durabilityCopy
    // The damaged kinds reach the tab only when the move aside failed (the
    // archive name was taken or the directory refused the rename); the file
    // was left exactly as found, so the unreadable sentence is true of them.
    case .unreadable, .corrupt, .unsupportedVersion, .unknownStatus: return unreadableCopy
    }
  }

  static func content(
    ledgerState: CorrectionProposalCoordinator.LedgerState?,
    proposals: [CorrectionProposal],
    learnFromEdits: Bool,
    now: Date,
    sourceAppName: (String) -> String?,
    cardState: (CorrectionProposal) -> CorrectionCardState
  ) -> Content {
    guard let ledgerState else { return .notComposed }
    guard learnFromEdits else { return .hidden }
    switch ledgerState {
    case .notLoaded: return .notComposed
    case .untrusted(let kind): return .untrusted(kind)
    case .ready: break
    }
    guard !proposals.isEmpty else { return .empty }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .named
    return .rows(
      proposals.map { proposal in
        Row(
          id: proposal.id, original: proposal.original, corrected: proposal.corrected,
          state: cardState(proposal),
          sourceApp: proposal.sourceBundleID.flatMap(sourceAppName),
          relativeTime: formatter.localizedString(for: proposal.createdAt, relativeTo: now),
          isResolving: proposal.status == .accepting)
      })
  }

  /// The rail badge: open proposals (`pending` AND `accepting`) on a trusted
  /// ledger, hidden only at zero (§3.1 step 11). Independent of row
  /// visibility: with the toggle off the rows are not drawn but the count is
  /// still true, and it is what tells the person there is something to see
  /// when they turn it back on. Untrusted or not composed has no trustworthy
  /// count and draws none.
  static func badgeCount(ledgerState: CorrectionProposalCoordinator.LedgerState?, proposals: [CorrectionProposal]) -> Int {
    guard ledgerState == .ready else { return 0 }
    return proposals.count
  }

  /// What a row says after a resolution that did not end the proposal. Only
  /// approved copy: plan §3.1 step 10's "Couldn't save" for every refusal
  /// (its "That sound-alike already belongs to <word>" needs the owner's
  /// name, which `ResolveOutcome` does not carry; until it does, the generic
  /// line is the truthful one), and the card's "Saved, but couldn't record it".
  static func notice(for outcome: CorrectionProposalCoordinator.ResolveOutcome) -> String? {
    switch outcome {
    case .accepted, .rejected, .alreadyResolved, .unknownProposal, .stalePresentation, .inProgress:
      return nil
    case .refused, .ledgerUnavailable:
      return "Couldn\u{2019}t save."
    case .landedButUnrecorded:
      return "Saved, but couldn\u{2019}t record it."
    }
  }
}

// MARK: - The tab

/// Dictionary → Pending (#996 §3.1 step 11): every open proposal as a list
/// row with the overlay card's content vocabulary (mishearing, arrow, correct
/// word, the shared state line) in the Settings palette, plus where and when,
/// and the same two decisions. Both buttons call ONE thing,
/// `CorrectionProposalCoordinator.resolve(id:_:surface: .pending)`; the row is
/// redrawn from the ledger the coordinator's revision then invalidates, never
/// removed optimistically.
struct PendingCorrectionsView: View {
  @Environment(CorrectionProposalCoordinator.self) private var coordinator: CorrectionProposalCoordinator?
  @Environment(SettingsManager.self) private var settings
  @Environment(\.pendingSourceAppName) private var sourceAppName
  /// A notice under the row whose last resolution did not end it.
  @State private var notices: [UUID: String] = [:]

  var body: some View {
    BrandedPanel(
      icon: "pencil.and.list.clipboard",
      header: DictionaryTab.pending.label,
      description: PendingCorrectionsPresentation.description
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if coordinator?.recoveredAtLaunch != nil {
          banner(PendingCorrectionsPresentation.recoveredCopy)
        }
        content(Self.presentation(coordinator: coordinator, settings: settings, sourceAppName: sourceAppName))
      }
    }
  }

  /// The rail badge, from the same coordinator reads as the rows.
  static func badge(coordinator: CorrectionProposalCoordinator?) -> Int {
    PendingCorrectionsPresentation.badgeCount(
      ledgerState: coordinator?.ledgerState, proposals: coordinator?.openProposalsNewestFirst ?? [])
  }

  /// One computation for the tab's content.
  static func presentation(
    coordinator: CorrectionProposalCoordinator?, settings: SettingsManager,
    sourceAppName: (String) -> String?, now: Date = Date()
  ) -> PendingCorrectionsPresentation.Content {
    PendingCorrectionsPresentation.content(
      ledgerState: coordinator?.ledgerState,
      proposals: coordinator?.openProposalsNewestFirst ?? [],
      learnFromEdits: settings.learnFromEdits,
      now: now,
      sourceAppName: sourceAppName,
      cardState: { coordinator?.cardState(for: $0) ?? .newWord })
  }

  @ViewBuilder
  private func content(_ content: PendingCorrectionsPresentation.Content) -> some View {
    switch content {
    case .notComposed, .hidden:
      // Hidden draws nothing rather than the empty-state sentence: "nothing
      // waiting" would be a claim about records that are merely not shown.
      EmptyView()
    case .untrusted(let kind):
      banner(PendingCorrectionsPresentation.untrustedCopy(for: kind))
    case .empty:
      emptyState
    case .rows(let rows):
      VStack(alignment: .leading, spacing: 12) {
        ForEach(rows) { row in
          PendingCorrectionRow(
            row: row,
            notice: notices[row.id],
            onReject: { resolve(row.id, .reject) },
            onAccept: { resolve(row.id, .accept) })
        }
      }
    }
  }

  private func resolve(_ id: UUID, _ decision: CorrectionProposalDecision) {
    guard let coordinator else { return }
    let outcome = coordinator.resolve(id: id, decision, surface: .pending)
    notices[id] = PendingCorrectionsPresentation.notice(for: outcome)
  }

  private var emptyState: some View {
    Text(PendingCorrectionsPresentation.emptyCopy)
      .settingsReadingCopy()
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 20)
      .padding(.vertical, 34)
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(Color.stDivider, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          .allowsHitTesting(false)
      )
  }

  /// `WordsLoadFailureBanner`'s shape, the warning palette.
  private func banner(_ message: String) -> some View {
    HStack(spacing: 9) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)
      Text(message)
        .font(.stHelper)
        .foregroundStyle(.stTextBody)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stWarningSoft, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stWarning.opacity(0.25), lineWidth: 1)
        .allowsHitTesting(false)
    )
  }
}

/// One proposal, in the mock's Settings list-row shape: the pair at 20 pt on
/// the left, the meta line under it, the two buttons on the right; stacks at
/// narrow widths.
private struct PendingCorrectionRow: View {
  let row: PendingCorrectionsPresentation.Row
  let notice: String?
  let onReject: () -> Void
  let onAccept: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 14) {
          words
          Spacer(minLength: 8)
          actions
        }
        VStack(alignment: .leading, spacing: 10) {
          words
          actions
        }
      }
      if let notice {
        Text(notice)
          .font(.stHelper)
          .foregroundStyle(.stWarning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.stPageBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        .allowsHitTesting(false)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(row.original) corrected to \(row.corrected). \(stateLine.lead), \(stateLine.emphasis).")
  }

  private var stateLine: (lead: String, emphasis: String) {
    CorrectionProposalCardCopy.stateLine(for: row.state)
  }

  private var words: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .lastTextBaseline, spacing: 8) {
        Text(row.original)
          .font(.system(size: 20))
          .foregroundStyle(.stTextSecondary)
        Text("\u{2192}")
          .font(.system(size: 16))
          .foregroundStyle(.stTextSecondary)
          .accessibilityHidden(true)
        Text(row.corrected)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.stTextPrimary)
      }
      .lineLimit(1)
      .truncationMode(.middle)
      meta
    }
  }

  /// "Already in your words · **adds the mishearing to it** · Slack · 2 hours ago"
  private var meta: some View {
    var line =
      Text(stateLine.lead + " \u{00B7} ").foregroundColor(.stTextSecondary)
      + Text(stateLine.emphasis).fontWeight(.semibold).foregroundColor(.stTextPrimary)
    if let app = row.sourceApp {
      line = line + Text(" \u{00B7} " + app).foregroundColor(.stTextSecondary)
    }
    line = line + Text(" \u{00B7} " + row.relativeTime).foregroundColor(.stTextSecondary)
    return line
      .font(.system(size: 13))
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var actions: some View {
    HStack(spacing: 8) {
      SettingsActionButton(
        title: CorrectionProposalCardCopy.reject, isEnabled: !row.isResolving,
        emphasis: .quiet, shape: .roundedRect, size: .medium, action: onReject
      )
      .accessibilityLabel("Reject: don't learn \(row.corrected)")
      SettingsActionButton(
        title: CorrectionProposalCardCopy.accept, isEnabled: !row.isResolving,
        emphasis: .filled, shape: .roundedRect, size: .medium, action: onAccept
      )
      .accessibilityLabel("Accept: learn \(row.corrected)")
    }
    .fixedSize()
  }
}
