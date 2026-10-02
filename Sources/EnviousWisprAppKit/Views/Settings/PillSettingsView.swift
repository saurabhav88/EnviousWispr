import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// The Recording Pill tab of Dictation Settings (#3385): where the pill opens
/// on screen and which pill is drawn while dictating. Moved whole from the
/// Appearance page; the controls, their bindings and their reasons are the
/// ones Appearance carried, unchanged.
struct PillSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // #1341: where the recording pill and status notices open on screen.
      // #2435: the description went with the picker's. The two segments say
      // "Top" and "Bottom" and the panel is called Pill Position, so a sentence
      // repeating that is text for its own sake, and the pill panel below carries
      // the one next-recording note the page needs.
      BrandedPanel(
        icon: "rectangle.portrait.and.arrow.right",
        header: "Pill Position"
      ) {
        BrandedSegmentedPicker(
          options: [
            (
              String(
                localized: "Top",
                comment: "Appearance settings, pill position: the top of the screen."),
              "arrow.up.to.line", OverlayPillPosition.top
            ),
            (
              String(
                localized: "Bottom",
                comment: "Appearance settings, pill position: the bottom of the screen."),
              "arrow.down.to.line", OverlayPillPosition.bottom
            ),
          ],
          selection: $settings.overlayPillPosition
        )
      }

      // #2376: which pill is drawn while dictating, per capability group.
      RecordingPillAppearancePanel()
    }
  }
}
