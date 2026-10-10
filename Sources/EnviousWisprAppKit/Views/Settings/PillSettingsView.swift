import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// The Recording Pill tab of Dictation Settings (#3385): where the pill opens
/// on screen and which pill is drawn while dictating. Moved whole from the
/// Appearance page; the controls, their bindings and their reasons are the
/// ones Appearance carried, unchanged. Chunk 7 gave the two controls the shared
/// row (title, short line, "?") inside one section; the bindings did not move.
struct PillSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // #3385: the tab's own name, in capitals, heads its one section, as on the
      // other Dictation tabs; no second "Recording Pill" string.
      SettingsSectionHeading(map: .id(.sectionPill), casing: .localizedUppercase)

      BrandedSection {
        BrandedRow {
          // #1341: where the recording pill and status notices open on screen.
          // #2435: the description went with the picker's. The two segments say
          // "Top" and "Bottom" and the panel is called Pill Position, so a sentence
          // repeating that is text for its own sake, and the pill panel below carries
          // the one next-recording note the page needs.
          // #3385: superseded by the approved row. "Position on screen" carries a
          // short line under its title and a help sentence behind "?", like every
          // shared row; the segments are unchanged and still write the one setting.
          SettingsRow(
            map: .id(.pillPosition),
            icon: "rectangle.portrait.and.arrow.right",
            help: DictationSettingsCopy.Pill.positionHelp
          ) {
            BrandedSegmentedPicker(
              options: SettingsChoicePresentation.pillPosition.map(\.pickerOption),
              selection: $settings.overlayPillPosition
            )
            // The mockup's control: two equal halves, no arrows, a fixed width so
            // the halves match (founder, 2026-10-03).
            .frame(width: 240)
          }
        }

        BrandedRow(showDivider: false) {
          // #2376: which pill is drawn while dictating, per capability group.
          RecordingPillAppearancePanel()
        }
      }
    }
  }
}
