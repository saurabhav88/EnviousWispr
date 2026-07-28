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

  @Test("The two live spoofs still need Gate 1 — the screen alone cannot refuse them")
  func spoofRequiresTheVeto() {
    // A file drawing two box rules, shown in a pager. Gate 2 matches it; Gate 1
    // is what refuses, and only when nothing supported is running.
    let spoof = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      text between rules
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(
      resolve(dependencies(scan: .available([]), screen: spoof)) == .refused(.noSupportedCLI))
    // With a CLI genuinely running elsewhere in the same terminal, this is the
    // founder's ACCEPTED residual risk, recorded as an observed outcome rather
    // than claimed closed.
    #expect(resolve(dependencies(screen: spoof)).evidence != nil)
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

  @Test("A relaunched terminal resets")
  func breakerResets() {
    let breaker = TerminalCircuitBreaker()
    breaker.trip(for: 900)
    #expect(breaker.isOpen(for: 900))
    breaker.reset(for: 900)
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
