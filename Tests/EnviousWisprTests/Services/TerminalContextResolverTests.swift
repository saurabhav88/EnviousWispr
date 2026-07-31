import ApplicationServices
import Darwin
import Foundation
import Testing

@testable import EnviousWisprServices

/// The three gates as one decision, plus the budget and the circuit breaker.
@Suite("Terminal context resolver")
struct TerminalContextResolverTests {

  // MARK: - Fixtures

  private static let claudePath = "/Users/m4pro_sv/.local/share/claude/versions/2.1.220"

  private static let claudeScreen = """
    some earlier output
    \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
    \u{276F} git commit -m fix the
    \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      ? for shortcuts
    """

  private static func runningClaude(term: String = "ghostty") -> TerminalProcessScan {
    .available([
      TerminalProcessSnapshot(
        processIdentifier: 42, executablePath: claudePath, arguments: ["claude"],
        termProgram: term, isAttachedToTerminal: true)
    ])
  }

  /// Records whether an injected dependency was reached. The closures are
  /// `@Sendable`, so a plain captured var will not compile.
  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() {
      lock.lock()
      defer { lock.unlock() }
      raised = true
    }
    var wasRaised: Bool {
      lock.lock()
      defer { lock.unlock() }
      return raised
    }
  }

  /// A clock the test drives, so no assertion depends on wall time.
  private final class TestClock: @unchecked Sendable {
    private var value: Double = 0
    var perCallCost: Double = 0
    func read() -> Double {
      defer { value += perCallCost }
      return value
    }
  }

  private func dependencies(
    bundle: String? = "com.mitchellh.ghostty",
    scan: TerminalProcessScan = runningClaude(),
    screen: String? = claudeScreen,
    clock: TestClock = TestClock()
  ) -> TerminalContextResolver.Dependencies {
    .init(
      bundleIdentifier: { bundle },
      scanProcesses: { scan },
      readScreenTail: { screen },
      now: { clock.read() })
  }

  private func resolve(
    _ dependencies: TerminalContextResolver.Dependencies,
    budget: TerminalResolutionBudget = .init(),
    breaker: TerminalCircuitBreaker = .init(),
    pid: pid_t = 900
  ) -> TerminalContextResult {
    TerminalContextResolver.resolve(
      targetPID: pid, budget: budget, breaker: breaker, dependencies: dependencies)
  }

  // MARK: - The happy path

  @Test("All three gates agreeing yields the input line and the tool")
  func resolvesWhenEveryGateAgrees() throws {
    let result = resolve(dependencies())
    let evidence = try #require(result.evidence)
    #expect(evidence.surface == .ghostty)
    #expect(evidence.located.cli == .claudeCode)
    #expect(evidence.located.inputLine == "git commit -m fix the")
    #expect(evidence.runningCLIs.map(\.processIdentifier) == [42])
  }

  // MARK: - Gate 0

  @Test("An app that is not a measured terminal refuses before any other work")
  func refusesIneligibleSurface() {
    let scanned = Flag()
    let screenRead = Flag()
    let dependencies = TerminalContextResolver.Dependencies(
      bundleIdentifier: { "com.apple.TextEdit" },
      scanProcesses: {
        scanned.raise()
        return Self.runningClaude()
      },
      readScreenTail: {
        screenRead.raise()
        return Self.claudeScreen
      })

    #expect(resolve(dependencies) == .refused(.surfaceIneligible))
    // Ordering is a cost decision too: an ineligible app must never reach a
    // process scan or an accessibility read.
    #expect(!scanned.wasRaised, "an ineligible app must not trigger a process scan")
    #expect(!screenRead.wasRaised, "an ineligible app must not trigger a screen read")
  }

  @Test("An unreadable bundle identifier refuses")
  func refusesUnknownBundleIdentifier() {
    #expect(resolve(dependencies(bundle: nil)) == .refused(.surfaceIneligible))
  }

  // MARK: - Gate 1, the veto

  @Test("Nothing supported running refuses, and never reads the screen")
  func vetoRefusesAndSkipsTheScreen() {
    let screenRead = Flag()
    let dependencies = TerminalContextResolver.Dependencies(
      bundleIdentifier: { "com.mitchellh.ghostty" },
      scanProcesses: { .available([]) },
      readScreenTail: {
        screenRead.raise()
        return Self.claudeScreen
      })

    #expect(resolve(dependencies) == .refused(.noSupportedCLI))
    #expect(!screenRead.wasRaised, "the veto must refuse before the screen is read at all")
  }

  @Test("An unreadable process list is its own refusal, not 'nothing running'")
  func unreadableProcessListIsDistinct() {
    #expect(resolve(dependencies(scan: .unavailable)) == .refused(.processScanUnavailable))
  }

  @Test("A CLI running under a DIFFERENT terminal does not license this one")
  func vetoIsScopedToTheFocusedTerminal() {
    #expect(
      resolve(dependencies(scan: Self.runningClaude(term: "iTerm.app")))
        == .refused(.noSupportedCLI))
  }

  // MARK: - Gate 2

  @Test("An unreadable screen refuses separately from an unrecognised one")
  func screenFailuresAreDistinct() {
    #expect(resolve(dependencies(screen: nil)) == .refused(.screenUnreadable))
    #expect(
      resolve(dependencies(screen: "just output\nand more")) == .refused(.screenRefused))
  }

  @Test("A markerless box-drawn file refuses at Gate 2, before the veto matters")
  func markerlessSpoofRefusesAtGate2() {
    let markerless = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      text between rules
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(resolve(dependencies(screen: markerless)) == .refused(.screenRefused))
  }

  @Test("A FAITHFUL spoof needs Gate 1 — the screen alone cannot refuse it")
  func faithfulSpoofRequiresTheVeto() {
    // A file that reproduces the marker too is indistinguishable from real input
    // by construction, which is exactly why the veto exists.
    let faithful = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} text between rules
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    // Nothing supported running: the veto refuses it.
    #expect(
      resolve(dependencies(scan: .available([]), screen: faithful)) == .refused(.noSupportedCLI))
    // A supported CLI running in ANOTHER tab of the same terminal: this is the
    // founder's ACCEPTED residual risk, recorded as an observed outcome rather
    // than claimed closed.
    #expect(resolve(dependencies(screen: faithful)).evidence != nil)
  }

  // MARK: - Budget

  @Test("An exhausted budget refuses immediately and touches nothing")
  func exhaustedBudgetRefusesImmediately() {
    let scanned = Flag()
    let dependencies = TerminalContextResolver.Dependencies(
      bundleIdentifier: { "com.mitchellh.ghostty" },
      scanProcesses: {
        scanned.raise()
        return Self.runningClaude()
      },
      readScreenTail: { Self.claudeScreen })

    let budget = TerminalResolutionBudget(total: 0.100)
    budget.charge(0.100)
    #expect(resolve(dependencies, budget: budget) == .refused(.deadline))
    #expect(!scanned.wasRaised)
  }

  @Test("The budget is CUMULATIVE across resolution and revalidation, not per call")
  func budgetIsCumulativeAcrossCalls() {
    // The defect this freezes: a per-CALL limit lets initial resolution plus
    // every commit check exceed the bound that was promised to the user.
    let clock = TestClock()
    clock.perCallCost = 0.030
    let budget = TerminalResolutionBudget(total: 0.100)
    let dependencies = dependencies(clock: clock)

    // Each resolve charges two steps at 0.030 each.
    #expect(resolve(dependencies, budget: budget).evidence != nil)
    let afterFirst = budget.remaining
    #expect(afterFirst < 0.100, "the first resolution must consume budget")

    _ = resolve(dependencies, budget: budget)
    #expect(budget.remaining < afterFirst, "a second call must not reset the budget")
  }

  @Test("Budget spending accumulates and never goes negative")
  func budgetAccounting() {
    let budget = TerminalResolutionBudget(total: 0.100)
    #expect(budget.remaining == 0.100)
    budget.charge(0.040)
    #expect(abs(budget.remaining - 0.060) < 0.0001)
    budget.charge(0.500)
    #expect(budget.remaining == 0)
    #expect(budget.isExhausted)
    // A negative charge cannot buy time back.
    budget.charge(-1.0)
    #expect(budget.isExhausted)
  }

  @Test("The cap is CUMULATIVE across calls, not applied to each one")
  func budgetStepChargesEveryCall() {
    // Founder 2026-07-28: "it has to be a 100 ms cap for all the questions."
    // The defect this freezes: the same bound applied to each of five reads, so
    // five could take five times the cap between them and no single call ever
    // looked late.
    //
    // TIMING MARGINS HERE ARE ONE-DIRECTIONAL, and must stay that way (#1893).
    // A busy-wait guarantees a call costs AT LEAST its target and says nothing
    // about the ceiling, and `step` also charges three accessibility
    // round-trips inside the same window. So every assertion must survive a
    // call costing MORE than asked. The original wanted four 25 ms calls to fit
    // a 100 ms budget EXACTLY — one call of overhead short — and a loaded CI
    // runner exhausted the budget in three, failing the required check on an
    // unrelated PR.
    let element = AXUIElementCreateSystemWide()
    let slowCall = {
      // Busy-wait rather than sleep: the charge must reflect real elapsed
      // time, and a test that slept would prove only that sleeping works.
      let until = DispatchTime.now().uptimeNanoseconds + 25_000_000
      while DispatchTime.now().uptimeNanoseconds < until {}
      return true
    }

    // NOR MAY AN ASSERTION USE AN ABSOLUTE MILLISECOND THRESHOLD, which is the
    // same defect pointing the other way and is the worse one: a descheduled
    // busy-wait can make a SINGLE call long enough to satisfy any fixed number,
    // so the per-call regression this test exists to catch would pass. Both
    // assertions below therefore compare measured quantities against each
    // other, never against a constant.
    //
    // A budget far larger than the work, so nothing can cut the sequence short
    // and the call count is fixed rather than raced for.
    let shared = TerminalResolutionBudget(total: 1.0)
    var calls = 0
    var perCall: [Double] = []
    for _ in 0..<3 {
      let started = DispatchTime.now().uptimeNanoseconds
      _ = shared.step(applying: element) {
        calls += 1
        return slowCall()
      }
      perCall.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
    }
    let spent = 1.0 - shared.remaining

    #expect(calls == 3, "a budget this large must never cut the sequence short")
    // THE POINT, and it holds no matter how long any individual call took. A
    // per-call bound retains only the FINAL call, so its spend can never exceed
    // that call's own wall time as measured from outside `step` — outer time
    // strictly contains what `step` charges. A cumulative one has also charged
    // the first two, so it clears that bar by their combined ~50 ms.
    #expect(
      spent > (perCall.last ?? 0),
      "the spend must exceed the last call alone, i.e. every call was charged")

    // And the SHARED budget really runs out. Two 25 ms calls exceed a 40 ms cap
    // between them while neither does alone, so exhaustion here is reachable
    // only by accumulating. The final call is a no-op: under a per-call bound
    // the budget would carry only its ~0 µs and stay open.
    let tight = TerminalResolutionBudget(total: 0.040)
    _ = tight.step(applying: element) { slowCall() }
    _ = tight.step(applying: element) { slowCall() }
    _ = tight.step(applying: element) { true }

    #expect(tight.isExhausted, "two 25 ms calls must exhaust a 40 ms cumulative cap")
    #expect(tight.remaining == 0)
  }

  @Test("A healthy sequence of calls barely touches the budget")
  func budgetStepIsFreeWhenCallsAreFast() {
    // Measured live 2026-07-28: all five reads cost mean 0.78 ms in Ghostty and
    // 1.79 ms in iTerm2. The cap is a failure bound, not a latency target, and
    // must never bite healthy work.
    let budget = TerminalResolutionBudget(total: 0.100)
    let element = AXUIElementCreateSystemWide()

    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<5 { _ = budget.step(applying: element) { true } }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9

    #expect(!budget.isExhausted, "five instant calls must not exhaust the cap")
    // Bound the spend by what the loop ACTUALLY took rather than by an absolute
    // millisecond figure (#1893). A fixed `remaining > 0.090` asserts that five
    // accessibility round-trips cost under 10 ms, which is a claim about the
    // machine, not about our budget — and this file's own comment records cold
    // first calls spiking to 19-35 ms. What belongs to the budget is that it
    // charges elapsed time and never adds a per-call surcharge on top.
    #expect(
      0.100 - budget.remaining <= elapsed + 0.001,
      "the budget must charge only time that really passed")
  }

  // MARK: - Circuit breaker

  @Test("A tripped breaker refuses the NEXT delivery without starting any read")
  func breakerSurvivesAcrossDeliveries() {
    // Stateful across deliveries by design: a per-delivery breaker would defeat
    // the whole point, because the accumulating blocked reads are what it exists
    // to prevent.
    let breaker = TerminalCircuitBreaker()
    breaker.trip(for: 900)

    let scanned = Flag()
    let dependencies = TerminalContextResolver.Dependencies(
      bundleIdentifier: { "com.mitchellh.ghostty" },
      scanProcesses: {
        scanned.raise()
        return Self.runningClaude()
      },
      readScreenTail: { Self.claudeScreen })

    // A FRESH budget, i.e. a new delivery.
    #expect(
      resolve(dependencies, budget: .init(), breaker: breaker, pid: 900)
        == .refused(.breakerOpen))
    #expect(!scanned.wasRaised, "an open breaker must not start another blocked read")
  }

  @Test("A different terminal starts with a closed breaker")
  func breakerIsPerTargetProcess() {
    let breaker = TerminalCircuitBreaker()
    breaker.trip(for: 900)
    #expect(resolve(dependencies(), breaker: breaker, pid: 901).evidence != nil)
    #expect(breaker.isOpen(for: 900))
    #expect(!breaker.isOpen(for: 901))
  }

  @Test("The breaker is keyed by process IDENTITY, so PID reuse cannot inherit it")
  func breakerKeyedByProcessIdentity() {
    // Cloud review found the gap: the latch lasts the whole process lifetime and
    // nothing clears it, so once macOS recycled that PID an unrelated terminal
    // would be refused forever with no way back.
    //
    // pid 900 does not exist here, so its start time is unreadable and it keys
    // consistently. THIS process does exist, so it keys on a real start time —
    // proving the key is more than the number.
    let breaker = TerminalCircuitBreaker()
    let live = getpid()
    breaker.trip(for: live)
    #expect(breaker.isOpen(for: live))
    #expect(!breaker.isOpen(for: 900), "a different process must not inherit the latch")
    #expect(TerminalProcessScanner.startTime(of: live) != nil)
    #expect(TerminalProcessScanner.startTime(of: pid_t(Int32.max)) == nil)
  }

  @Test("A read that overruns the budget TRIPS the breaker, in production code")
  func overrunTripsTheBreaker() {
    // Whole-diff review found the breaker was never armed: it was tested,
    // documented, and inert, so a wedged terminal would have repeated its delay
    // on every dictation forever. Tests that trip it by hand cannot catch that.
    // This drives the PRODUCT path and asserts the breaker ends up open.
    let clock = TestClock()
    clock.perCallCost = 0.400  // one wedged accessibility call
    let breaker = TerminalCircuitBreaker()
    let budget = TerminalResolutionBudget(total: 0.100)

    let result = resolve(dependencies(clock: clock), budget: budget, breaker: breaker, pid: 900)
    #expect(result == .refused(.deadline))
    #expect(breaker.isOpen(for: 900), "an overrun must arm the breaker, not merely refuse once")
  }

  @Test("Evidence that arrived AFTER the deadline is discarded, not used")
  func overspentEvidenceIsRejected() {
    // The read can complete perfectly and still be too late. Accepting it would
    // make the promised bound meaningless, because the user already waited.
    let clock = TestClock()
    clock.perCallCost = 0.400
    let result = resolve(
      dependencies(clock: clock), budget: .init(total: 0.100), breaker: .init(), pid: 900)
    #expect(result.evidence == nil)
  }

  @Test("The NEXT dictation after an overrun starts no read at all")
  func breakerStopsTheFollowingDelivery() {
    let clock = TestClock()
    clock.perCallCost = 0.400
    let breaker = TerminalCircuitBreaker()
    _ = resolve(dependencies(clock: clock), budget: .init(total: 0.100), breaker: breaker, pid: 900)

    // A fresh delivery: fresh budget, healthy clock, nothing wedged.
    let scanned = Flag()
    let healthy = TerminalContextResolver.Dependencies(
      bundleIdentifier: { "com.mitchellh.ghostty" },
      scanProcesses: {
        scanned.raise()
        return Self.runningClaude()
      },
      readScreenTail: { Self.claudeScreen })
    #expect(
      resolve(healthy, budget: .init(), breaker: breaker, pid: 900) == .refused(.breakerOpen))
    #expect(!scanned.wasRaised, "the wedged terminal must not be touched again")
  }

  @Test("A healthy resolution leaves the breaker closed")
  func healthyResolutionDoesNotTrip() {
    // The two-way control: without this, a breaker that tripped on EVERY
    // resolution would pass the tests above and disable the feature entirely.
    let breaker = TerminalCircuitBreaker()
    #expect(resolve(dependencies(), breaker: breaker, pid: 900).evidence != nil)
    #expect(!breaker.isOpen(for: 900))
  }

  // MARK: - Revalidation

  @Test("Unchanged evidence revalidates")
  func revalidatesWhenNothingChanged() throws {
    let dependencies = dependencies()
    let captured = try #require(resolve(dependencies).evidence)
    let result = TerminalContextResolver.revalidate(
      captured, targetPID: 900, budget: .init(), breaker: .init(),
      dependencies: dependencies)
    #expect(result.evidence == captured)
  }

  @Test("A screen that scrolled between read and commit is stale")
  func staleWhenScreenChanged() throws {
    let captured = try #require(resolve(dependencies()).evidence)
    // Same input line, but the buffer above it moved. The raw tail is the only
    // identity a screen-derived context has, so this MUST fail.
    let scrolled = "one more line of output\n" + Self.claudeScreen
    let result = TerminalContextResolver.revalidate(
      captured, targetPID: 900, budget: .init(), breaker: .init(),
      dependencies: dependencies(screen: scrolled))
    #expect(result == .refused(.staleAtCommit))
  }

  @Test("The CLI exiting between read and commit refuses")
  func staleWhenCLIExited() throws {
    let captured = try #require(resolve(dependencies()).evidence)
    let result = TerminalContextResolver.revalidate(
      captured, targetPID: 900, budget: .init(), breaker: .init(),
      dependencies: dependencies(scan: .available([])))
    #expect(result == .refused(.noSupportedCLI))
  }

  @Test("Focus moving to another app between read and commit refuses")
  func staleWhenFocusChanged() throws {
    let captured = try #require(resolve(dependencies()).evidence)
    let result = TerminalContextResolver.revalidate(
      captured, targetPID: 900, budget: .init(), breaker: .init(),
      dependencies: dependencies(bundle: "com.apple.TextEdit"))
    #expect(result == .refused(.surfaceIneligible))
  }

  @Test("The user editing the line between read and commit is stale")
  func staleWhenInputLineChanged() throws {
    let captured = try #require(resolve(dependencies()).evidence)
    let edited = Self.claudeScreen.replacingOccurrences(
      of: "git commit -m fix the", with: "git commit -m fix")
    let result = TerminalContextResolver.revalidate(
      captured, targetPID: 900, budget: .init(), breaker: .init(),
      dependencies: dependencies(screen: edited))
    #expect(result == .refused(.staleAtCommit))
  }

  @Test("Evidence equality ignores the order processes were enumerated in")
  func evidenceOrderIndependence() {
    let located = TerminalScreenParser.Located(cli: .claudeCode, inputLine: "x")
    let a = TerminalEvidence(
      surface: .ghostty,
      runningCLIs: [
        .init(processIdentifier: 7, cli: .codex), .init(processIdentifier: 3, cli: .claudeCode),
      ],
      screenTail: "tail", located: located)
    let b = TerminalEvidence(
      surface: .ghostty,
      runningCLIs: [
        .init(processIdentifier: 3, cli: .claudeCode), .init(processIdentifier: 7, cli: .codex),
      ],
      screenTail: "tail", located: located)
    // The kernel does not promise an enumeration order; a spurious mismatch here
    // would refuse at commit for no reason at all.
    #expect(a == b)
  }

  @Test("A CLI appearing or disappearing changes the token")
  func evidenceTracksTheRunningSet() {
    let located = TerminalScreenParser.Located(cli: .claudeCode, inputLine: "x")
    let one = TerminalEvidence(
      surface: .ghostty, runningCLIs: [.init(processIdentifier: 3, cli: .claudeCode)],
      screenTail: "tail", located: located)
    let two = TerminalEvidence(
      surface: .ghostty,
      runningCLIs: [
        .init(processIdentifier: 3, cli: .claudeCode), .init(processIdentifier: 7, cli: .codex),
      ],
      screenTail: "tail", located: located)
    #expect(one != two)
  }
}
