import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// PR10 of #763 — wires `HotkeyService`'s six recording callbacks to
/// `RecordingStarter` + `RecordingFinalizer` and pushes the initial
/// key/modifier/mode configuration at install. Exposes `startIfEnabled()`
/// for the post-runloop launch path, `suspend()`/`resume()` for the
/// Settings + Onboarding hotkey-recorder UI, and a read-through
/// `hotkeyDescription` for the main window status label.
///
/// **Does NOT own `HotkeyService`** — the service instance is owned by
/// `EnviousWisprApp` as `@State` and shared with `PipelineSettingsSync`
/// (live settings updates: recordingMode, key codes, modifiers,
/// hotkeyEnabled-driven start/stop) and `DictationLifecycleCoordinator`
/// (per-pipeline-state register/unregister of the cancel hotkey). A
/// single shared instance is required so live settings changes
/// propagate through PSS to the same service that HotkeyController
/// wired callbacks on. Single-owner alternatives were considered and
/// rejected during Codex grounded review (round 1).
///
/// Callback weak captures: `[weak starter]`/`[weak finalizer]` avoid a
/// retain cycle, but `DictationRuntime` strongly owns Starter +
/// Finalizer for the App lifetime. If a callback observes `nil` during
/// normal app lifetime, that is a fault — surface via
/// `SentryBreadcrumb.captureError`.
@MainActor
final class HotkeyController {
  let hotkeyService: HotkeyService
  let starter: RecordingStarter
  let finalizer: RecordingFinalizer
  let settings: SettingsManager

  var hotkeyDescription: String { hotkeyService.hotkeyDescription }

  init(
    hotkeyService: HotkeyService,
    starter: RecordingStarter,
    finalizer: RecordingFinalizer,
    settings: SettingsManager
  ) {
    self.hotkeyService = hotkeyService
    self.starter = starter
    self.finalizer = finalizer
    self.settings = settings
  }

  /// Push the initial key/modifier/mode configuration and wire the six
  /// recording callbacks. Called once from `DictationRuntime.init` as
  /// the last init step. Subsequent live settings changes flow through
  /// `PipelineSettingsSync` to the same shared `HotkeyService`.
  func install() {
    hotkeyService.recordingMode = settings.recordingMode
    hotkeyService.cancelKeyCode = settings.cancelKeyCode
    hotkeyService.cancelModifiers = settings.cancelModifiers
    hotkeyService.toggleKeyCode = settings.toggleKeyCode
    hotkeyService.toggleModifiers = settings.toggleModifiers
    hotkeyService.onToggleRecording = { [weak starter] in
      guard let starter else {
        Self.reportNilCollaborator(callback: "onToggleRecording")
        return
      }
      await starter.toggle(source: .toggleHotkey)
    }
    hotkeyService.onStartRecording = { [weak starter] in
      guard let starter else {
        Self.reportNilCollaborator(callback: "onStartRecording")
        return
      }
      await starter.start()
    }
    hotkeyService.onStopRecording = { [weak finalizer] in
      guard let finalizer else {
        Self.reportNilCollaborator(callback: "onStopRecording")
        return
      }
      await finalizer.userStop()
    }
    hotkeyService.onCancelRecording = { [weak finalizer] in
      guard let finalizer else {
        Self.reportNilCollaborator(callback: "onCancelRecording")
        return
      }
      await finalizer.cancel()
    }
    hotkeyService.onIsProcessing = { [weak starter] in
      starter?.isProcessing ?? false
    }
    hotkeyService.onLocked = { [weak finalizer] in
      guard let finalizer else {
        Self.reportNilCollaborator(callback: "onLocked")
        return
      }
      finalizer.markLocked()
    }
  }

  /// Carbon `RegisterEventHotKey` only delivers events while the
  /// `NSApplication` event loop is running. AppDelegate calls this from
  /// `applicationDidFinishLaunching` once that is the case. Unconditional
  /// behavior preserved from the former root state —
  /// no onboarding gate (the `:221` onboarding check in AppDelegate is
  /// for the `settingsSnapshot` telemetry event, not for hotkey start).
  func startIfEnabled() {
    if settings.hotkeyEnabled { hotkeyService.start() }
  }

  /// Pause Carbon hotkey delivery so the Settings / Onboarding hotkey
  /// recorder can capture raw key combos without firing dictation.
  func suspend() { hotkeyService.suspend() }

  /// Resume Carbon hotkey delivery after a recorder UI closes.
  func resume() { hotkeyService.resume() }

  private static func reportNilCollaborator(callback: String) {
    SentryBreadcrumb.captureError(
      NilCollaboratorError(callback: callback),
      category: .pipelineDispatchFailed, stage: "recording",
      extra: ["callback": callback])
  }

  private struct NilCollaboratorError: Error, CustomStringConvertible {
    let callback: String
    var description: String {
      "HotkeyController callback \(callback) observed nil collaborator during app lifetime"
    }
  }
}
