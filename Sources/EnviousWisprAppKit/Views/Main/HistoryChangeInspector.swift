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
        if let seconds = detail.seconds {
          Button {
            onHear(seconds)
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Hear it",
                comment: "History change details: plays the recording where this change was said."),
              size: .medium, systemImage: "play.fill")
          }
          .settingsButton(.outlined, size: .medium, isEnabled: true)
        }
        if !detail.original.isEmpty {
          Button {
            onCopyOriginal(detail.original)
          } label: {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Copy original",
                comment: "History change details: copies the words before AI polish."),
              size: .medium, systemImage: "doc.on.doc")
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
