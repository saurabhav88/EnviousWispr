import SwiftUI

/// Quick Add tab of the Dictionary page (#2497). Quick Add itself shipped in
/// v2.4.6 (#2381) but has no dedicated teaching page. Select a word in another
/// app, trigger Quick Add by shortcut or from the menu bar, and save it to the
/// dictionary without opening this settings window first. This tab teaches
/// that it exists, right where people are already looking at their word list.
/// Read-only: it links to Keybinds for the shortcut and explains the menu bar
/// route; it never touches `QuickAddWiring` or its coordinator.
///
/// **Known gap, tracked on issue #2497: the demo below is a placeholder.**
/// The real screen recording (highlight a word in a real app → trigger Quick
/// Add → it lands in the dictionary) still needs to be captured and dropped
/// in as a bundled resource before this ships to release users — a static
/// mockup of a video is not the same claim as a real one, and #2497
/// explicitly says a placeholder can't ship. The three written steps and the
/// keyboard/menu-bar callouts below are the real, final copy — verified
/// against `ShortcutBinding.swift` (default chord) and `MenuBarController.swift`
/// (the menu item's real title and behavior) rather than composed from memory
/// (cloud review, PR caught two invented product claims: a default-off
/// shortcut and a category picker that don't exist).
struct QuickAddTeachingSection: View {
  @Environment(\.settingsNavigate) private var navigate

  var body: some View {
    BrandedSection {
      BrandedRow(showDivider: false) {
        VStack(alignment: .leading, spacing: 16) {
          demoPlaceholder
          steps
          calloutRow
        }
      }
    }
  }

  private var demoPlaceholder: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color.stAccentLight, Color.stSectionBg],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .aspectRatio(16 / 10, contentMode: .fit)

      VStack(spacing: 10) {
        Image(systemName: "play.circle.fill")
          .font(.system(size: 34, weight: .regular))
          .foregroundStyle(.stAccent)
        Text(
          "Highlight \u{201C}Kubernetes\u{201D} in Slack \u{2192} press Control Option W \u{2192} it\u{2019}s added."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
      }

      Text("DEMO")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.stTextSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.stPageBg.opacity(0.7), in: Capsule())
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    // The three written steps below say the same thing without forcing
    // VoiceOver to hear it twice; the eventual real video will need its own
    // accessible description once it replaces this placeholder.
    .accessibilityHidden(true)
  }

  private var steps: some View {
    // ViewThatFits: three cards in one row need real width — at the app's
    // 750pt minimum window the Dictionary tab pane is narrow enough that a
    // stacked column reads better than three squeezed cards.
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) { stepCards }
      VStack(alignment: .leading, spacing: 12) { stepCards }
    }
  }

  @ViewBuilder
  private var stepCards: some View {
    stepCard(
      1, title: "Highlight a word",
      body: "Select the word you want to fix in an email, chat, or document.")
    stepCard(
      2, title: "Trigger Quick Add",
      body: "Press Control Option W, or open the EnviousWispr menu and choose the Add item.")
    stepCard(
      3, title: "Choose and save",
      body:
        "Choose the word you meant, or create a new one. Quick Add saves the highlighted spelling to your dictionary."
    )
  }

  private func stepCard(_ number: Int, title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(number)")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.stAccent)
        .frame(width: 22, height: 22)
        .background(Color.stAccentLight, in: Circle())
      Text(title)
        .settingsRowLabel()
      Text(body)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var calloutRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        shortcutCallout
        menuBarCallout
      }
      VStack(spacing: 12) {
        shortcutCallout
        menuBarCallout
      }
    }
  }

  private var shortcutCallout: some View {
    Button {
      navigate(.keybinds)
    } label: {
      calloutContent(
        icon: "keyboard",
        label: "Keyboard shortcut",
        // Verified against ShortcutBinding.swift: Quick Add ships bound to
        // Control Option W (keyCode 13, .control + .option) on a fresh
        // install — it is not off by default.
        value: "Control Option W by default. Change it under Keybinds."
      )
      // The button's own layout expands to full width and draws its own
      // background; without an explicit content shape the padding around
      // the text is not part of the tappable area.
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens Keybinds")
  }

  private var menuBarCallout: some View {
    calloutContent(
      icon: "circle.grid.2x2",
      label: "Menu bar",
      // Verified against MenuBarController.swift: the item's real title is
      // "Add Selected Word" (nothing selected) or "Add "<word>"" — never
      // literally "Quick Add".
      value:
        "Click the EnviousWispr icon, then choose the item that starts with \u{201C}Add\u{201D}"
    )
  }

  private func calloutContent(icon: String, label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 26, alignment: .center)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Text(value)
          .settingsRowLabel()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
