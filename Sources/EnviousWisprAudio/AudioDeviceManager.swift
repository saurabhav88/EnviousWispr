import CoreAudio
import Foundation

/// Represents an audio input device discovered via CoreAudio.
public struct AudioInputDevice: Sendable, Identifiable, Hashable {
  public let id: AudioDeviceID
  public let name: String
  public let uid: String
  /// #2664: total native input channels, from the single channel-count
  /// authority (`AudioDeviceEnumerator.inputChannelCount`). Always > 0 here —
  /// `allInputDevices()` drops a device reporting none. The settings row shows
  /// a per-device socket picker only when this exceeds 1.
  public let inputChannelCount: Int

  public init(id: AudioDeviceID, name: String, uid: String, inputChannelCount: Int) {
    self.id = id
    self.name = name
    self.uid = uid
    self.inputChannelCount = inputChannelCount
  }
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
        uid: uid,
        inputChannelCount: channelCount
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

  /// The device an Auto capture would actually OPEN.
  ///
  /// Since #2022 that is NOT always the system default: a default proven not to
  /// be a microphone (virtual or aggregate) loses to a real one. Any consumer
  /// answering "which input is in use" must ask THIS, not
  /// `defaultInputDeviceID()`, or it will name the device we deliberately
  /// refused — cloud review found exactly that in the settings pill and the
  /// Bluetooth awareness card.
  ///
  /// Exists because `InputDeviceResolver` is module-internal: this is the one
  /// public door to it, so the ladder stays the single selection authority
  /// rather than being re-derived per consumer.
  ///
  /// Cost matches `defaultInputDeviceID()` on the healthy path — one extra
  /// property read, and the enumeration only when the default is refused.
  public static func resolvedAutoInputDeviceID() -> AudioDeviceID? {
    InputDeviceResolver().resolve(preferredUID: nil).selectedDeviceID
  }

  /// Returns the UID of the current system-default input device, or nil if
  /// none. Used by Sentry extras (`capture.input_device_uid_system_default`)
  /// so divergence vs the preferred device is measured correctly.
  ///
  /// Deliberately the SYSTEM DEFAULT and not the resolved device: its whole
  /// purpose is to let divergence be measured, so it must keep reporting what
  /// macOS says even when the ladder refuses it.
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

  /// #1845: which BUILT-IN-family input a UID names, or nil for anything else.
  ///
  /// `transportLabel` reports `built_in` for BOTH the internal microphone and a
  /// microphone plugged into the 3.5 mm jack, because macOS routes the jack
  /// through the same audio codec. Measured on the founder's Mac 2026-07-31:
  ///
  /// | Picker name | UID | transport |
  /// |---|---|---|
  /// | MacBook Pro Microphone | `BuiltInMicrophoneDevice` | `bltn` |
  /// | External Microphone | `BuiltInHeadphoneInputDevice` | `bltn` |
  ///
  /// So transport alone cannot tell "the internal mic went quiet" from "a dead
  /// headset is plugged into the jack" — and the second is the population #1845
  /// exists to measure. The UID does distinguish them.
  ///
  /// **Returns a CLOSED VOCABULARY, never the UID itself.** That is a privacy
  /// requirement, not a style choice: a USB UID embeds the device serial
  /// (`AppleUSBAudioEngine:Plantronics:…:CBB85FCE…`) and a Bluetooth UID is the
  /// peer MAC address, so emitting raw UIDs would ship hardware identifiers.
  /// The two values below are Apple-fixed constants that name a PORT on every
  /// Mac, identify nobody, and are already documented as the UID-shape
  /// cross-check in `gotchas-audio.md`.
  ///
  /// Deliberately nil outside the built-in family: `usb`, `bluetooth` and
  /// `virtual` are already unambiguous in the transport label, so a second
  /// field there would be a duplicate authority for a fact that has one.
  ///
  /// **Device MODEL is deliberately not reported, and that was a considered
  /// decision rather than an omission (founder, 2026-07-31).** `kAudioDevice`
  /// `PropertyModelUID` is available and safe — measured `Blackwire 5220
  /// Series:047F:C053` for USB and `4066 9e` for Bluetooth, neither carrying a
  /// serial or the user's chosen device name. It was rejected on VALUE, not on
  /// privacy: the question worth answering is which of four input CLASSES
  /// failed, and a per-model breakdown does not change what we would do about
  /// it. Do not add it back without a use that a class-level answer cannot
  /// serve. The raw `deviceUID` remains permanently unemittable — the USB form
  /// embeds the unit serial and the Bluetooth form is the peer MAC address.
  public static func builtInInputKind(forUID uid: String?) -> String? {
    switch uid {
    case "BuiltInMicrophoneDevice": return "built_in_mic"
    case "BuiltInHeadphoneInputDevice": return "jack_input"
    default: return nil
    }
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

// MARK: - Frozen device facts for idle-time consumers (#4021)

/// One frozen read of every device fact the idle-time consumers need (#4021): the
/// microphone list, transport labels, the device Auto would open and the Bluetooth answers.
///
/// Read once on `CoreAudioQueryLane`, off the main actor, then published as a whole by
/// `AudioDeviceList`. Consumers read this value instead of asking Core Audio on the main
/// thread, where a third-party driver that stops answering froze the whole app.
package struct AudioDeviceSnapshot: Sendable, Equatable {
  /// One input device as read in this pass.
  package struct Device: Sendable, Equatable {
    package let id: AudioDeviceID
    /// The device name, or `"Unknown"` when unreadable (the same fallback as
    /// `allInputDevices()`).
    package let name: String
    /// The persistent UID, or nil when the read FAILED. Never collapsed to `""` here, so a
    /// failed identity read is never mistaken for a device that is simply absent.
    package let uid: String?
    package let inputChannelCount: Int
    /// Raw transport constant, or nil when the read failed.
    package let rawTransport: UInt32?

    package var transportLabel: String? {
      AudioDeviceEnumerator.transportLabel(forTransportType: rawTransport)
    }
  }

  /// False when the device LIST itself could not be read; `devices` is then empty and proves
  /// nothing.
  package let listReadSucceeded: Bool
  /// Input devices in system-list order, filtered to at least one input channel.
  package let devices: [Device]
  /// False when some device's channel count could not be read (it was skipped).
  package let channelsComplete: Bool
  /// False when some listed input device's UID could not be read.
  package let identitiesComplete: Bool
  /// The device Auto would open now, from one `InputDeviceResolver` pass over these frozen facts.
  package let resolvedAutoDeviceID: AudioDeviceID?

  /// Whether this inventory may prove a device is ABSENT: the list read succeeded and every
  /// device's channels and UID were read. Only then may a pinned microphone be treated as
  /// disconnected. A partial inventory still shows the devices it could read.
  package var provesAbsence: Bool { listReadSucceeded && channelsComplete && identitiesComplete }

  /// The list in the shape the settings picker and menu already use. A failed UID read shows as
  /// `""`, exactly as `allInputDevices()` does today.
  package var displayDevices: [AudioInputDevice] {
    devices.map {
      AudioInputDevice(id: $0.id, name: $0.name, uid: $0.uid ?? "", inputChannelCount: $0.inputChannelCount)
    }
  }

  /// Transport label for a listed device UID, or nil when the UID is not listed or its
  /// transport is unreadable (same as `AudioDeviceEnumerator.transportLabel(forUID:)`).
  package func transportLabel(forUID uid: String) -> String? {
    devices.first { $0.uid == uid }?.transportLabel
  }

  /// Whether Auto would open a Bluetooth device. Nil only when Auto resolves to no device.
  /// An unreadable transport answers false, matching today's
  /// `AudioDeviceEnumerator.isBluetoothDevice` (preserved on purpose: the Bluetooth presenter
  /// treats nil as "fall back", so turning an unreadable read into nil would change behaviour).
  package var autoInputIsBluetooth: Bool? {
    guard let id = resolvedAutoDeviceID else { return nil }
    return Self.isBluetooth(rawTransport(for: id))
  }

  /// Whether the listed device with this UID is Bluetooth. Nil only when no listed device has
  /// this UID (the presenter then falls back to Auto, as today with `deviceID(forUID:)`).
  package func uidIsBluetooth(_ uid: String) -> Bool? {
    guard let device = devices.first(where: { $0.uid == uid }) else { return nil }
    return Self.isBluetooth(device.rawTransport)
  }

  /// Transport for the resolved Auto device: from the list when it is an input listed here,
  /// otherwise the separately frozen default-device transport.
  private func rawTransport(for id: AudioDeviceID) -> UInt32? {
    if let device = devices.first(where: { $0.id == id }) { return device.rawTransport }
    return id == defaultDeviceID ? defaultDeviceTransport : nil
  }

  private static func isBluetooth(_ raw: UInt32?) -> Bool {
    raw == kAudioDeviceTransportTypeBluetooth || raw == kAudioDeviceTransportTypeBluetoothLE
  }

  /// The system default input and its transport as read in this pass (frozen for the resolver).
  let defaultDeviceID: AudioDeviceID?
  let defaultDeviceTransport: UInt32?
}

/// Builds an `AudioDeviceSnapshot` from ONE pass of Core Audio reads (#4021).
///
/// Its own reader, beside `allInputDevices()` (the old picker reader) and
/// `inputDeviceSnapshot()` (capture resolution), which stay unchanged: neither keeps names,
/// channel counts, nil-preserving UIDs and transports together. The resolver runs once over
/// facts frozen here, so it never re-reads the device list, the default or a transport.
package enum AudioDeviceSnapshotReader {
  /// The Core Audio property reads, injectable so tests touch no real hardware.
  package struct PropertyReads: Sendable {
    package var systemDeviceIDs: @Sendable () -> [AudioDeviceID]?
    package var inputChannelCount: @Sendable (AudioDeviceID) -> Int?
    package var name: @Sendable (AudioDeviceID) -> String?
    package var uid: @Sendable (AudioDeviceID) -> String?
    package var transport: @Sendable (AudioDeviceID) -> UInt32?
    package var defaultInputDeviceID: @Sendable () -> AudioDeviceID?

    package init(
      systemDeviceIDs: @escaping @Sendable () -> [AudioDeviceID]?,
      inputChannelCount: @escaping @Sendable (AudioDeviceID) -> Int?,
      name: @escaping @Sendable (AudioDeviceID) -> String?,
      uid: @escaping @Sendable (AudioDeviceID) -> String?,
      transport: @escaping @Sendable (AudioDeviceID) -> UInt32?,
      defaultInputDeviceID: @escaping @Sendable () -> AudioDeviceID?
    ) {
      self.systemDeviceIDs = systemDeviceIDs
      self.inputChannelCount = inputChannelCount
      self.name = name
      self.uid = uid
      self.transport = transport
      self.defaultInputDeviceID = defaultInputDeviceID
    }

    package static let live = AudioDeviceEnumerator.liveSnapshotReads
  }

  /// Blocking Core Audio reads: call only on `CoreAudioQueryLane`, never on the main actor.
  package static func read(_ reads: PropertyReads = .live) -> AudioDeviceSnapshot {
    let defaultID = reads.defaultInputDeviceID()
    guard let ids = reads.systemDeviceIDs() else {
      let defaultTransport = defaultID.flatMap(reads.transport)
      return AudioDeviceSnapshot(
        listReadSucceeded: false, devices: [], channelsComplete: false, identitiesComplete: false,
        resolvedAutoDeviceID: resolveAuto(
          defaultID: defaultID, defaultTransport: defaultTransport, inventory: .readFailed,
          transports: [:]),
        defaultDeviceID: defaultID, defaultDeviceTransport: defaultTransport)
    }

    var devices: [AudioDeviceSnapshot.Device] = []
    var channelsComplete = true
    var identitiesComplete = true
    for id in ids {
      // Same rule as `inputDeviceSnapshot()`: an unreadable channel count is neither an
      // output-only device nor a candidate; it is skipped and the pass can no longer prove absence.
      guard let channels = reads.inputChannelCount(id) else {
        channelsComplete = false
        continue
      }
      guard channels > 0 else { continue }
      let uid = reads.uid(id)
      if uid == nil { identitiesComplete = false }
      devices.append(
        .init(
          id: id, name: reads.name(id) ?? "Unknown", uid: uid, inputChannelCount: channels,
          rawTransport: reads.transport(id)))
    }

    var transports: [AudioDeviceID: UInt32] = [:]
    for device in devices { if let raw = device.rawTransport { transports[device.id] = raw } }
    // The default may not be a listed input (or its read may have been skipped): read its
    // transport once here so the resolver's #2022 check uses a frozen value too.
    let defaultTransport: UInt32? = defaultID.flatMap { id in
      devices.contains { $0.id == id } ? transports[id] : reads.transport(id)
    }
    if let defaultID, let defaultTransport { transports[defaultID] = defaultTransport }

    // Capture resolution keys candidates by UID with the same `?? ""` as `inputDeviceSnapshot()`.
    let candidates = devices.map {
      InputDeviceCandidate(id: $0.id, uid: $0.uid ?? "", rawTransport: $0.rawTransport)
    }
    return AudioDeviceSnapshot(
      listReadSucceeded: true, devices: devices, channelsComplete: channelsComplete,
      identitiesComplete: identitiesComplete,
      resolvedAutoDeviceID: resolveAuto(
        defaultID: defaultID, defaultTransport: defaultTransport,
        inventory: .success(candidates: candidates, complete: channelsComplete),
        transports: transports),
      defaultDeviceID: defaultID, defaultDeviceTransport: defaultTransport)
  }

  /// One `InputDeviceResolver` pass for Auto over frozen inputs only: the resolver stays the
  /// single selection authority (#2022 virtual-default divert, #1714 fallback), and it cannot
  /// reach live Core Audio from here.
  private static func resolveAuto(
    defaultID: AudioDeviceID?, defaultTransport: UInt32?, inventory: InputDeviceSnapshot,
    transports: [AudioDeviceID: UInt32]
  ) -> AudioDeviceID? {
    InputDeviceResolver(
      defaultInputDeviceID: { defaultID },
      inputDeviceSnapshot: { inventory },
      transportForDevice: { transports[$0] }
    ).resolve(preferredUID: nil).selectedDeviceID
  }
}

extension AudioDeviceEnumerator {
  /// Live reads for `AudioDeviceSnapshotReader`, built from this enumerator's existing single
  /// owners of each property read (declared here so it can reach the private helpers).
  static let liveSnapshotReads = AudioDeviceSnapshotReader.PropertyReads(
    systemDeviceIDs: { systemDeviceIDs() },
    inputChannelCount: { inputChannelCountRaw(for: $0) },
    name: { stringProperty(for: $0, selector: kAudioDevicePropertyDeviceNameCFString) },
    uid: { stringProperty(for: $0, selector: kAudioDevicePropertyDeviceUID) },
    transport: { transportTypeRaw(for: $0) },
    defaultInputDeviceID: { defaultInputDeviceID() }
  )
}
