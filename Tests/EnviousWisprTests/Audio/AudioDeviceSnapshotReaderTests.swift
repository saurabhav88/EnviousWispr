import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio

/// #4021: the frozen device facts the microphone list, menu, Settings and Bluetooth card read
/// instead of asking Core Audio on the main thread. When these fail, the user sees a wrong or
/// missing microphone, a pinned microphone reset after a failed read, or the wrong Bluetooth tip.
@Suite("Audio device snapshot reader", .tags(.productOutcome))
struct AudioDeviceSnapshotReaderTests {
  struct FakeDevice {
    var channels: Int?
    var name: String?
    var uid: String?
    var transport: UInt32?
  }

  /// Fake Core Audio that also counts every read, to prove one pass and no hidden re-reads.
  final class FakeHAL: Sendable {
    let list: [AudioDeviceID]?
    let devices: [AudioDeviceID: FakeDevice]
    let defaultID: AudioDeviceID?
    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    init(list: [AudioDeviceID]?, devices: [AudioDeviceID: FakeDevice], defaultID: AudioDeviceID?) {
      self.list = list
      self.devices = devices
      self.defaultID = defaultID
    }

    func count(_ key: String) -> Int { counts.withLock { $0[key, default: 0] } }
    private func bump(_ key: String) { counts.withLock { $0[key, default: 0] += 1 } }

    var reads: AudioDeviceSnapshotReader.PropertyReads {
      .init(
        systemDeviceIDs: {
          self.bump("list")
          return self.list
        },
        inputChannelCount: {
          self.bump("channels-\($0)")
          return self.devices[$0]?.channels
        },
        name: {
          self.bump("name-\($0)")
          return self.devices[$0]?.name
        },
        uid: {
          self.bump("uid-\($0)")
          return self.devices[$0]?.uid
        },
        transport: {
          self.bump("transport-\($0)")
          return self.devices[$0]?.transport
        },
        defaultInputDeviceID: {
          self.bump("default")
          return self.defaultID
        })
    }
  }

  static let builtIn = FakeDevice(
    channels: 1, name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice",
    transport: kAudioDeviceTransportTypeBuiltIn)
  static let usb = FakeDevice(
    channels: 2, name: "USB Mic", uid: "usb-1", transport: kAudioDeviceTransportTypeUSB)
  static let headset = FakeDevice(
    channels: 1, name: "AirPods", uid: "bt-1", transport: kAudioDeviceTransportTypeBluetooth)
  static let virtual = FakeDevice(
    channels: 2, name: "Meeting Audio", uid: "virtual-1",
    transport: kAudioDeviceTransportTypeVirtual)

  @Test(
    "Display list keeps system order, input filter, names, Unknown fallback, channels and labels")
  func displayInventory() {
    var unnamed = Self.usb
    unnamed.name = nil
    let outputOnly = FakeDevice(
      channels: 0, name: "Speakers", uid: "out-1", transport: kAudioDeviceTransportTypeBuiltIn)
    let hal = FakeHAL(
      list: [3, 1, 2], devices: [3: Self.builtIn, 1: outputOnly, 2: unnamed], defaultID: 3)
    let snapshot = AudioDeviceSnapshotReader.read(hal.reads)

    #expect(snapshot.displayDevices.map(\.id) == [3, 2])
    #expect(snapshot.displayDevices.map(\.name) == ["MacBook Pro Microphone", "Unknown"])
    #expect(snapshot.displayDevices.map(\.inputChannelCount) == [1, 2])
    #expect(snapshot.transportLabel(forUID: "BuiltInMicrophoneDevice") == "built_in")
    #expect(snapshot.transportLabel(forUID: "usb-1") == "usb")
    #expect(snapshot.transportLabel(forUID: "out-1") == nil, "an output-only device is not listed")
    #expect(snapshot.provesAbsence)
  }

  @Test("A failed UID read keeps the device listed but blocks proof of absence")
  func failedIdentityRead() {
    var noUID = Self.usb
    noUID.uid = nil
    let hal = FakeHAL(list: [1, 2], devices: [1: Self.builtIn, 2: noUID], defaultID: 1)
    let snapshot = AudioDeviceSnapshotReader.read(hal.reads)

    #expect(snapshot.devices.map(\.uid) == ["BuiltInMicrophoneDevice", nil])
    #expect(snapshot.displayDevices.map(\.uid) == ["BuiltInMicrophoneDevice", ""])
    #expect(snapshot.channelsComplete)
    #expect(snapshot.identitiesComplete == false)
    #expect(snapshot.provesAbsence == false)
  }

  @Test("List failure, partial inventory and a complete empty inventory are three different facts")
  func inventoryOutcomes() {
    let failed = AudioDeviceSnapshotReader.read(
      FakeHAL(list: nil, devices: [:], defaultID: nil).reads)
    #expect(failed.listReadSucceeded == false)
    #expect(failed.devices.isEmpty)
    #expect(failed.provesAbsence == false)

    var unreadable = Self.usb
    unreadable.channels = nil
    let partial = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [1, 2], devices: [1: Self.builtIn, 2: unreadable], defaultID: 1).reads)
    #expect(partial.devices.map(\.id) == [1], "readable devices stay usable")
    #expect(partial.channelsComplete == false)
    #expect(partial.provesAbsence == false)

    let empty = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [], devices: [:], defaultID: nil).reads)
    #expect(empty.listReadSucceeded)
    #expect(empty.devices.isEmpty)
    #expect(empty.provesAbsence, "a complete empty read is real absence")
  }

  @Test(
    "Auto follows the resolver: present default, virtual default diverted, no default falls back")
  func autoResolution() {
    let followsDefault = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [1, 2], devices: [1: Self.builtIn, 2: Self.usb], defaultID: 2).reads)
    #expect(followsDefault.resolvedAutoDeviceID == 2)

    let diverted = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [5, 1], devices: [5: Self.virtual, 1: Self.builtIn], defaultID: 5).reads)
    #expect(
      diverted.resolvedAutoDeviceID == 1,
      "#2022: a proven non-microphone default loses to a real one")

    let noDefault = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [2, 1], devices: [1: Self.builtIn, 2: Self.usb], defaultID: nil).reads)
    #expect(
      noDefault.resolvedAutoDeviceID == 1, "#1714: no default prefers the built-in microphone")
  }

  @Test("Bluetooth answers: true, false and no answer for Auto and for a UID")
  func bluetoothAnswers() {
    let onHeadset = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [1, 4], devices: [1: Self.builtIn, 4: Self.headset], defaultID: 4).reads)
    #expect(onHeadset.autoInputIsBluetooth == true)
    #expect(onHeadset.uidIsBluetooth("bt-1") == true)
    #expect(onHeadset.uidIsBluetooth("BuiltInMicrophoneDevice") == false)
    #expect(
      onHeadset.uidIsBluetooth("gone") == nil, "an unlisted UID falls back to Auto in the presenter"
    )

    let onBuiltIn = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [1], devices: [1: Self.builtIn], defaultID: 1).reads)
    #expect(onBuiltIn.autoInputIsBluetooth == false)

    let nothing = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [], devices: [:], defaultID: nil).reads)
    #expect(nothing.autoInputIsBluetooth == nil)

    // An unreadable transport on a FOUND device answers false, never nil: nil means "unresolved"
    // and makes the presenter fall back to the Auto answer, which could show the wrong
    // Bluetooth tip (silent harm). Matches today's `isBluetoothDevice`.
    var unreadablePinned = Self.usb
    unreadablePinned.transport = nil
    let pinnedUnreadable = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [2, 4], devices: [2: unreadablePinned, 4: Self.headset], defaultID: 4).reads)
    #expect(pinnedUnreadable.autoInputIsBluetooth == true)
    #expect(pinnedUnreadable.uidIsBluetooth("usb-1") == false)
    #expect(pinnedUnreadable.transportLabel(forUID: "usb-1") == nil)

    var unreadableDefault = Self.builtIn
    unreadableDefault.transport = nil
    let autoUnreadable = AudioDeviceSnapshotReader.read(
      FakeHAL(list: [1], devices: [1: unreadableDefault], defaultID: 1).reads)
    #expect(autoUnreadable.resolvedAutoDeviceID == 1)
    #expect(autoUnreadable.autoInputIsBluetooth == false)
  }

  @Test("One pass: the list and default are read once and each device property at most once")
  func noHiddenReReads() {
    let hal = FakeHAL(
      list: [5, 1, 4], devices: [5: Self.virtual, 1: Self.builtIn, 4: Self.headset], defaultID: 5)
    let snapshot = AudioDeviceSnapshotReader.read(hal.reads)
    #expect(snapshot.resolvedAutoDeviceID == 1)
    #expect(hal.count("list") == 1)
    #expect(hal.count("default") == 1)
    for id: AudioDeviceID in [5, 1, 4] {
      #expect(hal.count("channels-\(id)") == 1)
      #expect(hal.count("uid-\(id)") == 1)
      #expect(hal.count("transport-\(id)") == 1)
      #expect(hal.count("name-\(id)") == 1)
    }
  }
}
