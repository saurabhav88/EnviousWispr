import Testing

@testable import EnviousWisprAudio

// #2664: the ONE authority for which device input channel the mono capture
// takes. When this fails, the user sees either their chosen socket NOT being
// the one recorded (silence from a microphone that works everywhere else), or a
// stale choice for a device that shrank breaking a microphone that used to work.
@Suite("InputChannelPreference — #2664", .tags(.productOutcome))
struct InputChannelPreferenceTests {

  @Test("no preference means channel 0, today's behaviour for every device")
  func absentPreferenceIsChannelZero() {
    #expect(InputChannelPreference.effectiveChannel(requested: nil, availableChannels: 2) == 0)
    #expect(InputChannelPreference.effectiveChannel(requested: nil, availableChannels: nil) == 0)
  }

  @Test("Input 1 (stored as 0) is channel 0 whatever the device exposes")
  func explicitZeroIsChannelZero() {
    #expect(InputChannelPreference.effectiveChannel(requested: 0, availableChannels: 2) == 0)
    #expect(InputChannelPreference.effectiveChannel(requested: 0, availableChannels: 1) == 0)
  }

  @Test("a socket the device has is taken as asked")
  func inRangeChoiceIsHonoured() {
    // Scarlett 2i2: Input 2 is device channel 1.
    #expect(InputChannelPreference.effectiveChannel(requested: 1, availableChannels: 2) == 1)
    // A six-input interface, last socket.
    #expect(InputChannelPreference.effectiveChannel(requested: 5, availableChannels: 6) == 5)
  }

  @Test("a socket the device does not have falls back to channel 0, never traps or throws")
  func outOfRangeFallsToZero() {
    // Saved for a 2-input box, now plugged into a 1-input microphone with the same UID class.
    #expect(InputChannelPreference.effectiveChannel(requested: 1, availableChannels: 1) == 0)
    // Index == count is one past the last socket.
    #expect(InputChannelPreference.effectiveChannel(requested: 2, availableChannels: 2) == 0)
    // Channel count unreadable: fail closed to today's behaviour.
    #expect(InputChannelPreference.effectiveChannel(requested: 1, availableChannels: nil) == 0)
    // A read that collapsed to 0 channels.
    #expect(InputChannelPreference.effectiveChannel(requested: 1, availableChannels: 0) == 0)
    // A corrupt negative index.
    #expect(InputChannelPreference.effectiveChannel(requested: -1, availableChannels: 2) == 0)
  }

  @Test("a device with no readable UID has NO saved choice, so two such devices never share one")
  func unreadableUIDHasNoChoice() {
    // `AudioDeviceEnumerator` substitutes "" for a UID it could not read; a map
    // entry under "" (however it got there) must never reach a capture.
    let preference = ["": 1, "real-uid": 1]
    #expect(InputChannelPreference.requested(for: "", in: preference) == nil)
    #expect(InputChannelPreference.requested(for: nil, in: preference) == nil)
    #expect(InputChannelPreference.requested(for: "real-uid", in: preference) == 1)
    #expect(InputChannelPreference.requested(for: "unknown-uid", in: preference) == nil)
  }

  @Test("Auto flipping between a 1-input and a 2-input device applies each device's OWN value")
  func perDeviceValuesAreIndependent() {
    // The preference is keyed by device UID; the built-in microphone has no entry
    // and the interface has Input 2 chosen. Each resolves on its own count.
    let preference = ["scarlett-2i2-uid": 1]
    #expect(
      InputChannelPreference.effectiveChannel(
        requested: preference["builtin-mic-uid"], availableChannels: 1) == 0)
    #expect(
      InputChannelPreference.effectiveChannel(
        requested: preference["scarlett-2i2-uid"], availableChannels: 2) == 1)
  }
}
