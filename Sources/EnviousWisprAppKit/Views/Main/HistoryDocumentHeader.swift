import AppKit
import EnviousWisprCore
import SwiftUI

/// What a History page header says about its item (#4611 page header): quiet facts on the left
/// of the facts row, the speech engine and polish model on the right. Nothing else: the founder
/// turned down a details popover that repeated these.
struct HistoryDocumentFacts {
  /// Why the item has nothing to play, as a quiet mark with its sentence on hover.
  struct Unplayable {
    let label: LocalizedStringResource
    let reason: String
  }

  let createdAt: Date
  /// What is still happening (a meeting that is not ready yet); nil when done.
  var status: String? = nil
  /// "1:18" or "49:41".
  var length: String? = nil
  /// "2 speakers".
  var speakers: String? = nil
  /// Recording deleted (the meeting page); nil while it plays. The transcript page says why in
  /// its player card instead (#4611 T7).
  var unplayable: Unplayable? = nil
  /// The speech engine that wrote the words shown.
  var engine: String? = nil
  /// Only from real polish provenance (polished text present and a model recorded).
  var polishModel: String? = nil
}

/// The one header of History's transcript page and meeting page (founder, #4611): the way back
/// and the actions, the title, the facts row, then the view picker and Timestamps.
///
/// Each page keeps its own actions and state; this view only lays them out, so both pages read
/// the same and a change to the layout lands on both.
struct HistoryDocumentHeader<
  Title: View, Actions: View, Picker: View, Switches: View, Below: View
>: View {
  let tab: HistoryTab
  /// nil in the transcript's own window, which has no list to go back to.
  let back: (() -> Void)?
  let facts: HistoryDocumentFacts
  /// Previous and next in the list the page was opened from (founder, #4611: "like an email
  /// inbox"). Not shown in the transcript's own window.
  let neighbors: HistoryNeighbors
  /// False hides the picker row (nothing to choose and no times to hide).
  let showsViewRow: Bool
  /// nil when the words have no times.
  let timestamps: Binding<Bool>?
  /// #4611 D9 (meeting page): previous and next sit at the right, before the actions, after a
  /// thin divider; the way back stands alone on the left.
  var trailingNavigation = false
  /// #4611 D9 (meeting page, and the transcript page with two or more speakers): drawn in place
  /// of the speakers fact ("3 speakers" that opens who spoke); nil keeps the plain fact.
  var speakersAccessory: AnyView? = nil
  /// #4611 D9 (meeting page): the speech engine as a small chip instead of plain text.
  var engineChip = false
  /// #4611 D9 (meeting page, founder 2026-11-17): the engine right after the speakers as a small
  /// outlined label, instead of at the right of the facts row.
  var engineInline = false
  /// #4611 T2 (transcript page): the polish model as a chip too, and both chips right after the
  /// facts instead of at the far right.
  var polishChip = false
  @ViewBuilder let title: () -> Title
  @ViewBuilder let actions: () -> Actions
  @ViewBuilder let picker: () -> Picker
  /// More switches beside Timestamps (the meeting page's Follow playback).
  @ViewBuilder let switches: () -> Switches
  @ViewBuilder let below: () -> Below

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HStack(alignment: .center, spacing: DesignSpacing.lg) {
        if let back { HistoryDestinationBar(tab: tab, close: back) }
        if neighbors.inList, !trailingNavigation { HistoryNeighborButtons(neighbors: neighbors) }
        Spacer(minLength: 0)
        if neighbors.inList, trailingNavigation {
          HistoryNeighborButtons(neighbors: neighbors)
          Rectangle()
            .fill(Color.stDivider)
            .frame(width: 1, height: 20)
            .accessibilityHidden(true)
        }
        actions()
          .fixedSize()
      }
      title()
        .frame(maxWidth: .infinity, alignment: .leading)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.lg) {
          leftFacts
          if !polishChip { Spacer(minLength: 0) }
          rightFacts
          if polishChip { Spacer(minLength: 0) }
        }
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
          leftFacts
          rightFacts
        }
      }
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      if showsViewRow {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: DesignSpacing.lg) {
            picker()
            Spacer(minLength: 0)
            switchesRow
          }
          VStack(alignment: .leading, spacing: DesignSpacing.md) {
            picker()
            switchesRow
          }
        }
      }
      below()
    }
  }

  // MARK: - Facts

  private var leftFacts: some View {
    WrappingHStack(spacing: DesignSpacing.sm) {
      Text(facts.createdAt, format: .dateTime.month(.abbreviated).day().year())
      HistoryFooterDot()
      Text(facts.createdAt, format: .dateTime.hour().minute())
      if let status = facts.status {
        HistoryFooterDot()
        Text(verbatim: status)
      }
      if let length = facts.length {
        HistoryFooterDot()
        Text(verbatim: length).monospacedDigit()
      }
      if let speakersAccessory {
        HistoryFooterDot()
        speakersAccessory
      } else if let speakers = facts.speakers {
        HistoryFooterDot()
        Text(verbatim: speakers)
      }
      if let unplayable = facts.unplayable {
        HistoryFooterDot()
        HistoryUnplayableMark(label: unplayable.label, reason: unplayable.reason)
      }
      // #4611 D9 (founder 2026-11-17, the mock): on the meeting page the engine sits right after
      // the speakers as a small outlined label.
      if engineInline, let engine = facts.engine {
        Text(verbatim: engine)
          .font(.stHelper)
          .foregroundStyle(.stTextBody)
          .padding(.horizontal, DesignSpacing.md)
          .padding(.vertical, DesignSpacing.xxs)
          .overlay(Capsule().strokeBorder(Color.stDivider, lineWidth: 1))
          .padding(.leading, DesignSpacing.sm)
          .accessibilityLabel(
            Text(
              "Speech engine: \(engine)",
              comment: "History page header, VoiceOver: the speech engine that wrote the words. %@ is its name."))
      }
    }
  }

  private var rightFacts: some View {
    HStack(spacing: DesignSpacing.sm) {
      if let engine = facts.engine, !engineInline {
        HStack(spacing: DesignSpacing.xxs) {
          Image(systemName: "waveform").accessibilityHidden(true)
          Text(verbatim: engine)
        }
        .modifier(EngineChip(on: engineChip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          Text(
            "Speech engine: \(engine)",
            comment: "History page header, VoiceOver: the speech engine that wrote the words. %@ is its name."))
      }
      if let model = facts.polishModel {
        if facts.engine != nil, !engineInline, !polishChip { HistoryFooterDot() }
        HStack(spacing: DesignSpacing.xxs) {
          Image(systemName: "sparkles").accessibilityHidden(true)
          Text(verbatim: model)
        }
        .modifier(EngineChip(on: polishChip))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          Text(
            "AI Polished with \(model)",
            comment: "History transcript header, VoiceOver: AI polish rewrote this text. %@ is the model name."))
      }
    }
    .fixedSize()
  }

  // MARK: - View row

  private var switchesRow: some View {
    HStack(spacing: DesignSpacing.xl) {
      switches()
      timestampsSwitch
    }
    .fixedSize()
  }

  @ViewBuilder private var timestampsSwitch: some View {
    if let timestamps {
      Toggle(isOn: timestamps) {
        Text(
          "Timestamps",
          comment: "History transcript and meeting pages: shows or hides each turn's start time.")
          .font(.stRowLabel)
      }
      .toggleStyle(BrandedToggleStyle(onColor: .stAccentSolid))
      .fixedSize()
    }
  }
}

/// #4611 D9: the meeting page draws the engine as a small chip.
private struct EngineChip: ViewModifier {
  let on: Bool

  func body(content: Content) -> some View {
    if on {
      content.historyChip(tint: .stTextSecondary, fill: Color.stTextSecondary.opacity(0.14))
    } else {
      content
    }
  }
}

/// The item above and below the open one in its History list, newest first. A nil step is the
/// end of the list (its button shows disabled).
struct HistoryNeighbors {
  /// False in the transcript's own window: it was opened for one item, with no list behind it.
  var inList = false
  /// The newer item, above in the list.
  var previous: (() -> Void)? = nil
  /// The older item, below in the list.
  var next: (() -> Void)? = nil

  static var none: HistoryNeighbors { HistoryNeighbors() }
}

/// Left and right arrows beside the way back (founder, #4611). The Left and Right arrow keys
/// step too, while this page's window has the keyboard and no text field with words in it
/// (rename, notes) holds the keyboard.
private struct HistoryNeighborButtons: View {
  let neighbors: HistoryNeighbors
  @State private var keys = HistoryNeighborKeys()
  @Environment(\.settingsKeyMonitor) private var monitor

  var body: some View {
    HStack(spacing: DesignSpacing.xs) {
      button(
        symbol: "chevron.left", step: neighbors.previous,
        label: String(
          localized: "Previous", comment: "History page header: opens the newer item above this one in the list."))
      button(
        symbol: "chevron.right", step: neighbors.next,
        label: String(
          localized: "Next", comment: "History page header: opens the older item below this one in the list."))
    }
    .fixedSize()
    // Hands the current steps to the keys on every update, so a key never opens a stale item.
    .background(HistoryWindowReader(keys: keys, previous: neighbors.previous, next: neighbors.next))
    .onAppear { keys.start(monitor) }
    .onDisappear { keys.stop() }
  }

  private func button(symbol: String, step: (() -> Void)?, label: String) -> some View {
    Button {
      step?()
    } label: {
      Image(systemName: symbol)
        .fontWeight(.semibold)
        .frame(width: 16, height: 16)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: step != nil)
    .help(Text(verbatim: label))
    .accessibilityLabel(Text(verbatim: label))
  }
}

/// The Left and Right arrow keys for `HistoryNeighborButtons`, through the injected key monitor
/// (`SettingsKeyMonitoring`; only `EnviousWisprDesktopEffects` installs the real one): a
/// plain-arrow `keyboardShortcut` would run before a text field and steal its cursor keys.
@MainActor
private final class HistoryNeighborKeys {
  weak var window: NSWindow?
  var previous: (() -> Void)?
  var next: (() -> Void)?
  private var installed: (monitor: any SettingsKeyMonitoring, token: Any)?

  /// No monitor (a preview or test): the buttons still work, the keys do not.
  func start(_ monitor: (any SettingsKeyMonitoring)?) {
    guard installed == nil, let monitor else { return }
    let token = monitor.installConsuming { [weak self] event in
      guard let self else { return false }
      let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
      return self.handle(key: event.keyCode, plain: plain, windowNumber: event.windowNumber)
    }
    if let token { installed = (monitor, token) }
  }

  func stop() {
    if let installed { installed.monitor.remove(installed.token) }
    installed = nil
  }

  /// A text field with words in it keeps its cursor keys (rename, notes). An empty one does
  /// not: the sidebar's Search settings box often holds the keyboard when the page opens, and
  /// the list's search box can keep it after the list is gone (founder, #4611: the first
  /// presses did nothing).
  /// A focused control that moves with the arrows keeps them too: the playback slider, a
  /// stepper, a segmented control, a list (Codex review, #4611).
  /// A multi-line editor that is not a one-line field's editor (the notes editor) keeps them even
  /// when empty: Write notes opens it empty (#4611 D16).
  private static func isTyping(in window: NSWindow) -> Bool {
    switch window.firstResponder {
    case let text as NSTextView where !text.isFieldEditor:
      return text.superview != nil
    case let text as NSText:
      return text.superview != nil && !text.string.isEmpty
    case is NSSlider, is NSStepper, is NSSegmentedControl, is NSTableView, is NSCollectionView:
      return true
    default:
      return false
    }
  }

  private func handle(key: UInt16, plain: Bool, windowNumber: Int) -> Bool {
    guard plain, let window, window.windowNumber == windowNumber, window.isKeyWindow,
      !Self.isTyping(in: window)
    else { return false }
    switch key {
    case 123: previous?(); return previous != nil
    case 124: next?(); return next != nil
    default: return false
    }
  }
}

/// Reports the window the arrows sit in, so the key monitor answers only there, and the
/// current steps.
private struct HistoryWindowReader: NSViewRepresentable {
  let keys: HistoryNeighborKeys
  let previous: (() -> Void)?
  let next: (() -> Void)?

  func makeNSView(context: Context) -> Reader {
    let view = Reader()
    view.keys = keys
    return view
  }

  func updateNSView(_ view: Reader, context: Context) {
    view.keys = keys
    keys.previous = previous
    keys.next = next
  }

  final class Reader: NSView {
    var keys: HistoryNeighborKeys?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      keys?.window = window
    }
  }
}

/// The page header's Copy: an icon and its label, reading the CURRENT text when pressed, then
/// "Copied" with a checkmark for two seconds (`HistoryCopy`).
struct HistoryDocumentCopyButton: View {
  let label: String
  let isEnabled: Bool
  let text: () -> String?
  @State private var copiedAt: Date?

  var body: some View {
    let copy = TranscribeFileExport.copyButtonPresentation(
      label: label, copiedAt: copiedAt, now: Date(),
      holdSeconds: TranscribeFileExport.copiedHoldSeconds)
    Button {
      HistoryCopy.press(text(), copiedAt: $copiedAt)
    } label: {
      EnviousButtonLabel(verbatim: copy.title, size: .medium, systemImage: copy.systemImage)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: isEnabled)
    .accessibilityLabel(Text(verbatim: copy.title))
  }

  /// "Copy text", or the Marked up view's own label ("Copy cleaned").
  static func label(mode: FileImportCoordinator.DocumentView) -> String {
    mode == .markedUp
      ? TranscriptDocumentPresenter.exportButtonLabels(mode: mode).copy
      : String(localized: "Copy text", comment: "History transcript and meeting pages: copies the words shown.")
  }
}

/// The page header's More button: the app's own menu under a round "···".
struct HistoryDocumentMoreButton: View {
  let anchor: HistoryMenuAnchorHolder
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      Image(systemName: "ellipsis")
        .fontWeight(.bold)
        .frame(width: 16, height: 16)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: true)
    .background(HistoryMenuAnchor(holder: anchor))
    .help(Text("More actions", comment: "History transcript: opens the More menu."))
    .accessibilityLabel(Text("More actions", comment: "History transcript: opens the More menu."))
  }
}
