import CoreAudio
import AudioToolbox
import Foundation

/// Represents an audio input device discovered via CoreAudio.
struct AudioInputDevice: Sendable, Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let manufacturer: String
    let inputChannelCount: Int
}

/// Enumerates audio input devices using CoreAudio HAL.
enum AudioDeviceEnumerator {
    /// Returns all audio input devices currently connected.
    static func allInputDevices() -> [AudioInputDevice] {
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
    static func defaultInputDeviceID() -> AudioDeviceID? {
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
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let devices = allInputDevices()
        return devices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Private Helpers

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
final class AudioDeviceMonitor: Sendable {
    private let onDevicesChanged: @Sendable () -> Void
    /// Stored listener block — CoreAudio requires the same reference for removal.
    nonisolated(unsafe) private var listenerBlock: AudioObjectPropertyListenerBlock?

    init(onDevicesChanged: @escaping @Sendable () -> Void) {
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
