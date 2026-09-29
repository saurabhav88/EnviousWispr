import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The idle-memory sample's timing (#3289 §8b). When this fails, the founder's "does an idle app
/// give its memory back" chart counts busy moments as idle, sends more than one row per launch, or
/// sends while the user has turned usage metrics off.
@MainActor
@Suite(
  "IdleMemoryObserver: one sample after 12 idle minutes, never while working or opted out (#3289)",
  .tags(.observabilityContract))
struct IdleMemoryObserverTests {
  @MainActor final class Rig {
    var clock = ContinuousClock.now
    var working = false
    var epoch = 0
    var metrics = true
    var footprint: Int? = 480
    var wordCheck = (loaded: false, wanted: true)
    var sent: [IdleMemoryObserver.Sample] = []
    lazy var observer = IdleMemoryObserver(
      isWorkInFlight: { [unowned self] in self.working },
      workEpoch: { [unowned self] in self.epoch },
      usageMetricsOn: { [unowned self] in self.metrics },
      readFootprintMB: { [unowned self] in self.footprint },
      wordCheckState: { [unowned self] in self.wordCheck },
      emit: { [unowned self] in self.sent.append($0) },
      now: { [unowned self] in self.clock })

    func advance(minutes: Int) { clock = clock + .seconds(minutes * 60) }
  }

  private func makeRig() -> Rig {
    let rig = Rig()
    _ = rig.observer  // the launch instant is the rig's clock now
    return rig
  }

  @Test("12 idle minutes after launch send exactly one sample, with the state at that moment")
  func sendsOnceAfterTwelveMinutes() {
    let rig = makeRig()
    rig.advance(minutes: 11)
    rig.observer.tick()
    #expect(rig.sent.isEmpty, "sent before 12 idle minutes")
    rig.advance(minutes: 1)
    rig.observer.tick()
    #expect(
      rig.sent == [
        .init(
          footprintMB: 480, minutesSinceLaunch: 12, wordCheckLoaded: false, wordCheckWanted: true)
      ])
    rig.advance(minutes: 30)
    rig.observer.tick()
    #expect(rig.sent.count == 1, "a second sample in one launch")
  }

  @Test("work that ends between ticks starts the stretch at the first idle tick, never before")
  func workEndingBetweenTicks() {
    let rig = makeRig()
    rig.advance(minutes: 10)
    rig.working = true
    rig.observer.tick()  // busy at minute 10
    // The work ends 59 seconds later, between ticks; the next tick is at minute 11.
    rig.working = false
    rig.advance(minutes: 1)
    rig.observer.tick()  // first idle tick: the stretch restarts here (minute 11)
    rig.advance(minutes: 11)
    rig.observer.tick()  // minute 22: 11 minutes since the end could be seen
    #expect(rig.sent.isEmpty, "sent before 12 minutes after the work ended")
    rig.advance(minutes: 1)
    rig.observer.tick()  // minute 23: 12 minutes since the first idle tick
    #expect(rig.sent.count == 1)
    #expect(rig.sent.first?.minutesSinceLaunch == 23)
  }

  @Test("a dictation or import still in flight at every tick never lets the stretch grow")
  func longWorkNeverIdle() {
    let rig = makeRig()
    rig.working = true
    for _ in 0..<30 {
      rig.advance(minutes: 1)
      rig.observer.tick()
    }
    #expect(rig.sent.isEmpty, "sent while work was in flight")
  }

  /// A dictation that claims the engine at arming and ends before recording, or any take, between
  /// two ticks: no tick sees it in flight, only the lease's epoch moved.
  @Test("a claim that starts and ends between two ticks restarts the stretch after it")
  func claimBetweenTicks() {
    let rig = makeRig()
    rig.advance(minutes: 11)
    rig.epoch += 1  // claimed at 11:00 and released 40 s later, all between ticks
    rig.clock = rig.clock + .seconds(60)
    rig.observer.tick()  // minute 12, the first tick after it: the stretch restarts here
    #expect(rig.sent.isEmpty, "a take a minute ago counted as idle")
    rig.advance(minutes: 11)
    rig.observer.tick()  // minute 23
    #expect(rig.sent.isEmpty, "sent before 12 minutes after the claim ended")
    rig.advance(minutes: 1)
    rig.observer.tick()  // minute 24
    #expect(rig.sent.count == 1)
    #expect(rig.sent.first?.minutesSinceLaunch == 24)
  }

  @Test("a claim made before the observer started is not counted as work")
  func epochAtLaunchIsTheBaseline() {
    let rig = Rig()
    rig.epoch = 5  // claims before the observer existed
    _ = rig.observer
    rig.advance(minutes: 12)
    rig.observer.tick()
    #expect(rig.sent.count == 1)
  }

  @Test("usage metrics off sends nothing, and turning them on needs a fresh full stretch")
  func optOut() {
    let rig = makeRig()
    rig.metrics = false
    rig.advance(minutes: 30)
    rig.observer.tick()
    #expect(rig.sent.isEmpty, "sent while usage metrics were off")
    rig.metrics = true
    rig.advance(minutes: 1)
    rig.observer.tick()
    #expect(rig.sent.isEmpty, "backfilled an idle stretch from while metrics were off")
    rig.advance(minutes: 11)
    rig.observer.tick()
    #expect(rig.sent.count == 1)
  }

  @Test("turning usage metrics off and on between two ticks restarts the stretch")
  func optOutBetweenTicks() {
    let rig = makeRig()
    rig.advance(minutes: 6)
    rig.metrics = false
    rig.observer.usageMetricsChanged()
    rig.metrics = true
    rig.observer.usageMetricsChanged()  // back on before any tick saw it off
    rig.advance(minutes: 6)
    rig.observer.tick()  // minute 12: only 6 minutes since the switch changed
    #expect(rig.sent.isEmpty, "counted time from before the opt-out")
    rig.advance(minutes: 6)
    rig.observer.tick()
    #expect(rig.sent.count == 1)
  }

  @Test("a failed footprint read sends nothing, and the next tick can still send")
  func failedRead() {
    let rig = makeRig()
    rig.footprint = nil
    rig.advance(minutes: 12)
    rig.observer.tick()
    #expect(rig.sent.isEmpty)
    #expect(rig.observer.hasSent == false)
    rig.footprint = 512
    rig.advance(minutes: 1)
    rig.observer.tick()
    #expect(rig.sent.first?.footprintMB == 512)
  }

  @Test("the real footprint read returns this process's memory in MiB")
  func realFootprint() throws {
    let megabytes = try #require(IdleMemoryObserver.currentFootprintMB())
    // A running test host holds tens to hundreds of MiB; the bounds catch a bytes-for-MiB or a
    // wrong-flavor read, which land orders of magnitude away.
    #expect(megabytes > 10 && megabytes < 64 * 1024, "\(megabytes) MiB")
  }
}
