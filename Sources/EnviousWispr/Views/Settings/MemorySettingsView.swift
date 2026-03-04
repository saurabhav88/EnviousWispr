import SwiftUI

/// Model memory management settings.
struct MemorySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            BrandedSection(header: "Memory") {
                BrandedRow {
                    Picker("Unload model after", selection: $state.settings.modelUnloadPolicy) {
                        ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }
                if appState.settings.modelUnloadPolicy != .never {
                    BrandedRow {
                        Text("The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2-5 s).")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
                if appState.settings.modelUnloadPolicy == .immediately {
                    BrandedRow(showDivider: false) {
                        Text("Model is freed after every transcription. Expect a reload delay on each recording.")
                            .font(.stHelper)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
