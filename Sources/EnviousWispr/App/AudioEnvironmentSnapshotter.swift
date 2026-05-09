import AppKit
import CoreAudio
import EnviousWisprServices
import Foundation

protocol AudioEnvironmentCollecting: Sendable {
  func collect(
    reason: AudioEnvironmentSnapshot.Reason,
    route: String?,
    frontmostAppBundleID: String?,
    deviceEventAt: Date?,
    capturedAt: Date
  ) -> AudioEnvironmentSnapshot
}

@MainActor
final class AudioEnvironmentSnapshotter {
  private let collector: any AudioEnvironmentCollecting
  private let routeProvider: @MainActor () -> String?
  private let now: @MainActor () -> Date
  private var latestSnapshot: AudioEnvironmentSnapshot?
  private var latestGeneration: UInt64 = 0
  private var lastDeviceEventAt: Date?

  init(
    collector: any AudioEnvironmentCollecting = CoreAudioEnvironmentCollector(),
    routeProvider: @escaping @MainActor () -> String?,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.collector = collector
    self.routeProvider = routeProvider
    self.now = now
  }

  func recordingStarted() {
    refresh(reason: .recordingStart)
  }

  func applicationBecameActive() {
    refresh(reason: .appActive)
  }

  func audioDeviceEventOccurred() {
    lastDeviceEventAt = now()
    refresh(reason: .audioDeviceEvent)
  }

  func latestForError() -> [String: Any]? {
    latestSnapshot?.sentryContext(now: now())
  }

  func refresh(reason: AudioEnvironmentSnapshot.Reason) {
    latestGeneration &+= 1
    let generation = latestGeneration
    let capturedAt = now()
    let route = routeProvider()
    let frontmostAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let deviceEventAt = lastDeviceEventAt
    let collector = self.collector

    Task.detached(priority: .utility) { [weak self] in
      let snapshot = collector.collect(
        reason: reason,
        route: route,
        frontmostAppBundleID: frontmostAppBundleID,
        deviceEventAt: deviceEventAt,
        capturedAt: capturedAt
      )
      await MainActor.run { [weak self] in
        guard let self, generation == self.latestGeneration else { return }
        self.latestSnapshot = snapshot
      }
    }
  }
}

struct CoreAudioEnvironmentCollector: AudioEnvironmentCollecting {
  func collect(
    reason: AudioEnvironmentSnapshot.Reason,
    route: String?,
    frontmostAppBundleID: String?,
    deviceEventAt: Date?,
    capturedAt: Date
  ) -> AudioEnvironmentSnapshot {
    guard let processIDs = Self.processObjectIDs() else {
      return .unavailable(
        reason: reason,
        capturedAt: capturedAt,
        route: route,
        frontmostAppBundleID: frontmostAppBundleID,
        deviceEventAt: deviceEventAt,
        unavailableReason: "process_object_list_unavailable"
      )
    }

    var inputBundles: [String] = []
    var outputBundles: [String] = []
    var inputCount = 0
    var outputCount = 0

    for processID in processIDs {
      let isRunningInput = Self.boolProperty(
        objectID: processID,
        selector: kAudioProcessPropertyIsRunningInput
      )
      let isRunningOutput = Self.boolProperty(
        objectID: processID,
        selector: kAudioProcessPropertyIsRunningOutput
      )

      guard isRunningInput || isRunningOutput else { continue }

      let bundleID =
        Self.stringProperty(objectID: processID, selector: kAudioProcessPropertyBundleID)
        ?? Self.pidProperty(objectID: processID).flatMap { pid in
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }

      if isRunningInput {
        inputCount += 1
        if let bundleID { inputBundles.append(bundleID) }
      }
      if isRunningOutput {
        outputCount += 1
        if let bundleID { outputBundles.append(bundleID) }
      }
    }

    let inputDeviceID = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    let outputDeviceID = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)

    return AudioEnvironmentSnapshot(
      reason: reason,
      capturedAt: capturedAt,
      inputProcessCount: inputCount,
      outputProcessCount: outputCount,
      inputBundleIDs: inputBundles,
      outputBundleIDs: outputBundles,
      frontmostAppBundleID: frontmostAppBundleID,
      inputDeviceTransport: inputDeviceID.flatMap(Self.deviceTransport),
      outputDeviceTransport: outputDeviceID.flatMap(Self.deviceTransport),
      route: route,
      bluetoothOutputActive: outputDeviceID.map(Self.isBluetoothDevice) ?? false,
      deviceEventAt: deviceEventAt
    )
  }

  private static func processObjectIDs() -> [AudioObjectID]? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard sizeStatus == noErr, dataSize > 0 else { return nil }

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: count)
    let dataStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs)
    guard dataStatus == noErr else { return nil }
    return processIDs
  }

  private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = 0
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
    let transport = deviceTransportRaw(deviceID)
    return transport == kAudioDeviceTransportTypeBluetooth
      || transport == kAudioDeviceTransportTypeBluetoothLE
  }

  private static func deviceTransport(_ deviceID: AudioDeviceID) -> String? {
    guard let transport = deviceTransportRaw(deviceID) else { return nil }
    switch transport {
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
    default:
      return "unknown"
    }
  }

  private static func deviceTransportRaw(_ deviceID: AudioDeviceID) -> UInt32? {
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
    guard status == noErr else { return nil }
    return transport
  }

  private static func boolProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> Bool {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return status == noErr && value != 0
  }

  private static func pidProperty(objectID: AudioObjectID) -> pid_t? {
    var pid: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
    guard status == noErr, pid > 0 else { return nil }
    return pid
  }

  private static func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize = UInt32(MemoryLayout<CFString>.size)
    var result: CFString? = nil
    let status = withUnsafeMutablePointer(to: &result) { pointer in
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
    }
    guard status == noErr, let result else { return nil }
    return result as String
  }
}
