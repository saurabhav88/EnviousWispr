import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

struct DiagnosticsSettingsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(\.asrManager) private var asrManagerEnv
  @Environment(\.activeEngine) private var activeEngineEnv
  @Environment(DiagnosticsCoordinator.self) private var diagnostics
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  // PR-B.2 of #763: "Restart Onboarding" reaches the window coordinator
  // through the environment instead of an `NSApp.delegate` downcast.
  @Environment(AppWindowCoordinator.self) private var appWindowCoordinator
  // #1100: drives the DEBUG-only "Simulate AI polish state" picker below.
  // DEBUG-gated so release carries no extra environment dependency here.
  #if DEBUG
    @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  #endif

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var asrManager: any ASRManagerInterface { asrManagerEnv! }
  private var activeEngine: ActiveEngineOperation { activeEngineEnv! }

  #if DEBUG
    /// DEV-ONLY (AFM adapter PoC): surfaces whether EW_AFM_ADAPTER_PATH is set so
    /// the founder can see the adapter toggle only takes effect when the dev app
    /// was launched with the env var pointing at a `.fmadapter`.
    private var adapterPathHint: String {
      if let path = ProcessInfo.processInfo.environment["EW_AFM_ADAPTER_PATH"], !path.isEmpty {
        return "Adapter: \((path as NSString).lastPathComponent)."
      }
      return "EW_AFM_ADAPTER_PATH not set — toggle has no effect until you relaunch with it set."
    }
  #endif

  var body: some View {
    @Bindable var settings = settings
    #if DEBUG
      @Bindable var aiAvailability = aiAvailability
    #endif

    SettingsContentView {
      // ── Debug Mode ────────────────────────────────────────────────────
      BrandedSection(header: "Debug Mode") {
        BrandedRow {
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Enable debug mode", isOn: $settings.isDebugModeEnabled)
              .toggleStyle(BrandedToggleStyle())
            Text("Persists across relaunches. Toggle with Cmd+Shift+D from anywhere.")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          }
        }
        #if DEBUG
          // DEV-ONLY (AFM adapter PoC): flip on-device Apple Intelligence polish
          // between the tuned local .fmadapter and the stock model, live, to triage
          // "is this the stock model or our adapter?". Debug builds only.
          BrandedRow {
            VStack(alignment: .leading, spacing: 4) {
              Toggle("Use tuned on-device adapter (PoC)", isOn: $settings.devAdapterPolishEnabled)
                .toggleStyle(BrandedToggleStyle())
              Text(
                "Debug builds only. ON routes Apple Intelligence polish through the local .fmadapter at EW_AFM_ADAPTER_PATH; OFF uses the stock model. Flips live on the next dictation. \(adapterPathHint)"
              )
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            }
          }
        #endif
        if settings.isDebugModeEnabled {
          BrandedRow {
            Picker("Log Level", selection: $settings.debugLogLevel) {
              ForEach(DebugLogLevel.allCases, id: \.self) { level in
                Text(level.displayName).tag(level)
              }
            }
          }
          #if DEBUG
            // #1100: force the onboarding Apple Intelligence note to a given
            // state so it can be validated on a Mac where Apple Intelligence is
            // actually available. Pair with "Restart Onboarding…" below.
            BrandedRow {
              VStack(alignment: .leading, spacing: 4) {
                Picker(
                  "Simulate AI polish state",
                  selection: $aiAvailability.debugForcedNotice
                ) {
                  ForEach(AIAvailabilityCoordinator.DebugForcedNotice.allCases) { state in
                    Text(state.label).tag(state)
                  }
                }
                Text(
                  "Forces the onboarding Apple Intelligence note. Pair with \"Restart Onboarding…\" to see each state. Debug builds only."
                )
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
              }
            }
          #endif
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 4) {
              Button("Restart Onboarding…") {
                settings.onboardingState = .notStarted
                appWindowCoordinator.openOnboardingWindow()
              }
              .disabled(liveRecordingState.pipelineState != .idle)
              Text(
                "Re-runs the onboarding flow without wiping app state. Disabled during recording."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            }
          }
        }
        #if DEBUG
          // Intentionally NOT gated by `isDebugModeEnabled` above (Codex review,
          // #1247): the archive opt-in is a sticky, independently-persisted flag,
          // so if it's already on, the control that turns it off must stay
          // visible regardless of whether debug mode is currently toggled —
          // otherwise active mic-audio retention could be invisible. `#if DEBUG`
          // keeps the row itself out of release, where the archive doesn't exist.
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 4) {
              Toggle(
                "Save dictation audio for debugging",
                isOn: $settings.isDictationAudioArchiveEnabled
              )
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Saves a local copy of each dictation's audio for diagnosing transcription issues. Stored only on this Mac, newest 500 recordings kept. Persists across rebuilds. Applies starting with your very next dictation."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            }
          }
        #endif
      }

      // ── Log Files ─────────────────────────────────────────────────────
      BrandedSection(header: "Log Files") {
        BrandedRow {
          HStack {
            Button("Open Log Directory") {
              Task {
                let url = await AppLogger.shared.logDirectoryURL()
                NSWorkspace.shared.open(url)
              }
            }

            Button("Copy Log Path") {
              Task {
                let url = await AppLogger.shared.logDirectoryURL()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
              }
            }

            Button("Clear Logs") {
              Task {
                try? await AppLogger.shared.clearLogs()
              }
            }
            .foregroundStyle(.stError)
          }
        }
        BrandedRow(showDivider: false) {
          Text(
            "Logs are stored at ~/Library/Logs/EnviousWispr/. Maximum 10 MB per file, 5 files retained."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      }

      // ── OSLog ─────────────────────────────────────────────────────────
      BrandedSection(header: "OSLog") {
        BrandedRow {
          Text(
            "All log events are also sent to the macOS unified logging system. View them in Console.app by filtering for subsystem: com.enviouswispr.app"
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
        BrandedRow(showDivider: false) {
          Button("Open Console.app") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
          }
        }
      }

      // ── Performance ───────────────────────────────────────────────────
      BrandedSection(header: "Performance") {
        if diagnostics.benchmark.isRunning {
          BrandedRow {
            HStack {
              ProgressView()
                .controlSize(.small)
              Text(diagnostics.benchmark.progress)
                .font(.stHelper)
            }
          }
        } else {
          BrandedRow {
            HStack {
              Button("Run ASR Benchmark") {
                Task {
                  await diagnostics.benchmark.run(
                    using: asrManager, activeEngine: activeEngine)
                }
              }
              Button("Run Pipeline Benchmark") {
                Task {
                  await diagnostics.benchmark.runPipelineBenchmark(
                    using: asrManager, activeEngine: activeEngine)
                }
              }
            }
          }
        }

        if !diagnostics.benchmark.results.isEmpty {
          BrandedRow {
            ForEach(diagnostics.benchmark.results) { result in
              HStack {
                Text(result.label)
                  .font(.stHelper)
                Spacer()
                Text(String(format: "%.2fs", result.processingTime))
                  .font(.stHelper)
                  .monospacedDigit()
                Text(String(format: "%.0fx RT", result.rtf))
                  .font(.stHelper)
                  .foregroundStyle(.stTextSecondary)
                  .monospacedDigit()
              }
            }
          }
        }

        if let pipeline = diagnostics.benchmark.pipelineResult {
          BrandedRow {
            VStack(alignment: .leading, spacing: 4) {
              Text("Pipeline Benchmark Results")
                .font(.stRowLabel)
              HStack {
                Text("Batch ASR:")
                Spacer()
                Text(String(format: "%.3fs", pipeline.batchASRTime))
                  .monospacedDigit()
              }.font(.stHelper)

              if let streamTime = pipeline.streamingFinalizeTime {
                HStack {
                  Text("Streaming finalize:")
                  Spacer()
                  Text(String(format: "%.3fs", streamTime))
                    .monospacedDigit()
                }.font(.stHelper)
              }

              if let wer = pipeline.werDelta {
                HStack {
                  Text("Streaming vs Batch WER:")
                  Spacer()
                  Text(String(format: "%.1f%%", wer * 100))
                    .monospacedDigit()
                    .foregroundStyle(wer <= 0.02 ? .stSuccess : .stWarning)
                }.font(.stHelper)
              }

              HStack {
                Text("Audio duration:")
                Spacer()
                Text(String(format: "%.1fs", pipeline.audioDuration))
                  .monospacedDigit()
              }.font(.stHelper)
            }
          }
        }

        BrandedRow(showDivider: false) {
          HStack {
            Text("Model status:")
            Spacer()
            Text(asrManager.isModelLoaded ? "Loaded" : "Unloaded")
              .foregroundStyle(asrManager.isModelLoaded ? .stSuccess : .stTextSecondary)
          }
        }
      }
    }
  }
}
