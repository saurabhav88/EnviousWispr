import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices

/// Builds a per-recording `DictationSessionConfig` snapshot from the trigger
/// source, current settings, paste-intent inference, and active-pipeline idle
/// state at recording-start dispatch. Stateless: no stored state, no lifecycle.
///
/// Extracted from `the former root state(triggerSource:)` per
/// epic #763 PR5. Decision-tree rule #17 in `.claude/knowledge/appstate-ownership.md`.
enum DictationSessionConfigFactory {
  @MainActor
  static func make(
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitPipeline: WhisperKitPipeline,
    settings: SettingsManager,
    triggerSource: TriggerSource
  ) -> DictationSessionConfig {
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    let activePipelineIdle: Bool = {
      if isWhisperKit {
        switch whisperKitPipeline.state {
        case .idle, .ready, .complete, .error: return true
        default: return false
        }
      } else {
        switch kernelDriver.state {
        case .idle, .complete, .error: return true
        default: return false
        }
      }
    }()
    // #500: drop the legacy `permissions.hasAccessibilityPermission` gate so the
    // paste cascade always runs. The cascade already handles AX-not-trusted
    // gracefully at PasteCascadeExecutor.swift:106-118 (forces `.nonText`,
    // skips all tiers, falls through to clipboard) AND emits the
    // `.clipboardOnlyAccessibilityDenied` outcome which routes to the
    // educational `.accessibilityToast` overlay. The legacy gate bypassed
    // the cascade entirely (TranscriptFinalizer:143 direct copyToClipboard),
    // depriving AX-denied users of both the diagnostic and the toast.
    let autoPaste = activePipelineIdle
    let resolvedModel: String = {
      switch settings.llmProvider {
      case .appleIntelligence: return "apple-intelligence"
      case .ollama: return settings.ollamaModel
      default: return settings.llmModel
      }
    }()
    return DictationSessionConfig(
      autoCopyToClipboard: settings.autoCopyToClipboard,
      inputMode: settings.recordingMode,
      triggerSource: triggerSource,
      autoPasteToActiveApp: autoPaste,
      restoreClipboardAfterPaste: settings.restoreClipboardAfterPaste,
      vadAutoStop: settings.vadAutoStop,
      vadSilenceTimeout: settings.vadSilenceTimeout,
      vadSensitivity: settings.vadSensitivity,
      vadEnergyGate: settings.vadEnergyGate,
      languageMode: settings.languageMode,
      useStreamingASR: settings.useStreamingASR,
      modelUnloadPolicy: settings.modelUnloadPolicy,
      llmProvider: settings.llmProvider,
      llmModel: resolvedModel,
      polishInstructions: settings.activePolishInstructions,
      useExtendedThinking: settings.useExtendedThinking,
      selectedInputDeviceUID: settings.selectedInputDeviceUID,
      preferredInputDeviceIDOverride: settings.preferredInputDeviceIDOverride
    )
  }
}
