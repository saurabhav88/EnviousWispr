import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
final class OnboardingV2ViewModel {
    enum Screen { case welcome, settingUp, ready }
    enum SetupPhase { case checklist, permissions }

    enum ChecklistItemStatus: Equatable {
        case pending, inProgress, completed, error(String)

        var isInProgress: Bool {
            if case .inProgress = self { return true }
            return false
        }
    }

    var currentScreen: Screen = .welcome
    var setupPhase: SetupPhase = .checklist
    var checklistStatuses: [ChecklistItemStatus] = [.pending, .pending, .pending]

    var micGranted = false
    var accessibilityGranted = false
    var showSkipLink = false

    var downloadError: String?
    var retryCount = 0

    var lipsState: LipsAnimationState {
        switch currentScreen {
        case .welcome: return .idle
        case .ready: return .heart
        case .settingUp:
            if setupPhase == .permissions { return .triumph }
            if downloadError != nil { return .drooping }
            if case .completed = checklistStatuses[2] { return .triumph }
            if checklistStatuses[0].isInProgress { return .equalizer }
            return .idle
        }
    }

    func startSetup(asrManager: ASRManager, settings: SettingsManager) async {
        settings.onboardingState = .settingUp
        checklistStatuses[0] = .inProgress
        do {
            try await asrManager.loadModel()
            // Check cancellation before advancing — window may have closed during download.
            try Task.checkCancellation()
            checklistStatuses[0] = .completed

            checklistStatuses[1] = .inProgress
            try await Task.sleep(nanoseconds: 1_500_000_000)
            settings.llmProvider = .appleIntelligence
            checklistStatuses[1] = .completed

            checklistStatuses[2] = .inProgress
            try await Task.sleep(nanoseconds: 1_500_000_000)
            checklistStatuses[2] = .completed

            try await Task.sleep(nanoseconds: 400_000_000)
            settings.onboardingState = .needsPermissions
            setupPhase = .permissions
        } catch is CancellationError {
            // Task was cancelled (window closed mid-setup). Leave onboardingState as .settingUp
            // so the next launch re-runs the checklist from scratch.
        } catch {
            downloadError = error.localizedDescription
            checklistStatuses[0] = .error(error.localizedDescription)
        }
    }

    func retryDownload() {
        downloadError = nil
        checklistStatuses = [.pending, .pending, .pending]
        retryCount += 1
    }

    func requestMicPermission(permissions: PermissionsService) async {
        _ = await permissions.requestMicrophoneAccess()
        micGranted = permissions.hasMicrophonePermission
    }

    func openAccessibilitySettings(permissions: PermissionsService) {
        _ = permissions.requestAccessibilityAccess()
    }

    func finishOnboarding(settings: SettingsManager) {
        settings.onboardingState = .completed
    }
}

// MARK: - Main View

struct OnboardingV2View: View {
    private static let screenTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: 20)),
        removal: .opacity
    )

    @Environment(AppState.self) private var appState
    var onComplete: () -> Void

    @State private var viewModel = OnboardingV2ViewModel()

    var body: some View {
        ZStack {
            switch viewModel.currentScreen {
            case .welcome:
                WelcomeScreenV2(viewModel: viewModel)
                    .transition(Self.screenTransition)
            case .settingUp:
                SettingUpScreenV2(viewModel: viewModel)
                    .transition(Self.screenTransition)
            case .ready:
                ReadyScreenV2(viewModel: viewModel, onComplete: {
                    viewModel.finishOnboarding(settings: appState.settings)
                    onComplete()
                })
                .transition(Self.screenTransition)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.currentScreen)
        .padding(28)
        .frame(width: 460)
        .background(Color.obCardBg)
        .onAppear(perform: recoverFromPersistedState)
        // setupPhase is intentionally excluded from the id: changing phase at the end of
        // startSetup must NOT cancel the running task. currentScreen + retryCount are
        // sufficient triggers — retryCount bumps on retry, currentScreen bumps on navigation.
        .task(id: "\(viewModel.currentScreen)-\(viewModel.retryCount)") {
            guard viewModel.currentScreen == .settingUp,
                  viewModel.setupPhase == .checklist,
                  viewModel.downloadError == nil,
                  case .pending = viewModel.checklistStatuses[0] else { return }
            await viewModel.startSetup(asrManager: appState.asrManager, settings: appState.settings)
        }
    }

    private func recoverFromPersistedState() {
        switch appState.settings.onboardingState {
        case .notStarted:
            viewModel.currentScreen = .welcome
        case .settingUp:
            viewModel.currentScreen = .settingUp
            viewModel.setupPhase = .checklist
        case .needsPermissions:
            viewModel.currentScreen = .settingUp
            viewModel.checklistStatuses = [.completed, .completed, .completed]
            appState.permissions.refreshAccessibilityStatus()
            viewModel.micGranted = appState.permissions.hasMicrophonePermission
            viewModel.accessibilityGranted = appState.permissions.accessibilityGranted
            if viewModel.micGranted && viewModel.accessibilityGranted {
                viewModel.currentScreen = .ready
            } else {
                viewModel.setupPhase = .permissions
            }
        case .completed:
            viewModel.currentScreen = .ready
        }
    }
}

// MARK: - Screen 1: Welcome

private struct WelcomeScreenV2: View {
    var viewModel: OnboardingV2ViewModel

    private static let features: [(icon: String, title: String, subtitle: String)] = [
        ("shield.fill",  "On-Device",     "Your voice never leaves your Mac."),
        ("wifi.slash",   "Offline-Ready",  "Works without internet."),
        ("bolt.fill",    "Native Speed",   "Built for Apple Silicon."),
        ("person.fill",  "Free & Private", "No account, no tracking."),
    ]

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            RainbowLipsView(animationState: .idle, size: 144)
                .padding(.bottom, 18)

            Text("Your Voice, Instantly Captured.")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text("The privacy-first dictation app built for macOS.")
                .font(.obBody)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 22)

            VStack(spacing: 10) {
                ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.obAccent)
                            .frame(width: 32, height: 32)
                            .background(Color.obAccentSoft, in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .font(.obLabel)
                                .foregroundStyle(Color.obTextPrimary)
                            Text(feature.subtitle)
                                .font(.obCaption)
                                .foregroundStyle(Color.obTextSecondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 12))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .animation(.easeOut(duration: 0.4).delay(0.1 + Double(index) * 0.08), value: appeared)
                }
            }
            .padding(.bottom, 24)

            Spacer()

            Button("Get Started") {
                viewModel.currentScreen = .settingUp
            }
            .buttonStyle(OnboardingButtonStyle())
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Screen 2: Setting Up

private struct SettingUpScreenV2: View {
    var viewModel: OnboardingV2ViewModel

    private static let phaseTransition: AnyTransition = .opacity.combined(with: .offset(y: 8))

    var body: some View {
        ZStack {
            if viewModel.setupPhase == .checklist {
                ChecklistPhaseView(viewModel: viewModel)
                    .transition(Self.phaseTransition)
            } else {
                PermissionsPhaseView(viewModel: viewModel)
                    .transition(Self.phaseTransition)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.setupPhase)
    }
}

// MARK: Checklist Phase

private struct ChecklistPhaseView: View {
    var viewModel: OnboardingV2ViewModel

    private static let items: [(title: String, subtitle: String)] = [
        ("Downloading speech model", "~100 MB, one-time setup"),
        ("Configuring on-device AI", "Apple Intelligence"),
        ("Setting your hotkey",      "Default: ⌥ Option"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            RainbowLipsView(animationState: viewModel.lipsState, size: 144)
                .padding(.bottom, 18)

            Text("Warming Up the AI...")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .padding(.bottom, 6)

            Text("Setting up your private, on-device transcription.")
                .font(.obBody)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 20)

            VStack(spacing: 0) {
                ForEach(Array(Self.items.enumerated()), id: \.offset) { index, item in
                    ChecklistItemRow(
                        index: index,
                        status: viewModel.checklistStatuses[index],
                        title: item.title,
                        subtitle: item.subtitle,
                        showProgressBar: index == 0 && viewModel.checklistStatuses[0].isInProgress
                    )
                    if index < Self.items.count - 1 {
                        Divider().padding(.horizontal, 14)
                    }
                }
            }
            .padding(.vertical, 8)
            .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.obBorder, lineWidth: 1)
            )
            .padding(.bottom, 16)

            if let error = viewModel.downloadError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.obCaption)
                        .foregroundStyle(Color.obError)
                        .multilineTextAlignment(.center)

                    Button("Retry") { viewModel.retryDownload() }
                        .buttonStyle(OnboardingButtonStyle(color: .obError))
                }
                .padding(.top, 4)
            }

            Spacer()
        }
    }
}

private struct ChecklistItemRow: View {
    let index: Int
    let status: OnboardingV2ViewModel.ChecklistItemStatus
    let title: String
    let subtitle: String
    let showProgressBar: Bool

    @State private var spinAngle: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                statusIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.obLabel)
                        .foregroundStyle(Color.obTextPrimary)
                    Text(subtitle)
                        .font(.obCaption)
                        .foregroundStyle(Color.obTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showProgressBar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.obBorder)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.obRainbow)
                            .frame(width: geo.size.width * 0.65, height: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 3)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showProgressBar)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            ZStack {
                Circle()
                    .strokeBorder(Color.obBorder, lineWidth: 1.5)
                Text("\(index + 1)")
                    .font(.obCaptionSmall)
                    .foregroundStyle(Color.obTextTertiary)
            }
        case .inProgress:
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.obAccent, lineWidth: 2.5)
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(spinAngle))
                .onAppear { spinAngle = 360 }
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinAngle)
        case .completed:
            ZStack {
                Circle().fill(Color.obSuccess)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .transition(.scale.combined(with: .opacity))
        case .error:
            ZStack {
                Circle().fill(Color.obErrorSoft)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.obError)
            }
        }
    }
}

// MARK: Permissions Phase

private struct PermissionsPhaseView: View {
    var viewModel: OnboardingV2ViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            RainbowLipsView(animationState: .triumph, size: 144)
                .padding(.bottom, 18)

            Text("Almost there. Just two permissions.")
                .font(.obDisplay)
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text("These let EnviousWispr listen and paste for you.")
                .font(.obBody)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 22)

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "To hear your voice for transcription.",
                    isGranted: viewModel.micGranted,
                    onGrant: { Task { await viewModel.requestMicPermission(permissions: appState.permissions) } }
                )

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    subtitle: "To paste your transcribed text into any app.",
                    isGranted: viewModel.accessibilityGranted,
                    onGrant: { viewModel.openAccessibilitySettings(permissions: appState.permissions) }
                )
            }
            .padding(.bottom, 20)

            Spacer()

            VStack(spacing: 8) {
                Button {
                    viewModel.currentScreen = .ready
                } label: {
                    Text("Continue")
                        .font(.obSubheading)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 13)
                        .background(
                            viewModel.micGranted ? Color.obTextPrimary : Color.obTextPrimary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.micGranted)

                if viewModel.showSkipLink && !viewModel.accessibilityGranted {
                    Button("Skip for now") {
                        viewModel.currentScreen = .ready
                    }
                    .font(.obCaption)
                    .foregroundStyle(Color.obTextTertiary)
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            appState.permissions.refreshAccessibilityStatus()
            viewModel.micGranted = appState.permissions.hasMicrophonePermission
            viewModel.accessibilityGranted = appState.permissions.accessibilityGranted
            if viewModel.accessibilityGranted {
                appState.settings.autoCopyToClipboard = true
            }
        }
        .task { await pollPermissions() }
    }

    /// Polls both mic and accessibility status every 2 seconds.
    /// Shows "Skip for now" link after 10 seconds if accessibility not granted.
    /// Auto-cancelled when the view disappears via .task modifier.
    private func pollPermissions() async {
        var elapsed = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            elapsed += 2

            appState.permissions.refreshAccessibilityStatus()
            if appState.permissions.accessibilityGranted && !viewModel.accessibilityGranted {
                viewModel.accessibilityGranted = true
                appState.settings.autoCopyToClipboard = true
            }

            if appState.permissions.hasMicrophonePermission && !viewModel.micGranted {
                viewModel.micGranted = true
            }

            if elapsed >= 10 && !viewModel.showSkipLink {
                withAnimation { viewModel.showSkipLink = true }
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isGranted: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isGranted ? Color.obSuccess : Color.obAccent)
                .frame(width: 32, height: 32)
                .background(
                    isGranted ? Color.obSuccessSoft : Color.obAccentSoft,
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.obLabel)
                    .foregroundStyle(Color.obTextPrimary)
                Text(subtitle)
                    .font(.obCaption)
                    .foregroundStyle(Color.obTextSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.obSuccess)
                    Text("Granted")
                        .font(.obCaptionSmall)
                        .foregroundStyle(Color.obSuccessText)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Button("Grant") {
                    onGrant()
                }
                .buttonStyle(OnboardingButtonStyle(color: .obAccent))
                .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.3), value: isGranted)
    }
}

// MARK: - Screen 3: Ready

private struct ReadyScreenV2: View {
    var viewModel: OnboardingV2ViewModel
    @Environment(AppState.self) private var appState
    let onComplete: () -> Void

    var body: some View {
        @Bindable var bindableAppState = appState
        VStack(spacing: 0) {
            // Bigger lips + radial glow for a celebratory feel
            ZStack {
                RadialGradient(
                    colors: [Color.obAccent.opacity(0.12), Color.clear],
                    center: .center,
                    startRadius: 16,
                    endRadius: 100
                )
                .frame(width: 220, height: 220)
                .blur(radius: 4)

                RainbowLipsView(animationState: .heart, size: 144)
            }
            .padding(.bottom, 20)

            Text("Ready to Wispr!")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.obTextPrimary)
                .kerning(-0.4)
                .padding(.bottom, 6)

            Text("Tap the keycap to change your hotkey,\nthen press GET STARTED!")
                .font(.obBody)
                .foregroundStyle(Color.obTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            // Interactive keycap — tap to record, shows result inline
            KeycapHotkeyView(
                keyCode: $bindableAppState.settings.toggleKeyCode,
                modifiers: $bindableAppState.settings.toggleModifiers
            )
            .padding(.bottom, 20)

            if !appState.permissions.accessibilityGranted {
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(Color.obWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pro Tip")
                            .font(.obLabel)
                            .foregroundStyle(Color.obTextPrimary)
                        Text("Enable Accessibility in Settings to use Auto-Paste — transcriptions will paste directly into your active app.")
                            .font(.obCaption)
                            .foregroundStyle(Color.obTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .background(Color.obWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.obWarning.opacity(0.25), lineWidth: 1)
                )
                .padding(.bottom, 16)
                .transition(.opacity)
            }

            Spacer()

            VStack(spacing: 0) {
                Button(action: onComplete) {
                    Text("GET STARTED!")
                        .font(.system(size: 15, weight: .heavy))
                        .kerning(0.3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 13)
                        .background(Color.obTextPrimary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                // Power User nudge — separated by a hairline rule, per mockup
                VStack(spacing: 4) {
                    Divider()
                        .padding(.vertical, 14)

                    Text("POWER USER?")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.obTextPrimary)
                        .kerning(0.5)

                    Text("Change your AI model, hotkey, and more in Settings.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.obTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appState.permissions.accessibilityGranted)
    }
}

// MARK: - Keycap Hotkey View

/// A large interactive keycap that doubles as a hotkey recorder.
/// Tap to enter recording mode; press a key combo to save; tap again or press Escape to cancel.
private struct KeycapHotkeyView: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: NSEvent.ModifierFlags

    @Environment(AppState.self) private var appState
    @State private var isRecording = false
    @State private var cursorOpacity: Double = 1.0
    @State private var pulsePhase: Bool = false

    private var displayLabel: String {
        KeySymbols.format(keyCode: keyCode, modifiers: modifiers)
    }

    /// Human-readable name shown below the keycap (e.g. "LEFT OPTION")
    private var keyNameLabel: String {
        if ModifierKeyCodes.isModifierOnly(keyCode) && modifiers.isEmpty {
            return KeySymbols.formatModifierOnly(modifiers, keyCode: keyCode).uppercased()
        }
        return displayLabel.uppercased()
    }

    var body: some View {
        // Outer unified card — matches .hotkey-unified-card (max-width: 360px)
        VStack(spacing: 0) {
            // --- Keycap + "Change" chip ---
            ZStack(alignment: .topTrailing) {
                // Keycap shell — fixed size, NOT expanding to fill card
                keycapShell
                    .frame(width: 160, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(
                                isRecording ? Color.obAccent : Color.obAccent.opacity(0.18),
                                lineWidth: isRecording ? 2 : 1.5
                            )
                    )
                    // Default: 0 3px 10px rgba(124,58,237,0.12), 0 1px 3px rgba(15,10,26,0.07)
                    .shadow(
                        color: Color.obAccent.opacity(isRecording ? (pulsePhase ? 0.10 : 0.18) : 0.12),
                        radius: isRecording ? (pulsePhase ? 10 : 6) : 5,
                        y: isRecording ? 0 : 3
                    )
                    .shadow(
                        color: isRecording ? .clear : Color.obTextPrimary.opacity(0.07),
                        radius: 2, y: 1
                    )
                    .overlay(
                        KeyCaptureView(isRecording: isRecording, onKeyEvent: handleKeyEvent)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { toggleRecording() }

                // "Change" chip — overlaps top-right corner
                if !isRecording {
                    Text("Change")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.obAccent, in: Capsule())
                        .shadow(color: Color.obAccent.opacity(0.35), radius: 3, y: 2)
                        .offset(x: 12, y: -4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 4) // breathing room for chip

            // Key name label
            Text(isRecording ? "Listening for input" : keyNameLabel)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.55)
                .foregroundStyle(
                    isRecording ? Color.obAccent.opacity(0.7) : Color.obTextTertiary
                )
                .padding(.top, 7)
                .padding(.bottom, 14)

            // Divider
            Rectangle()
                .fill(Color.obBorder)
                .frame(height: 1)

            // Usage hint / cancel hint
            Group {
                if isRecording {
                    (Text("Press ").foregroundStyle(Color.obTextSecondary)
                    + Text("Esc").fontWeight(.semibold).foregroundStyle(Color.obTextPrimary)
                    + Text(" to cancel without changing your hotkey.").foregroundStyle(Color.obTextSecondary))
                        .font(.system(size: 12))
                } else {
                    Text("Hold to dictate. Release to transcribe.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.obTextSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
        }
        .padding(.top, 20)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: 320) // constrain card width like mockup
        .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isRecording ? Color.obAccent : Color.obBorder,
                    lineWidth: 1
                )
        )
        // Card shadow: default subtle, recording = purple glow ring
        .shadow(
            color: isRecording
                ? Color.obAccent.opacity(0.12)
                : Color.obTextPrimary.opacity(0.04),
            radius: isRecording ? 6 : 2,
            y: isRecording ? 0 : 1
        )
        .animation(.spring(duration: 0.25), value: isRecording)
        .onDisappear { if isRecording { stopRecording() } }
        .onChange(of: isRecording) { _, recording in
            if recording {
                cursorOpacity = 0.0
                pulsePhase = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    cursorOpacity = 1.0
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulsePhase = true
                    }
                }
            } else {
                cursorOpacity = 1.0
                pulsePhase = false
            }
        }
    }

    /// The keycap interior — gradient + inset shadow + content
    @ViewBuilder
    private var keycapShell: some View {
        ZStack {
            // Background
            if isRecording {
                Color.obAccent.opacity(0.10)
            } else {
                LinearGradient(
                    colors: [.white, Color.obSurface],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // Inset bottom shadow (simulate inset 0 -3px 0)
            if !isRecording {
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [Color.clear, Color.obAccent.opacity(0.09)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 6)
                }
                .allowsHitTesting(false)
            }

            // Content
            if isRecording {
                HStack(spacing: 6) {
                    Text("Press keys…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.obAccent)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.obAccent)
                        .frame(width: 2, height: 18)
                        .opacity(cursorOpacity)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                            value: cursorOpacity
                        )
                }
            } else {
                Text(displayLabel)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.obAccent)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        appState.hotkeyService.suspend()
    }

    private func stopRecording() {
        isRecording = false
        appState.hotkeyService.resume()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Escape with no modifiers cancels
        if event.type != .flagsChanged,
           event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            Task { @MainActor in stopRecording() }
            return
        }

        let newKeyCode = event.keyCode

        // Modifier-only hotkey (e.g. bare Option)
        if event.type == .flagsChanged, ModifierKeyCodes.isModifierOnly(newKeyCode) {
            Task { @MainActor in
                keyCode = newKeyCode
                modifiers = []
                stopRecording()
            }
            return
        }

        let newModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        Task { @MainActor in
            keyCode = newKeyCode
            modifiers = newModifiers
            stopRecording()
        }
    }
}
