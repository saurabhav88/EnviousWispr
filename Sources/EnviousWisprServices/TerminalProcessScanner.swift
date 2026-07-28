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
  /// No pre-filter by executable name. Measured cost for the whole sweep is
  /// mean 3 ms / p95 7 ms against a 100 ms budget (710 processes, hardened
  /// runtime, Developer-ID signed), so filtering would buy nothing while adding
  /// a hand-authored guess about how CLIs are launched — the guess that would
  /// silently drop an unusual install.
  static func liveSnapshot() -> TerminalProcessScan {
    guard let pids = allProcessIdentifiers() else { return .unavailable }
    var snapshots: [TerminalProcessSnapshot] = []
    snapshots.reserveCapacity(pids.count)
    for pid in pids {
      guard let path = executablePath(of: pid) else { continue }
      // Reading another user's or root's process is refused by the kernel for
      // roughly a third of PIDs. That is expected and is not an error.
      guard let (arguments, environment) = argumentsAndEnvironment(of: pid) else { continue }
      snapshots.append(
        TerminalProcessSnapshot(
          processIdentifier: pid,
          executablePath: path,
          arguments: arguments,
          termProgram: environment["TERM_PROGRAM"],
          isAttachedToTerminal: holdsControllingTerminal(pid)))
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
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    // NODEV, the "no controlling terminal" sentinel, is all-bits-set.
    return Int32(bitPattern: info.e_tdev) != -1
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
