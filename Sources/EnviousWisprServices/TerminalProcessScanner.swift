import Darwin
import Foundation

// MARK: - Supported surfaces and tools

/// Terminal apps whose rendered screen Gate 0 admits.
///
/// This is NOT the CLI support decision — Gate 1 owns that — but it IS a real
/// authorisation gate, because it licenses interpreting an app's bounded
/// `AXStringForRange` tail as a rendered terminal grid, which is a
/// terminal-specific reading of ordinary text. A correct bundle id for an
/// UNMEASURED terminal is therefore not inert, and the set ships with measured
/// entries only.
package enum TerminalSurface: String, CaseIterable, Sendable {
  case ghostty
  case terminalApp
  case iTerm2

  package init?(bundleIdentifier: String) {
    switch bundleIdentifier {
    case "com.mitchellh.ghostty": self = .ghostty
    case "com.apple.Terminal": self = .terminalApp
    case "com.googlecode.iterm2": self = .iTerm2
    default: return nil
    }
  }

  /// The `TERM_PROGRAM` value this terminal exports into the shells it spawns.
  ///
  /// Measured 2026-07-28, each from the shipped artifact rather than from
  /// documentation: `ghostty` observed live on 48 running processes;
  /// `Apple_Terminal` and `iTerm.app` read out of the Terminal.app and iTerm2
  /// binaries themselves.
  package var termProgramValue: String {
    switch self {
    case .ghostty: return "ghostty"
    case .terminalApp: return "Apple_Terminal"
    case .iTerm2: return "iTerm.app"
    }
  }
}

/// The terminal-hosted assistants whose input line Gate 2 knows how to locate.
package enum SupportedTerminalCLI: String, CaseIterable, Sendable {
  case claudeCode = "claude_code"
  case codex = "codex"
  case geminiCLI = "gemini_cli"
}

/// One supported CLI observed running, with the terminal it reported.
package struct RunningTerminalCLI: Equatable, Hashable, Sendable {
  package let processIdentifier: pid_t
  package let cli: SupportedTerminalCLI

  package init(processIdentifier: pid_t, cli: SupportedTerminalCLI) {
    self.processIdentifier = processIdentifier
    self.cli = cli
  }
}

/// The outcome of one process sweep.
///
/// `.unavailable` is NOT `.available([])`. An unreadable process list is
/// indistinguishable from an empty one at the point of decision, so both must
/// veto — but they are different facts, and only a typed result stops a caller
/// erasing the difference with `?? []`.
package enum TerminalProcessScan: Equatable, Sendable {
  case unavailable
  case available([TerminalProcessSnapshot])
}

/// What one process looks like to the veto. Plain values only: no ports, no
/// handles, nothing that keeps another process alive or escapes Services.
package struct TerminalProcessSnapshot: Equatable, Sendable {
  package let processIdentifier: pid_t
  package let executablePath: String
  package let arguments: [String]
  package let termProgram: String?
  /// Whether the process holds a controlling terminal.
  ///
  /// The single condition that separates a terminal program from an app: on the
  /// founder's machine 63 of 732 processes hold one, and every one of the 35
  /// name-lookalikes is in the other 669.
  package let isAttachedToTerminal: Bool

  package init(
    processIdentifier: pid_t, executablePath: String, arguments: [String], termProgram: String?,
    isAttachedToTerminal: Bool
  ) {
    self.processIdentifier = processIdentifier
    self.executablePath = executablePath
    self.arguments = arguments
    self.termProgram = termProgram
    self.isAttachedToTerminal = isAttachedToTerminal
  }
}

// MARK: - Scanner

/// Gate 1's evidence source: which supported CLIs are running, and under which
/// terminal app.
///
/// Gate 1 is a VETO, not a tab selector (founder 2026-07-28). It answers only
/// "is at least one supported CLI running under this terminal app"; the focused
/// tab's own screen decides which tool it is and where the line is. The
/// superseded design tried to pick the tab by matching working directories, and
/// measurement killed it: a terminal exposes only one directory per tab, so five
/// tabs in one project all report the same one, and the strict rule REFUSED on
/// the founder's own main project. No directory is read here, deliberately.
package enum TerminalProcessScanner {

  // MARK: Identity

  /// The command name each supported CLI runs under.
  static let commandNames: [String: SupportedTerminalCLI] = [
    "claude": .claudeCode,
    "codex": .codex,
    "gemini": .geminiCLI,
  ]

  /// Script runtimes that host a CLI, so that `argv[1]` is the real program.
  ///
  /// This is not a guess about installers — it is how a shebang script runs at
  /// all. Without it, `vim codex` would be read as Codex, because the file being
  /// edited sits in `argv[1]`.
  static let scriptRuntimes: Set<String> = ["node", "bun", "deno"]

  /// Identify a process by the name it runs under.
  ///
  /// **Only ever applied to a process that holds a controlling terminal.** That
  /// precondition is what makes a name usable at all. Measured 2026-07-28: the
  /// substrings `codex`/`gemini` matched **35 unrelated processes** on the
  /// founder's machine — every ChatGPT desktop helper, `Codex (Renderer)`,
  /// `codex_chronicle`, and a real executable literally named `codex` inside
  /// `ChatGPT.app` — and **every one of them is a GUI process with no terminal**.
  /// The terminal precondition eliminates the whole class structurally, rather
  /// than by a list of exceptions that would need extending forever.
  ///
  /// This REPLACED an install-path matcher (founder decision 2026-07-28). That
  /// matcher was measured to miss the Homebrew Codex installed on the founder's
  /// own machine, because it predicted where vendors install rather than asking
  /// what is running. Head-to-head on the same live processes: both approaches
  /// rejected all 35 impostors; only this one found Homebrew Codex.
  ///
  /// Known and accepted (founder: "we can't deal with every edge case — if
  /// people are doing these fooling things and complain we can fix for it"): a
  /// file deliberately named `codex` and run in a terminal is read as Codex.
  /// That requires a user to mislead their own machine, there is no attacker,
  /// and the worst outcome is a wrong space or capital in one sentence.
  static func identify(executablePath: String, arguments: [String]) -> SupportedTerminalCLI? {
    func commandName(_ path: String) -> String {
      var name = (path as NSString).lastPathComponent.lowercased()
      if name.hasSuffix(".js") { name = String(name.dropLast(3)) }
      return name
    }

    // Claude Code's executable is named after its VERSION
    // (`…/claude/versions/2.1.220`), so `argv[0]` is the only place its name
    // appears. Codex installed through Homebrew is the opposite: a real binary
    // named `codex`. Both shapes are live on the founder's machine.
    let executableName = commandName(executablePath)
    if let cli = commandNames[executableName] { return cli }
    if let first = arguments.first, let cli = commandNames[commandName(first)] { return cli }

    // A script runtime hosts the real program in `argv[1]`.
    guard scriptRuntimes.contains(executableName) else { return nil }
    guard let hosted = arguments.dropFirst().first, hosted.hasPrefix("/") else { return nil }
    return commandNames[commandName(hosted)]
  }

  // MARK: The veto

  /// Every supported CLI in `snapshots` that reports running under `surface`.
  ///
  /// `TERM_PROGRAM` is INHERITED down process trees, so it is a HEURISTIC for
  /// terminal ownership, not proof of it. Measured 2026-07-28: an iTerm2 process
  /// launched from a Ghostty shell still reported `ghostty`.
  ///
  /// The honest statement of the limit — an earlier comment here called the
  /// inheritance "benign", which grounded review correctly rejected: a process
  /// can report a terminal it is not running under. `TERM_PROGRAM=ghostty claude`
  /// run from Terminal.app, or a tmux server started under one terminal and
  /// attached from another, both attribute a CLI to the wrong app. Consequences
  /// are bounded by what this gate authorises: it can only ever let the veto
  /// PASS when it should have refused, never the reverse, and a passing veto
  /// still only permits Gate 2 to read the focused tab's own screen. The cost of
  /// being wrong here is the accepted class — a wrong space, a wrong capital, or
  /// one dropped word — never a wrong destination.
  ///
  /// A CLI reporting no `TERM_PROGRAM` is attributed to no terminal.
  static func supportedCLIs(
    in snapshots: [TerminalProcessSnapshot],
    hostedBy surface: TerminalSurface
  ) -> [RunningTerminalCLI] {
    let expected = surface.termProgramValue
    var found: [RunningTerminalCLI] = []
    for snapshot in snapshots {
      // The terminal precondition comes FIRST and is load-bearing: it is what
      // makes matching by name safe. Measured — all 35 name-lookalikes are GUI
      // processes with no controlling terminal.
      guard snapshot.isAttachedToTerminal else { continue }
      guard snapshot.termProgram == expected else { continue }
      guard
        let cli = identify(
          executablePath: snapshot.executablePath, arguments: snapshot.arguments)
      else { continue }
      found.append(RunningTerminalCLI(processIdentifier: snapshot.processIdentifier, cli: cli))
    }
    return found
  }

  // MARK: Live capture

  /// Snapshot every readable process.
  ///
  /// The result is TYPED rather than optional so that "the process list could
  /// not be read" cannot be collapsed into "nothing is running" by a caller
  /// writing `?? []`. Both outcomes veto, but they are different facts and the
  /// telemetry distinguishes them; an optional invites erasing that at the one
  /// call site where it matters.
  ///
  /// No pre-filter by executable name, and that half of the old note still
  /// stands: a filter that guesses how a CLI is LAUNCHED — binary names, install
  /// paths, argv shapes — is a hand-authored membership set that silently drops
  /// an unusual install.
  ///
  /// **The COST half of that note was false and is deleted (#1943).** It read
  /// "mean 3 ms / p95 7 ms against a 100 ms budget, so filtering would buy
  /// nothing". On the real path this sweep is the budget's dominant consumer:
  /// the app's own trace across one ordinary session ran 36, 49, 54, 61, 77,
  /// 77 ms and then 114.7 ms, which exhausted the whole cumulative budget in
  /// this one step and tripped the circuit breaker (#1941). Every accessibility
  /// read in the same traces is under 0.5 ms. Do not restore the 3 ms figure and
  /// do not size anything against it.
  ///
  /// The veto no longer calls this; it calls ``liveTerminalSnapshot()``, which
  /// filters on a structural kernel fact rather than on launch shape. This entry
  /// point remains the honest general reader — it returns EVERY readable
  /// process, including the ones holding no terminal — and the live tests rely
  /// on exactly that.
  static func liveSnapshot() -> TerminalProcessScan {
    sweep(prefilterByTerminal: false)
  }

  /// Snapshot only the processes that hold a controlling terminal — the sweep
  /// the veto actually needs.
  ///
  /// Identical to ``liveSnapshot()`` except that it asks
  /// ``holdsControllingTerminal(_:)`` FIRST and reads the executable path and
  /// the argv/environment blob only for the survivors.
  ///
  /// **At one observation point this cannot change the veto's answer, and that
  /// is structural rather than lucky:** `supportedCLIs(in:hostedBy:)`'s own first
  /// guard is `guard snapshot.isAttachedToTerminal`, so every process dropped
  /// here would have been dropped one step later anyway. The predicate is not
  /// duplicated — both sites call this same function.
  ///
  /// **Exact TEMPORAL equivalence is not claimed**, because the change moves the
  /// observation earlier in the per-process sequence. See the note at the guard
  /// below for the window and why it is bounded.
  ///
  /// **Why it is worth a second entry point.** Measured on an 807-process
  /// machine with the shipped source compiled verbatim (artifacts in
  /// `docs/feature-requests/issue-1943-artifacts/`): only 24 processes (3.0%)
  /// hold a terminal, and the tty check is simultaneously the CHEAPEST
  /// per-process primitive and the most selective filter.
  ///
  /// | over all 807 pids | mean |
  /// |---|---|
  /// | `proc_pidinfo` (this check) | 0.35 ms |
  /// | `proc_pidpath` | 1.71 ms |
  /// | `sysctl KERN_PROCARGS2` | 5.58 ms |
  ///
  /// Whole sweep, interleaved A/B, n=100: 5.54 ms mean / 6.13 ms p95 unfiltered
  /// versus 0.86 ms / 0.94 ms filtered — 6.5x at both. An equivalence control
  /// over 300 comparisons found 0 mismatches with 100 positive findings.
  ///
  /// This is NOT the launch-shape guess that ``liveSnapshot()``'s note warns
  /// about: holding a controlling terminal is a fact read from the kernel about
  /// the process, not a prediction about how somebody installed it.
  static func liveTerminalSnapshot() -> TerminalProcessScan {
    sweep(prefilterByTerminal: true)
  }

  /// The one process-sweep both entry points run.
  ///
  /// Written as a single worker rather than two loops so the PID walk, the
  /// fail-closed skips, and the `.unavailable` contract cannot drift apart —
  /// the two entry points differ by exactly one boolean.
  ///
  /// Every kernel read is injected so the sweep is testable WITHOUT a real
  /// process table. That matters more than it looks: CI runs the Debug suite on
  /// a hosted runner where nothing holds a controlling terminal, so a test
  /// driven by live processes would SKIP there and the filter would have no
  /// regression gate at all.
  ///
  /// - Parameter prefilterByTerminal: when true, ask the cheap
  ///   controlling-terminal question first and read nothing else for processes
  ///   that fail it.
  static func sweep(
    prefilterByTerminal: Bool,
    pids: () -> [pid_t]? = { allProcessIdentifiers() },
    holdsTerminal: (pid_t) -> Bool = { holdsControllingTerminal($0) },
    path: (pid_t) -> String? = { executablePath(of: $0) },
    argumentsAndEnvironment: (pid_t) -> (arguments: [String], environment: [String: String])? = {
      Self.argumentsAndEnvironment(of: $0)
    }
  ) -> TerminalProcessScan {
    guard let identifiers = pids() else { return .unavailable }
    var snapshots: [TerminalProcessSnapshot] = []
    // Allocation hint only, never a limit — the array grows if it is wrong.
    // 32 is sized from the measured population (24 of 807 held a terminal on an
    // ordinary day); reserving all ~810 for the filtered sweep would allocate
    // 97% waste on every dictation.
    snapshots.reserveCapacity(prefilterByTerminal ? 32 : identifiers.count)
    for pid in identifiers {
      // The cheap, selective discriminator first, when the caller wants it. A
      // process that exits between this call and the reads below simply drops
      // out at one of them, exactly as in the unfiltered sweep; every primitive
      // fails closed.
      //
      // Honest limit, stated because it is real rather than because it matters:
      // this reads the tty flag BEFORE the argv/environment blob, where the
      // unfiltered sweep reads it after. A process that gained or lost its
      // controlling terminal in that microsecond window is classified at a
      // slightly different instant. That is not a NEW race — the unfiltered
      // sweep has the mirror of it — and neither instant is more correct. The
      // only process it can affect is one whose terminal is opening or closing
      // mid-sweep, and Gate 1 is a veto whose worst outcome is the already
      // accepted class: a wrong space or capital in one sentence, never a wrong
      // destination.
      var attached = true
      if prefilterByTerminal {
        guard holdsTerminal(pid) else { continue }
      } else {
        // Unfiltered: the flag is still reported, read in its original position
        // after the other two so this entry point's timing is unchanged.
        attached = false
      }
      guard let executablePath = path(pid) else { continue }
      // Reading another user's or root's process is refused by the kernel for
      // roughly a third of PIDs. That is expected and is not an error.
      guard let (arguments, environment) = argumentsAndEnvironment(pid) else { continue }
      snapshots.append(
        TerminalProcessSnapshot(
          processIdentifier: pid,
          executablePath: executablePath,
          arguments: arguments,
          termProgram: environment["TERM_PROGRAM"],
          // Filtered: true by construction, the guard above is the only way in.
          // Unfiltered: read here, exactly where it was read before.
          isAttachedToTerminal: attached ? true : holdsTerminal(pid)))
    }
    return .available(snapshots)
  }

  /// Whether `pid` holds a controlling terminal.
  ///
  /// Fails CLOSED: an unreadable process reports false, so it cannot license a
  /// read. Verified with a two-way control — the same `/bin/sleep` binary
  /// reports true under a terminal and false outside one, so nothing but the
  /// terminal explains the difference.
  static func holdsControllingTerminal(_ pid: pid_t) -> Bool {
    guard let info = bsdInfo(pid) else { return false }
    // NODEV, the "no controlling terminal" sentinel, is all-bits-set.
    return Int32(bitPattern: info.e_tdev) != -1
  }

  /// When `pid` started, in seconds since the epoch.
  ///
  /// Pairs with the PID to make a key that survives PID REUSE. macOS recycles
  /// PIDs, so a latch keyed on the number alone would keep punishing an
  /// unrelated process that happened to inherit it.
  package static func startTime(of pid: pid_t) -> UInt64? {
    guard let info = bsdInfo(pid) else { return nil }
    return UInt64(info.pbi_start_tvsec)
  }

  private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info
  }

  // MARK: Darwin plumbing

  private static func allProcessIdentifiers() -> [pid_t]? {
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return nil }
    // Head-room: the list can grow between sizing and reading.
    let capacity = Int(needed) / MemoryLayout<pid_t>.size + 64
    var buffer = [pid_t](repeating: 0, count: capacity)
    let written = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
      guard let base = pointer.baseAddress else { return 0 }
      return proc_listpids(
        UInt32(PROC_ALL_PIDS), 0, base, Int32(pointer.count * MemoryLayout<pid_t>.size))
    }
    guard written > 0 else { return nil }
    let count = min(Int(written) / MemoryLayout<pid_t>.size, capacity)
    return Array(buffer.prefix(count)).filter { $0 > 0 }
  }

  /// Read a process's executable path with a BOUNDED decode.
  ///
  /// `String(cString:)` would trust that the call wrote a terminator inside the
  /// buffer. That is normally guaranteed; decoding against the reported length
  /// costs nothing and removes the trust.
  private static func executablePath(of pid: pid_t) -> String? {
    // `PROC_PIDPATHINFO_MAXSIZE` is a C macro and is not imported into Swift;
    // it is defined as 4 * MAXPATHLEN, which is what this reproduces.
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let written = buffer.withUnsafeMutableBytes { bytes -> Int32 in
      guard let base = bytes.baseAddress else { return 0 }
      return proc_pidpath(pid, base, UInt32(bytes.count))
    }
    guard written > 0, Int(written) <= buffer.count else { return nil }
    let bytes = buffer[..<Int(written)].map { UInt8(bitPattern: $0) }
    guard let path = String(bytes: bytes, encoding: .utf8), !path.isEmpty else { return nil }
    return path
  }

  /// Read `KERN_PROCARGS2` and split it into arguments and environment.
  ///
  /// The kernel hands back a packed blob laid out as `argc`, the executable
  /// path, null padding, `argc` argument strings, then environment strings.
  /// Every step is bounds-checked against the returned size: this is another
  /// process's memory image, and a malformed or truncated blob must fail
  /// closed rather than read past the end.
  static func argumentsAndEnvironment(of pid: pid_t) -> (
    arguments: [String], environment: [String: String]
  )? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var raw = [UInt8](repeating: 0, count: size)
    let readOK = raw.withUnsafeMutableBufferPointer { pointer -> Bool in
      guard let base = pointer.baseAddress else { return false }
      return sysctl(&mib, 3, base, &size, nil, 0) == 0
    }
    guard readOK, size > 0, size <= raw.count else { return nil }
    return parseProcArgs(Array(raw.prefix(size)))
  }

  /// Pure blob parser, split out so the layout can be tested without a process.
  ///
  /// FAILS CLOSED on anything malformed, and that is the whole contract. An
  /// earlier version returned partial success for a truncated blob — a short
  /// argument list and an empty environment — which is the worst possible
  /// outcome here: an absent `TERM_PROGRAM` is indistinguishable from a genuine
  /// one, so a half-read process would be quietly mis-attributed rather than
  /// skipped. Grounded review caught that the tests had frozen the wrong
  /// behaviour.
  static func parseProcArgs(_ raw: [UInt8]) -> (
    arguments: [String], environment: [String: String]
  )? {
    let headerSize = MemoryLayout<Int32>.size
    guard raw.count > headerSize else { return nil }
    let argumentCount = raw.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    // argc of zero means the blob carries no argv at all, which no live process
    // produces; treat it as malformed rather than as an empty success.
    guard argumentCount > 0, argumentCount < 4096 else { return nil }

    var index = headerSize
    // The executable path must be present AND terminated.
    guard let executableEnd = raw[index...].firstIndex(of: 0), executableEnd > index else {
      return nil
    }
    index = executableEnd
    while index < raw.count, raw[index] == 0 { index += 1 }

    func nextString() -> String? {
      guard index < raw.count, let end = raw[index...].firstIndex(of: 0) else { return nil }
      guard let value = String(bytes: raw[index..<end], encoding: .utf8) else { return nil }
      index = end + 1
      return value
    }

    var arguments: [String] = []
    arguments.reserveCapacity(Int(argumentCount))
    for _ in 0..<Int(argumentCount) {
      guard let argument = nextString() else { return nil }
      arguments.append(argument)
    }

    // The environment runs to the end of the blob. Every entry must be a
    // terminated, decodable string; a trailing empty entry ends it early.
    var environment: [String: String] = [:]
    while index < raw.count {
      guard let entry = nextString() else { return nil }
      if entry.isEmpty { break }
      guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
        continue
      }
      environment[String(entry[entry.startIndex..<separator])] =
        String(entry[entry.index(after: separator)...])
    }
    return (arguments, environment)
  }
}
