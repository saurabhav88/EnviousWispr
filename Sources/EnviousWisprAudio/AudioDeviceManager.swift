import CoreAudio
import EnviousWisprCore
import Foundation

/// Represents an audio input device discovered via CoreAudio.
public struct AudioInputDevice: Sendable, Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let manufacturer: String
    public let inputChannelCount: Int
}

/// Enumerates audio input devices using CoreAudio HAL.
public enum AudioDeviceEnumerator {
    /// Returns all audio input devices currently connected.
    public static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            let channelCount = inputChannelCount(for: deviceID)
            guard channelCount > 0 else { return nil }

            let name = stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            let uid = stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
            let manufacturer = stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString) ?? ""

            return AudioInputDevice(
                id: deviceID,
                name: name,
                uid: uid,
                manufacturer: manufacturer,
                inputChannelCount: channelCount
            )
        }
    }

    /// Returns the default system input device ID, or nil if unavailable.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Finds a device ID by its persistent UID string.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let devices = allInputDevices()
        return devices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Bluetooth & Smart Device Selection

    /// Returns true if the given device uses Bluetooth transport (Classic or LE).
    public static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(for: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Returns the AudioDeviceID of the built-in microphone, if one exists.
    public static func builtInMicrophoneDeviceID() -> AudioDeviceID? {
        let devices = allInputDevices()
        return devices.first { transportType(for: $0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
    }

    /// Returns the default system output device ID, or nil if unavailable.
    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Returns true if the device's I/O cycle is active (audio is flowing somewhere).
    public static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isRunning)
        return isRunning != 0
    }

    /// Recommended input device given current output device and media-playing state.
    /// Returns the built-in mic if Bluetooth output is active and media is playing;
    /// nil otherwise (meaning "use whatever is currently selected").
    public static func recommendedInputDevice() -> AudioDeviceID? {
        guard let outputDeviceID = defaultOutputDeviceID() else { return nil }
        guard isBluetoothDevice(outputDeviceID) else { return nil }
        guard isDeviceRunningSomewhere(outputDeviceID) else { return nil }
        return builtInMicrophoneDeviceID()
    }

    // MARK: - Private Helpers

    static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        return transport
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        // AudioBufferList has a variable-length trailing array of AudioBuffer entries.
        // Allocate the exact byte count reported by CoreAudio to avoid heap corruption
        // on multi-stream devices where dataSize > MemoryLayout<AudioBufferList>.size.
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard getStatus == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(for deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // CoreAudio string properties return CFStringRef — use withUnsafeMutablePointer
        // to avoid the warning about forming UnsafeMutableRawPointer to a reference type.
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var result: CFString? = nil

        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let name = result else { return nil }
        return name as String
    }
}

/// Monitors audio device connect/disconnect events via CoreAudio property listener.
public final class AudioDeviceMonitor: Sendable {
    private let onDevicesChanged: @Sendable () -> Void
    /// Stored listener block — CoreAudio requires the same reference for removal.
    nonisolated(unsafe) private var listenerBlock: AudioObjectPropertyListenerBlock?

    public init(onDevicesChanged: @escaping @Sendable () -> Void) {
        self.onDevicesChanged = onDevicesChanged
        startListening()
    }

    deinit {
        stopListening()
    }

    private func startListening() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let callback = self.onDevicesChanged
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            callback()
        }
        self.listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            block
        )
    }

    private func stopListening() {
        guard let block = listenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            block
        )
        listenerBlock = nil
    }
}
