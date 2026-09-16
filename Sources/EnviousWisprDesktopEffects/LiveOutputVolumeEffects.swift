import AudioToolbox
import CoreAudio
import EnviousWisprAppKit
import Foundation

/// #1413 — the live CoreAudio OUTPUT-scope reads and writes behind
/// `OutputVolumeControlling`. Lives here, not in Audio or AppKit, for the same
/// reason the hotkey and panel effects do: the unit-test target links those
/// modules, and a suite must never lower the developer's speakers
/// (`scripts/check-dependency-direction.sh` bans `AudioObjectSetPropertyData`
/// outside this module).
///
/// Volume is `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (the value
/// the volume keys move) and mute is `kAudioDevicePropertyMute`, both on the
/// output scope, main element. Existence and settability are asked with
/// `AudioObjectHasProperty` / `AudioObjectIsPropertySettable`; a device that
/// answers no is `.unsupported`, a read that fails is `.unreadable`, and neither
/// ever becomes a fabricated value (plan §3.2).
@MainActor
package final class LiveOutputVolumeEffects: OutputVolumeControlling {
  package init() {}

  package func identity(of device: AudioDeviceID) -> OutputDeviceIdentity? {
    guard let uid = Self.uid(of: device) else { return nil }
    return OutputDeviceIdentity(id: device, uid: uid, transportTypeRaw: Self.transportType(of: device))
  }

  /// Every device on the system, input-only and output-only alike.
  ///
  /// The size query and the read are two calls, so the list can change between
  /// them (cloud review, PR #3000): a shrunken list leaves a zero-filled tail,
  /// a grown one can leave the held output past the buffer. Only the bytes
  /// CoreAudio wrote back are read, and a failed read or a miss is retried
  /// (three attempts in all) before the device is reported gone, because a
  /// `nil` here retires the hold as `skippedDeviceGone` and leaves the Mac
  /// lowered or muted.
  package func device(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    let stride = MemoryLayout<AudioDeviceID>.size
    for _ in 0..<3 {
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr
      else { continue }
      let count = Int(size) / stride
      guard count > 0 else { continue }
      var ids = [AudioDeviceID](repeating: 0, count: count)
      size = UInt32(count * stride)
      guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
      else { continue }
      if let device = ids.prefix(Int(size) / stride).first(where: { Self.uid(of: $0) == uid }) {
        return device
      }
    }
    return nil
  }

  package func readVolume(of device: AudioDeviceID) -> OutputPropertyRead<Float> {
    var address = Self.volumeAddress
    switch Self.settability(device, &address) {
    case .supported: break
    case .unsupported: return .unsupported
    case .unreadable: return .unreadable
    }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return status == noErr ? .value(value) : .unreadable
  }

  package func readMute(of device: AudioDeviceID) -> OutputPropertyRead<Bool> {
    var address = Self.muteAddress
    switch Self.settability(device, &address) {
    case .supported: break
    case .unsupported: return .unsupported
    case .unreadable: return .unreadable
    }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return status == noErr ? .value(value != 0) : .unreadable
  }

  package func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool {
    var address = Self.volumeAddress
    guard Self.isSettable(device, &address) else { return false }
    var value = Float32(min(max(volume, 0), 1))
    let size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
  }

  package func setMute(_ muted: Bool, of device: AudioDeviceID) -> Bool {
    var address = Self.muteAddress
    guard Self.isSettable(device, &address) else { return false }
    var value: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
  }

  // MARK: - Addresses and probes

  private static var volumeAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static var muteAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  private enum Settability { case supported, unsupported, unreadable }

  /// Existence AND settability; the settable query returns a status and a
  /// Boolean. A failed QUERY is `unreadable`, not `unsupported`: it proves
  /// nothing about the device.
  private static func settability(
    _ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress
  ) -> Settability {
    guard AudioObjectHasProperty(device, &address) else { return .unsupported }
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else {
      return .unreadable
    }
    return settable.boolValue ? .supported : .unsupported
  }

  private static func isSettable(
    _ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress
  ) -> Bool {
    if case .supported = settability(device, &address) { return true }
    return false
  }

  private static func transportType(of device: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  private static func uid(of device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeRetainedValue() as String
  }
}
