// scripts/lib/mic-in-use.swift — is ANY input device running anywhere? (#3013)
//
// Three answers, never two (gotchas-audio.md RULE: device-liveness-is-three-valued):
//   exit 0  running somewhere: SOME process holds SOME input device (any app, any
//           build configuration, including a Release EnviousWispr that writes no
//           app.log at all, and a non-default device the user selected through
//           AudioCaptureManager.selectedInputDeviceUID)
//   exit 1  every input device is idle
//   exit 2  could not tell (device list unreadable, or a property read failed on
//           a device that has input channels)
// Two-way controlled on 2026-09-16: `running` while a 6-second AVAudioEngine
// tap held the default input, `idle` two seconds after it stopped. Property
// reads, not a capture, so no microphone permission is needed. Compiled on
// demand by scripts/nightly-local-battery.sh, which treats the answer as
// ADVISORY: EnviousWispr's warm-engine policy keeps the capture unit running
// while idle (measured the same day: the built-in microphone read running
// while the only dev instance was idle), so "running" does not mean "a take
// is in flight". Every device is checked, not only the default (cloud review
// r7): the app records from a persistently selected device when one is set.
import CoreAudio
import Foundation

func readUInt32(
  _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
) -> UInt32? {
  var addr = AudioObjectPropertyAddress(
    mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func hasInputChannels(_ device: AudioDeviceID) -> Bool? {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreamConfiguration,
    mScope: kAudioObjectPropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
    return nil
  }
  let raw = UnsafeMutableRawPointer.allocate(
    byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
  defer { raw.deallocate() }
  guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return nil }
  let list = raw.assumingMemoryBound(to: AudioBufferList.self)
  let buffers = UnsafeMutableAudioBufferListPointer(list)
  return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

var listAddr = AudioObjectPropertyAddress(
  mSelector: kAudioHardwarePropertyDevices,
  mScope: kAudioObjectPropertyScopeGlobal,
  mElement: kAudioObjectPropertyElementMain)
var listSize: UInt32 = 0
guard
  AudioObjectGetPropertyDataSize(
    AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize) == noErr,
  listSize > 0
else {
  print("could-not-tell: device list")
  exit(2)
}
var devices = [AudioDeviceID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioDeviceID>.size)
guard
  AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize, &devices) == noErr
else {
  print("could-not-tell: device list read")
  exit(2)
}

var indeterminate = false
var inputDevices = 0
for device in devices.prefix(Int(listSize) / MemoryLayout<AudioDeviceID>.size) {
  guard let isInput = hasInputChannels(device) else {
    indeterminate = true
    continue
  }
  guard isInput else { continue }
  inputDevices += 1
  guard
    let running = readUInt32(
      device, kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal)
  else {
    indeterminate = true
    continue
  }
  if running != 0 {
    print("running: device \(device)")
    exit(0)
  }
}
if indeterminate || inputDevices == 0 {
  print("could-not-tell: \(inputDevices) input devices, indeterminate=\(indeterminate)")
  exit(2)
}
print("idle: \(inputDevices) input devices")
exit(1)
