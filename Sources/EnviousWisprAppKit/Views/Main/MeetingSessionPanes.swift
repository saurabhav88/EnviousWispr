import SwiftUI

enum MeetingSessionPane: Hashable {
  case notes, transcript
}

/// The two panes keep their view identities when the transcript changes after Stop.
struct MeetingSessionPanes<Notes: View, Transcript: View>: View {

  let width: CGFloat
  let recording: Bool
  @Binding var selection: MeetingSessionPane
  @ViewBuilder let notes: () -> Notes
  @ViewBuilder let transcript: () -> Transcript

  var body: some View {
    let narrow = MeetingAfterPresentation.stacksPanes(width: width)
    let layout = narrow ? AnyLayout(ZStackLayout(alignment: .topLeading))
      : AnyLayout(HStackLayout(spacing: DesignSpacing.xl))
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      if narrow {
        BrandedSegmentedPicker(
          options: [
            (String(localized: "Your notes"), nil, MeetingSessionPane.notes),
            (recording ? String(localized: "Live transcript") : String(localized: "Transcript"),
              nil, MeetingSessionPane.transcript),
          ], selection: $selection
        )
        .fixedSize()
        .padding(.horizontal, DesignSpacing.xl)
        .padding(.top, DesignSpacing.md)
      }
      layout {
        ScrollView {
          notes()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSpacing.xl)
        }
        .frame(width: narrow ? nil : MeetingAfterPresentation.notesPaneWidth(width: width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
        .opacity(!narrow || selection == .notes ? 1 : 0)
        .allowsHitTesting(!narrow || selection == .notes)
        .disabled(narrow && selection != .notes)
        .accessibilityHidden(narrow && selection != .notes)

        transcript()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(DesignSpacing.xl)
          .background(
            Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
          .opacity(!narrow || selection == .transcript ? 1 : 0)
          .allowsHitTesting(!narrow || selection == .transcript)
          .disabled(narrow && selection != .transcript)
          .accessibilityHidden(narrow && selection != .transcript)
      }
    }
  }
}
