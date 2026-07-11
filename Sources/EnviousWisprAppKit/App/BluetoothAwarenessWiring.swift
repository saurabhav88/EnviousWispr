import EnviousWisprAudio
import EnviousWisprServices

extension BluetoothAwarenessPresenter {
  /// Composition-root factory (#1480): build the Bluetooth card presenter wired
  /// to the live overlay, settings, recording state, and settings navigation, and
  /// install the card's three button handlers. Keeps this wiring out of
  /// `WisprBootstrapper` so the composition root stays lean. The presenter is the
  /// single decision owner; only the live CoreAudio resolvers and the telemetry
  /// sink live here.
  @MainActor
  static func live(
    overlay: RecordingOverlayPanel,
    settings: SettingsManager,
    liveRecordingState: LiveRecordingState,
    navigationCoordinator: NavigationCoordinator,
    appWindowCoordinator: AppWindowCoordinator
  ) -> BluetoothAwarenessPresenter {
    let presenter = BluetoothAwarenessPresenter(
      readCurrentIntent: { [weak overlay] in overlay?.currentIntent ?? .hidden },
      showOverlay: { [weak overlay] in overlay?.show(intent: .bluetoothAwareness) },
      hideIfCurrent: { [weak overlay] in
        if overlay?.currentIntent == .bluetoothAwareness { overlay?.hide() }
      },
      effectiveInputIsBluetooth: { [weak settings] in
        // Predict the CONFIGURED input via the settings precedence (override →
        // selectedInputDeviceUID → CoreAudio default); a nonempty UID that no
        // longer resolves fails CLOSED. The precedence is the pure, unit-tested
        // `computeEffectiveInputIsBluetooth`; only the live resolvers live here
        // (plan §3 — the capture router stays authoritative for the physical device).
        guard let settings else { return false }
        return BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
          preferredOverride: settings.preferredInputDeviceIDOverride,
          selectedUID: settings.selectedInputDeviceUID,
          defaultInputIsBluetooth: {
            guard let id = AudioDeviceEnumerator.defaultInputDeviceID() else { return nil }
            return AudioDeviceEnumerator.isBluetoothDevice(id)
          },
          uidIsBluetooth: { uid in
            guard let id = AudioDeviceEnumerator.deviceID(forUID: uid) else { return nil }
            return AudioDeviceEnumerator.isBluetoothDevice(id)
          })
      },
      // Fail closed (not idle → no card) if the state is somehow unavailable.
      dictationIsIdle: { [weak liveRecordingState] in
        !(liveRecordingState?.isDictationActive ?? true)
      },
      onboardingCompleted: { [weak settings] in settings?.onboardingState == .completed },
      tipsEnabled: { [weak settings] in settings?.showBluetoothTips ?? false },
      openMicrophoneSettings: { [weak navigationCoordinator, weak appWindowCoordinator] in
        navigationCoordinator?.request(.audio)
        appWindowCoordinator?.showWindow()
      },
      emit: { action, reason in
        TelemetryService.shared.bluetoothAwareness(
          action: action.rawValue, reason: reason?.rawValue)
      }
    )
    overlay.setBluetoothAwarenessHandlers(
      onGotIt: { [weak presenter] in presenter?.handleUserAction(.gotIt) },
      onClose: { [weak presenter] in presenter?.handleUserAction(.close) },
      onAdjustSettings: { [weak presenter] in presenter?.handleUserAction(.adjustSettings) }
    )
    return presenter
  }
}
