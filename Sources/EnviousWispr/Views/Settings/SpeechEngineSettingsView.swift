import SwiftUI

/// Transcription engine, multi-language options, recording environment, and cleanup settings.
struct SpeechEngineSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            // ── Section 1: Transcription Engine ──────────────────────────────
            BrandedSection(header: "Transcription Engine") {
                BrandedRow {
                    BrandedSegmentedPicker(
                        options: [
                            ("Fast (English)", ASRBackendType.parakeet),
                            ("Multi-Language", ASRBackendType.whisperKit)
                        ],
                        selection: $state.settings.selectedBackend
                    )
                }
                BrandedRow(showDivider: false) {
                    Text(appState.settings.selectedBackend == .parakeet
                        ? "Powered by Parakeet — fast English transcription with built-in punctuation."
                        : "Powered by WhisperKit — broader language support with optimized quality defaults.")
                        .font(.stHelper)
                        .foregroundStyle(.stTextTertiary)
                }
            }

            // ── Section 2: WhisperKit Model Setup (conditional) ───────────────
            if appState.settings.selectedBackend == .whisperKit {
                BrandedSection(header: "Model Setup") {
                    BrandedRow(showDivider: false) {
                        whisperKitSetupContent
                    }
                }
            }

            // ── Section 3: Language Selection (only when model is ready) ──
            if appState.settings.selectedBackend == .whisperKit,
               case .ready = appState.whisperKitSetup.setupState {
                BrandedSection(header: "Language") {
                    BrandedRow(showDivider: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Language", selection: $state.settings.whisperKitLanguage) {
                                Text("English").tag("en")
                                Text("German (Deutsch)").tag("de")
                                Text("Tamil (தமிழ்)").tag("ta")
                            }
                            .pickerStyle(.segmented)
                            Text("Select the language you'll be speaking. Parakeet is English-only; WhisperKit supports multiple languages.")
                                .font(.stHelper)
                                .foregroundStyle(.stTextTertiary)
                        }
                    }
                }
            }

            // ── Section 3: Recording Environment ─────────────────────────────
            BrandedSection(header: "Recording Environment") {
                BrandedRow {
                    EnvironmentPresetCards(selection: Binding(
                        get: { appState.settings.environmentPreset },
                        set: { state.settings.environmentPreset = $0 }
                    ))
                }
                BrandedRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Stop recording on silence", isOn: $state.settings.vadAutoStop)
                            .toggleStyle(BrandedToggleStyle())
                    }
                }
                if appState.settings.vadAutoStop {
                    BrandedRow {
                        VStack(alignment: .leading, spacing: 4) {
                            BrandedSlider("Pause duration", value: $state.settings.vadSilenceTimeout, in: 0.5...3.0, step: 0.25, low: "0.5s", high: "3.0s", format: "%.1fs")
                            Text("How long to wait after you stop speaking before ending the recording.")
                                .font(.stHelper)
                                .foregroundStyle(.stTextTertiary)
                        }
                    }
                }
            }

            // ── Section 4: Cleanup ────────────────────────────────────────────
            BrandedSection(header: "Cleanup") {
                BrandedRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Remove filler words (um, uh, hmm...)", isOn: $state.settings.fillerRemovalEnabled)
                            .toggleStyle(BrandedToggleStyle())
                        Text("Strips common filler words from transcriptions.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
            }
        }
        .onAppear {
            if appState.settings.selectedBackend == .whisperKit {
                Task { await appState.whisperKitSetup.detectState() }
            }
        }
        .onChange(of: appState.settings.selectedBackend) { _, newBackend in
            if newBackend == .whisperKit {
                Task { await appState.whisperKitSetup.detectState() }
            }
        }
    }

    // MARK: - WhisperKit Setup UI

    @ViewBuilder
    private var whisperKitSetupContent: some View {
        switch appState.whisperKitSetup.setupState {
        case .checking:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Checking model status...")
                    .foregroundStyle(.stTextTertiary)
            }

        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                whisperKitStepIndicator("Download Model")

                Text("WhisperKit requires a ~1.5 GB model download. It runs fully on your Mac — no internet needed after setup.")
                    .font(.stHelper)
                    .foregroundStyle(.stTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Download WhisperKit Model") {
                        appState.whisperKitSetup.downloadModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    whisperKitRefreshButton
                }
            }

        case .downloading(let progress, let status):
            VStack(alignment: .leading, spacing: 8) {
                whisperKitStepIndicator("Downloading...")

                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.stTextTertiary)
                        .lineLimit(1)
                    Spacer()
                    if progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.stTextTertiary)
                    }
                    Button("Cancel") {
                        appState.whisperKitSetup.cancelDownload()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }

        case .ready:
            HStack {
                Label("Model Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                whisperKitRefreshButton
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.stHelper)
                    .foregroundStyle(.stTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try Again") {
                    Task { await appState.whisperKitSetup.detectState() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func whisperKitStepIndicator(_ title: String) -> some View {
        Label(title, systemImage: "1.circle.fill")
            .foregroundStyle(Color.accentColor)
            .font(.caption.bold())
    }

    @ViewBuilder
    private var whisperKitRefreshButton: some View {
        Button {
            Task { await appState.whisperKitSetup.forceDetectState() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Re-check model status")
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
    }
}

private struct PresetCard: View {
    let info: PresetInfo
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Color.clear.frame(height: 1) // layout anchor
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .background(Color.stAccent)
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
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.stAccent.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(isSelected ? Color.stAccent : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 1)
                    )
                    .shadow(color: isSelected ? Color.stAccent.opacity(0.20) : .clear, radius: 4, y: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "selected" : "")
    }
}
