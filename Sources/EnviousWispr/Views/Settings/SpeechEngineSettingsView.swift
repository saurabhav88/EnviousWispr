import SwiftUI

private let brandPurple: Color = Color(hex: "7c3aed")
private let brandPurpleSoft: Color = Color(hex: "7c3aed").opacity(0.08)

/// Transcription engine, multi-language options, recording environment, and cleanup settings.
struct SpeechEngineSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            // ── Section 1: Transcription Engine ──────────────────────────────
            Section("Transcription Engine") {
                Picker("Engine", selection: $state.settings.selectedBackend) {
                    Text("Fast (English)").tag(ASRBackendType.parakeet)
                    Text("Multi-Language").tag(ASRBackendType.whisperKit)
                }
                .pickerStyle(.segmented)

                Text(appState.settings.selectedBackend == .parakeet
                    ? "Powered by Parakeet — fast English transcription with built-in punctuation."
                    : "Powered by WhisperKit — broader language support with configurable quality controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ── Section 2: Multi-Language Options (conditional) ───────────────
            if appState.settings.selectedBackend == .whisperKit {
                Section("Multi-Language Options") {
                    Toggle("Auto-detect language", isOn: $state.settings.whisperKitLanguageAutoDetect)
                        .tint(brandPurple)
                    Text("Automatically identifies which language you're speaking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Accuracy")
                            Spacer()
                            Text(String(format: "%.1f", appState.settings.whisperKitTemperature))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(brandPurple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(brandPurpleSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        HStack(spacing: 8) {
                            Text("Low").font(.caption2).foregroundStyle(.secondary)
                            Slider(value: $state.settings.whisperKitTemperature, in: 0.0...1.0, step: 0.1)
                                .tint(brandPurple)
                            Text("High").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Lower = more consistent, higher = more creative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Speech filter")
                            Spacer()
                            Text(String(format: "%.1f", appState.settings.whisperKitNoSpeechThreshold))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(brandPurple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(brandPurpleSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        HStack(spacing: 8) {
                            Text("Low").font(.caption2).foregroundStyle(.secondary)
                            Slider(value: $state.settings.whisperKitNoSpeechThreshold, in: 0.0...1.0, step: 0.05)
                                .tint(brandPurple)
                            Text("High").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("How aggressively to filter silence from the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Section 3: Recording Environment ─────────────────────────────
            Section("Recording Environment") {
                EnvironmentPresetCards(selection: Binding(
                    get: { appState.settings.environmentPreset },
                    set: { state.settings.environmentPreset = $0 }
                ))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Toggle("Stop recording on silence", isOn: $state.settings.vadAutoStop)
                    .tint(brandPurple)

                if appState.settings.vadAutoStop {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Pause duration")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1fs", appState.settings.vadSilenceTimeout))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(brandPurple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(brandPurpleSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        HStack(spacing: 8) {
                            Text("0.5s").font(.caption2).foregroundStyle(.secondary)
                            Slider(value: $state.settings.vadSilenceTimeout, in: 0.5...3.0, step: 0.25)
                                .tint(brandPurple)
                            Text("3.0s").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("How long to wait after you stop speaking before ending the recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Section 4: Cleanup ────────────────────────────────────────────
            Section("Cleanup") {
                Toggle("Remove filler words (um, uh, hmm...)", isOn: $state.settings.fillerRemovalEnabled)
                    .tint(brandPurple)
                Text("Strips common filler words from transcriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(brandPurple)
    }
}

// ── Environment preset card picker ───────────────────────────────────────────

private struct PresetInfo {
    let preset: EnvironmentPreset
    let emoji: String
    let name: String
    let description: String
}

private let presets: [PresetInfo] = [
    PresetInfo(preset: .quiet, emoji: "🤫", name: "Quiet",  description: "Library, bedroom, quiet office"),
    PresetInfo(preset: .normal, emoji: "🏠", name: "Normal", description: "Home, private office"),
    PresetInfo(preset: .noisy, emoji: "🏢", name: "Noisy",  description: "Open office, café, outdoors"),
]

private struct EnvironmentPresetCards: View {
    @Binding var selection: EnvironmentPreset

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.preset) { info in
                PresetCard(info: info, isSelected: selection == info.preset) {
                    selection = info.preset
                }
            }
        }
        .padding(12)
    }
}

private struct PresetCard: View {
    let info: PresetInfo
    let isSelected: Bool
    let onTap: () -> Void

    private let brandPurple = Color(hex: "7c3aed")

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Color.clear.frame(height: 1) // layout anchor
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .background(brandPurple)
                            .clipShape(Circle())
                            .offset(x: 2, y: -2)
                    }
                }
                .frame(height: 12)

                Text(info.emoji)
                    .font(.system(size: 22))

                Text(info.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(info.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? brandPurple.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(isSelected ? brandPurple : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 1)
                    )
                    .shadow(color: isSelected ? brandPurple.opacity(0.20) : .clear, radius: 4, y: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
