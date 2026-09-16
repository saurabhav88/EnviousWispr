// scripts/lib/mic-in-use.swift — is the default input device running anywhere? (#3013)
//
// Three answers, never two (gotchas-audio.md RULE: device-liveness-is-three-valued):
//   exit 0  running somewhere: SOME process holds the default input (any app, any
//           build configuration, including a Release EnviousWispr that writes no
//           app.log at all)
//   exit 1  idle
//   exit 2  could not tell (no default input device, or the property read failed)
// The caller treats 2 as occupied. Two-way controlled on 2026-09-16: `running`
// while a 6-second AVAudioEngine tap held the input, `idle` two seconds after
// it stopped. A property read, not a capture, so it needs no microphone
// permission. Compiled on demand by scripts/nightly-local-battery.sh.
import CoreAudio
import Foundation
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                      mScope: kAudioObjectPropertyScopeGlobal,
                                      mElement: kAudioObjectPropertyElementMain)
var dev = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { exit(2) }
addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                  mScope: kAudioObjectPropertyScopeGlobal,
                                  mElement: kAudioObjectPropertyElementMain)
var running: UInt32 = 0
size = UInt32(MemoryLayout<UInt32>.size)
guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { exit(2) }
print(running != 0 ? "running" : "idle")
exit(running != 0 ? 0 : 1)
