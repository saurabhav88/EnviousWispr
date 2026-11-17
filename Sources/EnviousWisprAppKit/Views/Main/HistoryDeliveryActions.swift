import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// History's delivery actions in one place (#4586 H8): Copy with its two-second "Copied", Share
/// and Save as…. Every History surface (the transcript page, the meeting page and its panes, the
/// cards) calls these with a closure that reads its text at the moment of delivery, so the
/// surface keeps its own text policy (which view, which Timestamps setting) and this file owns
/// only the mechanics.
@MainActor
enum HistoryDelivery {
  /// Share: the text is read when the receiving app asks for it (`DeliverableText`), never at
  /// the press, so a picker left open never hands over words deleted or hidden meanwhile. A nil
  /// read refuses the delivery.
  static func share(from anchor: NSView?, text: @escaping @MainActor @Sendable () -> String?) {
    guard let anchor else { return }
    let provider = NSItemProvider()
    provider.register(DeliverableText(resolve: text))
    NSSharingServicePicker(items: [provider]).show(
      relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  /// Save as… for text read AFTER the panel closes: the row can change or be deleted while it is
  /// open. A failed write reports Foundation's localized sentence (#3908), never the NSError dump.
  static func save(defaultName: String, text: () -> String?, onError: (String) -> Void) {
    guard let url = chooseSaveURL(defaultName: defaultName), let text = text() else { return }
    if let message = write(.text(text), to: url) { onError(message) }
  }

  /// What a Save as… whose document is put together after the panel closes has to write.
  enum Document: Equatable {
    /// Write this text.
    case text(String)
    /// Write nothing and tell the user why.
    case refused(String)
    /// Write nothing and say nothing (the item went away).
    case nothing
  }

  /// Save as… for a document assembled after the panel closes (a meeting's notes and
  /// transcript), so a meeting deleted meanwhile saves nothing.
  static func save(
    defaultName: String, document: @escaping @MainActor () async -> Document,
    onError: @escaping @MainActor (String) -> Void
  ) {
    guard let url = chooseSaveURL(defaultName: defaultName) else { return }
    Task {
      if let message = write(await document(), to: url) { onError(message) }
    }
  }

  /// Writes the document as UTF-8 plain text. Returns the sentence to show the user, or nil when
  /// it was written or there was nothing to write.
  static func write(_ document: Document, to url: URL) -> String? {
    switch document {
    case .text(let text):
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return nil
      } catch {
        return error.localizedDescription
      }
    case .refused(let message):
      return message
    case .nothing:
      return nil
    }
  }

  /// The plain-text save panel, run modally. Nil when cancelled.
  private static func chooseSaveURL(defaultName: String) -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = defaultName
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}

/// One press of a History Copy button.
@MainActor
enum HistoryCopy {
  /// Copies `text` once (`TranscribeFileExport.copy`: the clipboard, then VoiceOver's "Copied"),
  /// then holds "Copied" for two seconds. A later press restarts the hold; an earlier press's
  /// timer never clears it. Nil copies nothing and shows nothing. Returns whether it copied.
  @discardableResult
  static func press(
    _ text: String?, copiedAt: Binding<Date?>,
    copy: (String) -> Void = { TranscribeFileExport.copy($0) },
    hold: Double = TranscribeFileExport.copiedHoldSeconds
  ) -> Bool {
    guard let text else { return false }
    copy(text)
    let pressed = Date()
    copiedAt.wrappedValue = pressed
    Task {
      try? await Task.sleep(for: .seconds(hold))
      if copiedAt.wrappedValue == pressed { copiedAt.wrappedValue = nil }
    }
    return true
  }
}

/// A pane's Copy (#4611 D1, T3): "Copy", then "Copied" for two seconds at the same width. The
/// visible word stays short; `spoken` (tooltip and VoiceOver) says what it copies. Reads `text`
/// when pressed. `feedback`, when given, is a page-owned Copied shared by several panes (the
/// meeting page: copying another pane clears this one's Copied, and a tab or layout change keeps
/// the hold); otherwise the button keeps its own.
struct HistoryPaneCopyButton: View {
  let spoken: String
  let isEnabled: Bool
  var feedback: Binding<Date?>? = nil
  let text: () -> String?
  @State private var localCopiedAt: Date?

  private var copiedAt: Binding<Date?> {
    feedback ?? $localCopiedAt
  }

  var body: some View {
    let copied = copiedAt.wrappedValue != nil
    Button {
      HistoryCopy.press(text(), copiedAt: copiedAt)
    } label: {
      ZStack {
        EnviousButtonLabel(
          LocalizedStringResource("Copy", comment: "History meeting: a pane's Copy button."),
          size: .medium, systemImage: "doc.on.doc"
        )
        .opacity(copied ? 0 : 1)
        EnviousButtonLabel(
          LocalizedStringResource(
            "Copied", comment: "History meeting: a pane's Copy button, just after copying."),
          size: .medium, systemImage: "checkmark"
        )
        .opacity(copied ? 1 : 0)
      }
    }
    .settingsButton(.quiet, size: .medium, isEnabled: isEnabled)
    .disabled(!isEnabled)
    .help(Text(verbatim: spoken))
    .accessibilityLabel(Text(verbatim: spoken))
  }
}

/// A card's round Copy icon (#4611): its tooltip and VoiceOver name are `label`, then "Copied"
/// with a checkmark for two seconds. Reads `text` when pressed.
struct HistoryIconCopyButton: View {
  let label: String
  var isEnabled = true
  let text: () -> String?
  @State private var copiedAt: Date?

  var body: some View {
    let copy = TranscribeFileExport.copyButtonPresentation(
      label: label, copiedAt: copiedAt, now: Date(),
      holdSeconds: TranscribeFileExport.copiedHoldSeconds)
    Button {
      HistoryCopy.press(text(), copiedAt: $copiedAt)
    } label: {
      Image(systemName: copy.systemImage)
        .frame(width: 16, height: 16)
    }
    .settingsButton(.quiet, size: .medium, isEnabled: isEnabled)
    .help(Text(verbatim: copy.title))
    .accessibilityLabel(Text(verbatim: copy.title))
  }
}
