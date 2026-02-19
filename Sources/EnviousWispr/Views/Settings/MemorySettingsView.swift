import SwiftUI

/// Model memory management settings.
struct MemorySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Memory") {
                Picker("Unload model after", selection: $state.modelUnloadPolicy) {
                    ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }

                if appState.modelUnloadPolicy != .never {
                    Text("The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2-5 s).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if appState.modelUnloadPolicy == .immediately {
                    Text("Model is freed after every transcription. Expect a reload delay on each recording.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
