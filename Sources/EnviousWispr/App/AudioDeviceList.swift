import Observation
import EnviousWisprAudio

/// Manages the list of available audio input devices, refreshing automatically on hardware changes.
@MainActor @Observable
final class AudioDeviceList {
    var availableInputDevices: [AudioInputDevice] = []
    private var deviceMonitor: AudioDeviceMonitor?

    init() {
        refresh()
        deviceMonitor = AudioDeviceMonitor { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        availableInputDevices = AudioDeviceEnumerator.allInputDevices()
    }
}
