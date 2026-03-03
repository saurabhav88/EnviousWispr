import SwiftUI
@preconcurrency import AVFoundation

// MARK: - Onboarding Color Palette

extension Color {
    // Backgrounds
    static let obBg           = Color(red: 0.973, green: 0.961, blue: 1.0)
    static let obSurface      = Color(red: 0.941, green: 0.925, blue: 0.976)
    static let obCardBg       = Color.white

    // Text
    static let obTextPrimary  = Color(red: 0.059, green: 0.039, blue: 0.102)
    static let obTextSecondary = Color(red: 0.290, green: 0.239, blue: 0.376)
    static let obTextTertiary = Color(red: 0.490, green: 0.435, blue: 0.588)

    // Brand
    static let obAccent       = Color(red: 0.486, green: 0.227, blue: 0.929)
    static let obAccentHover  = Color(red: 0.427, green: 0.157, blue: 0.851)
    static let obAccentSoft   = Color(red: 0.486, green: 0.227, blue: 0.929).opacity(0.1)

    // Semantic
    static let obSuccess      = Color(red: 0.0, green: 0.784, blue: 0.502)
    static let obSuccessSoft  = Color(red: 0.0, green: 0.784, blue: 0.502).opacity(0.1)
    static let obSuccessText  = Color(red: 0.0, green: 0.541, blue: 0.337)
    static let obWarning      = Color(red: 0.902, green: 0.761, blue: 0.0)
    static let obError        = Color(red: 0.902, green: 0.145, blue: 0.227)
    static let obErrorSoft    = Color(red: 0.902, green: 0.145, blue: 0.227).opacity(0.1)

    // Borders
    static let obBorder       = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.06)
    static let obBorderHover  = Color(red: 0.541, green: 0.169, blue: 0.886).opacity(0.12)

    // Buttons
    static let obBtnDark      = Color(red: 0.059, green: 0.039, blue: 0.102)
    static let obBtnDarkHover = Color(red: 0.102, green: 0.071, blue: 0.188)

    // Rainbow gradient (static property — used as AnyShapeStyle)
    static let obRainbow = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.165, blue: 0.251),
            Color(red: 1.0, green: 0.549, blue: 0.0),
            Color(red: 1.0, green: 0.843, blue: 0.0),
            Color(red: 0.678, green: 1.0, blue: 0.184),
            Color(red: 0.0, green: 0.98, blue: 0.604),
            Color(red: 0.0, green: 1.0, blue: 1.0),
            Color(red: 0.118, green: 0.565, blue: 1.0),
            Color(red: 0.255, green: 0.412, blue: 0.882),
            Color(red: 0.541, green: 0.169, blue: 0.886),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Onboarding Font Tokens

extension Font {
    static let obDisplay      = Font.system(size: 22, weight: .heavy, design: .rounded)
    static let obHeading      = Font.system(size: 18, weight: .bold, design: .rounded)
    static let obSubheading   = Font.system(size: 14, weight: .semibold)
    static let obBody         = Font.system(size: 14, weight: .regular)
    static let obCaption      = Font.system(size: 12, weight: .regular)
    static let obCaptionSmall = Font.system(size: 11, weight: .regular)
    static let obMono         = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let obMonoBold     = Font.system(size: 12, weight: .bold, design: .monospaced)
    static let obLabel        = Font.system(size: 13, weight: .medium)
    static let obButton       = Font.system(size: 15, weight: .bold)
    static let obButtonSmall  = Font.system(size: 13, weight: .semibold)
}

// MARK: - Button Styles

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .kerning(-0.1)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obBtnDark, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .foregroundStyle(Color.obTextSecondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.obBorderHover, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

struct OnboardingAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obAccent, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

struct OnboardingErrorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.obSubheading)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obError, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

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
    enum MicPermissionStatus: Equatable {
        case notDetermined
        case granted
        case denied      // user denied — can fix in System Settings
        case restricted  // MDM/parental controls — user cannot fix
    }
    var micStatus: MicPermissionStatus = .notDetermined

    // Step 2
    var isDownloading: Bool = false
    var downloadComplete: Bool = false
    var downloadError: String? = nil
    var retryCount: Int = 0

    // Step 4
    var tutorialTranscription: String? = nil
    var tutorialState: TutorialState = .waiting

    enum TutorialState {
        case waiting, recording, result(String), skipped
    }

    // Step 3 — BYOK validation state
    var byokValidationState: BYOKValidationState = .idle

    enum BYOKValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    func advanceToNextStep() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func requestMicPermission() async {
        // Guard: if already denied or restricted, don't call requestAccess
        // (it would return false immediately with no dialog, confusing the user).
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch currentStatus {
        case .denied:
            micStatus = .denied
            return
        case .restricted:
            micStatus = .restricted
            return
        case .authorized:
            micStatus = .granted
            try? await Task.sleep(nanoseconds: 500_000_000)
            advanceToNextStep()
            return
        case .notDetermined:
            break // fall through to requestAccess below
        @unknown default:
            break
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if granted {
            micStatus = .granted
            try? await Task.sleep(nanoseconds: 500_000_000)
            advanceToNextStep()
        } else {
            // After notDetermined→requestAccess→denied, check if restricted
            let finalStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            micStatus = (finalStatus == .restricted) ? .restricted : .denied
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

    func retryDownload() {
        downloadError = nil
        isDownloading = false
        retryCount += 1
    }

    func openSystemSettingsForMic() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Validate an API key by calling the provider's model listing endpoint directly,
    /// then save to KeychainManager only if valid.
    /// Uses Option B: LLMModelDiscovery.discoverModels() with raw key, bypassing KeychainManager.
    func validateAndSaveKey(
        provider: BYOKProvider,
        apiKey: String,
        appState: AppState
    ) async {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            byokValidationState = .invalid("API key cannot be empty.")
            return
        }

        byokValidationState = .validating

        do {
            // Step 1: Validate first — call provider API with raw key string
            let discovery = LLMModelDiscovery()
            _ = try await discovery.discoverModels(
                provider: provider.llmProvider,
                apiKey: apiKey.trimmingCharacters(in: .whitespaces)
            )

            // Step 2: Valid — persist to KeychainManager
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
            try appState.keychainManager.store(key: provider.keychainID, value: trimmedKey)

            // Step 3: Set provider in Settings
            appState.settings.llmProvider = provider.llmProvider

            // Step 4: Await model discovery so a model is selected before advancing
            // (validateKeyAndDiscoverModels already picks a default model)
            await appState.validateKeyAndDiscoverModels(provider: provider.llmProvider)

            byokValidationState = .valid

        } catch let error as LLMError where error == .invalidAPIKey {
            byokValidationState = .invalid("Invalid API key. Please check it's correct and active.")
        } catch is CancellationError {
            return
        } catch {
            byokValidationState = .invalid("Could not validate key. Check your connection and try again.")
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

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(viewModel.currentStep)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.currentStep)
        }
        .padding(.top, 24)
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .frame(width: 460)
        .background(Color.obCardBg)
        .onAppear {
            // Resume at correct step based on persisted state.
            // Hard gates already cleared → skip to Step 3 (AI Polish).
            if appState.settings.onboardingState == .needsCompletion {
                viewModel.micStatus = .granted
                viewModel.downloadComplete = true
                viewModel.currentStep = .aiPolish
            }
        }
        .task(id: "\(viewModel.currentStep.rawValue)-\(viewModel.retryCount)") {
            // Auto-start async work when step becomes active (retryCount causes re-trigger on retry)
            switch viewModel.currentStep {
            case .welcome:
                // Check mic TCC status — handle all 4 cases immediately
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                switch status {
                case .authorized:
                    viewModel.micStatus = .granted
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if viewModel.currentStep == .welcome {
                        viewModel.advanceToNextStep()
                    }
                case .denied:
                    viewModel.micStatus = .denied
                case .restricted:
                    viewModel.micStatus = .restricted
                case .notDetermined:
                    break // user must tap the button
                @unknown default:
                    break
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

                ZStack {
                    Circle()
                        .fill(dotFill(isCompleted: isCompleted, isCurrent: isCurrent))
                        .frame(width: 30, height: 30)
                        .shadow(
                            color: isCurrent ? Color.obAccent.opacity(0.3) : .clear,
                            radius: isCurrent ? 6 : 0,
                            y: isCurrent ? 2 : 0
                        )

                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.obMonoBold)
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step.rawValue + 1)")
                            .font(.obMonoBold)
                            .foregroundStyle(isCurrent ? .white : Color.obTextTertiary)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.currentStep)

                if step != OnboardingViewModel.Step.allCases.last {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(
                            isCompleted
                                ? AnyShapeStyle(Color.obRainbow)
                                : AnyShapeStyle(Color.obSurface)
                        )
                        .frame(width: 28, height: 2)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: viewModel.currentStep)
                }
            }
        }
        .padding(.bottom, 22)
    }

    private func dotFill(isCompleted: Bool, isCurrent: Bool) -> Color {
        if isCompleted { return .obSuccess }
        if isCurrent   { return .obAccent }
        return .obSurface
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

    private func finishOnboarding() {
        appState.settings.onboardingState = .completed
        onComplete()
    }
}

// MARK: - Step 1: Welcome + Mic Permission

private struct WelcomeStepView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Lips brand icon
            RainbowLipsView(animationState: lipsState)
                .frame(width: 70, height: 70)
                .padding(.bottom, 18)

            // Title
            Text("Welcome to EnviousWispr")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .padding(.bottom, 6)

            // Subtitle
            Text("Press a hotkey to transcribe your voice. First, we need microphone access.")
                .font(.obBody)
                .lineSpacing(7.7)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.bottom, 18)

            // Icon flow: mic → app → text (hidden once permission decision is made)
            if viewModel.micStatus == .notDetermined {
                HStack(spacing: 8) {
                    iconFlowItem(systemName: "mic.fill")
                    Text("→")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.obTextTertiary)
                    iconFlowItem(systemName: "app.fill")
                    Text("→")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.obTextTertiary)
                    iconFlowItem(systemName: "text.alignleft")
                }
                .padding(.bottom, 18)
            }

            // Permission status alert
            if viewModel.micStatus == .granted {
                HStack(spacing: 8) {
                    Text("Microphone access granted ✓")
                        .font(.obLabel)
                        .foregroundStyle(Color.obSuccessText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 360)
                .background(Color.obSuccessSoft, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.obSuccess.opacity(0.2), lineWidth: 1)
                )
                .padding(.bottom, 18)
            } else if viewModel.micStatus == .denied || viewModel.micStatus == .restricted {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(viewModel.micStatus == .restricted
                             ? "Microphone access is restricted by your organization."
                             : "Microphone access was denied.")
                            .font(.obLabel)
                            .foregroundStyle(Color.obError)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 360)
                    .background(Color.obErrorSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.obError.opacity(0.2), lineWidth: 1)
                    )

                    if viewModel.micStatus == .restricted {
                        Text("This setting is controlled by a device management profile and cannot be changed.")
                            .font(.obCaption)
                            .foregroundStyle(Color.obTextTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    } else {
                        Text("Open System Settings > Privacy & Security > Microphone and enable EnviousWispr.")
                            .font(.obCaption)
                            .foregroundStyle(Color.obTextTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                }
                .padding(.bottom, 18)
            }

            Spacer()

            // Button row (inline, no nav footer)
            VStack(spacing: 8) {
                switch viewModel.micStatus {
                case .denied:
                    Button("Open System Settings") { viewModel.openSystemSettingsForMic() }
                        .buttonStyle(OnboardingErrorButtonStyle())
                case .restricted:
                    EmptyView() // Cannot fix — no action button. Message above explains.
                case .granted:
                    Button("Continue") { viewModel.advanceToNextStep() }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                case .notDetermined:
                    Button("Grant Microphone Access") {
                        Task { await viewModel.requestMicPermission() }
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 10)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // Poll for in-session mic permission changes (e.g. revoked from System Settings)
            // authorizationStatusDidChangeNotification is iOS-only; polling is the macOS approach.
            guard viewModel.micStatus == .notDetermined || viewModel.micStatus == .granted else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized:    viewModel.micStatus = .granted
            case .denied:        viewModel.micStatus = .denied
            case .restricted:    viewModel.micStatus = .restricted
            case .notDetermined: break
            @unknown default:    break
            }
        }
    }

    private var lipsState: LipsAnimationState {
        switch viewModel.micStatus {
        case .denied, .restricted: return .denied
        case .granted: return .happy
        case .notDetermined: return .idle
        }
    }

    private func iconFlowItem(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16))
            .foregroundStyle(Color.obTextTertiary)
            .frame(width: 36, height: 36)
            .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.obBorder, lineWidth: 1)
            )
    }
}

// MARK: - Step 2: Model Download + Hotkey

private struct ModelDownloadStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState

    @State private var spinAngle: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Lips icon
            RainbowLipsView(animationState: lipsState)
                .frame(width: 70, height: 70)
                .padding(.bottom, 18)

            if viewModel.downloadComplete {
                // Success state
                Text("Model Ready")
                    .font(.obDisplay)
                    .foregroundStyle(Color.obTextPrimary)
                    .kerning(-0.4)
                    .padding(.bottom, 6)

                Text("The on-device transcription model is installed and ready to use.")
                    .font(.obBody)
                    .lineSpacing(7.7)
                    .foregroundStyle(Color.obTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.bottom, 18)

            } else if let error = viewModel.downloadError {
                // Error state
                Text("Download Failed")
                    .font(.obDisplay)
                    .foregroundStyle(Color.obTextPrimary)
                    .kerning(-0.4)
                    .padding(.bottom, 6)

                Text(error)
                    .font(.obBody)
                    .lineSpacing(7.7)
                    .foregroundStyle(Color.obTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.bottom, 18)

            } else {
                // Downloading state — custom spinner
                ZStack {
                    Circle()
                        .stroke(Color.obSurface, lineWidth: 3)
                        .frame(width: 40, height: 40)
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Color.obAccent, lineWidth: 3)
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(spinAngle))
                        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinAngle)
                }
                .padding(.bottom, 16)
                .onAppear { spinAngle = 360 }

                Text("Getting Ready…")
                    .font(.obDisplay)
                    .foregroundStyle(Color.obTextPrimary)
                    .kerning(-0.4)
                    .padding(.bottom, 6)

                Text("Downloading the on-device transcription model (~100 MB). This is a one-time setup that enables fast, private dictation.")
                    .font(.obBody)
                    .lineSpacing(7.7)
                    .foregroundStyle(Color.obTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.bottom, 12)

                // Rainbow progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.obSurface)
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.obRainbow)
                            .frame(width: geo.size.width * 0.65, height: 4) // indeterminate at 65%
                    }
                }
                .frame(maxWidth: 360, maxHeight: 4)
                .padding(.bottom, 12)

                Text("Usually takes less than a minute on a standard connection.")
                    .font(.obCaption)
                    .foregroundStyle(Color.obTextTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 14)
            }

            // Hotkey callout card (shown during download and on completion)
            if viewModel.isDownloading || viewModel.downloadComplete {
                hotkeyCalloutCard
                    .padding(.bottom, 10)

                HotkeyConfigRow(appState: appState)
            }

            Spacer()

            // Retry button on error
            if viewModel.downloadError != nil {
                Button("Retry Download") {
                    viewModel.retryDownload()
                }
                .buttonStyle(OnboardingErrorButtonStyle())
                .padding(.top, 10)
            }
        }
    }

    private var lipsState: LipsAnimationState {
        if viewModel.downloadComplete { return .wave }
        if viewModel.downloadError != nil { return .drooping }
        return .equalizer
    }

    private var hotkeyDisplayString: String {
        KeySymbols.format(
            keyCode: appState.settings.toggleKeyCode,
            modifiers: appState.settings.toggleModifiers
        )
    }

    private var hotkeyCalloutCard: some View {
        VStack(spacing: 10) {
            Text("Your hotkey is \(hotkeyDisplayString)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.1)

            Text("Press and hold it anytime to start dictating.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.obTextSecondary)
                .lineSpacing(5.85)

            // Hero keycap
            VStack(spacing: 4) {
                Text(hotkeyDisplayString)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.obAccent)
                    .frame(minWidth: 80, minHeight: 56)
                    .padding(.horizontal, 20)
                    .background(
                        LinearGradient(
                            colors: [.white, Color.obSurface],
                            startPoint: .top, endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.obAccent.opacity(0.15), lineWidth: 1.5)
                    )
                    .shadow(color: Color.obAccent.opacity(0.1), radius: 4, y: 2)

                Text(hotkeyDisplayString.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.obTextTertiary)
                    .kerning(0.3)
            }
        }
        .padding(18)
        .frame(maxWidth: 360)
        .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.obBorder, lineWidth: 1)
        )
        .shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1.5, y: 1)
    }

}

// MARK: - Hotkey Config Row (Step 2 inline recorder)

private struct HotkeyConfigRow: View {
    @Bindable var appState: AppState

    private var badgeSymbol: String {
        let syms = KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers)
        if !syms.isEmpty { return syms }
        return KeySymbols.symbolForModifierKeyCode(appState.settings.toggleKeyCode) ?? "⌨"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Modifier icon badge — falls back to modifier key symbol for modifier-only hotkeys
            Text(badgeSymbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.obAccent)
                .frame(width: 36, height: 36)
                .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.obBorderHover, lineWidth: 1)
                )
                .shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                HotkeyRecorderView(
                    keyCode: $appState.settings.toggleKeyCode,
                    modifiers: $appState.settings.toggleModifiers,
                    defaultKeyCode: 49,
                    defaultModifiers: .control,
                    label: "Hotkey",
                    colors: .init(
                        label: .obTextPrimary,
                        fieldText: .obTextPrimary,
                        fieldBackground: .obCardBg,
                        recordingBackground: Color.obAccent.opacity(0.1),
                        recordingBorder: .obAccent,
                        placeholder: .obTextTertiary,
                        resetIcon: .obTextTertiary
                    )
                )

                Text("Click the shortcut to change it")
                    .font(.obCaptionSmall)
                    .foregroundStyle(Color.obTextTertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 360)
        .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.obBorder, lineWidth: 1)
        )
    }
}

// MARK: - BYOK Provider

/// Supported Bring-Your-Own-Key providers for AI Polish.
enum BYOKProvider: Equatable {
    case openai
    case gemini

    /// Display name for the provider.
    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    /// Placeholder text for the API key input field.
    var keyPlaceholder: String {
        switch self {
        case .openai: return "sk-..."
        case .gemini: return "AIza..."
        }
    }

    /// URL for the API key management page.
    var apiKeyURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    /// Corresponding LLMProvider value.
    var llmProvider: LLMProvider {
        switch self {
        case .openai: return .openAI
        case .gemini: return .gemini
        }
    }

    /// Corresponding KeychainManager key ID.
    var keychainID: String {
        switch self {
        case .openai: return KeychainManager.openAIKeyID
        case .gemini: return KeychainManager.geminiKeyID
        }
    }
}

// MARK: - Step 3: AI Polish Setup

private struct AIPolishStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState

    @State private var selectedOption: PolishOption = .onDevice
    @State private var selectedProvider: BYOKProvider = .openai
    @State private var apiKey: String = ""
    @State private var validationTask: Task<Void, Never>? = nil
    @State private var autoAdvanceTask: Task<Void, Never>? = nil

    enum PolishOption { case onDevice, byok }

    var body: some View {
        VStack(spacing: 0) {
            RainbowLipsView(animationState: .shimmer)
                .frame(width: 70, height: 70)
                .padding(.bottom, 18)

            Text("Enhance Your Transcriptions")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .padding(.bottom, 6)

            Text("AI Polish cleans up grammar, punctuation, and filler words after transcription. Choose how you'd like it to work:")
                .font(.obBody)
                .lineSpacing(7.7)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.bottom, 18)

            // Polish option cards
            HStack(spacing: 10) {
                polishCard(
                    icon: "desktopcomputer",
                    title: "On-Device (Free)",
                    body: "Runs locally on your Mac. No API key needed. Good for basic cleanup.",
                    badge: ("PRIVATE", Color.obSuccessText, Color.obSuccessSoft),
                    isSelected: selectedOption == .onDevice
                ) { selectedOption = .onDevice }

                polishCard(
                    icon: "key.fill",
                    title: "Bring Your Own Key",
                    body: "Use OpenAI or Gemini for advanced polishing. Requires an API key.",
                    badge: ("BETTER QUALITY", Color.obAccent, Color.obAccentSoft),
                    isSelected: selectedOption == .byok
                ) {
                    selectedOption = .byok
                }
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 14)

            // BYOK provider selection (shown when BYOK selected)
            if selectedOption == .byok {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        providerRow(
                            emoji: "⚡",
                            name: "OpenAI",
                            subtitle: "GPT-4o for polishing",
                            isSelected: selectedProvider == .openai
                        ) { selectedProvider = .openai }

                        providerRow(
                            emoji: "✦",
                            name: "Gemini",
                            subtitle: "Gemini 2.5 Pro",
                            isSelected: selectedProvider == .gemini
                        ) { selectedProvider = .gemini }
                    }
                    .frame(maxWidth: 360)

                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .leading) {
                            if apiKey.isEmpty {
                                Text("Paste your \(selectedProvider.displayName) API key")
                                    .font(.obMono)
                                    .foregroundColor(.obTextSecondary)
                            }
                            TextField("", text: $apiKey)
                                .font(.obMono)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.obBorderHover, lineWidth: 1)
                        )

                        Text("Your key should start with \"\(selectedProvider.keyPlaceholder)\"")
                            .font(.obCaptionSmall)
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    }
                    .frame(maxWidth: 360)

                    // Help link row
                    HStack(spacing: 4) {
                        Text("Don't have a key?")
                            .font(.obCaptionSmall)
                            .foregroundStyle(Color.obTextTertiary)

                        Button("Get one here \u{2192}") {
                            NSWorkspace.shared.open(selectedProvider.apiKeyURL)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.obAccent)
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                }
                .padding(.bottom, 14)
                .onChange(of: selectedProvider) { _, _ in
                    apiKey = ""
                    validationTask?.cancel()
                    validationTask = nil
                    viewModel.byokValidationState = .idle
                }
                .onChange(of: apiKey) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        viewModel.byokValidationState = .idle
                    }
                }
            }

            Text("You can change this anytime in Settings")
                .font(.obCaption)
                .foregroundStyle(Color.obTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Spacer()

            // Button row inline
            VStack(spacing: 8) {
                // Show "Verify Key" when BYOK selected, key entered, not yet validated
                if selectedOption == .byok && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                    && viewModel.byokValidationState != .valid {
                    Button {
                        validationTask = Task {
                            await viewModel.validateAndSaveKey(
                                provider: selectedProvider,
                                apiKey: apiKey,
                                appState: appState
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.byokValidationState == .validating {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(validateBtnLabel)
                        }
                    }
                    .buttonStyle(OnboardingAccentButtonStyle())
                    .disabled(viewModel.byokValidationState == .validating)
                }

                // Validation feedback
                byokFeedbackView

                Button("Continue") {
                    autoAdvanceTask?.cancel()
                    applyPolishChoice()
                    viewModel.advanceToNextStep()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedOption == .byok
                    && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                    && viewModel.byokValidationState != .valid
                )

                Button("Skip for now \u{2192}") {
                    autoAdvanceTask?.cancel()
                    viewModel.advanceToNextStep()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.obTextTertiary)
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
        .onChange(of: selectedOption) { _, newOption in
            if newOption == .onDevice {
                viewModel.byokValidationState = .idle
            }
        }
        .onChange(of: viewModel.byokValidationState) { _, newState in
            if case .valid = newState {
                autoAdvanceTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    applyPolishChoice()
                    viewModel.advanceToNextStep()
                }
            }
        }
        .onDisappear {
            autoAdvanceTask?.cancel()
        }
    }

    private func applyPolishChoice() {
        switch selectedOption {
        case .onDevice:
            appState.settings.llmProvider = .appleIntelligence
        case .byok:
            break // provider + model already set by validateAndSaveKey → validateKeyAndDiscoverModels
        }
    }

    @ViewBuilder
    private var byokFeedbackView: some View {
        switch viewModel.byokValidationState {
        case .idle:
            EmptyView()
        case .validating:
            Text("Validating key... (this can take a few seconds)")
                .font(.obCaption)
                .foregroundStyle(Color.obTextTertiary)
        case .valid:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Key saved and validated")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.obSuccessText)
        case .invalid(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.obError)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private var validateBtnLabel: String {
        switch viewModel.byokValidationState {
        case .validating: return "Validating..."
        case .valid:      return "Key Saved \u{2713}"
        default:          return "Verify Key"
        }
    }

    private func polishCard(
        icon: String,
        title: String,
        body: String,
        badge: (String, Color, Color),
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.obTextSecondary)

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.obTextPrimary)
                    .kerning(-0.1)

                Text(body)
                    .font(.obCaptionSmall)
                    .foregroundStyle(Color.obTextSecondary)
                    .lineSpacing(11 * 0.4)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                Text(badge.0)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(badge.1)
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badge.2, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.obAccent.opacity(0.03) : Color.obCardBg,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isSelected ? Color.obAccent : Color.obBorder,
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: isSelected ? Color.obAccent.opacity(0.08) : .clear,
                radius: isSelected ? 1.5 : 0
            )
        }
        .buttonStyle(.plain)
    }

    private func providerRow(
        emoji: String,
        name: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(emoji)
                    .font(.system(size: 16))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.obMonoBold)
                        .foregroundStyle(Color.obTextPrimary)
                        .kerning(-0.1)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color.obTextSecondary)
                }

                Spacer()

                if isSelected {
                    Circle()
                        .fill(Color.obAccent)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
            }
            .padding(10)
            .background(
                isSelected ? Color.obAccent.opacity(0.06) : Color.obCardBg,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.obAccent : Color.obBorder,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 4: Try It Now

private struct TryItNowStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState

    @State private var pulsing: Bool = false

    private var hotkeyDisplayString: String {
        KeySymbols.format(
            keyCode: appState.settings.toggleKeyCode,
            modifiers: appState.settings.toggleModifiers
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RainbowLipsView(animationState: lipsState)
                .frame(width: 70, height: 70)
                .padding(.bottom, 18)

            Text("Let's Try It Out")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .padding(.bottom, 6)

            Text("Press and hold **\(hotkeyDisplayString)**, say a few words, then release.")
                .font(.obBody)
                .lineSpacing(7.7)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.bottom, 18)

            // Hero keycap
            VStack(spacing: 4) {
                Text(hotkeyDisplayString)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.obAccent)
                    .frame(minWidth: 80, minHeight: 56)
                    .padding(.horizontal, 20)
                    .background(
                        LinearGradient(
                            colors: [.white, Color.obSurface],
                            startPoint: .top, endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.obAccent.opacity(0.15), lineWidth: 1.5)
                    )
                    .shadow(
                        color: Color.obAccent.opacity(pulsing ? 0.08 : 0.1),
                        radius: pulsing ? 8 : 4,
                        y: 2
                    )
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulsing)

                Text(hotkeyDisplayString.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.obTextTertiary)
                    .kerning(0.3)
                    .textCase(.uppercase)
            }
            .padding(.bottom, 16)
            .onAppear { pulsing = true }

            // Transcription feedback box
            transcriptionBox
                .padding(.bottom, 14)

            Spacer()

            // Skip link (trailing aligned)
            HStack {
                Spacer()
                Button("Skip this step →") {
                    viewModel.advanceToNextStep()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.obTextTertiary)
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
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

    private var lipsState: LipsAnimationState {
        switch viewModel.tutorialState {
        case .waiting:    return .idle
        case .recording:  return .recording
        case .result:     return .smile
        case .skipped:    return .idle
        }
    }

    @ViewBuilder
    private var transcriptionBox: some View {
        switch viewModel.tutorialState {
        case .waiting:
            VStack(spacing: 8) {
                Text("Your transcription will appear here...")
                    .font(.obBody)
                    .foregroundStyle(Color.obTextTertiary)
                    .italic()
            }
            .frame(maxWidth: 360, minHeight: 100)
            .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        Color.obAccent.opacity(0.12),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )

        case .recording:
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.obError)
                    .frame(width: 10, height: 10)

                // Waveform bars
                HStack(spacing: 3) {
                    ForEach([8, 16, 12, 20, 14, 10, 18], id: \.self) { height in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.obError)
                            .frame(width: 3, height: CGFloat(height))
                    }
                }

                Text("Recording...")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.obError)
            }
            .frame(maxWidth: 360, minHeight: 100)
            .background(Color.obError.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.obError.opacity(0.2), lineWidth: 1.5)
            )

        case .result(let text):
            VStack(alignment: .leading) {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.obRainbow)
                        .frame(width: 3)
                        .padding(.vertical, 2)

                    Text(text)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.obTextPrimary)
                        .lineSpacing(16 * 0.6)
                        .padding(.leading, 14)
                }
            }
            .padding(20)
            .frame(maxWidth: 360, minHeight: 100, alignment: .topLeading)
            .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.obSuccess.opacity(0.25), lineWidth: 1.5)
            )
            .shadow(color: Color.obSuccess.opacity(0.08), radius: 10, y: 4)

        case .skipped:
            EmptyView()
        }
    }
}

// MARK: - Step 5: Ready

private struct ReadyStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(AppState.self) private var appState
    let onComplete: () -> Void

    private var hotkeyDisplayString: String {
        KeySymbols.format(
            keyCode: appState.settings.toggleKeyCode,
            modifiers: appState.settings.toggleModifiers
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RainbowLipsView(animationState: .triumph)
                .frame(width: 70, height: 70)
                .padding(.bottom, 18)

            Text("You're All Set!")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .padding(.bottom, 6)

            Text("EnviousWispr is running in your menu bar. Press **\(hotkeyDisplayString)** anytime to dictate.")
                .font(.obBody)
                .lineSpacing(7.7)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.bottom, 18)

            // Enhancement card (toggle + settings link)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Auto-Paste")
                            .font(.obSubheading)
                            .foregroundStyle(Color.obTextPrimary)
                        Text("Automatically paste transcriptions into the active app.")
                            .font(.obCaption)
                            .foregroundStyle(Color.obTextSecondary)
                            .lineSpacing(12 * 0.35)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { appState.permissions.accessibilityGranted },
                        set: { enabled in
                            if enabled {
                                _ = appState.permissions.requestAccessibilityAccess()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.obSuccess)
                }
                .padding(.vertical, 6)

            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 360)
            .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.obBorder, lineWidth: 1)
            )
            .shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1.5, y: 1)
            .padding(.bottom, 10)

            if appState.permissions.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.obSuccess)
                    Text("Accessibility enabled")
                        .font(.obCaption)
                        .foregroundStyle(Color.obSuccessText)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()

            // Full-width Done button
            Button {
                onComplete()
            } label: {
                Text("Done")
                    .font(.obButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 360)
                    .padding(.vertical, 13)
                    .background(Color.obBtnDark, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 10)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard !appState.permissions.accessibilityGranted else { return }
            appState.permissions.refreshAccessibilityStatus()
        }
    }
}

