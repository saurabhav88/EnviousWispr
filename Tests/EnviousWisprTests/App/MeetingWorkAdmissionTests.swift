import Dispatch
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #3972 R25, plan §6: when these fail, a meeting's processing starts while the user dictates,
/// keeps running under memory pressure, or never resumes after the dictation or the pressure
/// ended, or a cancelled meeting keeps waiting.
@MainActor
@Suite("Meeting work admission", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingWorkAdmissionTests {
  @MainActor
  @Observable
  final class Activity {
    var dictating = true
  }

  @MainActor
  final class Returned {
    var value = false
  }

  /// A flag Observation cannot see, like `EngineCoordinator`'s start window.
  @MainActor
  final class Hidden {
    var starting = true
  }

  @Test("the idle wait returns when observed dictation state ends")
  func observedChangeWakes() async {
    let activity = Activity()
    let returned = Returned()
    let wait = Task { @MainActor in
      await MeetingWorkAdmission.waitUntil { !activity.dictating }
      returned.value = true
    }
    await Task.yield()
    #expect(returned.value == false)
    activity.dictating = false
    await wait.value
    #expect(returned.value)
  }

  @Test("an input Observation cannot see wakes the wait through its poke")
  func pokeWakes() async {
    let hidden = Hidden()
    let wakes = MeetingWakeSignal()
    let wait = Task { @MainActor in
      await MeetingWorkAdmission.waitUntil({ !hidden.starting }, wakes: wakes)
    }
    await Self.waitForRegistration(wakes)
    // A poke while still busy re-arms rather than returning.
    wakes.poke()
    await Self.waitForRegistration(wakes)
    hidden.starting = false
    wakes.poke()
    await wait.value
    #if DEBUG
      #expect(wakes.registrationCountForTesting == 0)
    #endif
  }

  @Test("a cancelled wait returns at once, leaving no registration")
  func cancellationReturns() async {
    let wakes = MeetingWakeSignal()
    let wait = Task { @MainActor in
      await MeetingWorkAdmission.waitUntil({ false }, wakes: wakes)
    }
    await Self.waitForRegistration(wakes)
    wait.cancel()
    await wait.value
    #if DEBUG
      #expect(wakes.registrationCountForTesting == 0)
    #endif
  }

  @Test("a wait already satisfied returns without suspending")
  func alreadyIdle() async {
    await MeetingWorkAdmission.waitUntil { true }
  }

  @Test("memory pressure: warning and critical are elevated; the wait returns on normal")
  func pressureTransitions() async {
    let pressure = MeetingMemoryPressure()
    #expect(pressure.isElevated == false)
    pressure.receive(.warning)
    #expect(pressure.level == .warning)
    pressure.receive(.critical)
    #expect(pressure.level == .critical)
    let returned = Returned()
    let wait = Task { @MainActor in
      await pressure.waitUntilNormal()
      returned.value = true
    }
    await Task.yield()
    // Still critical: a later warning keeps it elevated.
    pressure.receive(.warning)
    await Task.yield()
    #expect(returned.value == false)
    pressure.receive(.normal)
    await wait.value
    #expect(returned.value)
    #expect(pressure.isElevated == false)
  }

  @Test("a cancelled pressure wait returns while pressure stays elevated")
  func pressureWaitCancels() async {
    let pressure = MeetingMemoryPressure()
    pressure.receive(.critical)
    let wait = Task { @MainActor in await pressure.waitUntilNormal() }
    await Task.yield()
    wait.cancel()
    await wait.value
    #expect(pressure.isElevated)
  }

  @Test("the real pressure source starts once and stops cleanly")
  func sourceLifecycle() {
    let pressure = MeetingMemoryPressure()
    pressure.start()
    pressure.start()
    pressure.stop()
    pressure.stop()
    #expect(pressure.level == .normal)
  }

  /// Bounded yield wait for the wait's synchronous registration (no clock involved).
  private static func waitForRegistration(
    _ wakes: MeetingWakeSignal, sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    #if DEBUG
      for _ in 0..<1_000 where wakes.registrationCountForTesting == 0 { await Task.yield() }
      #expect(wakes.registrationCountForTesting == 1, sourceLocation: sourceLocation)
    #else
      for _ in 0..<100 { await Task.yield() }
    #endif
  }
}
