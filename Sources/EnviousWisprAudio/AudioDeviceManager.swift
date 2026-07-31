import CoreAudio
import Foundation

/// Represents an audio input device discovered via CoreAudio.
public struct AudioInputDevice: Sendable, Identifiable, Hashable {
  public let id: AudioDeviceID
  public let name: String
  public let uid: String
}

/// One input-device candidate, frozen during a SINGLE enumeration pass (#1714).
///
/// Distinct from `AudioInputDevice`, which carries no transport: capture
/// resolution has to rank candidates by transport, and re-reading the transport
/// per candidate later would describe a different hardware state than the one
/// that was enumerated.
struct InputDeviceCandidate: Sendable, Equatable {
  let id: AudioDeviceID
  let uid: String
  /// Raw CoreAudio transport constant, or nil if the property read FAILED.
  /// Nil-preserving on purpose: `kAudioDeviceTransportTypeUnknown` (0) is itself
  /// a real reported value, so collapsing a failed read into it would hide the
  /// failure from telemetry.
  let rawTransport: UInt32?
}

/// The result of ONE input-device enumeration pass (#1714).
///
/// A CoreAudio read failure is a distinct case, never an empty success. The two
/// are different facts and they select different errors: an empty successful
/// list proves no microphone is attached, a failed read proves nothing, and
/// telling the user to connect a microphone after a failed READ would be a
/// false statement.
enum InputDeviceSnapshot: Sendable, Equatable {
  /// Devices we could read, plus whether we managed to read them ALL.
  ///
  /// The two facts are separate because a per-device read failure must not cost
  /// the user the devices that ARE readable (#1714 cloud review r2). A USB stick
  /// pulled mid-enumeration makes its own properties unreadable while the
  /// built-in microphone beside it stays perfectly usable, and refusing to
  /// dictate there would break founder priority 1 — dictation works whenever it
  /// physically can.
  ///
  /// `complete: false` narrows to exactly one thing: the list can no longer
  /// PROVE absence. Candidates in hand stay fully usable; an EMPTY incomplete
  /// list is uncertainty, never grounds for "connect a microphone".
  case success(candidates: [InputDeviceCandidate], complete: Bool)
  /// The device LIST itself could not be read, so we hold no candidates at all.
  case readFailed
}

/// Enumerates audio input devices using CoreAudio HAL.
public enum AudioDeviceEnumerator {
  /// The system's current device-ID list, or nil when either HAL read fails.
  ///
  /// SOLE owner of the size-then-read sequence for `kAudioHardwarePropertyDevices`
  /// (#1714 cloud review P2). The two are separate calls, so the list can shrink
  /// between them — a microphone unplugged in that window makes
  /// `AudioObjectGetPropertyData` write back a SMALLER `dataSize` while the
  /// buffer keeps its original length and a zero-filled tail. Iterating the
  /// whole buffer then treats `kAudioObjectUnknown` (0) as a real device. Both
  /// callers get the truncation for free rather than each remembering it.
  ///
  /// An empty list is a successful read of a machine with no devices; only a
  /// nonzero HAL status is a failure. Callers own how failure collapses.
  private static func systemDeviceIDs() -> [AudioDeviceID]? {
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
    guard status == noErr else { return nil }
    guard dataSize > 0 else { return [] }

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
    guard status == noErr else { return nil }

    // `dataSize` now holds the bytes CoreAudio ACTUALLY wrote. `prefix` clamps,
    // so a list that grew between the calls cannot read past the buffer either.
    let returnedCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    return Array(deviceIDs.prefix(returnedCount))
  }

  /// Returns all audio input devices currently connected.
  public static func allInputDevices() -> [AudioInputDevice] {
    guard let deviceIDs = systemDeviceIDs() else { return [] }

    return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
      let channelCount = inputChannelCount(for: deviceID)
      guard channelCount > 0 else { return nil }

      let name =
        stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
      let uid = stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""

      return AudioInputDevice(
        id: deviceID,
        name: name,
        uid: uid
      )
    }
  }

  /// ONE frozen input-device enumeration for capture resolution (#1714).
  ///
  /// Two differences from `allInputDevices()`, both load-bearing:
  /// a property-read failure stays a typed failure instead of collapsing into
  /// an empty list (`allInputDevices()` returns `[]` for both), and every
  /// candidate carries the RAW transport read during this same pass.
  ///
  /// This is one frozen RESOLUTION INPUT, not an atomic CoreAudio transaction:
  /// the device list and each device's own properties are separate reads at
  /// separate instants. `InputDeviceResolver` calls this at most once per
  /// attempt; callers must never re-enumerate for logging or telemetry.
  ///
  /// Deliberately NOT merged with `allInputDevices()`, which stays the settings
  /// picker's reader: the picker needs display names and can live with the
  /// failure-collapses-to-empty behaviour, capture resolution needs transports
  /// and cannot. Two owners for two questions, not an accident to tidy up.
  static func inputDeviceSnapshot() -> InputDeviceSnapshot {
    // A successful read of an empty machine yields `.success([])`; only a HAL
    // failure is uncertainty. Truncation to what CoreAudio actually returned is
    // `systemDeviceIDs()`'s job — this reader must never re-derive it.
    guard let deviceIDs = systemDeviceIDs() else { return .readFailed }

    var candidates: [InputDeviceCandidate] = []
    var complete = true
    for deviceID in deviceIDs {
      // A FAILED channel-count read is not an output-only device (#1714
      // whole-diff review) and is not grounds for discarding the devices we CAN
      // read (#1714 cloud review r2). It means exactly one thing: we do not know
      // what this device is. So it becomes neither a candidate nor evidence —
      // it is skipped, and the snapshot records that it can no longer prove
      // absence. Collapsing this to a candidate would risk binding a device we
      // never verified; collapsing it to a whole-snapshot failure would throw
      // away working microphones.
      guard let channels = inputChannelCountRaw(for: deviceID) else {
        complete = false
        continue
      }
      guard channels > 0 else { continue }
      candidates.append(
        InputDeviceCandidate(
          id: deviceID,
          uid: stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "",
          rawTransport: transportTypeRaw(for: deviceID)
        ))
    }
    return .success(candidates: candidates, complete: complete)
  }

  /// The closed allow-list of transports we will bind a microphone on (#1714).
  ///
  /// An ALLOW-list, not a deny-list: the dominant risk is silently binding a
  /// loopback or meeting-app virtual device and recording digital silence,
  /// which is worse for the user than an honest error. So an unreadable (nil),
  /// unknown (0) or future unrecognised transport is REFUSED, not accepted.
  ///
  /// AirPlay is deliberately absent — it is an output protocol, not a known
  /// microphone path. A newly observed working transport is added from fleet
  /// evidence, never accepted before its behaviour is known.
  ///
  /// This constrains only the automatic last resort. A device the user pinned
  /// is selected before this predicate is ever consulted.
  static func isAllowedPhysicalInputTransport(_ rawTransport: UInt32?) -> Bool {
    guard let rawTransport else { return false }
    switch rawTransport {
    case kAudioDeviceTransportTypeBuiltIn,
      kAudioDeviceTransportTypeUSB,
      kAudioDeviceTransportTypeBluetooth,
      kAudioDeviceTransportTypeBluetoothLE,
      kAudioDeviceTransportTypeContinuityCaptureWired,
      kAudioDeviceTransportTypeContinuityCaptureWireless,
      kAudioDeviceTransportTypeThunderbolt,
      kAudioDeviceTransportTypeDisplayPort,
      kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypePCI,
      kAudioDeviceTransportTypeFireWire,
      kAudioDeviceTransportTypeAVB:
      return true
    default:
      return false
    }
  }

  /// Transports we recognise as definitively NOT a physical microphone, so a
  /// list containing only these PROVES no microphone is attached (#1714 §4.1).
  ///
  /// Deliberately narrower than "fails the allow-list". Everything else that
  /// fails it — unreadable, unknown (0), AirPlay, a future constant — is
  /// UNCERTAINTY, and telling the user to connect a microphone there would be a
  /// claim we cannot back.
  static func isKnownNonMicrophoneTransport(_ rawTransport: UInt32?) -> Bool {
    guard let rawTransport else { return false }
    return rawTransport == kAudioDeviceTransportTypeVirtual
      || rawTransport == kAudioDeviceTransportTypeAggregate
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

  /// Returns the UID of the current system-default input device, or nil if
  /// none. Used by Sentry extras (`capture.input_device_uid_system_default`)
  /// so divergence vs the preferred device is measured correctly.
  public static func defaultInputDeviceUID() -> String? {
    guard let id = defaultInputDeviceID() else { return nil }
    return stringProperty(for: id, selector: kAudioDevicePropertyDeviceUID)
  }

  /// The persistent UID of a specific device ID. Used when a source knows the
  /// bound numeric CoreAudio ID and needs the stable UID for telemetry evidence.
  static func inputDeviceUID(for deviceID: AudioDeviceID) -> String? {
    stringProperty(for: deviceID, selector: kAudioDevicePropertyDeviceUID)
  }

  // MARK: - Bluetooth & Smart Device Selection

  /// Returns true if the given device uses Bluetooth transport (Classic or LE).
  public static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
    let transport = transportType(for: deviceID)
    return transport == kAudioDeviceTransportTypeBluetooth
      || transport == kAudioDeviceTransportTypeBluetoothLE
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

  // MARK: - Transport labels (#1376 single authority)

  /// Maps a CoreAudio transport-type constant to the app's low-cardinality
  /// transport string. Pure — the single authority for these labels, extracted
  /// from `AudioEnvironmentSnapshotter.deviceTransport` so no second vocabulary
  /// exists (#1376). Nil-preserving: a nil raw transport (property read failed)
  /// yields nil so callers that emit only `if let` keep omitting their key.
  public static func transportLabel(forTransportType raw: UInt32?) -> String? {
    guard let raw else { return nil }
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn:
      return "built_in"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      return "bluetooth"
    case kAudioDeviceTransportTypeUSB:
      return "usb"
    case kAudioDeviceTransportTypeAggregate:
      return "aggregate"
    case kAudioDeviceTransportTypeVirtual:
      return "virtual"
    case kAudioDeviceTransportTypeDisplayPort:
      return "display_port"
    case kAudioDeviceTransportTypeHDMI:
      return "hdmi"
    case kAudioDeviceTransportTypeAirPlay:
      return "air_play"
    case kAudioDeviceTransportTypePCI:
      return "pci"
    case kAudioDeviceTransportTypeFireWire:
      return "fire_wire"
    case kAudioDeviceTransportTypeThunderbolt:
      return "thunderbolt"
    // #1714 founder decision 2026-07-30: the physical allow-list ACCEPTS these
    // three, so reporting them as `unknown` said "we bound something we could
    // not identify" about a device we selected on purpose. Naming them changes
    // only what a bound device is CALLED — never eligibility or selection.
    case kAudioDeviceTransportTypeContinuityCaptureWired:
      return "continuity_capture_wired"
    case kAudioDeviceTransportTypeContinuityCaptureWireless:
      return "continuity_capture_wireless"
    case kAudioDeviceTransportTypeAVB:
      return "avb"
    default:
      return "unknown"
    }
  }

  /// Transport label for a device ID, or nil if the device transport is
  /// unreadable (nil-preserving — see `transportLabel(forTransportType:)`).
  public static func transportLabel(for deviceID: AudioDeviceID) -> String? {
    transportLabel(forTransportType: transportTypeRaw(for: deviceID))
  }

  /// Transport label for an input-device UID, or nil if the UID resolves to no
  /// currently-connected input device.
  public static func transportLabel(forUID uid: String) -> String? {
    guard let id = deviceID(forUID: uid) else { return nil }
    return transportLabel(for: id)
  }

  // MARK: - Private Helpers

  /// Raw CoreAudio transport-type constant, or nil if the property read fails.
  /// The single low-level read behind both `transportType(for:)` and
  /// `transportLabel(for:)` (#1376).
  static func transportTypeRaw(for deviceID: AudioDeviceID) -> UInt32? {
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
    guard status == noErr else { return nil }
    return transport
  }

  static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
    transportTypeRaw(for: deviceID) ?? 0
  }

  /// Total native input channel count for a device, summed across every input
  /// stream (`kAudioDevicePropertyStreamConfiguration`). Module-internal (#1523)
  /// so the capture backend can record it as prepare-time fleet telemetry —
  /// this is the single channel-count authority; do not add a second reader.
  /// Nil-preserving channel count (#1714 whole-diff review).
  ///
  /// Returns nil when a CoreAudio property READ FAILS, and 0 when the device
  /// genuinely exposes no input streams. `inputChannelCount(for:)` collapses
  /// both to 0, which is right for its two callers but WRONG for capture
  /// resolution: a device whose read failed would be silently dropped from the
  /// snapshot, and if it were the only microphone the resolver would treat the
  /// empty list as PROOF none exists and tell the user to connect one.
  ///
  /// Same nil-preserving shape as `transportTypeRaw(for:)` above, for the same
  /// reason — this is the per-DEVICE twin of the failure-vs-empty distinction
  /// `inputDeviceSnapshot()` already makes for the device LIST.
  static func inputChannelCountRaw(for deviceID: AudioDeviceID) -> Int? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
    guard status == noErr else { return nil }
    // A zero-size stream configuration is a SUCCESSFUL read of a device with no
    // input streams — an output-only device, correctly skipped.
    guard dataSize > 0 else { return 0 }

    // AudioBufferList has a variable-length trailing array of AudioBuffer entries.
    // Allocate the exact byte count reported by CoreAudio to avoid heap corruption
    // on multi-stream devices where dataSize > MemoryLayout<AudioBufferList>.size.
    let rawPointer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }

    let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

    let getStatus = AudioObjectGetPropertyData(
      deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
    guard getStatus == noErr else { return nil }

    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
    return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  /// Collapsing channel count: a failed read reads as 0, which is what the
  /// settings picker and the bind-time telemetry both want. Capture resolution
  /// must NOT use this — see `inputChannelCountRaw(for:)`.
  static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
    inputChannelCountRaw(for: deviceID) ?? 0
  }

  private static func stringProperty(
    for deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
  ) -> String? {
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
    var devicesAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var defaultInputAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
      &devicesAddress,
      nil,
      block
    )
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &defaultInputAddress,
      nil,
      block
    )
  }

  private func stopListening() {
    guard let block = listenerBlock else { return }

    var devicesAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var defaultInputAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &devicesAddress,
      nil,
      block
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &defaultInputAddress,
      nil,
      block
    )
    listenerBlock = nil
  }
}
