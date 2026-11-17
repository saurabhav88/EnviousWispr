import EnviousWisprCore
import Observation
import SwiftUI

/// One mounted History entry's request. The app's runners own execution and the saved row.
@MainActor @Observable
final class HistoryPolishPreview {
  enum State {
    case idle, running(HistoryPolishChoice), comparing(HistoryPolishCandidate)
    case failed, stale, keeping
  }

  private(set) var state: State = .idle
  // #4609: bookkeeping no view reads; observing it re-rendered a card on every write.
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var requestID = UUID()

  var canStart: Bool {
    if case .keeping = state { return false }
    return true
  }

  func start(rowID: UUID, choice: HistoryPolishChoice, runner: HistoryRepolishRunner,
    history: TranscriptCoordinator
  ) {
    guard canStart else { return }
    let previous = task
    cancel()
    // #4609: a card drawn from catalog display data has no hydrated payload; read the verified
    // live row, at the start and again for the finished candidate.
    guard let row = history.liveHistoryRow(id: rowID) else {
      state = .stale
      return
    }
    state = .running(choice)
    let request = requestID
    task = Task { [weak self] in
      do {
        await previous?.value
        try Task.checkCancellation()
        guard self?.requestID == request else { return }
        let candidate = try await runner.candidate(for: row, choice: choice)
        guard !Task.isCancelled, let self, request == requestID else { return }
        state = history.liveHistoryRow(id: rowID).map(candidate.matches) == true
          ? .comparing(candidate) : .stale
      } catch {
        guard !Task.isCancelled, let self, request == requestID else { return }
        state = .failed
      }
    }
  }

  func keep(_ candidate: HistoryPolishCandidate, history: TranscriptCoordinator) {
    guard case .comparing = state else { return }
    state = .keeping
    let request = requestID
    task = Task { [weak self] in
      do {
        let saved = try await history.keepHistoryPolish(candidate)
        guard !Task.isCancelled, let self, request == requestID else { return }
        state = saved ? .idle : .stale
      } catch {
        guard !Task.isCancelled, let self, request == requestID else { return }
        state = .failed
      }
    }
  }

  func cancel() {
    task?.cancel()
    // Retain the draining task so a later choice waits for the lease to be returned.
    requestID = UUID()
    // #4609: every card calls this when it scrolls off screen; writing `.idle` over `.idle`
    // still notified observers and redrew the card mid-scroll.
    if case .idle = state { return }
    state = .idle
  }
}

struct HistoryPolishMenu: View {
  let title: LocalizedStringResource
  let surface: HistoryRepolishRunner.Surface
  let currentProvider: String?
  let currentModel: String?
  var currentSize: String? = nil
  var isEnabled = true
  let select: (HistoryPolishChoice) -> Void

  @Environment(HistoryRepolishRunner.self) private var runner
  @Environment(NavigationCoordinator.self) private var navigation
  @Environment(AppWindowCoordinator.self) private var appWindow

  var body: some View {
    let choices = runner.choices(surface)
    Menu {
      if choices.isEmpty {
        Text("No models are ready", comment: "History polish menu: no configured AI model can run.")
      }
      ForEach(choices, id: \.self) { choice in
        Button {
          select(choice)
        } label: {
          Text(verbatim: label(choice))
        }
        .disabled(!isEnabled)
      }
      Divider()
      Button {
        switch surface {
        case .dictation: navigation.request(.aiPolish)
        case .transcript: navigation.request(.transcribeFile)
        case .summary: navigation.request(.meetings(.summaries))
        }
        appWindow.showWindow()
      } label: {
        Text(setupTitle)
      }
    } label: {
      Label { Text(title) } icon: { Image(systemName: "sparkles") }
    }
  }

  private var setupTitle: LocalizedStringResource { Self.setupTitle(surface) }

  /// The same list as History's own More menu items (#4611): each ready model, "No models are
  /// ready" when there is none, then the setup link. `setUp` opens the surface's setup page.
  static func menuItems(
    surface: HistoryRepolishRunner.Surface, choices: [HistoryPolishChoice], currentProvider: String?,
    currentModel: String?, currentSize: String?, isEnabled: Bool,
    select: @escaping (HistoryPolishChoice) -> Void, setUp: @escaping () -> Void
  ) -> [HistoryMenuItem] {
    var items: [HistoryMenuItem] = choices.map { choice in
      .init(
        id: "polish-\(choice.provider.rawValue)-\(choice.model)-\(choice.egOneSize?.rawValue ?? "")",
        title: label(
          choice, currentProvider: currentProvider, currentModel: currentModel, currentSize: currentSize),
        isEnabled: isEnabled, kind: .action { select(choice) })
    }
    if choices.isEmpty {
      items.append(
        .init(
          id: "polish-none",
          title: String(localized: "No models are ready", comment: "History polish menu: no configured AI model can run."),
          isEnabled: false, kind: .action {}))
    }
    items += [
      .divider("polish-d"),
      .init(id: "polish-setup", title: String(localized: setupTitle(surface)), kind: .action(setUp)),
    ]
    return items
  }

  static func setupTitle(_ surface: HistoryRepolishRunner.Surface) -> LocalizedStringResource {
    switch surface {
    case .dictation:
      "Set up more models in AI Polish"
    case .transcript:
      "Set up file-cleanup models in Transcribe a File"
    case .summary:
      "Set up summary models in EnviousMeet"
    }
  }

  private func label(_ choice: HistoryPolishChoice) -> String {
    Self.label(choice, currentProvider: currentProvider, currentModel: currentModel, currentSize: currentSize)
  }

  /// A choice's menu title: the model, marked when it made the current text, and who receives
  /// the text when it leaves the Mac. Shared with History's own More menu (#4611).
  static func label(
    _ choice: HistoryPolishChoice, currentProvider: String?, currentModel: String?, currentSize: String?
  ) -> String {
    let sameSize = choice.provider != .egOne || choice.egOneSize?.rawValue == (currentSize ?? "full")
    let isCurrent = currentProvider == choice.provider.rawValue
      && currentModel == choice.model && sameSize
    let title = isCurrent ? HistoryTranscriptView.currentChoiceTitle(choice.title) : choice.title
    guard let recipient = choice.recipient else { return title }
    return String(
      localized: "\(title) · Text goes to \(recipient)",
      comment: "History model menu: %@ is the model name, second %@ is the company receiving text.")
  }
}

extension HistoryPolishChoice {
  var title: String {
    switch provider {
    case .openAI, .gemini, .claude, .ollama: model
    default: PolishSetupSurfaceCopy.engineName(provider, egOneSize: egOneSize)
    }
  }

  var recipient: String? {
    guard sendsTextOffMac else { return nil }
    switch provider {
    case .openAI: return "OpenAI"
    case .gemini: return "Google"
    case .claude: return "Anthropic"
    case .ollama: return "Ollama"
    default: return nil
    }
  }
}

/// #4611 D8: comparing a new version opens a sheet: Current and New side by side, each scrolling on
/// its own (stacked when the window is narrow), the model named in the sheet's header, Keep
/// current and Keep new at the bottom. Escape or closing the sheet keeps the current text. Used
/// by every History comparison (summary, Polish transcript with, dictation Polish again), so the
/// app compares the same way everywhere. Placed where the old inline box was; it takes no room.
struct HistoryPolishComparison: View {
  let current: String
  let new: String
  let model: String
  var title: LocalizedStringResource = LocalizedStringResource(
    "Compare versions", comment: "History: the sheet comparing the current and the new text.")
  /// The texts are summary Markdown: drawn with headings and bullets as the summary pane draws
  /// them, never with their raw markers. False draws plain text (transcripts, dictations).
  var formatted = false
  let keep: () -> Void
  let discard: () -> Void
  @State private var decided = false

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .sheet(
        isPresented: Binding(
          get: { !decided },
          set: { presented in
            // Escape, or any other way the sheet closes without a choice, keeps the current text.
            if !presented, !decided {
              decided = true
              discard()
            }
          })
      ) {
        HistoryPolishComparisonSheet(
          current: current, new: new, model: model, title: title, formatted: formatted,
          keep: {
            decided = true
            keep()
          },
          discard: {
            decided = true
            discard()
          })
      }
  }
}

private struct HistoryPolishComparisonSheet: View {
  let current: String
  let new: String
  let model: String
  let title: LocalizedStringResource
  let formatted: Bool
  let keep: () -> Void
  let discard: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
        Text(title)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
        Spacer(minLength: DesignSpacing.md)
        Text(
          "New version written with \(model)",
          comment: "History comparison sheet: which AI model wrote the new version. %@ is the model.")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
      .padding(.horizontal, DesignSpacing.xl)
      .padding(.vertical, DesignSpacing.lg)
      Divider()
      // Side by side when each column gets at least 320 points; stacked otherwise. Measured from
      // the sheet's own width (a wrapping text's ideal width is its whole unwrapped line).
      GeometryReader { geometry in
        let currentColumn = column(
          LocalizedStringResource("Current", comment: "History comparison sheet: the saved text's column."),
          text: current)
        let newColumn = column(
          LocalizedStringResource("New", comment: "History comparison sheet: the new text's column."),
          text: new)
        if geometry.size.width >= 640 {
          HStack(spacing: 0) {
            currentColumn
            Divider()
            newColumn
          }
        } else {
          VStack(spacing: 0) {
            currentColumn
            Divider()
            newColumn
          }
        }
      }
      Divider()
      HStack(spacing: DesignSpacing.md) {
        Spacer()
        Button(action: discard) {
          EnviousButtonLabel(
            LocalizedStringResource("Keep current", comment: "History comparison: keeps the saved text."),
            size: .medium)
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true)
        .keyboardShortcut(.cancelAction)
        Button(action: keep) {
          EnviousButtonLabel(
            LocalizedStringResource("Keep new", comment: "History comparison: saves the new text."),
            size: .medium)
        }
        .settingsButton(.filled, size: .medium, isEnabled: true)
      }
      .padding(.horizontal, DesignSpacing.xl)
      .padding(.vertical, DesignSpacing.lg)
    }
    // A sheet takes its content's size: up to 860 points, never wider than the window it covers;
    // the columns stack when that leaves them too little room.
    .frame(width: Self.width, height: 540)
    .background(Color.stSectionBg)
  }

  /// The window's width less a margin, at most 860 points.
  private static var width: CGFloat {
    let window = NSApp.keyWindow?.contentLayoutRect.width ?? 860
    return max(360, min(860, window - 40))
  }

  private func column(_ heading: LocalizedStringResource, text: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(heading)
        .font(.stSectionHeader)
        .textCase(.uppercase)
        .tracking(0.6)
        .foregroundStyle(.stAccent)
        .padding(.horizontal, DesignSpacing.xl)
        .padding(.vertical, DesignSpacing.md)
      Divider()
      ScrollView {
        Group {
          if formatted {
            MeetingReadableSummary(blocks: HistoryMeetingAfterView.readableBlocks(text))
          } else {
            Text(verbatim: text)
              .font(.stCardText)
              .foregroundStyle(.stTextBody)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.xl)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(heading))
  }
}

struct HistoryPolishProgress: View {
  let title: LocalizedStringResource
  var cancel: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: DesignSpacing.md) {
      ProgressView().controlSize(.small).accessibilityHidden(true)
      Text(title).font(.stBody)
      Spacer()
      if let cancel {
        Button("Cancel", action: cancel)
          .settingsButton(.quiet, size: .medium, isEnabled: true)
      }
    }
    .padding(DesignSpacing.xl)
    .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: DesignRadius.lg))
  }
}

struct HistoryPolishPreviewContent: View {
  let preview: HistoryPolishPreview
  @Environment(TranscriptCoordinator.self) private var history

  var body: some View {
    switch preview.state {
    case .idle: EmptyView()
    case .running(let choice):
      HistoryPolishProgress(
        title: "Polishing again with \(choice.title)…", cancel: preview.cancel)
    case .comparing(let candidate):
      HistoryPolishComparison(
        current: candidate.comparisonCurrentText ?? candidate.base.historyText,
        new: candidate.comparisonNewText ?? candidate.text,
        model: HistoryPolishChoice(
          provider: candidate.provider, model: candidate.model, egOneSize: candidate.egOneSize).title,
        keep: { preview.keep(candidate, history: history) }, discard: preview.cancel)
    case .keeping: HistoryPolishProgress(title: "Saving…")
    case .failed:
      polishNotice(
        title: String(
          localized: "Couldn't finish polishing.",
          comment: "History: polishing again failed; title of the warning notice."))
    case .stale:
      polishNotice(
        title: String(
          localized: "The saved text changed.",
          comment: "History: the text changed while polishing again; title of the warning notice."))
    }
  }

  /// A failed or stale polish: the same warning box as a failed meeting summary, with Dismiss.
  private func polishNotice(title: String) -> some View {
    InsetNotice(
      verbatim: String(
        localized: "Open More actions and choose a model to try again.",
        comment: "History: under a failed polish; says how to try polishing again."),
      title: title, systemImage: "exclamationmark.triangle", tint: .stWarning
    ) {
      Button(action: preview.cancel) {
        EnviousButtonLabel(
          LocalizedStringResource(
            "Dismiss", comment: "History: hides the failed polish message."),
          size: .medium)
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
    }
  }
}
