import SwiftUI

/// A single sidebar navigation row. When selected it carries the brand-purple
/// gradient pill, a lavender hairline, and a soft glow (the "spiced" selection);
/// otherwise it's a quiet lavender-icon row. Drawn manually so the selection
/// looks identical whether or not the window is the key window.
///
/// #3385 (tracker A7, the design's sidebar `mk`): a selected row now RESTS on a
/// flat brand-purple fill; the gradient, hairline and glow appear only while the
/// pointer is on it. An unselected row's hover stays the quiet tint. Still drawn
/// manually, for the inactive-window reason above. Moved out of `SettingsView`
/// so a test can host the production row.
struct SidebarNavRow<Icon: View>: View {
  let label: String
  let isSelected: Bool
  /// Small in-progress dot (#1701 Chunk 2). Paired with an accessibility
  /// value rather than color/shape alone, per accessibility-noncolor-motion.
  /// #3385: one value drives the dot AND its words, so a Dictionary dot can no
  /// longer be announced as a file import (`SettingsShellCopy.sidebarValue`).
  var activity: SettingsShellCopy.SidebarActivity = .none
  /// Render-only: forces the hover paint so a harness can draw it. Production
  /// never passes it (`SettingsShellWiringTests` checks), so real hover comes
  /// only from the pointer.
  var hoverOverride: Bool? = nil
  @ViewBuilder var icon: () -> Icon
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  /// DERIVED, never stored. See `SettingsHover.respondsToPointer`.
  private var hovering: Bool {
    hoverOverride ?? SettingsHover.respondsToPointer(pointerInside, true, environmentEnabled)
  }

  private var radius: CGFloat { 9 }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        icon()
          .frame(width: 19, height: 18)
          .padding(.trailing, 10)
        // #3385: full label at 14pt, wrapping if it must; no shrink-to-fit
        // below the 14pt floor to hide an overflow.
        Text(label)
          .font(.stBody)
          .foregroundStyle(isSelected ? Color.white : .stTextBody)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        // The dot's slot is always laid out, so a run starting or ending never
        // rewraps the label or changes the row's height (measured: without the
        // reserved slot, "Dictation Settings" wrapped to two lines when busy).
        if activity == .polishNeedsSetup {
          // #3438: a request, not a progress dot. Its words are also the row's spoken value.
          Text(PolishSetupSurfaceCopy.sidebarTag)
            // The Settings text floor is 14pt (founder 2026-07-03).
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : Color.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
              Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.orange.opacity(0.16))
            )
            .fixedSize()
            .accessibilityHidden(true)
        } else {
          Circle()
            .fill(isSelected ? Color.white : Color.stAccentSolid)
            .frame(width: 7, height: 7)
            .opacity(activity == .none ? 0 : 1)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background { paint.allowsHitTesting(false) }
      // The pointer's answer to "is this a thing I can click". Fifteen rows,
      // the most-visited control in the window, and until #2447 not one of them
      // reacted. Tint radius matches the selection pill's 9 so a row that is
      // hovered and then selected does not change shape.
      //
      // A SELECTED row already carries the brand gradient, which a 6% accent
      // tint disappears into, so it takes a white veil instead -- otherwise the
      // row the pointer rests on most often is the one row that looks dead.
      // #3385: superseded. A selected row rests on the flat fill and answers the
      // pointer by gaining the gradient and glow (no veil); an unselected row
      // keeps the 6% tint. Same 9pt radius, so hover then select keeps its shape.
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { pointerInside = $0 }
    .animation(reduceMotion ? nil : SettingsHover.animation, value: hovering)
    .accessibilityLabel(label)
    .accessibilityValue(SettingsShellCopy.sidebarValue(isSelected: isSelected, activity: activity))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  @ViewBuilder
  private var paint: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if isSelected && hovering {
      shape
        .fill(
          LinearGradient(
            colors: [
              Color(.sRGB, red: 0.604, green: 0.361, blue: 0.965, opacity: 1),
              Color(.sRGB, red: 0.486, green: 0.227, blue: 0.929, opacity: 1),
            ],
            startPoint: .top, endPoint: .bottom)
        )
        .overlay(
          shape.strokeBorder(
            Color(.sRGB, red: 0.773, green: 0.714, blue: 1.0, opacity: 0.5), lineWidth: 1)
        )
        .shadow(color: Color.stAccent.opacity(0.40), radius: 7, y: 2)
    } else if isSelected {
      shape.fill(Color.stAccentSolid)
    } else if hovering {
      shape.fill(SettingsHover.rowTint)
    }
  }
}
