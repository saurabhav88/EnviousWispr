import AppKit
import EnviousWisprCore
import SwiftUI

@testable import EnviousWisprAppKit

/// The approved-parts sheets for `DesignRenderHarness` (#4506): every part DESIGN.md lists under
/// "Approved parts", built from the real production component with fixed test data and actions
/// that do nothing. Three sheets keep each one readable: structure, controls and cards.
///
/// States, per the component's own contract (a state is shown only where the part has it):
/// - at rest: every part;
/// - self-disabled (`isEnabled: false` or `.disabled(true)` on the control): buttons, switch;
/// - parent-disabled (`.disabled(true)` on a container, control left enabled): buttons, switch;
/// - selected: tab strip, choice bar, engine card, switch on and off;
/// - destructive: the destructive button;
/// - decorative (drawn, not a control): `EnviousButtonLabel` with `EnviousButtonFace` and no
///   `Button`;
/// - keyboard-focused: `.settingsFieldChrome(focused:)`, the one approved part that paints its own
///   focused look (accent border at 2pt). `DesignRenderHarness` makes the second field the first
///   responder and waits until SwiftUI reports the focus (`focusObserved`) before capturing.
///   `SettingsInfoButton`, `SettingsTabStrip` and `SettingsSummaryCard` hold focus only to route
///   it; they paint nothing of their own for it.
/// Not staged here, and why: hover and pressed need a pointer; they are compared in Live UAT
/// (plan §11.1).
///
/// Every symbol used here exists unchanged at the PR 1 baseline revision (c80a4b958), so the same
/// sheets render on both sides of the before/after comparison.
enum DesignPartsSheets {
  /// DESIGN.md "Approved parts" names, mapped to where each appears in the sheets below.
  /// `DesignRenderHarness.partsSheetsCoverTheBook` compares this list with DESIGN.md.
  static let coverage: [String: String] = [
    "SettingsContentView": "structure",
    "BrandedSection": "structure",
    "BrandedPanel": "structure",
    "BrandedRow": "structure",
    "SettingsRow": "structure",
    "SettingsRowIcon": "structure",
    "SettingsSectionHeading": "structure",
    "SettingsInfoButton": "structure",
    "SettingsHelpText": "structure",
    "SettingsHelpArticleLink": "structure",
    "InsetNotice": "structure",
    "WrappingHStack": "structure",
    "ProviderStatusChip": "structure",
    ".settingsHoverRow(...)": "structure",
    "SettingsTabStrip": "controls",
    "BrandedSegmentedPicker": "controls",
    "BrandedToggleStyle": "controls",
    "BrandedSlider": "controls",
    ".settingsButton(...)": "controls",
    "EnviousButtonLabel": "controls",
    "EnviousButtonFace": "controls",
    "EnviousCloseGlyph": "controls",
    ".settingsFieldChrome(focused:)": "controls",
    "OnboardingButtonStyle": "controls",
    "SettingsSummaryCard": "cards",
    "EngineCard": "cards",
  ]

  static func sheet(_ name: String) -> AnyView? {
    switch name {
    case "structure": AnyView(StructureSheet())
    case "controls": AnyView(ControlsSheet())
    case "cards": AnyView(CardsSheet())
    default: nil
    }
  }

  static func label(_ text: String) -> some View {
    Text(verbatim: text).font(.stHelper).foregroundStyle(.stTextSecondary)
  }

  struct StructureSheet: View {
    var body: some View {
      SettingsContentView {
        SettingsSectionHeading(fixtureTitle: "SECTION HEADING", icon: "slider.horizontal.3")
        BrandedSection(
          verbatimHeader: "Branded section",
          content: {
            BrandedRow {
              SettingsRow(
                fixtureTitle: "Settings row", icon: "doc.on.clipboard",
                resolvedShort: "The short grey line under a setting.",
                resolvedHelp: "The help bubble text."
              ) {
                Toggle("", isOn: .constant(true)).toggleStyle(BrandedToggleStyle()).labelsHidden()
              }
            }
            BrandedRow {
              HStack(spacing: 10) {
                SettingsRowIcon(systemName: "bell")
                Text(verbatim: "Row icon and help button").font(.stRowLabel)
                Spacer()
                SettingsInfoButton(rowTitle: "Row icon and help button", tooltip: "More about this")
                {
                  SettingsHelpText(text: "The help bubble text.")
                }
              }
            }
            BrandedRow(showDivider: false) {
              VStack(alignment: .leading, spacing: 6) {
                SettingsHelpText(text: "Help text explains a setting in one or two sentences.")
                SettingsHelpArticleLink(
                  url: URL(string: "https://enviouswispr.com/help/"),
                  label: "Read the help article",
                  accessibilityLabel: "Read the help article")
              }
            }
          }, footer: { EmptyView() })
        BrandedPanel(
          icon: "info.circle", header: "Branded panel",
          description: "A card with an icon, a header and a description."
        ) {
          InsetNotice(verbatim: "An inset notice sits inside a panel.")
        }
        BrandedSection(
          verbatimHeader: "Status chips and wrapping",
          content: {
            BrandedRow {
              WrappingHStack {
                ProviderStatusChip(status: ProviderStatus(label: "Ready", tone: .ready))
                ProviderStatusChip(status: ProviderStatus(label: "Needs setup", tone: .needsSetup))
                ProviderStatusChip(
                  status: ProviderStatus(label: "Not available", tone: .unavailable))
                ProviderStatusChip(status: ProviderStatus(label: "Error", tone: .error))
                ProviderStatusChip(
                  status: ProviderStatus(label: "Headline", tone: .ready), isHeadline: true)
              }
            }
            BrandedRow(showDivider: false) {
              Text(verbatim: "A row with the hover modifier, at rest").font(.stBody)
                .padding(6).settingsHoverRow()
            }
          }, footer: { EmptyView() })
      }
    }
  }

  struct ControlsSheet: View {
    @FocusState private var fieldFocused: Bool

    enum Tab: Hashable { case one, two, three }

    var body: some View {
      SettingsContentView {
        BrandedSection(
          verbatimHeader: "Tabs and choices",
          content: {
            BrandedRow {
              SettingsTabStrip(
                items: [
                  SettingsTabItem(
                    id: Tab.one, icon: "cpu", label: "Engine", map: .dictationTabEngine),
                  SettingsTabItem(
                    id: .two, icon: "text.bubble", label: "Live Preview",
                    map: .dictationTabLivePreview),
                  SettingsTabItem(
                    id: .three, icon: "bell", label: "Chimes", map: .dictationTabChimes),
                ], selection: .constant(.one))
            }
            BrandedRow {
              BrandedSegmentedPicker(
                options: [("Casual", "face.smiling", 0), ("Neutral", nil, 1), ("Formal", nil, 2)],
                selection: .constant(1))
            }
            BrandedRow(showDivider: false) {
              BrandedSegmentedPicker(
                options: [("Always", nil, 0), ("Continue", nil, 1)], selection: .constant(0),
                comfortable: true)
            }
          }, footer: { EmptyView() })
        BrandedSection(
          verbatimHeader: "Switch, slider and field",
          content: {
            BrandedRow {
              Toggle(isOn: .constant(true)) { DesignPartsSheets.label("Switch on") }
                .toggleStyle(BrandedToggleStyle())
            }
            BrandedRow {
              Toggle(isOn: .constant(false)) { DesignPartsSheets.label("Switch off") }
                .toggleStyle(BrandedToggleStyle())
            }
            BrandedRow {
              Toggle(isOn: .constant(true)) { DesignPartsSheets.label("Switch, self-disabled") }
                .toggleStyle(BrandedToggleStyle()).disabled(true)
            }
            BrandedRow {
              VStack {
                Toggle(isOn: .constant(true)) { DesignPartsSheets.label("Switch, parent-disabled") }
                  .toggleStyle(BrandedToggleStyle())
              }.disabled(true)
            }
            BrandedRow {
              BrandedSlider("Slider", value: .constant(0.6), in: 0...1)
            }
            BrandedRow {
              TextField("Paste your key", text: .constant("Typed text"))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .settingsFieldChrome(focused: $fieldFocused)
            }
            BrandedRow(showDivider: false) {
              FocusedField()
            }
          }, footer: { EmptyView() })
        BrandedSection(
          verbatimHeader: "Buttons",
          content: {
            BrandedRow {
              ButtonRow(label: "enabled", isEnabled: true)
            }
            BrandedRow {
              ButtonRow(label: "self-disabled", isEnabled: false)
            }
            BrandedRow {
              ButtonRow(label: "parent-disabled", isEnabled: true).disabled(true)
            }
            BrandedRow {
              HStack(spacing: 10) {
                Button {} label: {
                  EnviousButtonLabel(verbatim: "Back", size: .medium)
                }
                .settingsButton(.quiet, shape: .roundedRect, size: .medium, isEnabled: true)
                Button {} label: {
                  EnviousButtonLabel(
                    verbatim: "Continue", size: .large, trailingSystemImage: "arrow.right")
                }
                .settingsButton(.filled, shape: .roundedRect, size: .large, isEnabled: true)
                Button {} label: {
                  EnviousButtonLabel(verbatim: "Preview", systemImage: "play.fill")
                }
                .settingsButton(isEnabled: true)
              }
            }
            BrandedRow {
              HStack(spacing: 10) {
                EnviousButtonLabel(verbatim: "Decorative, no action")
                  .modifier(EnviousButtonFace(paintsEnabled: true))
                Button {} label: {
                  EnviousCloseGlyph()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
              }
            }
            BrandedRow(showDivider: false) {
              Button("Onboarding continue") {}.buttonStyle(OnboardingButtonStyle())
            }
          }, footer: { EmptyView() })
      }
    }
  }

  /// The text the focused field shows; the harness finds the field by it.
  static let focusedFieldText = "Field with keyboard focus"

  /// Set by `FocusedField` when SwiftUI reports that the field holds focus. The harness resets it,
  /// makes the field first responder, and captures only after it turns true.
  @MainActor static var focusObserved = false

  struct FocusedField: View {
    @FocusState private var focused: Bool

    var body: some View {
      TextField("Focused field", text: .constant(DesignPartsSheets.focusedFieldText))
        .textFieldStyle(.plain)
        .focused($focused)
        .settingsFieldChrome(focused: $focused)
        .onChange(of: focused) { _, isFocused in DesignPartsSheets.focusObserved = isFocused }
    }
  }

  struct ButtonRow: View {
    let label: String
    let isEnabled: Bool

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        DesignPartsSheets.label(label)
        HStack(spacing: 10) {
          Button {} label: {
            EnviousButtonLabel(verbatim: "Download")
          }
          .settingsButton(.filled, isEnabled: isEnabled)
          Button {} label: {
            EnviousButtonLabel(verbatim: "Test")
          }
          .settingsButton(isEnabled: isEnabled)
          Button {} label: {
            EnviousButtonLabel(verbatim: "Back")
          }
          .settingsButton(.quiet, isEnabled: isEnabled)
          Button(role: .destructive) {} label: {
            EnviousButtonLabel(verbatim: "Delete")
          }
          .settingsButton(isEnabled: isEnabled)
        }
      }
    }
  }

  struct CardsSheet: View {
    var body: some View {
      SettingsContentView {
        SettingsSummaryCard(
          map: .id(.transcriptionEngine), isExpanded: .constant(false),
          changeAccessibilityLabel: DictationSettingsCopy.Engine.changeEngine,
          change: .transcriptionEngineChange, keepCurrent: .transcriptionEngineKeepCurrent
        ) {
          EngineSummaryContent(
            icon: "bolt.fill", name: "Fast", model: "Parakeet v3",
            short: "For everyday English and European dictation")
        } status: {
          ProviderStatusChip(status: ProviderStatus(label: "Ready", tone: .ready), isHeadline: true)
        } choices: {
          EmptyView()
        }
        HStack(alignment: .top, spacing: 12) {
          EngineCard(
            icon: "bolt.fill", map: .id(.transcriptionEngineFast),
            tagline: "For everyday English and European dictation",
            specs: [("Model", "Parakeet v3"), ("Runs on", "Apple Neural Engine")],
            isSelected: true, onSelect: {})
          EngineCard(
            icon: "globe", map: .id(.transcriptionEngineAllLanguages),
            tagline: "For other languages or the toughest audio",
            specs: [("Model", "Whisper Large v3 Turbo"), ("Runs on", "Apple GPU")],
            isSelected: false, onSelect: {})
        }
        .environment(\.settingsPR1Density, true)
      }
    }
  }
}
