import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import IOKit.pwr_mgt
import SwiftUI

// MARK: - ViewModel

@MainActor
@Observable
final class OnboardingV2ViewModel {
  enum Screen { case welcome, settingUp, ready }
  enum SetupPhase { case checklist, permissions }

  enum ChecklistItemStatus: Equatable {
    case pending, inProgress, completed
    case error(String)

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

  var downloadError: String?
  /// Raw error details for support diagnostics (hidden behind "Copy error details" button).
  var rawErrorDetails: String?
  var retryCount = 0

  /// ViewModel-owned progress state, polled from ASR manager.
  /// SwiftUI can't observe @Observable properties through protocol existentials
  /// (asrManager is typed as `any ASRManagerInterface`), so we poll and copy.
  var downloadProgress: Double = 0
  var downloadPhase: String = ""
  var downloadDetail: String = ""
  private var progressPollTimer: Timer?

  /// Quirky installation message, cycled during the compilation phase.
  var installQuip: String = ""
  private var quipTimer: Timer?
  private var quipIndex: Int = 0

  /// Fun status messages shown during model compilation (~20-30s wait).
  private static let installQuips = [
    "Tuning the neural ears...",
    "Teaching AI to listen politely...",
    "Loading all 50,000 words...",
    "Installing 'um' and 'uh' filters...",
    "Calibrating whisper detection...",
    "Warming up Apple Silicon...",
    "Polishing the speech engine...",
    "Training patience module...",
    "Preparing to ignore background noise...",
    "Sharpening neural networks...",
    "Convincing AI that you said 'duck'...",
    "Almost there... pinky promise",
  ]

  // Sleep prevention — holds a power assertion during download to prevent macOS sleep.
  private var sleepAssertionID: IOPMAssertionID = 0
  private var isSleepPrevented = false

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

  /// Minimum free disk space required for model download + compilation (1 GB).
  private static let requiredDiskSpaceBytes: Int64 = 1_073_741_824

  func startSetup(asrManager: any ASRManagerInterface, settings: SettingsManager) async {
    settings.onboardingState = .settingUp

    // Disk space preflight — fail early with a friendly message instead of failing at 80%.
    if let attrs = try? FileManager.default.attributesOfFileSystem(
      forPath: NSHomeDirectory()
    ), let freeSpace = attrs[.systemFreeSize] as? Int64,
      freeSpace < Self.requiredDiskSpaceBytes
    {
      let freeMB = freeSpace / 1_048_576
      downloadError =
        "Not enough disk space (\(freeMB) MB free). EnviousWispr needs about 1 GB to download and install the speech model."
      checklistStatuses[0] = .error(downloadError!)
      return
    }

    checklistStatuses[0] = .inProgress
    preventSleep()
    startProgressPolling()
    do {
      try await asrManager.loadModel()
      stopProgressPolling()
      allowSleep()
      // Check cancellation before advancing — window may have closed during download.
      try Task.checkCancellation()
      checklistStatuses[0] = .completed
      installQuip = ""
      stopQuipTimer()
      TelemetryService.shared.onboardingStepCompleted(step: "model_download", result: "completed")

      checklistStatuses[1] = .inProgress
      try await Task.sleep(nanoseconds: 1_500_000_000)
      // #923: Apple Intelligence is now the canonical default
      // (SettingsDefaultValues.llmProvider), so no write here. Writing the
      // default would make every onboarded user look "customized" forever,
      // polluting the default/custom distinction the migration relies on.
      // Onboarded users get Apple Intelligence via the canonical default; this
      // step stays a visual checklist beat + telemetry only.
      checklistStatuses[1] = .completed
      TelemetryService.shared.onboardingStepCompleted(step: "ai_config", result: "completed")

      checklistStatuses[2] = .inProgress
      try await Task.sleep(nanoseconds: 1_500_000_000)
      checklistStatuses[2] = .completed
      TelemetryService.shared.onboardingStepCompleted(step: "hotkey_config", result: "completed")

      try await Task.sleep(nanoseconds: 400_000_000)
      settings.onboardingState = .needsPermissions
      setupPhase = .permissions
    } catch is CancellationError {
      stopProgressPolling()
      allowSleep()
      // Task was cancelled (window closed mid-setup). Leave onboardingState as .settingUp
      // so the next launch re-runs the checklist from scratch.
    } catch {
      stopProgressPolling()
      allowSleep()
      let friendly = Self.friendlyError(error)
      downloadError = friendly
      rawErrorDetails = "\(error)"
      checklistStatuses[0] = .error(friendly)
    }
  }

  func retryDownload() {
    downloadError = nil
    rawErrorDetails = nil
    installQuip = ""
    stopQuipTimer()
    checklistStatuses = [.pending, .pending, .pending]
    retryCount += 1
  }

  // MARK: - Progress Polling

  /// Start polling the shared progress file at ~8 Hz.
  /// The XPC ASR service writes progress to a temp file; we read it here.
  /// This bypasses all XPC serialization issues.
  func startProgressPolling() {
    stopProgressPolling()
    let progressFile = ProgressFile.shared
    let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let state = progressFile.read() else { return }
        self.downloadProgress = state.fraction
        self.downloadPhase = state.phase
        self.downloadDetail = state.detail

        // Start quip timer when compilation begins (fraction >= 0.5)
        if state.fraction >= 0.5 && self.quipTimer == nil {
          self.startQuipTimer()
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    progressPollTimer = timer
  }

  func stopProgressPolling() {
    progressPollTimer?.invalidate()
    progressPollTimer = nil
    stopQuipTimer()
  }

  // MARK: - Installation Quips

  private func startQuipTimer() {
    quipIndex = 0
    installQuip = Self.installQuips[0]
    let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.quipIndex = (self.quipIndex + 1) % Self.installQuips.count
        self.installQuip = Self.installQuips[self.quipIndex]
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    quipTimer = timer
  }

  private func stopQuipTimer() {
    quipTimer?.invalidate()
    quipTimer = nil
    installQuip = ""
  }

  // MARK: - Sleep Prevention

  private func preventSleep() {
    guard !isSleepPrevented else { return }
    let reason = "EnviousWispr is downloading the speech model" as CFString
    let success = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason,
      &sleepAssertionID
    )
    isSleepPrevented = (success == kIOReturnSuccess)
  }

  private func allowSleep() {
    guard isSleepPrevented else { return }
    IOPMAssertionRelease(sleepAssertionID)
    isSleepPrevented = false
  }

  // MARK: - Friendly Error Messages

  /// Maps raw error descriptions to user-friendly messages.
  private static func friendlyError(_ error: any Error) -> String {
    let desc = error.localizedDescription.lowercased()

    if desc.contains("timed out") || desc.contains("timeout") {
      return "The download timed out. Please check your internet connection and try again."
    }
    if desc.contains("not connected") || desc.contains("network") || desc.contains("offline") {
      return "No internet connection. Please connect to the internet and try again."
    }
    if desc.contains("could not connect") || desc.contains("cannot connect") {
      return
        "Couldn't reach the download server. Please check your internet connection and try again."
    }
    if desc.contains("rate limit") {
      return "The download server is busy. Please wait a moment and try again."
    }
    if desc.contains("disk") || desc.contains("space") || desc.contains("no space") {
      return "Not enough disk space. Please free up space and try again."
    }

    // Fallback: use the original description but trim technical prefixes
    return "Download failed: \(error.localizedDescription)"
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
    TelemetryService.shared.onboardingCompleted(
      asrBackend: settings.selectedBackend.rawValue, recordingMode: settings.recordingMode.rawValue)
  }
}

// MARK: - Main View

struct OnboardingV2View: View {
  private static let screenTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 20)),
    removal: .opacity
  )

  @Environment(SettingsManager.self) private var settings
  @Environment(PermissionsService.self) private var permissions
  @Environment(\.asrManager) private var asrManagerEnv
  var onComplete: () -> Void

  @State private var viewModel = OnboardingV2ViewModel()

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var asrManager: any ASRManagerInterface { asrManagerEnv! }

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
        ReadyScreenV2(onComplete: {
          viewModel.finishOnboarding(settings: settings)
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
        case .pending = viewModel.checklistStatuses[0]
      else { return }
      await viewModel.startSetup(asrManager: asrManager, settings: settings)
    }
  }

  private func recoverFromPersistedState() {
    switch settings.onboardingState {
    case .notStarted:
      viewModel.currentScreen = .welcome
    case .settingUp:
      viewModel.currentScreen = .settingUp
      viewModel.setupPhase = .checklist
    case .needsPermissions:
      viewModel.currentScreen = .settingUp
      viewModel.checklistStatuses = [.completed, .completed, .completed]
      permissions.refreshAccessibilityStatus()
      viewModel.micGranted = permissions.hasMicrophonePermission
      viewModel.accessibilityGranted = permissions.accessibilityGranted
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
    ("shield.fill", "On-Device", "Your voice never leaves your Mac."),
    ("wifi.slash", "Offline-Ready", "Works without internet."),
    ("bolt.fill", "Native Speed", "Built for Apple Silicon."),
    ("person.fill", "Free & Private", "No account required. Anonymous analytics only."),
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
        TelemetryService.shared.onboardingStarted()
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
    ("Setting up speech model", "One-time setup"),
    ("Configuring on-device AI", "Apple Intelligence"),
    ("Setting your hotkey", "Default: ⌥ Option"),
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

      Text("Downloading the local speech model so EnviousWispr can run privately on your Mac.")
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
            subtitle: downloadSubtitle(for: index, fallback: item.subtitle),
            showProgressBar: index == 0 && viewModel.checklistStatuses[0].isInProgress,
            progress: index == 0 ? viewModel.downloadProgress : nil
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

          HStack(spacing: 12) {
            Button("Retry") { viewModel.retryDownload() }
              .buttonStyle(OnboardingButtonStyle(color: .obError))

            if viewModel.rawErrorDetails != nil {
              Button("Copy error details") {
                if let details = viewModel.rawErrorDetails {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(details, forType: .string)
                }
              }
              .font(.obCaption)
              .foregroundStyle(Color.obTextTertiary)
              .buttonStyle(.plain)
            }
          }
        }
        .padding(.top, 4)
      }

      Spacer()
    }
  }

  /// Returns live status text for the model setup row.
  /// During download: "Downloading... X MB of 23 MB"
  /// During compilation: cycles through quirky installation quips
  private func downloadSubtitle(for index: Int, fallback: String) -> String {
    guard index == 0, viewModel.checklistStatuses[0].isInProgress else { return fallback }

    // During compilation phase — show quips
    if viewModel.downloadProgress >= 0.5 && !viewModel.installQuip.isEmpty {
      return viewModel.installQuip
    }

    let phase = viewModel.downloadPhase
    let detail = viewModel.downloadDetail
    if phase.isEmpty { return fallback }
    return detail.isEmpty ? phase : "\(phase) \(detail)"
  }
}

private struct ChecklistItemRow: View {
  let index: Int
  let status: OnboardingV2ViewModel.ChecklistItemStatus
  let title: String
  let subtitle: String
  let showProgressBar: Bool
  /// Live download progress (0.0–1.0). Nil means indeterminate/not applicable.
  var progress: Double?

  @State private var spinAngle: Double = 0

  /// Maps FluidAudio's raw progress to a bar that fills 0–100% during download,
  /// then stays full during installation. FluidAudio uses [0.0, 0.5] for download
  /// and [0.5, 1.0] for CoreML compilation.
  private var barFraction: CGFloat {
    guard let progress else { return 0.02 }
    if progress >= 0.5 {
      return 1.0  // Installation phase — bar stays full
    }
    // Download phase: map [0.0, 0.5] → [0.0, 1.0]
    return max(CGFloat(progress * 2.0), 0.02)
  }

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
              .frame(width: geo.size.width * barFraction, height: 3)
              .animation(.easeInOut(duration: 0.3), value: barFraction)
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
  @Environment(PermissionsService.self) private var permissions
  @Environment(SettingsManager.self) private var settings

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
          onGrant: {
            Task { await viewModel.requestMicPermission(permissions: permissions) }
          }
        )

        PermissionRow(
          icon: "accessibility",
          title: "Accessibility",
          subtitle: "To paste your transcribed text into any app.",
          isGranted: viewModel.accessibilityGranted,
          onGrant: { viewModel.openAccessibilitySettings(permissions: permissions) }
        )

        // #735: trust-builder banner. "Accessibility" is the scariest-sounding
        // permission on macOS for non-technical users — same flag a keylogger
        // would request. Defuse the fear by saying exactly what we use it for
        // and exactly what we don't. Shown only while AX is ungranted; vanishes
        // the moment the user grants it.
        if !viewModel.accessibilityGranted {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Color.obWarning)
                .font(.system(size: 16, weight: .semibold))
              VStack(alignment: .leading, spacing: 6) {
                Text("Required to paste your dictation")
                  .font(.obLabel)
                  .foregroundStyle(Color.obTextPrimary)
                Text(
                  "macOS calls this permission \"Accessibility,\" but EnviousWispr uses it for exactly one thing: pasting your transcript into the app you're typing in. Without it, every dictation lands in the clipboard and you'd have to paste manually."
                )
                .font(.obCaption)
                .foregroundStyle(Color.obTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                  "We only use Accessibility at the moment we paste your transcript. Never to read your keystrokes, never to watch what happens in other apps."
                )
                .font(.obCaption)
                .foregroundStyle(Color.obTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .padding(14)
          .background(Color.obWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.obWarning.opacity(0.25), lineWidth: 1)
          )
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(.bottom, 20)
      .animation(.easeInOut(duration: 0.30), value: viewModel.accessibilityGranted)

      Spacer()

      // #735: gate Continue on BOTH mic AND accessibility. PostHog (60d prod)
      // showed 17% of completers (3 of 18) denied accessibility, pressed past,
      // and never dictated again — auto-paste fails silently without AX. The
      // "Skip for now" backdoor and the no-AX-required Continue both fed that
      // silent-failure population. Gate the user here, never on the Ready
      // screen — by then they've committed to a hotkey.
      VStack(spacing: 8) {
        let bothGranted = viewModel.micGranted && viewModel.accessibilityGranted
        Button {
          viewModel.currentScreen = .ready
        } label: {
          Text("Continue")
            .font(.obSubheading)
            .foregroundStyle(.white)
            .frame(maxWidth: 360)
            .padding(.vertical, 13)
            .background(
              bothGranted ? Color.obTextPrimary : Color.obTextPrimary.opacity(0.4),
              in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .disabled(!bothGranted)
      }
    }
    .onAppear {
      permissions.refreshAccessibilityStatus()
      viewModel.micGranted = permissions.hasMicrophonePermission
      viewModel.accessibilityGranted = permissions.accessibilityGranted
      if viewModel.accessibilityGranted {
        settings.autoCopyToClipboard = true
      }
    }
    .task { await pollPermissions() }
  }

  /// Polls both mic and accessibility status every 2 seconds.
  /// Continue gates on BOTH grants (#735) — no Skip backdoor.
  /// Auto-cancelled when the view disappears via .task modifier.
  private func pollPermissions() async {
    var elapsed = 0
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      elapsed += 2

      permissions.refreshAccessibilityStatus()
      if permissions.accessibilityGranted && !viewModel.accessibilityGranted {
        viewModel.accessibilityGranted = true
        settings.autoCopyToClipboard = true
        TelemetryService.shared.onboardingStepCompleted(
          step: "accessibility_permission", result: "granted")
      }

      if permissions.hasMicrophonePermission && !viewModel.micGranted {
        viewModel.micGranted = true
        TelemetryService.shared.onboardingStepCompleted(step: "mic_permission", result: "granted")
      }
      // #735: showSkipLink no longer used (Skip-for-now backdoor removed); `elapsed` retained
      // so future telemetry can re-attach a "time-on-permissions-screen" event if needed.
      _ = elapsed
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
  @Environment(SettingsManager.self) private var settings
  @Environment(PermissionsService.self) private var permissions
  let onComplete: () -> Void

  var body: some View {
    @Bindable var settings = settings
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
        keyCode: $settings.toggleKeyCode,
        modifiers: $settings.toggleModifiers
      )
      .padding(.bottom, 20)

      if !permissions.accessibilityGranted {
        HStack(spacing: 10) {
          Image(systemName: "lightbulb.fill")
            .foregroundStyle(Color.obWarning)
          VStack(alignment: .leading, spacing: 2) {
            Text("Pro Tip")
              .font(.obLabel)
              .foregroundStyle(Color.obTextPrimary)
            Text(
              "Enable Accessibility in Settings to use Auto-Paste — transcriptions will paste directly into your active app."
            )
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
    .animation(.easeInOut(duration: 0.35), value: permissions.accessibilityGranted)
  }
}

// MARK: - Keycap Hotkey View

/// A large interactive keycap that doubles as a hotkey recorder.
/// Tap to enter recording mode; press a key combo to save; tap again or press Escape to cancel.
private struct KeycapHotkeyView: View {
  @Binding var keyCode: UInt16
  @Binding var modifiers: NSEvent.ModifierFlags

  // PR10 of #763: hotkey suspend/resume dispatch through DictationRuntime
  // façade; the shared HotkeyService is no longer accessible via the former root state.
  @Environment(DictationRuntime.self) private var dictationRuntime
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
      .padding(.top, 4)  // breathing room for chip

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
            + Text(" to cancel without changing your hotkey.").foregroundStyle(
              Color.obTextSecondary))
            .font(.system(size: 12))
        } else {
          VStack(spacing: 4) {
            Text("Hold to dictate. Release to transcribe.")
              .font(.system(size: 12.5))
              .foregroundStyle(Color.obTextSecondary)
            Text("Double-press to go hands-free.")
              .font(.system(size: 12))
              .foregroundStyle(Color.obAccent.opacity(0.72))
          }
        }
      }
      .multilineTextAlignment(.center)
      .padding(.vertical, 14)
      .padding(.horizontal, 4)
    }
    .padding(.top, 20)
    .padding(.horizontal, 20)
    .padding(.bottom, 18)
    .frame(maxWidth: 320)  // constrain card width like mockup
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
    dictationRuntime.suspendHotkeys()
  }

  private func stopRecording() {
    isRecording = false
    dictationRuntime.resumeHotkeys()
  }

  private func handleKeyEvent(_ event: NSEvent) {
    // Escape with no modifiers cancels
    if event.type != .flagsChanged,
      event.keyCode == 53,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    {
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
