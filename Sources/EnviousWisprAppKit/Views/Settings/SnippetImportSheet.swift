import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// The Snippet Import sheet (#2997), built to the approved design
/// (`docs/feature-requests/issue-628-design/EnviousWispr Snippets.dc.html`).
///
/// The same shell as `CustomWordsImportSheet`: one observable model, one root `switch`, one
/// container-level `.animation()`. Paste, Open a file and From another app feed the same
/// review and commit path. Dismissing at any point cancels in-flight work and writes
/// nothing; a commit already started completes and is not shown.
struct SnippetImportSheet: View {
  private static let screenTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 20)),
    removal: .opacity
  )

  @State private var model: SnippetImportFlowModel
  @State private var showDiscardConfirm = false
  @Environment(\.dismiss) private var dismiss

  init(dependencies: SnippetImportFlowModel.Dependencies) {
    _model = State(initialValue: SnippetImportFlowModel(dependencies: dependencies))
  }

  var body: some View {
    // The macOS-15+ native window-close protection is a second, best-effort layer for the
    // OS-level window-close trigger only; Cancel, Escape and Done always use the local
    // dialog below on every macOS version (as `CustomWordsImportSheet` records, #1700).
    if #available(macOS 15.0, *) {
      sheetContent
        .dismissalConfirmationDialog(
          "You've entered snippets. This will discard them.",
          shouldPresent: model.hasDiscardableDraft
        ) {
          Button("Discard", role: .destructive) { model.cancel() }
          Button("Keep editing", role: .cancel) { model.keepEditingDiscardableDraft() }
        }
    } else {
      sheetContent
    }
  }

  private var sheetContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      ZStack {
        switch model.step {
        case .methodPicker:
          SnippetImportMethodPickerScreen(model: model)
            .transition(Self.screenTransition)
        case .paste:
          SnippetImportPasteScreen(model: model)
            .transition(Self.screenTransition)
        case .file:
          SnippetImportFileScreen(model: model)
            .transition(Self.screenTransition)
        case .appPicker:
          SnippetImportAppPickerScreen(model: model)
            .transition(Self.screenTransition)
        case .review:
          SnippetImportReviewScreen(model: model)
            .transition(Self.screenTransition)
        case .working(let work):
          SnippetImportWorkingScreen(work: work)
            .transition(Self.screenTransition)
        case .result(let result):
          SnippetImportResultScreen(result: result)
            .transition(Self.screenTransition)
        }
      }
      .animation(.easeInOut(duration: 0.25), value: model.step)

      footer
    }
    .padding(24)
    .frame(width: 480)
    // The footer's Cancel is not the only way out: closing the settings window or clearing
    // the sheet route dismisses without it, and an in-flight load or comparison would
    // otherwise keep running against a sheet that is gone.
    .onDisappear { model.cancel() }
    .confirmationDialog(
      "You've entered snippets. This will discard them.",
      isPresented: $showDiscardConfirm,
      titleVisibility: .visible
    ) {
      Button("Discard", role: .destructive) {
        model.cancel()
        dismiss()
      }
      Button("Keep editing", role: .cancel) { model.keepEditingDiscardableDraft() }
    }
  }

  /// Single authority for every explicit discard action (Cancel, Escape, Done).
  private func requestCancel() {
    if model.hasDiscardableDraft {
      showDiscardConfirm = true
    } else {
      model.cancel()
      dismiss()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if model.canGoBack {
        SettingsActionButton(title: "Back", isEnabled: true) { model.goBack() }
      }
      Text(title)
        .font(.title3)
        .bold()
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack {
      Spacer()
      switch model.step {
      case .result:
        // Routed through requestCancel(): a `.nothingFound`, `.nothingCompatible` or
        // `.failed` result still holds an uncommitted draft, so Done confirms first in
        // those cases; `.completed`/`.nothingApproved` proceed silently, same as before.
        // The overlaid, zero-opacity button gives Escape the same route: without it, this
        // screen has no `.cancelAction` button at all, so Escape would dismiss the system
        // sheet directly and reach `.onDisappear`'s unconfirmed cleanup, the exact bug
        // this issue is about, left open on the one screen this change touches (Codex
        // code-diff review). `.overlay` rather than a second sibling button: a sibling
        // would reserve its own layout footprint, visibly shifting Done off the trailing
        // edge (Codex, round 3). `.opacity(0)` rather than `.hidden()`: `.hidden()` views
        // cannot receive or respond to interactions at all per Apple's own documentation,
        // which would silently reintroduce the exact Escape bug this button exists to fix
        // (Codex, round 4). `.opacity` only affects rendering, not hit testing or shortcut
        // dispatch. `.accessibilityHidden(true)` keeps VoiceOver/Full Keyboard Access from
        // exposing two overlapping "Done" controls at the same location (Codex, round 6).
        // It only affects the accessibility tree, not keyboard shortcut dispatch.
        //
        // #2447 restyles the VISIBLE button only. The zero-opacity overlay below stays a
        // raw `Button` deliberately: it exists to carry `.cancelAction` and is never seen,
        // so a hover treatment on it would be decoration for a control nobody can look at,
        // and every word of the comment above describes constraints on THAT button, which
        // restyling risks quietly invalidating.
        SettingsActionButton(
          title: "Done", isEnabled: true, emphasis: .filled, shortcut: .defaultAction
        ) {
          requestCancel()
        }
        .overlay {
          Button("Done") { requestCancel() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
            // **`.opacity(0)` hides it from the EYE, not from the POINTER.** The comment
            // above records why `.hidden()` was rejected: a hidden view receives no
            // interaction, which killed shortcut dispatch. What that left behind is a fully
            // hit-testable control sitting on top of the visible one: clicks reached the
            // same action so nothing looked wrong, and the visible button's hover never
            // fired because the pointer never reached it (cloud review, #2447).
            //
            // Hit testing and shortcut dispatch are separate paths: Apple documents
            // `allowsHitTesting` as governing "hit test operations" and pointer
            // interaction, while a keyboard shortcut fires for a control "anywhere in the
            // frontmost window", which is a presence condition. This restores the pointer
            // to the button underneath while leaving Escape's route intact. Verified by
            // pressing Escape on this screen, not inferred from the two doc pages.
            .allowsHitTesting(false)
        }
      case .review:
        SettingsActionButton(title: "Cancel", isEnabled: true, shortcut: .cancelAction) {
          requestCancel()
        }
        SettingsActionButton(
          verbatimTitle: confirmTitle, isEnabled: true, emphasis: .filled, shortcut: .defaultAction
        ) {
          model.confirm()
        }
      case .methodPicker, .paste, .file, .appPicker, .working:
        SettingsActionButton(title: "Cancel", isEnabled: true, shortcut: .cancelAction) {
          requestCancel()
        }
      }
    }
  }

  /// Names the actual consequence, so Confirm is never a mystery button.
  private var confirmTitle: String {
    let count = model.approvedRows.count
    switch count {
    case 0: return "Add nothing"
    case 1: return "Add 1 snippet"
    default: return "Add \(count) snippets"
    }
  }

  private var title: String {
    switch model.step {
    case .methodPicker: return "Import snippets"
    case .paste: return "Paste snippets"
    case .file: return "Open a file"
    case .appPicker: return "From another app"
    case .review: return "Review"
    case .working(.loadingCandidates): return "Finding snippets"
    case .working(.comparing): return "Checking your list"
    case .working(.committing): return "Saving"
    case .result(.completed): return "Import complete"
    case .result(.nothingFound): return "Nothing to import"
    case .result(.nothingCompatible): return "Nothing compatible"
    case .result(.nothingApproved): return "Nothing added"
    case .result(.failed): return "Import didn't finish"
    }
  }
}

// MARK: - Method picker

private struct SnippetImportMethodPickerScreen: View {
  let model: SnippetImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Bring your snippets in from anywhere. Nothing is added until you review it.")
        .settingsReadingCopy()

      ImportMethodCard(
        icon: "doc.on.clipboard",
        title: "Paste snippets",
        subtitle: "Paste a list from anywhere: plain lines, CSV, or exported JSON."
      ) {
        model.select(.paste)
      }
      // Additive, never "restore": a snippet you already have is reported and skipped, and
      // your keyword is not touched (plan §14 Q1: the keyword is yours to set, never imported).
      ImportMethodCard(
        icon: "square.and.arrow.down",
        title: "Open a file",
        subtitle:
          "Moving Macs, or bringing your snippets back? Pick the "
          + "\(SnippetsExportAction.defaultFilename) you exported, a CSV, or a plain list. "
          + "Snippets you already have are left as they are."
      ) {
        model.select(.file)
      }
      ImportMethodCard(
        icon: "sparkles",
        title: "From another app",
        subtitle: "Bring your snippets over from another dictation app."
      ) {
        model.select(.app)
      }
    }
  }
}

// MARK: - From another app

private struct SnippetImportAppPickerScreen: View {
  let model: SnippetImportFlowModel
  /// Detection runs when this screen appears, not at launch or when the sheet opens: an
  /// installed competitor is never quietly inspected in the background, only when the user
  /// has asked to see this list (the same discipline as the Dictionary picker).
  @State private var installed: [String] = []
  @State private var didLookForApps = false

  private var registry: SnippetImportAppRegistry { .v1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Snippets you already saved in another dictation app, found on this Mac.")
        .settingsReadingCopy()

      if !didLookForApps {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Looking for apps on this Mac.").settingsReadingCopy()
        }
      } else if installed.isEmpty {
        InsetNotice(
          text:
            "No supported dictation apps found on this Mac. EnviousWispr can read snippets from \(SmartImportSupportedAppsCopy.sentence(joining: registry.displayNames))."
        )
      } else {
        ForEach(registry.adapters.filter { installed.contains($0.identifier) }, id: \.identifier) {
          adapter in
          ImportMethodCard(
            icon: "app.badge",
            title: adapter.displayName,
            subtitle: "Read your snippets from \(adapter.displayName)."
          ) {
            model.begin(with: AppSnippetImportSource(adapter: adapter))
          }
        }
      }

      // The honest shape before they commit to it: snippets come across as the other app
      // holds them, and ones you already have are skip-only. TypeWhisper entries using the
      // supported date, time or clipboard fill-ins can be imported (#3018); entries containing
      // unsupported fill-ins are counted on the review screen rather than silently dropped.
      Text(
        "Snippets you already have are left as they are. TypeWhisper entries using supported "
          + "date, time or clipboard fill-ins can be imported. Entries containing unsupported "
          + "fill-ins are left out and counted."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    .task {
      // Detached rather than a plain Task: a plain Task inherits MainActor from this view,
      // and these are disk existence checks across several locations.
      let found = await Task.detached { () -> [String] in
        SnippetImportAppRegistry.v1.adapters.filter(\.isInstalled).map(\.identifier)
      }.value
      installed = found
      didLookForApps = true
    }
  }
}

// MARK: - Paste

private struct SnippetImportPasteScreen: View {
  @Bindable var model: SnippetImportFlowModel
  @FocusState private var isEditorFocused: Bool

  /// The count belongs to the draft it was taken from. Recomputed off the main actor behind
  /// a debounce and a generation, never inline in the editor's change handler: at the
  /// ceiling a paste is 16 MB, and counting it per keystroke on the main actor would freeze
  /// the editor (plan §3.2).
  @State private var count = 0
  @State private var skipped = 0
  @State private var parseProblem: String?
  @State private var sniff: SnippetPasteSniff = .list
  @State private var isCounting = false
  @State private var countingTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Paste your snippets, then check the count before you continue.")
        .settingsReadingCopy()

      // Bound to the model, not to local state: the sheet rebuilds this screen on every
      // step change, so Back from Review would otherwise hand the user an empty editor.
      TextEditor(text: $model.pasteDraft)
        .focused($isEditorFocused)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(height: 180)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(Color.stDivider, lineWidth: 1)
        )
        .accessibilityLabel("Snippets to import")

      // The design's format hint.
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "info.circle")
          .foregroundStyle(.stAccent)
          .accessibilityHidden(true)
        Text(
          "One per line: the trigger, then =, then the text. A tab, an arrow, or a comma work too. For text on several lines, paste exported JSON or CSV, or type \\n where a line should break."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      // Shown only when the two grammars would read the text differently (plan §3.2): a
      // line carrying both a comma and an explicit separator. Hidden otherwise, so the
      // design's screen is unchanged for ordinary pastes.
      if sniff == .ambiguous {
        HStack(spacing: 10) {
          Text("Read as").font(.stHelper).foregroundStyle(.stTextSecondary)
          // `auto` shows as List, which is what `auto` resolves an ambiguous paste to.
          Picker(
            "Read as",
            selection: Binding(
              get: { model.pasteFormat == .csv ? SnippetPasteFormat.csv : .list },
              set: { model.pasteFormat = $0 })
          ) {
            Text("List").tag(SnippetPasteFormat.list)
            Text("CSV").tag(SnippetPasteFormat.csv)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
      }

      HStack {
        Text(summary)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Spacer(minLength: 0)
        // Over-limit is a refusal, not a warning: Continue would land the user on the
        // terminal failure screen, which has no Back. Block it where they can still edit.
        SettingsActionButton(
          title: "Continue",
          isEnabled: !(isCounting || count == 0 || parseProblem != nil),
          emphasis: .filled,
          shortcut: .defaultAction
        ) {
          // The same resolution the count used: the choice applies only to an ambiguous
          // paste (`PasteSnippetsImportSource.resolvedFormat`).
          model.begin(
            with: PasteSnippetsImportSource(text: model.pasteDraft, format: model.pasteFormat))
        }
      }
    }
    .onAppear {
      isEditorFocused = true
      // Back from Review returns to an existing draft, so the count has to be right on
      // arrival, not only after the next keystroke.
      recount(model.pasteDraft, format: model.pasteFormat, debounce: false)
    }
    .onChange(of: model.pasteDraft) { _, draft in
      recount(draft, format: model.pasteFormat, debounce: true)
    }
    .onChange(of: model.pasteFormat) { _, format in
      recount(model.pasteDraft, format: format, debounce: false)
    }
    .onDisappear { countingTask?.cancel() }
  }

  /// Counts OFF the main actor, keeping the parse failure rather than collapsing it to a
  /// zero count. Each edit cancels the previous count, and a result is applied only while
  /// its draft is still the current one.
  private func recount(_ draft: String, format: SnippetPasteFormat, debounce: Bool) {
    countingTask?.cancel()
    isCounting = true
    countingTask = Task {
      if debounce {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
      }
      do {
        let counted = try await Self.count(draft, format: format)
        guard !Task.isCancelled, draft == model.pasteDraft else { return }
        count = counted.count
        skipped = counted.skipped
        sniff = counted.sniff
        parseProblem = nil
        isCounting = false
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, draft == model.pasteDraft else { return }
        count = 0
        skipped = 0
        parseProblem = error.localizedDescription
        isCounting = false
      }
    }
  }

  /// The same bounded preview the import will run (byte ceiling first, then sniff, then
  /// parse), so the count can never disagree with what Continue produces.
  @concurrent private static func count(
    _ draft: String, format: SnippetPasteFormat
  ) async throws -> (count: Int, skipped: Int, sniff: SnippetPasteSniff) {
    let preview = try PasteSnippetsImportSource.preview(text: draft, choice: format)
    let skipped = preview.batch.notices.reduce(into: 0) { total, notice in
      if case .linesSkipped(let n) = notice { total += n }
    }
    return (preview.batch.candidates.count, skipped, preview.sniff)
  }

  private var summary: String {
    if isCounting { return "Counting…" }
    if let parseProblem { return parseProblem }
    if model.pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Nothing pasted yet."
    }
    if count == 0 { return "No snippets found. Each line needs a trigger and some text." }
    var line = "\(count) \(count == 1 ? "snippet" : "snippets") found"
    if skipped > 0 { line += ", \(skipped) \(skipped == 1 ? "line" : "lines") skipped" }
    return line + "."
  }
}

// MARK: - Open a file

/// Never says "restore": an import ADDS snippets you don't have and SKIPS ones you do.
private struct SnippetImportFileScreen: View {
  let model: SnippetImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "Choose the \(SnippetsExportAction.defaultFilename) you exported, a CSV with a trigger column and a text column, or a plain list. Your keyword stays as it is."
      )
      .settingsReadingCopy()

      Text("Snippets you already have are left exactly as they are.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)

      SettingsActionButton(
        title: "Choose a file", isEnabled: true, emphasis: .filled, systemImage: "folder"
      ) {
        // The panel is opened first and the file read only after a choice, so cancelling
        // reads nothing and starts no work.
        if let url = SnippetImportFilePanel.chooseFile() {
          model.begin(with: SnippetFileImportSource(url: url))
        }
      }
    }
  }
}

// MARK: - Review

private struct SnippetImportReviewScreen: View {
  let model: SnippetImportFlowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let staleNotice = model.staleNotice {
        InsetNotice(verbatim: staleNotice)
      }
      ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
        InsetNotice(verbatim: SnippetImportResultCopy.noticeMessage(for: notice))
      }

      Text(summary)
        .settingsReadingCopy()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(model.rows) { row in
            SnippetImportReviewRowView(row: row) { decision in
              model.setDecision(decision, forRow: row.id)
            }
          }
        }
      }
      .frame(maxHeight: 280)
    }
  }

  private var summary: String {
    var new = 0
    var existing = 0
    var duplicates = 0
    for row in model.rows {
      switch row.status {
      case .new: new += 1
      case .existing: existing += 1
      case .duplicateInBatch: duplicates += 1
      }
    }
    return SnippetImportResultCopy.reviewSummary(
      new: new, existing: existing, duplicates: duplicates)
  }
}

private struct SnippetImportReviewRowView: View {
  let row: SnippetImportReviewRow
  let setDecision: (SnippetImportDecision) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.trigger)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
        // One line, ellipsised, as the Snippets list does: an expansion can be a whole
        // signature, and a row that grows to fit one stops being scannable.
        Text(oneLine(row.expansion))
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .lineLimit(1)
          .truncationMode(.tail)
        if let note = row.statusNote {
          Text(note)
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
        }
      }
      Spacer(minLength: 0)

      if row.isAddable {
        Toggle(
          "Add",
          isOn: Binding(
            get: { row.decision == .add },
            set: { setDecision($0 ? .add : .skip) }
          )
        )
        .toggleStyle(.checkbox)
        .accessibilityLabel("Add \(row.trigger)")
      } else {
        Text(row.status == .duplicateInBatch ? "Skipped" : "You have this")
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  private func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
  }
}

// MARK: - Working and result

private struct SnippetImportWorkingScreen: View {
  let work: SnippetImportFlowModel.Work

  var body: some View { ImportWorkingRow(label: label) }

  private var label: String {
    switch work {
    case .loadingCandidates: return "Looking for snippets to import."
    case .comparing: return "Comparing against your existing snippets."
    case .committing: return "Saving your approved snippets."
    }
  }
}

private struct SnippetImportResultScreen: View {
  let result: SnippetImportFlowModel.Result

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(SnippetImportResultCopy.message(for: result))
        .settingsReadingCopy()
      Spacer(minLength: 0)
    }
  }

  private var icon: String {
    switch result {
    case .completed: return "checkmark.circle.fill"
    case .nothingFound, .nothingCompatible, .nothingApproved: return "info.circle"
    case .failed: return "exclamationmark.triangle"
    }
  }

  private var tint: Color {
    switch result {
    case .completed: return .stSuccess
    case .nothingFound, .nothingCompatible, .nothingApproved: return .stAccent
    case .failed: return .stWarning
    }
  }
}
