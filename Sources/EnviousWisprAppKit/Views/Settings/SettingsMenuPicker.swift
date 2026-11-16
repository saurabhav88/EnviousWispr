import SwiftUI

/// A choice from a short list (DESIGN.md "Menus"): the page's squarish outlined button showing
/// the current choice and an up-down chevron, which opens the Mac's own menu with a check beside
/// the current choice.
///
/// Founder, 2026-11-16: the system pop-up button drew a capsule that did not match the page's
/// buttons ("these buttons are whack. I prefer this squarish design more", pointing at the
/// Snippets Import button), and every drop-down should open the same menu the History More
/// button opens. The trigger is painted by `EnviousButtonStyle` (outlined, rounded rectangle,
/// medium), the same face as Import, because `menuStyle(.button)` hands the menu's label to the
/// button style in the environment. The list itself is a real `Picker`, so the menu, its check,
/// keyboard and VoiceOver behaviour are the system's.
///
/// Apply `.settingsArrivalFocusControl()` and `.accessibilityLabel(...)` at the call site, as
/// for any Settings control.
struct SettingsMenuPicker<Value: Hashable, Choices: View>: View {
  /// The picker's name, read by VoiceOver and used as the inline picker's hidden label.
  let title: String
  @Binding var selection: Value
  /// The current choice's words, shown on the button.
  let valueLabel: String
  var isEnabled = true
  @ViewBuilder let choices: () -> Choices

  var body: some View {
    Menu {
      Picker(selection: $selection) {
        choices()
      } label: {
        Text(verbatim: title)
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      EnviousButtonLabel(
        verbatim: valueLabel, size: .medium, trailingSystemImage: "chevron.up.chevron.down"
      )
      .modifier(
        EnviousButtonFace(
          emphasis: .outlined, shape: .roundedRect, size: .medium, paintsEnabled: isEnabled))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .disabled(!isEnabled)
    .accessibilityValue(Text(verbatim: valueLabel))
  }
}
