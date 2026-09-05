import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// Drives `AudioCaptureManager`'s `#if DEBUG` seams, so the whole suite is
// DEBUG-only (`swift-testing-debug-seam-needs-if-debug`).
#if DEBUG

  // #2664: changing the socket must reach the NEXT recording. The capture unit
  // stays warm for up to 30 s between takes and `resolveSource()` reuses it when
  // the route is unchanged, so without a channel conjunct in that decision a user
  // who picks Input 2 after a silent take would dictate again into the SAME unit
  // still wired to Input 1 — and see the same silence, now with the fix applied.
  //
  // These cases drive the REAL `resolveSource()` against a real
  // `HALDeviceInputSource` carrying a committed bind, with every hardware read
  // injected: the route resolver's output-device reads, the input resolver's
  // default-device read, and the unit's own liveness. Source type, target UID and
  // device compatibility are held CONSTANT across every arm; only the manager's
  // channel preference changes. When this fails, the user sees a socket change
  // do nothing until the warm engine times out.
  @MainActor
  @Suite("AudioCaptureManager warm reuse honours the socket choice — #2664", .tags(.productOutcome))
  struct InputChannelReuseTests {

    private static let boundDeviceID: AudioDeviceID = 42
    private static let boundUID = "scarlett-2i2-uid"

    /// A warm HAL source bound to a two-input device on `channel`, Auto-selected
    /// (`targetDeviceUID` nil), whose device predicate answers "still the default"
    /// through an injected resolver. No `AudioUnit` exists; liveness is forced.
    private static func warmSource(channel: Int, deviceID: AudioDeviceID = boundDeviceID)
      -> HALDeviceInputSource
    {
      let source = HALDeviceInputSource()
      source.targetDeviceUID = nil
      source.inputDeviceResolver = InputDeviceResolver(
        defaultInputDeviceID: { deviceID },
        inputDeviceSnapshot: { .success(candidates: [], complete: true) },
        transportForDevice: { _ in nil })
      source.setBoundInputDeviceForTesting(
        BoundInputDevice(
          deviceID: deviceID, deviceUID: boundUID, transportLabel: "usb",
          resolutionSource: "system_default", inputChannel: channel),
        nativeChannelCount: 2)
      source.isRunningOverrideForTesting = true
      return source
    }

    /// A manager on Auto with `warm` installed as its live source and both
    /// output-route reads injected, so `resolveSource()` runs with no hardware.
    private static func makeManager(warm: HALDeviceInputSource, preference: [String: Int])
      -> AudioCaptureManager
    {
      let manager = AudioCaptureManager()
      manager.preferredInputDeviceIDOverride = ""
      manager.installRouteResolverForTesting(
        CaptureRouteResolver(
          defaultOutputDeviceID: { nil }, isBluetoothOutputDevice: { _ in false }))
      manager.installCapturedSourceForTesting(warm, sessionID: 1)
      manager.inputChannelByDeviceUID = preference
      return manager
    }

    // MARK: - The two arms the plan names

    @Test("unchanged preference: the warm unit on Input 2 is REUSED")
    func unchangedPreferenceReuses() {
      let warm = Self.warmSource(channel: 1)
      let manager = Self.makeManager(warm: warm, preference: [Self.boundUID: 1])

      let resolved = manager.resolveSourceForTesting()

      #expect(resolved === warm, "an unchanged socket must not force a rebuild")
    }

    @Test(
      "changed preference: the warm unit on Input 2 is REBUILT when the user goes back to Input 1")
    func changedPreferenceRebuilds() {
      let warm = Self.warmSource(channel: 1)
      // The user cleared the choice (or picked Input 1): the map no longer names
      // this device, so the effective channel is 0 and the warm unit is on 1.
      let manager = Self.makeManager(warm: warm, preference: [:])

      let resolved = manager.resolveSourceForTesting()

      #expect(resolved !== warm, "a changed socket must tear the warm unit down")
      // The replacement is a fresh production HAL source carrying the manager's
      // CURRENT map, so its cold prepare reads the new choice — not the copy the
      // torn-down source prepared on.
      let rebuilt = resolved as? HALDeviceInputSource
      #expect(rebuilt != nil, "the rebuilt source is the production HAL type")
      #expect(rebuilt?.inputChannelByDeviceUID == [:])
    }

    @Test(
      "changed preference the other way: a warm unit on Input 1 is rebuilt when Input 2 is chosen")
    func choosingInputTwoRebuildsAChannelZeroUnit() {
      // This is the customer's exact path: silent take on the default, pick
      // Input 2 in Settings, dictate again inside the warm window.
      let warm = Self.warmSource(channel: 0)
      let manager = Self.makeManager(warm: warm, preference: [Self.boundUID: 1])

      let resolved = manager.resolveSourceForTesting()

      #expect(resolved !== warm)
      #expect((resolved as? HALDeviceInputSource)?.inputChannelByDeviceUID == [Self.boundUID: 1])
    }

    // MARK: - Held constant: everything that is NOT the channel

    @Test("a preference for a DIFFERENT device leaves the warm unit alone")
    func otherDevicePreferenceIsIrrelevant() {
      let warm = Self.warmSource(channel: 0)
      let manager = Self.makeManager(warm: warm, preference: ["some-other-interface": 1])

      #expect(manager.resolveSourceForTesting() === warm)
    }

    @Test("a preference the bound device cannot honour compares equal to its channel-0 bind")
    func unusablePreferenceDoesNotForceAPointlessRebuild() {
      // Input 6 chosen for a two-input box: cold prepare would land on channel 0
      // again, so rebuilding every take would only cost the warm engine.
      let warm = Self.warmSource(channel: 0)
      let manager = Self.makeManager(warm: warm, preference: [Self.boundUID: 5])

      #expect(manager.resolveSourceForTesting() === warm)
    }

    // MARK: - The predicate itself, keyed by UID

    @Test("same UID, new device ID keeps the choice (a replug recycles the numeric handle)")
    func sameUIDNewDeviceIDKeepsTheChoice() {
      let source = Self.warmSource(channel: 1, deviceID: 7)
      #expect(source.boundInputChannelMatches(preference: [Self.boundUID: 1]))
      #expect(source.boundInputChannelMatches(preference: [:]) == false)
    }

    @Test("no committed bind answers false, like the device predicate beside it")
    func noBindIsNotAMatch() {
      let source = HALDeviceInputSource()
      #expect(source.boundInputChannelMatches(preference: [:]) == false)
    }
  }

#endif
