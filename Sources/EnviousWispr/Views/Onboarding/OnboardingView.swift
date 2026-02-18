import SwiftUI

/// First-launch onboarding flow.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Capsule()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: accessibilityStep
                case 3: readyStep
                default: EmptyView()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button("Continue") { currentStep += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") {
                        appState.hasCompletedOnboarding = true
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 360)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to EnviousWispr")
                .font(.title)
                .bold()

            Text("Local-first dictation powered by on-device AI.\nYour voice never leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: appState.permissions.hasMicrophonePermission
                  ? "checkmark.circle.fill" : "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(appState.permissions.hasMicrophonePermission ? .green : .orange)

            Text("Microphone Access")
                .font(.title2)
                .bold()

            Text("EnviousWispr needs microphone access to capture your speech for transcription.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if !appState.permissions.hasMicrophonePermission {
                Button("Grant Microphone Access") {
                    Task { _ = await appState.permissions.requestMicrophoneAccess() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Label("Microphone access granted", systemImage: "checkmark")
                    .foregroundStyle(.green)
            }
        }
        .padding()
    }

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: appState.permissions.hasAccessibilityPermission
                  ? "checkmark.circle.fill" : "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(appState.permissions.hasAccessibilityPermission ? .green : .orange)

            Text("Accessibility Permission")
                .font(.title2)
                .bold()

            Text("Enables paste-to-app and global hotkey support.\nYou can skip this and enable later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if !appState.permissions.hasAccessibilityPermission {
                Button("Open Accessibility Settings") {
                    appState.permissions.promptAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Label("Accessibility access granted", systemImage: "checkmark")
                    .foregroundStyle(.green)
            }
        }
        .padding()
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Label("Click Record or use the global hotkey", systemImage: "mic.circle")
                Label("Transcripts auto-copy to clipboard", systemImage: "doc.on.clipboard")
                Label("Polish with AI in Settings", systemImage: "sparkles")
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}
