import SwiftUI

/// First-launch onboarding flow with step badges.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    private let steps = ["Welcome", "Microphone", "Accessibility", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("Setup")
                .font(.headline)
                .padding(.top, 16)

            // Step badges
            HStack(spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                    StepBadge(
                        label: label,
                        step: index + 1,
                        state: index < currentStep ? .completed
                             : index == currentStep ? .current
                             : .upcoming
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

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
                    Button {
                        currentStep -= 1
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                            Text("Back")
                        }
                    }
                }

                Spacer()

                if currentStep < steps.count - 1 {
                    Button {
                        currentStep += 1
                    } label: {
                        HStack(spacing: 2) {
                            Text("Continue")
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") {
                        appState.settings.hasCompletedOnboarding = true
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 480, height: 380)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            IconCircle(systemName: "mic.circle.fill", tint: .blue)

            Text("Welcome to EnviousWispr")
                .font(.title)
                .bold()

            Text("Smart dictation powered by on-device AI.\nRecord, transcribe, and polish your words.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            IconCircle(
                systemName: appState.permissions.hasMicrophonePermission
                    ? "checkmark.circle.fill" : "mic.badge.plus",
                tint: appState.permissions.hasMicrophonePermission ? .green : .orange
            )

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
            IconCircle(
                systemName: appState.permissions.hasAccessibilityPermission
                    ? "checkmark.circle.fill" : "lock.shield",
                tint: appState.permissions.hasAccessibilityPermission ? .green : .orange
            )

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
            IconCircle(systemName: "checkmark.seal.fill", tint: .green)

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

// MARK: - Step Badge

enum StepState {
    case completed, current, upcoming
}

struct StepBadge: View {
    let label: String
    let step: Int
    let state: StepState

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .completed:
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            case .current:
                Text("\(step).")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.accentColor)
            case .upcoming:
                Text("\(step).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(label)
                .font(.caption)
                .fontWeight(state == .current ? .bold : .regular)
                .foregroundStyle(state == .upcoming ? Color.secondary.opacity(0.5) : state == .completed ? Color.green : Color.accentColor)
        }
    }
}

// MARK: - Icon Circle

struct IconCircle: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 48))
            .foregroundStyle(tint)
            .frame(width: 80, height: 80)
            .background(
                Circle()
                    .fill(tint.opacity(0.12))
            )
    }
}
