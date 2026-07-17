import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Optional recording start/stop sound cue settings (#1342): a master toggle
/// plus a picker among four original sound pairings, each independently
/// previewable.
struct RecordingSoundsSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  private let columns = [GridItem(.adaptive(minimum: 210, maximum: .infinity), spacing: 12)]

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      BrandedSection(header: "Sounds") {
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "bell.and.waveform")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.playRecordingSounds) {
                Text("Play recording sounds").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Plays a short sound when recording starts and stops. People nearby may hear it."
              )
              .settingsReadingCopy()
            }
          }
        }
      }

      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(RecordingSoundPairing.allCases, id: \.self) { pairing in
          RecordingSoundPairingCard(
            pairing: pairing,
            isSelected: settings.recordingSoundPairing == pairing
          ) {
            settings.recordingSoundPairing = pairing
          }
        }
      }
    }
  }
}

// MARK: - Pairing card

/// One selectable sound pairing: name, one-line character description, and
/// independent Preview Start / Preview Stop controls. The card itself is a
/// non-interactive container — the selection `Button` and the two preview
/// `Button`s are SIBLINGS, never nested inside one another (Grounded Review
/// r3: SwiftUI buttons must not nest).
private struct RecordingSoundPairingCard: View {
  let pairing: RecordingSoundPairing
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(name)
              .font(.stRowTitle)
              .foregroundStyle(isSelected ? .stAccent : .stTextPrimary)
            Spacer()
            if isSelected {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white, Color.stAccent)
            }
          }
          Text(description)
            .settingsReadingCopy()
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
      .accessibilityValue(isSelected ? "Selected" : "")
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

      HStack(spacing: 6) {
        Button("Preview Start") { RecordingSoundCue.play(pairing: pairing, moment: .start) }
          .accessibilityLabel("Preview \(name) start sound")
        Button("Preview Stop") { RecordingSoundCue.play(pairing: pairing, moment: .stop) }
          .accessibilityLabel("Preview \(name) stop sound")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .foregroundStyle(.stAccent)
    }
    .padding(14)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(isSelected ? Color.stAccent : Color.stDivider, lineWidth: isSelected ? 2 : 1)
    )
    .animation(.easeInOut(duration: 0.15), value: isSelected)
  }

  private var name: String {
    switch pairing {
    case .airGlint: return "Air Glint"
    case .velvetTap: return "Velvet Tap"
    case .satinShift: return "Satin Shift"
    case .cloudPop: return "Cloud Pop"
    }
  }

  private var description: String {
    switch pairing {
    case .airGlint: return "A clean, airy glint — lifts gently for start, settles lower for stop."
    case .velvetTap: return "A muted, compact tap — brighter on start, lower and softer on stop."
    case .satinShift:
      return "A smooth two-tone texture shifting brighter for start, darker for stop."
    case .cloudPop: return "A tiny filtered-air pop — crisp on start, subdued on stop."
    }
  }
}
