@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Production telemetry observer for OS-level audio events (issue #574).
///
/// Goal: get cross-user data on which audio events real production users
/// actually trigger (BT pair, system input flip, USB plug, Continuity Camera
/// mic arrival), so we can decide whether V2 Lane A synthetic scenarios are
/// testing physically possible states. Without this data the decision is
/// theoretical.
///
/// Approach: extend existing production telemetry rather than build a parallel
/// DEBUG-only listener. Sentry breadcrumb on every fire (always),
/// `audio.system_event_during_recording` PostHog event on fire-during-active-
/// recording.
///
/// Owner: `AppDelegate` (matches `DebugFaultEndpoint` retain pattern). NOT on
/// AppState — Bible epic #319 (Phase E #502, Phase F #503) actively shrinks
/// AppState. Reporter holds plain collaborator references (no AppState back-
/// reference) so it cannot accidentally mutate AppState state.
///
/// Process placement: host app. CoreAudio system-object property listeners
/// fire in any process; `AVCaptureDevice.wasConnected/wasDisconnected`
/// notifications post via NotificationCenter to any registered observer.
/// Service-side observers are out of scope (audio service has no
/// `ObservabilityBootstrap.initialize()` call) — `Audio engine interrupted`
/// Sentry event from the recovery path covers engine-config events for now.
///
/// Concurrency: `@MainActor`. Observer callbacks fire on HAL/NotificationCenter
/// queues; each block snapshots payload synchronously, then hops to MainActor
/// via `Task { @MainActor }` before reading collaborator state and emitting
/// telemetry. `SentrySDK.addBreadcrumb` takes a synchronized lock — keeping
/// emission off HAL threads is load-bearing.
@MainActor
final class AudioSystemEventReporter {
  private let audioCapture: any AudioCaptureInterface
  private let asrManager: any ASRManagerInterface
  private let pipelineStateProvider: @MainActor () -> PipelineState

  /// CoreAudio property listener blocks. Stored as instance state so the same
  /// reference can be passed to `AudioObjectRemovePropertyListenerBlock` in
  /// deinit — required for clean removal (matches `AudioDeviceMonitor` pattern
  /// in `Sources/EnviousWisprAudio/AudioDeviceManager.swift`).
  ///
  /// `nonisolated(unsafe)` because Swift 6 makes `@MainActor` class `deinit`
  /// nonisolated; deinit must touch these storage slots to remove the
  /// listeners. The blocks themselves are non-`Sendable` function types but
  /// the actual access pattern is single-shot — set in init, read once in
  /// deinit, never racing.
  nonisolated(unsafe) private var defaultInputListener: AudioObjectPropertyListenerBlock?
  nonisolated(unsafe) private var defaultOutputListener: AudioObjectPropertyListenerBlock?

  /// NotificationCenter observer tokens. Same `nonisolated(unsafe)` rationale
  /// as above.
  nonisolated(unsafe) private var captureDeviceConnectedToken: (any NSObjectProtocol)?
  nonisolated(unsafe) private var captureDeviceDisconnectedToken: (any NSObjectProtocol)?

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    pipelineStateProvider: @escaping @MainActor () -> PipelineState
  ) {
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.pipelineStateProvider = pipelineStateProvider
    registerCoreAudioListeners()
    registerCaptureDeviceObservers()
  }

  deinit {
    // CoreAudio listener removal must use the same block reference passed to
    // the registration call. Tokens are stored as instance state above.
    if let block = defaultInputListener {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &addr, nil, block)
    }
    if let block = defaultOutputListener {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &addr, nil, block)
    }
    if let token = captureDeviceConnectedToken {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = captureDeviceDisconnectedToken {
      NotificationCenter.default.removeObserver(token)
    }
  }

  // MARK: - Observer registration

  private func registerCoreAudioListeners() {
    // Default input device change — fires when user pairs BT, plugs USB,
    // toggles input in System Settings, etc.
    let inputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      // HAL callback thread. Hop to MainActor before reading state or emitting.
      Task { @MainActor [weak self] in
        self?.emit(event: "coreAudio.defaultInputDevice.changed", context: [:])
      }
    }
    var inputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let inputStatus = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &inputAddr, nil, inputBlock)
    if inputStatus == noErr {
      defaultInputListener = inputBlock
    } else {
      Task {
        await AppLogger.shared.log(
          "[AudioSystemEventReporter] failed to register default-input listener: status=\(inputStatus)",
          level: .info, category: "Audio"
        )
      }
    }

    let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.emit(event: "coreAudio.defaultOutputDevice.changed", context: [:])
      }
    }
    var outputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let outputStatus = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &outputAddr, nil, outputBlock)
    if outputStatus == noErr {
      defaultOutputListener = outputBlock
    } else {
      Task {
        await AppLogger.shared.log(
          "[AudioSystemEventReporter] failed to register default-output listener: status=\(outputStatus)",
          level: .info, category: "Audio"
        )
      }
    }
  }

  private func registerCaptureDeviceObservers() {
    captureDeviceConnectedToken = NotificationCenter.default.addObserver(
      forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil
    ) { [weak self] notification in
      // NotificationCenter dispatch queue. Capture payload synchronously,
      // then hop to MainActor.
      let deviceTypeRaw =
        (notification.object as? AVCaptureDevice)?.deviceType.rawValue ?? "unknown"
      Task { @MainActor [weak self] in
        self?.emit(
          event: "captureDevice.connected",
          context: ["device_type": deviceTypeRaw])
      }
    }
    captureDeviceDisconnectedToken = NotificationCenter.default.addObserver(
      forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil
    ) { [weak self] notification in
      let deviceTypeRaw =
        (notification.object as? AVCaptureDevice)?.deviceType.rawValue ?? "unknown"
      Task { @MainActor [weak self] in
        self?.emit(
          event: "captureDevice.disconnected",
          context: ["device_type": deviceTypeRaw])
      }
    }
  }

  // MARK: - Emission

  private func emit(event: String, context: [String: String]) {
    // Snapshot collaborators on MainActor.
    let route = audioCapture.currentAudioRoute  // built_in_mic / capture_session_bt / unknown
    let backend = asrManager.activeBackendType.rawValue  // parakeet / whisperKit
    let recordingActive = pipelineStateProvider() == .recording

    var data: [String: Any] = [
      "transport": route,
      "backend": backend,
    ]
    for (key, value) in context {
      data[key] = value
    }

    SentryBreadcrumb.add(stage: "audio.device", message: event, data: data)

    if recordingActive {
      TelemetryService.shared.audioSystemEventDuringRecording(
        event: event, backend: backend, transport: route)
    }
  }
}
