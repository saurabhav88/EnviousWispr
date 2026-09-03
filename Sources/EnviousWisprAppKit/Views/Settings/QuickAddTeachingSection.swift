import EnviousWisprServices
import SwiftUI

/// Quick Add tab of the Dictionary page (#2497). Quick Add itself shipped in
/// v2.4.6 (#2381) but has no dedicated teaching page. Select a word in another
/// app, trigger Quick Add by shortcut or from the menu bar, and save it to the
/// dictionary without opening this settings window first. This tab teaches
/// that it exists, right where people are already looking at their word list.
/// Read-only: it links to Keybinds for the shortcut and explains the menu bar
/// route; it never touches `QuickAddWiring` or its coordinator.
///
/// **No demo frame here, and that is the shipped decision (#2497, founder
/// 2026-09-02).** The tab originally carried a 16:10 gradient panel captioned
/// "PREVIEW COMING SOON", holding space for a screen recording that was never
/// captured; it shipped that way and Codex reopened #2497 against it. Rather
/// than record the video, the founder cut the panel: the three steps and the
/// two callouts already carry the whole explanation, and a permanent IOU
/// drawn in the release build is a worse claim than no picture at all. Do not
/// reintroduce a placeholder frame — a real recording, or nothing.
///
/// **No standalone intro line either, and that is the same decision.** One was
/// drafted to stand where the frame had been, on the worry that the tab would
/// otherwise open cold on "1. Highlight a word"; the founder rejected the
/// premise, because the Dictionary page always opens on Your Words
/// (`YourWordsView.selectedTab` defaults to `.yourWords`) and this tab is only
/// ever reached by clicking a rail row that already reads "Quick Add / Add from
/// any app". Nobody arrives here without having asked for it.
///
/// The three written steps and the keyboard/menu-bar callouts are the real,
/// final copy — verified
/// against `ShortcutBinding.swift` (default chord) and `MenuBarController.swift`
/// (the menu item's real title and behavior) rather than composed from memory
/// (cloud review, PR caught two invented product claims: a default-off
/// shortcut and a category picker that don't exist).
///
/// **The shortcut shown is the LIVE configured one, run through the SAME
/// ownership check the menu bar's own hint uses
/// (`MenuBarController.quickAddShortcutLabel`) rather than a bare format
/// call** — two more cloud-review rounds caught, in order: a hardcoded
/// "Control Option W" that goes wrong the moment someone rebinds Quick Add
/// on Keybinds; and, once that was fixed to read the live binding, that the
/// live binding can still lose arbitration to Record or Cancel
/// (`ShortcutMatcher.quickAddOwnsItsBinding`) — this tab must not advertise a
/// chord that will not actually fire, so it falls back to pointing at the
/// menu bar when that happens.
struct QuickAddTeachingSection: View {
  @Environment(\.settingsNavigate) private var navigate
  @Environment(SettingsManager.self) private var settings

  /// The chord to teach, or `nil` when Quick Add's configured binding has
  /// lost arbitration to Record or Cancel (`MenuBarController
  /// .quickAddShortcutLabel`, the same authority the menu bar's own hint
  /// uses — never a second ownership check re-derived here). Showing a chord
  /// that will not actually trigger Quick Add is worse than showing nothing.
  private var shortcutDisplay: String? {
    MenuBarController.quickAddShortcutLabel(
      keyCode: settings.quickAddKeyCode, modifiers: settings.quickAddModifiers,
      recordKeyCode: settings.toggleKeyCode, recordModifiers: settings.toggleModifiers,
      cancelKeyCode: settings.cancelKeyCode, cancelModifiers: settings.cancelModifiers)
  }

  /// Step 2's full sentence, and now the ONLY place the chord is rendered. It
  /// names the chord only when that chord will actually fire, and otherwise says
  /// nothing about a shortcut at all — the "or the menu bar" half only makes
  /// sense as an ALTERNATIVE when one exists.
  private var triggerStepBody: String {
    if let shortcutDisplay {
      return "Press \(shortcutDisplay), or open the EnviousWispr menu and choose the Add item."
    }
    return "Open the EnviousWispr menu and choose the Add item."
  }

  var body: some View {
    BrandedSection {
      BrandedRow(showDivider: false) {
        VStack(alignment: .leading, spacing: 16) {
          steps
          calloutRow
        }
      }
    }
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
    stepCard(2, title: "Trigger Quick Add", body: triggerStepBody)
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
        // The LIVE configured shortcut, not the shipped default — this must
        // stay correct after someone rebinds Quick Add on Keybinds. When it
        // currently conflicts with Record or Cancel, say so rather than
        // showing a chord that will not fire.
        value: shortcutDisplay.map { "\($0). Change it under Keybinds." }
          ?? "Currently unavailable — set one under Keybinds."
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
