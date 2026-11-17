import SwiftUI

/// One AI Polish change, opened from either half of it in the Marked up view (#3147 §3.4):
/// the original words and the polished words, then Hear it (only when the change's original
/// words were heard in a timed passage), Copy original (only when there are original words) and
/// Done. Shown inside the card under the text, as the approved mock places it; Escape closes it.
struct HistoryChangeInspector: View {
  let detail: HistoryDictationPresentation.ChangeDetail
  let onHear: (Double) -> Void
  let onCopyOriginal: (String) -> Void
  let onDone: () -> Void
  /// Copy original shows "Copied" for the shared hold time.
  /// When Copy original was last pressed; a later press or another change clears it.
  @State private var copiedOriginalAt: Date?
  private var copiedOriginal: Bool { copiedOriginalAt != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.lg) {
      Grid(
        alignment: .leading, horizontalSpacing: DesignSpacing.xl, verticalSpacing: DesignSpacing.sm
      ) {
        GridRow {
          Text(
            "Original", comment: "History change details: label before the words before AI polish."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          Text(verbatim: Self.quoted(detail.original, empty: Self.nothingWord))
            .font(.stBody)
            .foregroundStyle(.stTextPrimary)
            .textSelection(.enabled)
        }
        GridRow {
          Text(
            "Polished", comment: "History change details: label before the words AI polish wrote."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          Text(verbatim: Self.quoted(detail.polished, empty: Self.removedWord))
            .font(.stBody)
            .foregroundStyle(.stTextPrimary)
            .textSelection(.enabled)
        }
      }
      HStack(spacing: DesignSpacing.md) {
        // #4609: the button's place is kept before passage times arrive, so the row never
        // reflows when they do; hidden and out of the accessibility tree until then.
        Button {
          if let seconds = detail.seconds { onHear(seconds) }
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Hear it",
              comment: "History change details: plays the recording where this change was said."),
            size: .medium, systemImage: "play.fill")
        }
        .settingsButton(.outlined, size: .medium, isEnabled: detail.seconds != nil)
        .opacity(detail.seconds == nil ? 0 : 1)
        .accessibilityHidden(detail.seconds == nil)
        if !detail.original.isEmpty {
          Button {
            onCopyOriginal(detail.original)
            let pressed = Date()
            copiedOriginalAt = pressed
            Task {
              try? await Task.sleep(for: .seconds(TranscribeFileExport.copiedHoldSeconds))
              if copiedOriginalAt == pressed { copiedOriginalAt = nil }
            }
          } label: {
            EnviousButtonLabel(
              copiedOriginal
                ? LocalizedStringResource(
                  "Copied", comment: "History change details: Copy original just copied.")
                : LocalizedStringResource(
                  "Copy original",
                  comment: "History change details: copies the words before AI polish."),
              size: .medium, systemImage: copiedOriginal ? "checkmark" : "doc.on.doc")
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
        Spacer(minLength: 0)
        Button {
          onDone()
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource("Done", comment: "History change details: closes the details."),
            size: .medium)
        }
        .settingsButton(.quiet, size: .medium, isEnabled: true, shortcut: .cancelAction)
      }
    }
    .padding(DesignSpacing.xl)
    // The inspector is reused for the next marked change: its Copied state belongs to the last.
    .onChange(of: detail.original) { _, _ in copiedOriginalAt = nil }
    .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
    .overlay(
      RoundedRectangle(cornerRadius: DesignRadius.xl)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        .allowsHitTesting(false)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      Text("This change", comment: "History change details: VoiceOver name of the panel."))
  }

  static var nothingWord: String {
    String(
      localized: "nothing",
      comment:
        "History change details: shown in quotes when AI polish added words that had no original.")
  }

  static var removedWord: String {
    String(
      localized: "removed",
      comment: "History change details: shown in quotes when AI polish removed the original words.")
  }

  /// “words”, or (nothing)/(removed) for an empty side.
  static func quoted(_ words: String, empty: String) -> String {
    words.isEmpty ? "(\(empty))" : "“\(words)”"
  }
}
