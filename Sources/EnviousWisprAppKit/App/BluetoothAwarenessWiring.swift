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
    overlay: OverlayDirector,
    settings: SettingsManager,
    liveRecordingState: LiveRecordingState,
    navigationCoordinator: NavigationCoordinator,
    appWindowCoordinator: AppWindowCoordinator
  ) -> BluetoothAwarenessPresenter {
    let box = PresenterBox()
    let presenter = BluetoothAwarenessPresenter(
      readCurrentIntent: { [weak overlay] in overlay?.currentIntent ?? .hidden },
      // **The card's three buttons ride WITH the presentation now**, rather than
      // living in `setBluetoothAwarenessHandlers` for the app's lifetime whether
      // or not a card is showing.
      //
      // The box exists because the presenter does not: this closure is one of
      // its own constructor arguments, so it cannot capture it. The shipped code
      // has the same ordering and solved it by binding the handlers in a SECOND
      // call afterwards — which is precisely the lifetime field being removed.
      // Weak inside, so a card cannot keep its presenter alive.
      showOverlay: { [weak overlay] in
        overlay?.send(
          .featureRequest(.bluetoothAwareness),
          actions: { action in
            guard let presenter = box.value else { return }
            switch action {
            case .acknowledgeBluetoothAwareness: presenter.handleUserAction(.gotIt)
            case .closeBluetoothAwareness: presenter.handleUserAction(.close)
            case .openBluetoothSettings: presenter.handleUserAction(.adjustSettings)
            default: break
            }
          })
      },
      // SILENT: dismissing the card is not a dictation ending.
      hideIfCurrent: { [weak overlay] in
        if overlay?.currentIntent == .bluetoothAwareness { overlay?.dismissSilently() }
      },
      effectiveInputIsBluetooth: { [weak settings] in
        // Predict the CONFIGURED input the way HAL binds it: explicit override,
        // else the CoreAudio default input (selectedInputDeviceUID is never
        // opened by HAL, so it is not consulted here). The precedence is the
        // pure, unit-tested `computeEffectiveInputIsBluetooth`; only the live
        // resolvers live here (plan §3 — the capture router stays authoritative
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
            guard let id = AudioDeviceEnumerator.resolvedAutoInputDeviceID() else { return nil }
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
    box.value = presenter
    return presenter
  }

  /// Holds the presenter for a closure that is one of its own constructor
  /// arguments. Weak, so the card's action handler can never be what keeps the
  /// presenter alive.
  @MainActor
  private final class PresenterBox {
    weak var value: BluetoothAwarenessPresenter?
  }
}
