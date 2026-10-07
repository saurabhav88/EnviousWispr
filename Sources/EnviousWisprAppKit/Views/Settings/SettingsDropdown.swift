import SwiftUI

/// The mockup's dropdown menu (#3385), in one place: a solid popover under its trigger, rows
/// with a check column, a leading mark, a title and a line under it, and optional group
/// headings. The microphone picker, the AI Polish provider card and the AI Polish model menus
/// all open one of these, so the menus look and behave alike. Each caller owns its trigger,
/// its open state and what a choice writes.
extension View {
  /// Opens `content` as the mockup's menu under this view. A macOS popover closes on an
  /// outside click and on Escape, which is the mockup's click-away.
  func settingsDropdown<Menu: View>(
    isPresented: Binding<Bool>, width: CGFloat, maxHeight: CGFloat? = nil,
    @ViewBuilder content: @escaping () -> Menu
  ) -> some View {
    popover(isPresented: isPresented, arrowEdge: .bottom) {
      SettingsDropdownMenu(width: width, maxHeight: maxHeight, content: content)
    }
  }
}

/// The menu body: padding, a fixed width, a scroll when a height limit is given, and the
/// solid card colour (the default popover material let the page show through).
private struct SettingsDropdownMenu<Content: View>: View {
  let width: CGFloat
  let maxHeight: CGFloat?
  @ViewBuilder let content: () -> Content

  var body: some View {
    Group {
      if let maxHeight {
        ScrollView(.vertical) { stack }
          .frame(maxHeight: maxHeight)
      } else {
        stack
      }
    }
    .frame(width: width)
    .presentationBackground(Color.stSectionBg)
  }

  private var stack: some View {
    VStack(alignment: .leading, spacing: 2) { content() }
      .padding(6)
  }
}

/// A group heading inside a dropdown ("ON THIS MAC"). Groups after the first carry a hairline
/// above them, as in the mockup.
struct SettingsDropdownHeading: View {
  let title: String
  var showsDivider = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsDivider {
        Divider().overlay(Color.stDivider).padding(.vertical, 4)
      }
      Text(title.uppercased())
        .font(.stSectionHeader)
        .tracking(0.6)
        .foregroundStyle(Color.stTextSecondary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

/// One choice: a check for the chosen row, a leading mark, the title, an optional line under
/// it and an optional trailing view (a verdict chip). The chosen row is tinted and its title
/// is accent. `spokenTitle` is the VoiceOver name; the chosen state is a trait, not words.
struct SettingsDropdownRow<Leading: View, Subtitle: View, Trailing: View>: View {
  let isChosen: Bool
  let spokenTitle: String
  var isEnabled = true
  let action: () -> Void
  @ViewBuilder let leading: () -> Leading
  let title: String
  var titleIsCode = false
  @ViewBuilder let subtitle: () -> Subtitle
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(Color.stAccent)
          .opacity(isChosen ? 1 : 0)
          .accessibilityHidden(true)
        leading()
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(
              titleIsCode ? .system(size: 14, weight: .semibold, design: .monospaced) : .stRowLabel
            )
            .foregroundStyle(isChosen ? Color.stAccent : Color.stTextPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          subtitle()
        }
        Spacer(minLength: 6)
        trailing()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(isChosen ? Color.stAccentLight : Color.clear)
      )
      .settingsHoverRow(cornerRadius: 8)
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityLabel(spokenTitle)
    .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
  }
}

extension SettingsDropdownRow where Trailing == EmptyView {
  init(
    isChosen: Bool, spokenTitle: String, isEnabled: Bool = true, action: @escaping () -> Void,
    @ViewBuilder leading: @escaping () -> Leading, title: String, titleIsCode: Bool = false,
    @ViewBuilder subtitle: @escaping () -> Subtitle
  ) {
    self.init(
      isChosen: isChosen, spokenTitle: spokenTitle, isEnabled: isEnabled, action: action,
      leading: leading, title: title, titleIsCode: titleIsCode, subtitle: subtitle,
      trailing: { EmptyView() })
  }
}

/// The closed state of a field-style dropdown (the model menus): the current value in the
/// input colours, a chevron, and the accent border while the menu is open.
struct SettingsDropdownField: View {
  let value: String
  var valueIsCode = true
  let isOpen: Bool
  let width: CGFloat
  let spokenTitle: String
  var isEnabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(value)
          .font(valueIsCode ? .system(size: 14, design: .monospaced) : .stBody)
          .foregroundStyle(isEnabled ? Color.stTextPrimary : Color.stTextSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 6)
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.stTextSecondary)
          .accessibilityHidden(true)
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .padding(.vertical, 7)
      .frame(width: width, alignment: .leading)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isOpen ? Color.stAccent : Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .settingsHoverRow(cornerRadius: 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .settingsArrivalFocusControl()
    .disabled(!isEnabled)
    .accessibilityLabel(spokenTitle)
    .accessibilityValue(value)
  }
}
