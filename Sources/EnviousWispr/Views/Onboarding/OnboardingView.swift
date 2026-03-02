import SwiftUI
@preconcurrency import AVFoundation

// MARK: - ViewModel

/// Observable state for the onboarding flow.
/// Drives all step transitions and async permission/download work.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Int, CaseIterable {
        case welcome       // Step 1: Welcome + mic permission (hard gate)
        case modelDownload // Step 2: Model download + hotkey intro (hard gate)
        case aiPolish      // Step 3: AI Polish setup (soft, skippable)
        case tryItNow      // Step 4: Interactive tutorial (soft, skippable)
        case ready         // Step 5: You're all set
    }

    var currentStep: Step = .welcome

    // Step 1
    var micPermissionGranted: Bool = false
    var micPermissionDenied: Bool = false

    // Step 2
    var isDownloading: Bool = false
    var downloadComplete: Bool = false
    var downloadError: String? = nil

    // Step 4
    var tutorialTranscription: String? = nil
    var tutorialState: TutorialState = .waiting

    enum TutorialState {
        case waiting, recording, result(String), skipped
    }

    func advanceToNextStep() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func requestMicPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        micPermissionGranted = granted
        micPermissionDenied = !granted
        if granted {
            // Brief pause so user sees the checkmark before auto-advancing
            try? await Task.sleep(nanoseconds: 500_000_000)
            advanceToNextStep()
        }
    }

    func startModelDownload(asrManager: ASRManager, settings: SettingsManager) async {
        guard !downloadComplete else {
            advanceToNextStep()
            return
        }
        isDownloading = true
        downloadError = nil
        do {
            try await asrManager.loadModel()
            downloadComplete = true
            isDownloading = false
            // Persist that hard gates are cleared — closing after this point is an
            // abort of the soft steps only, not a hard-gate abort.
            settings.onboardingState = .needsCompletion
            // Brief pause so user sees completion before auto-advancing
            try? await Task.sleep(nanoseconds: 800_000_000)
            advanceToNextStep()
        } catch {
            isDownloading = false
            downloadError = error.localizedDescription
        }
    }

    func openSystemSettingsForMic() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Main View

/// 5-step onboarding window for first-run setup.
/// Displayed as a standalone SwiftUI Window scene, not a sheet.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    var onComplete: () -> Void

    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)
                .padding(.horizontal, 32)

            Divider()
                .padding(.top, 16)

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.25), value: viewModel.currentStep)

            Divider()

            navigationFooter
                .padding(20)
        }
        .frame(width: 500, height: 550)
        .onAppear {
            // Resume at correct step based on persisted state.
            // Hard gates already cleared → skip to Step 3 (AI Polish).
            if appState.settings.onboardingState == .needsCompletion {
                viewModel.micPermissionGranted = true
                viewModel.downloadComplete = true
                viewModel.currentStep = .aiPolish
            }
        }
        .task(id: viewModel.currentStep) {
            // Auto-start async work when step becomes active
            switch viewModel.currentStep {
            case .welcome:
                // Check if mic is already granted (e.g., user re-opened onboarding)
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .authorized {
                    viewModel.micPermissionGranted = true
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    viewModel.advanceToNextStep()
                }
            case .modelDownload:
                await viewModel.startModelDownload(asrManager: appState.asrManager, settings: appState.settings)
            default:
                break
            }
        }
    }

    // MARK: Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
                let isCurrent = step == viewModel.currentStep
                let isCompleted = step.rawValue < viewModel.currentStep.rawValue

                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(isCompleted ? Color.accentColor : (isCurrent ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
                            .frame(width: 22, height: 22)
                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 11, weight: isCurrent ? .bold : .regular))
                                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        }
                    }

                    Text(step.label)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }

                if step != OnboardingViewModel.Step.allCases.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    // MARK: Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .welcome:       WelcomeStepView(viewModel: viewModel)
        case .modelDownload: ModelDownloadStepView(viewModel: viewModel)
        case .aiPolish:      AIPolishStepView(viewModel: viewModel)
        case .tryItNow:      TryItNowStepView(viewModel: viewModel)
        case .ready:         ReadyStepView(viewModel: viewModel, onComplete: finishOnboarding)
        }
    }

    // MARK: Navigation Footer

    @ViewBuilder
    private var navigationFooter: some View {
        HStack {
            // Back button (not shown on first/last step, nor during auto-gated steps)
            if viewModel.currentStep.rawValue > 0
                && viewModel.currentStep != .ready
                && viewModel.currentStep != .modelDownload {
                Button {
                    if let prev = OnboardingViewModel.Step(rawValue: viewModel.currentStep.rawValue - 1) {
                        viewModel.currentStep = prev
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Step-specific primary action
            switch viewModel.currentStep {
            case .welcome:
                if !viewModel.micPermissionGranted {
                    Button("Grant Microphone Access") {
                        Task { await viewModel.requestMicPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }

            case .modelDownload:
                if let error = viewModel.downloadError {
                    Button("Retry") {
                        Task { await viewModel.startModelDownload(asrManager: appState.asrManager, settings: appState.settings) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if !viewModel.isDownloading {
                    EmptyView()
                }

            case .aiPolish:
                Button("Continue") {
                    viewModel.advanceToNextStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            case .tryItNow:
                Button("Skip") {
                    viewModel.advanceToNextStep()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .ready:
                EmptyView() // Done button is inside ReadyStepView
            }
        }
    }

    private func finishOnboarding() {
        appState.settings.onboardingState = .completed
        onComplete()
    }
}

// MARK: - Step 1: Welcome + Mic Permission

private struct WelcomeStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon row: Mic → Arrow → App → Arrow → Text
            HStack(spacing: 12) {
                iconPill(systemName: "mic.fill", color: .blue)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                iconPill(systemName: "app.badge", color: .purple)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                iconPill(systemName: "doc.text.fill", color: .green)
            }

            Text("Welcome to EnviousWispr")
                .font(.title2.bold())

            Text("Press a hotkey to transcribe your voice. First, we need microphone access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            if viewModel.micPermissionGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else if viewModel.micPermissionDenied {
                VStack(spacing: 8) {
                    Label("Microphone access denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                    Text("Open System Settings > Privacy & Security > Microphone and enable EnviousWispr.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Button("Open System Settings") {
                        viewModel.openSystemSettingsForMic()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    private func iconPill(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 24))
            .foregroundStyle(color)
            .frame(width: 52, height: 52)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Step 2: Model Download + Hotkey

private struct ModelDownloadStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.downloadComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)

                Text("Model Ready")
                    .font(.title2.bold())

                Text("The on-device transcription model is installed and ready to use.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            } else if let error = viewModel.downloadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)

                Text("Download Failed")
                    .font(.title2.bold())

                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 32)
            } else {
                ProgressView()
                    .scaleEffect(1.4)
                    .padding(.bottom, 4)

                Text("Getting Ready…")
                    .font(.title2.bold())

                Text("Downloading the on-device transcription model (~100 MB). This is a one-time setup that enables fast, private dictation.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                Text("Usually takes less than a minute on a standard connection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if viewModel.isDownloading || viewModel.downloadComplete {
                // Hotkey callout — teach the hotkey while user waits
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("Your hotkey: ")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    KeyCapView(label: "⌥")
                    Text("+").foregroundStyle(.secondary).font(.subheadline)
                    KeyCapView(label: "Space")
                    Text("to start dictating")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.vertical, 24)
    }
}

/// Renders a keyboard key cap label.
private struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - Step 3: AI Polish Setup

private struct AIPolishStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState

    @State private var selectedCard: AIPolishCard = .skip

    enum AIPolishCard { case skip, byok }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("AI Polish (Optional)")
                .font(.title2.bold())

            Text("EnviousWispr can improve your transcription for grammar and clarity using an AI model.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            HStack(spacing: 12) {
                // Skip / no polish card
                AIPolishCardView(
                    icon: "checkmark.circle",
                    title: "Skip for Now",
                    subtitle: "Use transcription as-is — fast and private.",
                    isSelected: selectedCard == .skip,
                    action: {
                        selectedCard = .skip
                        appState.settings.llmProvider = .none
                    }
                )

                // BYOK card
                AIPolishCardView(
                    icon: "key.fill",
                    title: "Cloud (BYOK)",
                    subtitle: "Use OpenAI or Gemini with your own key.",
                    isSelected: selectedCard == .byok,
                    action: {
                        selectedCard = .byok
                    }
                )
            }
            .padding(.horizontal, 24)

            if selectedCard == .byok {
                Text("Configure your API key in Settings > AI Polish after onboarding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 24)
    }
}

private struct AIPolishCardView: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 4: Try It Now

private struct TryItNowStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Let's Try It Out")
                .font(.title2.bold())

            Text("Press and hold your hotkey, say a few words, then release.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            // Hotkey callout
            HStack(spacing: 8) {
                KeyCapView(label: "⌥")
                Text("+").foregroundStyle(.secondary).font(.subheadline)
                KeyCapView(label: "Space")
            }

            // Live feedback area
            feedbackArea

            Spacer()
        }
        .padding(.vertical, 24)
        .onAppear {
            // Suppress paste and clipboard-copy during tutorial so transcription
            // never lands in a background window. Flag is cleared on disappear.
            appState.isOnboardingTutorialActive = true
        }
        .onDisappear {
            appState.isOnboardingTutorialActive = false
        }
        // Observe pipeline state changes reactively via @Observable AppState —
        // avoids overwriting the main pipeline.onStateChange callback.
        .onChange(of: appState.pipelineState) { _, newState in
            switch newState {
            case .recording:
                viewModel.tutorialState = .recording
            case .complete:
                let text = appState.pipeline.currentTranscript?.displayText ?? ""
                if !text.isEmpty {
                    viewModel.tutorialState = .result(text)
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        viewModel.advanceToNextStep()
                    }
                } else {
                    viewModel.tutorialState = .waiting
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var feedbackArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.07))
                .frame(height: 80)

            switch viewModel.tutorialState {
            case .waiting:
                Text("Waiting for dictation…")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            case .recording:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text("Recording…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .result(let text):
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text(text)
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .lineLimit(3)
                }
            case .skipped:
                EmptyView()
            }
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Step 5: Ready

private struct ReadyStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState
    let onComplete: () -> Void

    @State private var autoPasteEnabled = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.bold())

            Text("EnviousWispr is ready. Press your hotkey anytime to start dictating.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            // Auto-Paste toggle
            VStack(spacing: 0) {
                Toggle(isOn: $autoPasteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Auto-Paste")
                            .font(.subheadline.bold())
                        Text("Automatically paste transcriptions into the active app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(16)
                .onChange(of: autoPasteEnabled) { _, enabled in
                    if enabled {
                        // Trigger Accessibility permission dialog
                        _ = appState.permissions.requestAccessibilityAccess()
                    }
                }
            }
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)

            // AI Polish discovery
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Text("AI Polish available — configure in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Settings") {
                    appState.pendingNavigationSection = .aiPolish
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button("Done") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 24)
    }
}

// MARK: - Step Label Extension

private extension OnboardingViewModel.Step {
    var label: String {
        switch self {
        case .welcome:       return "Welcome"
        case .modelDownload: return "Setup"
        case .aiPolish:      return "AI Polish"
        case .tryItNow:      return "Try It"
        case .ready:         return "Done"
        }
    }
}
