import EnviousWisprAudio
import EnviousWisprServices

extension BluetoothAwarenessPresenter {
  /// Composition-root factory (#1480): build the Bluetooth card presenter wired
  /// to the live overlay, settings, recording state, and settings navigation, and
  /// install the card's three button handlers. Keeps this wiring out of
  /// `WisprBootstrapper` so the composition root stays lean. The presenter is the
  /// single decision owner; only the device-fact lookups (from the device list's
  /// last accepted snapshot, #4021) and the telemetry sink live here.
  @MainActor
  static func live(
    overlay: OverlayDirector,
    settings: SettingsManager,
    liveRecordingState: LiveRecordingState,
    navigationCoordinator: NavigationCoordinator,
    appWindowCoordinator: AppWindowCoordinator,
    audioDeviceList: AudioDeviceList
  ) -> BluetoothAwarenessPresenter {
    // **`PresenterBox` is gone** (#2292 C3b). It existed because the card's
    // action closure was one of the presenter's own constructor arguments, so it
    // could not capture the presenter. The buttons now ride on the card's own
    // `PillRequest`, which the presenter builds in a method at show time — `self`
    // is simply in scope, and there is no ordering problem left to solve.
    let presenter = BluetoothAwarenessPresenter(
      overlay: overlay,
      effectiveInputIsBluetooth: { [weak settings, weak audioDeviceList] in
        // Predict the CONFIGURED input the way HAL binds it: explicit override,
        // else the CoreAudio default input (selectedInputDeviceUID is never
        // opened by HAL, so it is not consulted here). The precedence is the
        // pure, unit-tested `computeEffectiveInputIsBluetooth`; only the device-fact
        // lookups live here (plan §3 — the capture router stays authoritative
        // for the physical device).
        guard let settings else { return false }
        return BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
          preferredOverride: settings.preferredInputDeviceIDOverride,
          autoInputIsBluetooth: {
            // The device Auto would actually OPEN, not the system default. Since
            // #2022 a virtual or aggregate default loses to a real microphone,
            // and if that fallback IS a headset then reading the default here
            // would answer "not Bluetooth" and withhold the whole awareness card
            // from a user who is on Bluetooth (cloud review).
            // #4021: answered from the last accepted device snapshot (read off the
            // main actor); before the first snapshot there is no answer, so no card.
            audioDeviceList?.snapshot?.autoInputIsBluetooth
          },
          uidIsBluetooth: { uid in
            // Nil only for an unlisted UID (falls back to Auto); a listed device with
            // an unreadable transport answers false, as before (#4021 chunk 2).
            audioDeviceList?.snapshot?.uidIsBluetooth(uid)
          })
      },
      // Fail closed (not idle → no card) if the state is somehow unavailable.
      dictationIsIdle: { [weak liveRecordingState] in
        !(liveRecordingState?.isDictationActive ?? true)
      },
      onboardingCompleted: { [weak settings] in settings?.onboardingState == .completed },
      tipsEnabled: { [weak settings] in settings?.showBluetoothTips ?? false },
      openMicrophoneSettings: { [weak navigationCoordinator, weak appWindowCoordinator] in
        navigationCoordinator?.request(.dictation(.microphone))
        appWindowCoordinator?.showWindow()
      },
      emit: { action, reason in
        TelemetryService.shared.bluetoothAwareness(
          action: action.rawValue, reason: reason?.rawValue)
      }
    )
    return presenter
  }
}
