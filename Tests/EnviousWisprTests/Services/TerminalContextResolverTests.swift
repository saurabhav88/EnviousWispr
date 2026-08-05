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
    budget.charge(0.100, label: "probe")
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
    budget.charge(0.040, label: "probe")
    #expect(abs(budget.remaining - 0.060) < 0.0001)
    budget.charge(0.500, label: "probe")
    #expect(budget.remaining == 0)
    #expect(budget.isExhausted)
    // A negative charge cannot buy time back.
    budget.charge(-1.0, label: "probe")
    #expect(budget.isExhausted)
  }

  @Test("The cap is CUMULATIVE across calls, not applied to each one")
  func budgetStepChargesEveryCall() {
    // Founder 2026-07-28: "it has to be a 100 ms cap for all the questions."
    // The defect this freezes: the same bound applied to each of five reads, so
    // five could take five times the cap between them and no single call ever
    // looked late.
    //
    // The CUMULATIVE half of that decision is what this test freezes and it is
    // unchanged. The VALUE is no longer 100 ms — it is
    // `TerminalResolutionBudget.defaultTotal`, raised to 200 ms on 2026-08-05
    // (#1941). This test passes its own total, so it does not depend on either.
    //
    // NO ASSERTION HERE MAY DEPEND ON WALL TIME (#1893), which is the rule the
    // rest of this suite already follows through `TestClock`. Three review
    // rounds landed on this one test, each on a different face of the same
    // mistake, and each patch created the next: a busy-wait guarantees a floor
    // and never a ceiling, so a threshold sized for calls that take *at least*
    // 25 ms fails when a runner makes one take longer (the original, which
    // needed four 25 ms calls to fit 100 ms exactly and broke an unrelated PR);
    // widening that threshold instead lets a SINGLE descheduled call satisfy
    // it, so the per-call regression passes and the test goes quietly green;
    // and comparing against the spend hits `remaining`'s clamp at zero. There
    // is no correct constant, because the failure modes point in both
    // directions at once. `step` therefore takes the same injected clock the
    // resolver already takes, and the numbers below are exact.
    let element = AXUIElementCreateSystemWide()
    let clock = TestClock()
    clock.perCallCost = 0.030  // every `step` reads the clock twice: 30 ms each

    let shared = TerminalResolutionBudget(total: 1.0, now: { clock.read() })
    var calls = 0
    for _ in 0..<3 { _ = shared.step(applying: element, label: "probe") { calls += 1 } }

    #expect(calls == 3)
    // THE POINT. Cumulative charges all three: 0.090. A per-call bound retains
    // only the final call and would read 0.030.
    #expect(abs((1.0 - shared.remaining) - 0.090) < 1e-9, "every call must be charged")

    // And the SHARED budget really runs out. Two 30 ms calls exceed a 40 ms cap
    // between them while neither does alone, so exhaustion is reachable only by
    // accumulating — a per-call bound would sit at 30 ms and stay open.
    let tight = TerminalResolutionBudget(total: 0.040, now: { clock.read() })
    for _ in 0..<2 { _ = tight.step(applying: element, label: "probe") {} }

    #expect(tight.isExhausted, "two 30 ms calls must exhaust a 40 ms cumulative cap")
    #expect(tight.remaining == 0)
  }

  @Test("A healthy sequence of calls barely touches the budget")
  func budgetStepIsFreeWhenCallsAreFast() {
    // Measured live 2026-07-28: all five reads cost mean 0.78 ms in Ghostty and
    // 1.79 ms in iTerm2. The cap is a failure bound, not a latency target, and
    // must never bite healthy work.
    //
    // Driven by `TestClock` rather than the wall clock (#1893). The original
    // asserted `remaining > 0.090` against real time, which is a claim that five
    // accessibility round-trips cost under 10 ms — a fact about the machine, not
    // about our budget, and one this file's own note contradicts by recording
    // cold first calls at 19-35 ms.
    let clock = TestClock()
    clock.perCallCost = 0.001  // a healthy read, at the measured order of cost
    let budget = TerminalResolutionBudget(total: 0.100, now: { clock.read() })
    let element = AXUIElementCreateSystemWide()

    for _ in 0..<5 { _ = budget.step(applying: element, label: "probe") {} }

    #expect(!budget.isExhausted, "five healthy calls must not exhaust the cap")
    #expect(
      budget.remaining > 0.090,
      "five healthy calls must leave the budget nearly whole")
  }

  @Test("the budget records what each step cost, named, for the log line")
  func timingDescriptionNamesEachStep() {
    // The breaker trip on 2026-08-04 was undiagnosable because the budget
    // charged itself and recorded nothing. Three hypotheses were tested by hand
    // against a live machine and all three were wrong. This is the line that
    // makes the next trip answerable from the log alone.
    let clock = TestClock()
    clock.perCallCost = 0.002
    let budget = TerminalResolutionBudget(total: 0.100, now: { clock.read() })
    let element = AXUIElementCreateSystemWide()

    #expect(
      budget.timingDescription.isEmpty,
      "no step ran, so the line must carry nothing rather than an empty bracket")

    _ = budget.step(applying: element, label: "focused") {}
    _ = budget.step(applying: element, label: "screen") {}

    let description = budget.timingDescription
    #expect(description.contains("focused="), "each step is named, got \(description)")
    #expect(description.contains("screen="), "each step is named, got \(description)")
    #expect(description.contains("total="), "and the total is what the cap is judged against")

    // The point of the line is that the numbers are REAL, not that they exist.
    // A description that renders every step as 0.0ms would satisfy `contains`
    // and diagnose nothing, which is the failure mode this asserts against.
    #expect(
      description.contains("2.0ms"),
      "the recorded cost must be the driven clock's, got \(description)")
    #expect(
      description.contains("total=4.0ms"),
      "and the total must be their sum, got \(description)")

    // A phase marker separates the initial read from the commit-boundary
    // re-check, which reuses the same labels. It must cost nothing: if a marker
    // charged even a rounding error, the total the cap is judged against would
    // drift with the number of phases rather than with real work.
    budget.mark("recheck")
    _ = budget.step(applying: element, label: "focused") {}

    let withPhases = budget.timingDescription
    #expect(withPhases.contains("|recheck|"), "the phase boundary must be visible")
    #expect(
      withPhases.contains("total=6.0ms"),
      "the marker adds no time; only the third real step does, got \(withPhases)")
  }

  @Test("a cost charged OUTSIDE an accessibility step still reaches the total")
  func nonAccessibilityCostsAreInTheTotal() {
    // Cloud review's finding, frozen. The process sweep is not an accessibility
    // call, so nothing else charges it — `resolve` times it by hand and charges
    // the shared budget directly. It was recorded NOWHERE, so a sweep that ate
    // 90 ms of the 100 ms cap printed `total=1.0ms`: the line would have been at
    // its most misleading in exactly the case it exists to explain.
    let clock = TestClock()
    clock.perCallCost = 0.002
    let budget = TerminalResolutionBudget(total: 0.100, now: { clock.read() })
    let element = AXUIElementCreateSystemWide()

    budget.charge(0.090, label: "scan")
    _ = budget.step(applying: element, label: "screen") {}

    let description = budget.timingDescription
    #expect(description.contains("scan=90.0ms"), "named and real, got \(description)")
    #expect(
      description.contains("total=92.0ms"),
      "the total must include it, got \(description)")

    // Two-way control on the escape hatch: a cost the caller says is ALREADY
    // recorded must not appear twice. `overspent(by: 0, label: nil, …)` runs on
    // the screen-read path for exactly that reason, and a version that recorded
    // anyway would double every step in the line.
    budget.charge(0.005, label: nil)
    let after = budget.timingDescription
    #expect(
      after == description,
      "an unlabelled charge changes the budget, never the trace, got \(after)")
    #expect(budget.remaining < 0.006, "but it IS charged")
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
