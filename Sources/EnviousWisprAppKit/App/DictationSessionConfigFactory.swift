import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Builds a per-recording `DictationSessionConfig` snapshot from the trigger
/// source, current settings, paste-intent inference, and active-pipeline idle
/// state at recording-start dispatch. Stateless: no stored state, no lifecycle.
///
/// Extracted from the former root state's recording-config construction per
/// epic #763 PR5. Decision-tree rule #17 in `state-ownership.md`.
enum DictationSessionConfigFactory {
  @MainActor
  static func make(
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    settings: SettingsManager,
    triggerSource: TriggerSource,
    recoverySessionID: String? = nil,
    recoveryPayload: Data? = nil
  ) -> DictationSessionConfig {
    // PR-5 Rung 5 (#827): both backends share `PipelineState` vocabulary now,
    // so the per-backend idle switch collapses; the legacy `.ready` case
    // (WhisperKit-only) maps to `.idle` in the kernel driver's state mapping.
    let active: KernelDictationDriver =
      asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
    let activePipelineIdle: Bool = {
      switch active.state {
      case .idle, .complete, .error: return true
      default: return false
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
    // #1173: the single source of truth for the effective model (was an inline
    // switch here; now shared with the settings telemetry projection).
    let resolvedModel = settings.effectiveLLMModel
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
      preferredInputDeviceIDOverride: settings.preferredInputDeviceIDOverride,
      recoverySessionID: recoverySessionID,
      recoveryPayload: recoveryPayload
    )
  }
}
