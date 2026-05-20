import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Model memory management settings.
struct MemorySettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      BrandedSection(header: "Memory") {
        BrandedRow {
          Picker("Unload model after", selection: $settings.modelUnloadPolicy) {
            ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
              Text(policy.displayName).tag(policy)
            }
          }
        }
        if settings.modelUnloadPolicy != .never {
          BrandedRow {
            Text(
              "The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2-5 s)."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
          }
        }
        if settings.modelUnloadPolicy == .immediately {
          BrandedRow(showDivider: false) {
            Text(
              "Model is freed after every transcription. Expect a reload delay on each recording."
            )
            .font(.stHelper)
            .foregroundStyle(.stWarning)
          }
        }
      } footer: {
        FrozenPerRecordingFootnote()
      }
    }
  }
}
