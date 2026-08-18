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
    // #1891: EXHAUSTIVE on purpose — the previous `default: return false` made
    // this the one consumer the compiler could not flag. Adding `.advisory`
    // without this line would have silently disabled auto-paste on the NEXT
    // take: the user fixes their muted microphone, dictates successfully, and
    // the text never lands. That is a heart-path regression hiding behind a
    // green build and a green test suite. A future state must fail to compile
    // here rather than quietly opt out of pasting.
    let activePipelineIdle: Bool = {
      switch active.state {
      case .idle, .complete, .error, .advisory: return true
      case .loadingModel, .recording, .transcribing, .polishing: return false
      }
    }()
    // #500: drop the legacy `permissions.hasAccessibilityPermission` gate so the
    // paste cascade always runs. The cascade already handles AX-not-trusted
    // gracefully at PasteCascadeExecutor.swift:106-118 (forces `.nonText`,
    // skips all tiers, falls through to clipboard) AND emits the
    // `.clipboardOnlyAccessibilityDenied` outcome which routes to the
    // educational `.accessibilityToast` overlay. The legacy gate bypassed
    // the cascade entirely (the wiring's direct copyToClipboard branch),
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
      smartInsertion: settings.smartInsertion,
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
      recoveryPayload: recoveryPayload,
      // #2087: frozen here, so the rules a recording ends under are the rules it
      // started under. `RecordingSessionKernel`'s cancel branch is the reader.
      escapeRecoveryEnabled: settings.escapeRecoveryEnabled
    )
  }
}
