import Darwin
import Foundation
import Testing

@testable import EnviousWisprServices

/// Gate 1's veto: which supported CLIs are running, and under which terminal.
///
/// Every decoy path below was CAPTURED from the founder's running machine on
/// 2026-07-28, not invented. A matcher tuned against imagined lookalikes proves
/// nothing about the real ones — `/Applications/ChatGPT.app/Contents/Resources/codex`
/// is a genuine executable literally named `codex`, and no amount of guessing
/// would have produced it.
@Suite("Terminal process scanner")
struct TerminalProcessScannerTests {

  private func snapshot(
    _ pid: pid_t, _ path: String, _ args: [String] = [], term: String?,
    terminal: Bool = true
  ) -> TerminalProcessSnapshot {
    TerminalProcessSnapshot(
      processIdentifier: pid, executablePath: path, arguments: args, termProgram: term,
      isAttachedToTerminal: terminal)
  }

  /// Captured live 2026-07-28 while all three tools were genuinely running.
  private let claudePath = "/Users/m4pro_sv/.local/share/claude/versions/2.1.220"
  private let nodePath = "/opt/homebrew/Cellar/node/26.4.0/bin/node"
  private let homebrewCodexPath = "/opt/homebrew/Caskroom/codex/0.144.1/bin/codex"

  // MARK: - Terminal surfaces

  @Test("Gate 0 admits exactly the three measured terminals")
  func surfaceMembership() {
    #expect(TerminalSurface(bundleIdentifier: "com.mitchellh.ghostty") == .ghostty)
    #expect(TerminalSurface(bundleIdentifier: "com.apple.Terminal") == .terminalApp)
    #expect(TerminalSurface(bundleIdentifier: "com.googlecode.iterm2") == .iTerm2)

    // Unmeasured terminals are excluded, NOT carried as harmless: admitting one
    // licenses reading its screen as a terminal grid.
    for excluded in [
      "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.warp.Warp",
      "com.apple.TextEdit", "com.microsoft.VSCode",
    ] {
      #expect(
        TerminalSurface(bundleIdentifier: excluded) == nil, "\(excluded) must not be admitted")
    }
  }

  @Test("TERM_PROGRAM values match what each terminal actually exports")
  func termProgramValues() {
    // Read out of the shipped binaries / observed live 2026-07-28.
    #expect(TerminalSurface.ghostty.termProgramValue == "ghostty")
    #expect(TerminalSurface.terminalApp.termProgramValue == "Apple_Terminal")
    #expect(TerminalSurface.iTerm2.termProgramValue == "iTerm.app")
  }

  // MARK: - Identity: the three tools as they actually run

  @Test("Claude Code's version-named executable is identified from argv[0]")
  func identifiesClaudeCode() {
    // Captured live: the executable is named after its VERSION, so argv[0] is
    // the only place the name appears.
    #expect(
      TerminalProcessScanner.identify(
        executablePath: claudePath, arguments: ["claude", "--resume"]) == .claudeCode)
  }

  @Test("Homebrew Codex is identified — the install-path matcher missed this one")
  func identifiesHomebrewCodex() {
    // THE case that changed the design (founder decision 2026-07-28). This
    // binary is installed on the founder's machine and the previous install-path
    // matcher walked straight past it, so terminal insertion would silently
    // never engage for anyone who installed Codex this way.
    #expect(
      TerminalProcessScanner.identify(
        executablePath: homebrewCodexPath, arguments: ["codex"]) == .codex)
  }

  @Test("npm-hosted Gemini and Codex are identified through their script runtime")
  func identifiesScriptHostedCLIs() {
    #expect(
      TerminalProcessScanner.identify(
        executablePath: nodePath,
        arguments: ["node", "/Users/m4pro_sv/.npm-global/bin/gemini"]) == .geminiCLI)
    #expect(
      TerminalProcessScanner.identify(
        executablePath: nodePath,
        arguments: ["node", "/Users/m4pro_sv/.npm-global/bin/codex"]) == .codex)
    // Invoked at the script itself rather than through the npm bin symlink.
    #expect(
      TerminalProcessScanner.identify(
        executablePath: nodePath,
        arguments: [
          "node", "/Users/x/lib/node_modules/@google/gemini-cli/bundle/gemini.js",
        ]) == .geminiCLI)
  }

  @Test("A file argument is only read as a program when a script runtime hosts it")
  func onlyScriptRuntimesHostTheirArgument() {
    // Editing a file that happens to be named `codex` must not read as Codex.
    #expect(
      TerminalProcessScanner.identify(
        executablePath: "/usr/bin/vim", arguments: ["vim", "/Users/x/notes/codex"]) == nil)
    #expect(
      TerminalProcessScanner.identify(
        executablePath: "/bin/cat", arguments: ["cat", "/Users/x/gemini"]) == nil)
  }

  @Test("A relative hosted argument is ignored")
  func ignoresRelativeHostedArgument() {
    // A relative path belongs to the CLI's own working directory, which is
    // deliberately never read.
    #expect(
      TerminalProcessScanner.identify(
        executablePath: nodePath, arguments: ["node", "./bin/codex"]) == nil)
  }

  @Test("A flag argument is not a program name")
  func ignoresFlagArguments() {
    #expect(
      TerminalProcessScanner.identify(
        executablePath: "/usr/bin/true", arguments: ["true", "--resume"]) == nil)
  }

  // MARK: - Identity: the real negatives

  /// Captured 2026-07-28. A name-substring matcher fires on every one of these,
  /// and every one is a GUI process holding NO controlling terminal — which is
  /// why the terminal precondition closes the class structurally.
  static let capturedDecoys: [String] = [
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/ChatGPT.app/Contents/Resources/codex_chronicle",
    "/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host",
    "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150.0.7871.128/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)",
    "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150.0.7871.128/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)",
    "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150.0.7871.128/Helpers/browser_crashpad_handler",
    "/Users/m4pro_sv/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService",
    "/Users/m4pro_sv/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome",
    "/Users/m4pro_sv/.claude/mcp-servers/envious-canvas/.venv/bin/python3",
  ]

  @Test(
    "Every captured GUI lookalike is refused by the terminal precondition",
    arguments: capturedDecoys)
  func terminalPreconditionRefusesGUILookalikes(path: String) {
    // These run with no controlling terminal, exactly as measured.
    let found = TerminalProcessScanner.supportedCLIs(
      in: [snapshot(1, path, [path], term: "ghostty", terminal: false)],
      hostedBy: .ghostty)
    #expect(found.isEmpty, "\(path) must not license a terminal read")
  }

  @Test("The ChatGPT binary literally named codex is refused")
  func refusesChatGPTCodexBinary() {
    // The hardest single decoy: a real executable named `codex`. It is a GUI
    // helper, so it holds no terminal.
    let path = "/Applications/ChatGPT.app/Contents/Resources/codex"
    #expect(
      TerminalProcessScanner.supportedCLIs(
        in: [snapshot(1, path, ["codex", "exec", "--json"], term: "ghostty", terminal: false)],
        hostedBy: .ghostty
      ).isEmpty)
  }

  // MARK: - The veto

  @Test("No supported CLI under the terminal app means the veto fires")
  func vetoFiresWhenNothingSupportedRuns() {
    let snapshots = [
      snapshot(1, "/bin/zsh", ["zsh"], term: "ghostty"),
      snapshot(2, "/usr/bin/vim", ["vim", "notes.txt"], term: "ghostty"),
      snapshot(
        3, "/Applications/ChatGPT.app/Contents/Resources/codex", ["codex"],
        term: "ghostty", terminal: false),
    ]
    #expect(
      TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: .ghostty).isEmpty,
      "this is the configuration that closes the vim/less spoof")
  }

  @Test("A terminal-attached supported CLI passes the veto")
  func vetoPassesWithOneCLI() {
    #expect(
      TerminalProcessScanner.supportedCLIs(
        in: [snapshot(1, claudePath, ["claude"], term: "ghostty")],
        hostedBy: .ghostty) == [RunningTerminalCLI(processIdentifier: 1, cli: .claudeCode)])
  }

  @Test("A CLI with no controlling terminal never passes the veto")
  func vetoRefusesDetachedCLI() {
    // Same process, same name, same TERM_PROGRAM — only the terminal differs.
    // This is the two-way control for the precondition.
    #expect(
      TerminalProcessScanner.supportedCLIs(
        in: [snapshot(1, claudePath, ["claude"], term: "ghostty", terminal: false)],
        hostedBy: .ghostty
      ).isEmpty)
    #expect(
      TerminalProcessScanner.supportedCLIs(
        in: [snapshot(1, claudePath, ["claude"], term: "ghostty", terminal: true)],
        hostedBy: .ghostty
      ).count == 1)
  }

  @Test("Several supported CLIs pass — multi-tab is the normal case")
  func vetoPassesWithSeveralCLIs() {
    // The founder runs five tabs in one project. The superseded strict design
    // REFUSED here; refusing again would silently break his everyday setup.
    let snapshots = (1...5).map { snapshot(pid_t($0), claudePath, ["claude"], term: "ghostty") }
    #expect(TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: .ghostty).count == 5)
  }

  @Test("A CLI in a different terminal does not license a read in this one")
  func vetoIsScopedToTheFocusedTerminal() {
    let snapshots = [
      snapshot(1, claudePath, ["claude"], term: "iTerm.app"),
      snapshot(2, claudePath, ["claude"], term: "Apple_Terminal"),
    ]
    #expect(TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: .ghostty).isEmpty)
    #expect(
      TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: .iTerm2)
        .map(\.processIdentifier) == [1])
  }

  @Test("A CLI reporting no TERM_PROGRAM is attributed to no terminal")
  func unattributedCLIDoesNotPassTheVeto() {
    #expect(
      TerminalProcessScanner.supportedCLIs(
        in: [snapshot(1, claudePath, ["claude"], term: nil)], hostedBy: .ghostty
      ).isEmpty)
  }

  // MARK: - Blob parsing

  /// Build a `KERN_PROCARGS2` blob the way the kernel lays one out.
  private func procArgsBlob(
    execPath: String, arguments: [String], environment: [String], padding: Int = 3
  ) -> [UInt8] {
    var blob = [UInt8]()
    withUnsafeBytes(of: Int32(arguments.count).littleEndian) { blob.append(contentsOf: $0) }
    blob.append(contentsOf: Array(execPath.utf8))
    blob.append(contentsOf: [UInt8](repeating: 0, count: padding))
    for value in arguments + environment {
      blob.append(contentsOf: Array(value.utf8))
      blob.append(0)
    }
    blob.append(0)
    return blob
  }

  @Test("A well-formed blob yields its arguments and environment")
  func parsesWellFormedBlob() throws {
    let blob = procArgsBlob(
      execPath: "/opt/homebrew/bin/node",
      arguments: ["node", "/Users/x/.npm-global/bin/gemini"],
      environment: ["TERM_PROGRAM=ghostty", "PATH=/usr/bin", "LANG=en_US.UTF-8"])
    let parsed = try #require(TerminalProcessScanner.parseProcArgs(blob))
    #expect(parsed.arguments == ["node", "/Users/x/.npm-global/bin/gemini"])
    #expect(parsed.environment["TERM_PROGRAM"] == "ghostty")
    #expect(parsed.environment["LANG"] == "en_US.UTF-8")
  }

  @Test("An environment value containing '=' keeps its whole value")
  func parsesEnvironmentValueWithEquals() throws {
    let blob = procArgsBlob(
      execPath: "/bin/zsh", arguments: ["zsh"],
      environment: ["TERM_PROGRAM=ghostty", "OPTS=a=b=c"])
    let parsed = try #require(TerminalProcessScanner.parseProcArgs(blob))
    #expect(parsed.environment["OPTS"] == "a=b=c")
  }

  @Test("A truncated or malformed blob fails closed rather than reading past the end")
  func malformedBlobFailsClosed() {
    #expect(TerminalProcessScanner.parseProcArgs([]) == nil)
    #expect(TerminalProcessScanner.parseProcArgs([1, 2]) == nil)

    // Negative and absurd argument counts are hostile input from another
    // process's memory image.
    var negative = [UInt8]()
    withUnsafeBytes(of: Int32(-1).littleEndian) { negative.append(contentsOf: $0) }
    negative.append(contentsOf: Array("/bin/zsh".utf8) + [0])
    #expect(TerminalProcessScanner.parseProcArgs(negative) == nil)

    var absurd = [UInt8]()
    withUnsafeBytes(of: Int32(100_000).littleEndian) { absurd.append(contentsOf: $0) }
    absurd.append(contentsOf: Array("/bin/zsh".utf8) + [0])
    #expect(TerminalProcessScanner.parseProcArgs(absurd) == nil)
  }

  @Test("A blob claiming more arguments than it contains fails closed")
  func blobWithOverstatedArgumentCountFailsClosed() {
    // This test previously asserted PARTIAL SUCCESS, which froze the wrong
    // behaviour: a half-read process reports no TERM_PROGRAM, and "absent" is
    // indistinguishable from "genuinely unset", so it would be mis-attributed
    // rather than skipped. Grounded review caught the test, not just the code.
    var blob = [UInt8]()
    withUnsafeBytes(of: Int32(9).littleEndian) { blob.append(contentsOf: $0) }
    blob.append(contentsOf: Array("/bin/zsh".utf8))
    blob.append(contentsOf: [0, 0])
    blob.append(contentsOf: Array("zsh".utf8) + [0])
    #expect(TerminalProcessScanner.parseProcArgs(blob) == nil)
  }

  @Test("Unterminated executable, argument and environment strings fail closed")
  func unterminatedStringsFailClosed() {
    var header = [UInt8]()
    withUnsafeBytes(of: Int32(1).littleEndian) { header.append(contentsOf: $0) }

    // Executable path never terminated.
    #expect(TerminalProcessScanner.parseProcArgs(header + Array("/bin/zsh".utf8)) == nil)

    // Argument never terminated.
    #expect(
      TerminalProcessScanner.parseProcArgs(
        header + Array("/bin/zsh".utf8) + [0, 0] + Array("zsh".utf8)) == nil)

    // Environment entry never terminated.
    #expect(
      TerminalProcessScanner.parseProcArgs(
        header + Array("/bin/zsh".utf8) + [0, 0] + Array("zsh".utf8) + [0]
          + Array("TERM_PROGRAM=ghostty".utf8)) == nil)
  }

  @Test("An argument count of zero is malformed, not an empty success")
  func zeroArgumentCountFailsClosed() {
    var blob = [UInt8]()
    withUnsafeBytes(of: Int32(0).littleEndian) { blob.append(contentsOf: $0) }
    blob.append(contentsOf: Array("/bin/zsh".utf8) + [0, 0])
    #expect(TerminalProcessScanner.parseProcArgs(blob) == nil)
  }

  @Test("Invalid UTF-8 in the blob fails closed")
  func invalidUTF8FailsClosed() {
    var blob = [UInt8]()
    withUnsafeBytes(of: Int32(1).littleEndian) { blob.append(contentsOf: $0) }
    blob.append(contentsOf: Array("/bin/zsh".utf8) + [0, 0])
    blob.append(contentsOf: [0xFF, 0xFE, 0xFD] + [0])
    #expect(TerminalProcessScanner.parseProcArgs(blob) == nil)
  }

  // MARK: - Live capture, positive control

  @Test("An unreadable process list is a different result from an empty one")
  func scanResultDistinguishesUnavailableFromEmpty() {
    // `?? []` at the one call site that matters would erase this. The type is
    // what stops it.
    #expect(TerminalProcessScan.unavailable != TerminalProcessScan.available([]))
  }

  @Test("The live scanner sees this very process")
  func liveScannerSeesSelf() throws {
    // Without a positive control, an empty result and a broken scanner are
    // indistinguishable — and a veto reading "nothing is running" fails the
    // feature silently rather than loudly.
    guard case .available(let snapshots) = TerminalProcessScanner.liveSnapshot() else {
      Issue.record("process enumeration was unavailable")
      return
    }
    #expect(snapshots.count > 20, "process enumeration returned implausibly few processes")

    let me = getpid()
    let mine = try #require(
      snapshots.first { $0.processIdentifier == me },
      "the scanner must be able to see its own process")
    #expect(!mine.executablePath.isEmpty)
    #expect(!mine.arguments.isEmpty)
  }

  @Test("Live argument and environment reads work against this process")
  func liveArgumentsAndEnvironmentForSelf() throws {
    let parsed = try #require(TerminalProcessScanner.argumentsAndEnvironment(of: getpid()))
    #expect(!parsed.arguments.isEmpty)
    // PATH is set for any process the test runner can spawn.
    #expect(parsed.environment["PATH"] != nil)
  }

  @Test("The terminal flag is computed, not stuck, and fails closed on a dead PID")
  func terminalFlagIsComputedAndFailsClosed() {
    // ENVIRONMENT-INDEPENDENT by design. An earlier version asserted that live
    // data contained BOTH tty-attached and detached processes; that passes on a
    // developer Mac and FAILS on a headless CI runner, where nothing holds a
    // controlling terminal. The assertion was about the machine, not the code.
    //
    // What is actually deterministic: a PID that cannot exist must report false
    // (fails closed), and every machine has detached processes. The positive
    // direction is proven where it belongs — `vetoRefusesDetachedCLI` drives the
    // same snapshot through with the flag true and false and asserts opposite
    // outcomes.
    #expect(!TerminalProcessScanner.holdsControllingTerminal(pid_t(Int32.max)))

    guard case .available(let snapshots) = TerminalProcessScanner.liveSnapshot() else {
      Issue.record("process enumeration was unavailable")
      return
    }
    #expect(snapshots.contains { !$0.isAttachedToTerminal })
  }

  @Test("The strict parser still accepts real kernel blobs at scale")
  func strictParserDoesNotRejectRealProcesses() {
    // The parser was tightened to fail closed on malformed input. A tightening
    // that also rejected HONEST blobs would disable the veto everywhere while
    // every unit test stayed green, because the unit fixtures are hand-built.
    //
    // Counts only what exists on EVERY machine: a process list, and successfully
    // parsed arguments. It deliberately does NOT count `TERM_PROGRAM`, which is
    // absent on a headless runner and made an earlier version of this test
    // machine-dependent.
    guard case .available(let snapshots) = TerminalProcessScanner.liveSnapshot() else {
      Issue.record("process enumeration was unavailable")
      return
    }
    let withArguments = snapshots.filter { !$0.arguments.isEmpty }.count
    #expect(
      snapshots.count > 20,
      "only \(snapshots.count) processes parsed — the strict parser is rejecting real blobs")
    #expect(
      withArguments > 10,
      "only \(withArguments) processes yielded arguments — argument parsing regressed")
  }

  // MARK: - Filtered sweep (#1943)

  /// Whether this machine has any process holding a controlling terminal.
  ///
  /// A hosted CI runner generally has none, and a live control that cannot
  /// possibly find one would pass VACUOUSLY rather than prove anything. Gating
  /// makes it SKIP there and RUN here, instead of reporting a green that carries
  /// no information.
  static func machineHasATerminalProcess() -> Bool {
    guard case .available(let snapshots) = TerminalProcessScanner.liveTerminalSnapshot() else {
      return false
    }
    return snapshots.isEmpty == false
  }

  @Test("Pre-filtering by the terminal flag cannot change the veto's answer")
  func filteringByTerminalFlagCannotChangeTheVeto() {
    // The whole #1943 change rests on this one claim, so it is frozen against a
    // FIXTURE rather than against live data: deterministic, and non-vacuous
    // because the list deliberately contains both a real CLI that would be kept
    // and decoys that must be dropped either way.
    let snapshots = [
      // Claude Code's executable is named after its VERSION, so `argv[0]` is the
      // only place its name appears — a fixture without it silently identifies
      // nothing, which is what the two-way control at the end of this test
      // caught when it was missing.
      snapshot(101, claudePath, ["claude"], term: "ghostty"),
      snapshot(102, homebrewCodexPath, term: "ghostty"),
      // Detached lookalikes — dropped by the veto today, and dropped earlier by
      // the filtered sweep. Both routes must agree.
      snapshot(
        201, "/Applications/ChatGPT.app/Contents/Resources/codex", term: "ghostty",
        terminal: false),
      // Carries `argv[0]` too, so it WOULD identify as Claude Code but for the
      // terminal flag — a decoy the flag alone rejects, which is the point.
      snapshot(202, claudePath, ["claude"], term: "ghostty", terminal: false),
      // A terminal-holding process that is not a supported CLI at all.
      snapshot(203, "/bin/zsh", term: "ghostty"),
    ]
    let preFiltered = snapshots.filter(\.isAttachedToTerminal)
    #expect(
      preFiltered.count == 3, "fixture must exercise the filter, not sit entirely on one side")

    for surface in TerminalSurface.allCases {
      let unfiltered = TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: surface)
      let filtered = TerminalProcessScanner.supportedCLIs(in: preFiltered, hostedBy: surface)
      #expect(unfiltered == filtered, "veto disagreed for \(surface)")
    }
    // Two-way control: the fixture actually produces a positive, so an
    // implementation returning nothing everywhere could not pass this.
    #expect(TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: .ghostty).count == 2)
  }

  @Test("The filter skips the expensive reads entirely for a detached process")
  func filteredSweepDoesNotReadDetachedProcesses() {
    // THE CI REGRESSION GATE. Every other test of this filter needs a real
    // process holding a controlling terminal, which a hosted runner does not
    // have — they SKIP there, or pass vacuously on an empty result. This one
    // injects the process table, so it runs everywhere and actually asserts the
    // saving the whole change exists for: the expensive reads are never even
    // attempted for a detached PID.
    var pathReads: [pid_t] = []
    var blobReads: [pid_t] = []

    let scan = TerminalProcessScanner.sweep(
      prefilterByTerminal: true,
      pids: { [101, 202] },
      holdsTerminal: { $0 == 202 },
      path: {
        pathReads.append($0)
        return "/opt/homebrew/bin/codex"
      },
      argumentsAndEnvironment: {
        blobReads.append($0)
        return (["codex"], ["TERM_PROGRAM": "ghostty"])
      })

    #expect(pathReads == [202], "executable path was read for a detached process")
    #expect(blobReads == [202], "the argv/environment blob was read for a detached process")

    guard case .available(let snapshots) = scan else {
      Issue.record("expected .available")
      return
    }
    #expect(snapshots.map(\.processIdentifier) == [202])
    #expect(snapshots.first?.isAttachedToTerminal == true)
  }

  @Test("Without the prefilter the same sweep reads every process — the two-way control")
  func unfilteredSweepReadsEveryProcess() {
    // Mutation control for the test above: identical injection, prefilter off.
    // If the guard stopped doing the filtering, the two tests would agree and
    // this pair would no longer discriminate.
    var pathReads: [pid_t] = []

    let scan = TerminalProcessScanner.sweep(
      prefilterByTerminal: false,
      pids: { [101, 202] },
      holdsTerminal: { $0 == 202 },
      path: {
        pathReads.append($0)
        return "/opt/homebrew/bin/codex"
      },
      argumentsAndEnvironment: { _ in (["codex"], ["TERM_PROGRAM": "ghostty"]) })

    #expect(pathReads == [101, 202], "the unfiltered sweep must still read every process")

    guard case .available(let snapshots) = scan else {
      Issue.record("expected .available")
      return
    }
    // And it still reports the flag truthfully rather than hard-coding it.
    #expect(snapshots.map(\.processIdentifier) == [101, 202])
    #expect(snapshots.first(where: { $0.processIdentifier == 101 })?.isAttachedToTerminal == false)
    #expect(snapshots.first(where: { $0.processIdentifier == 202 })?.isAttachedToTerminal == true)
  }

  @Test("An unreadable PID list is .unavailable in both sweep modes")
  func sweepPreservesUnavailable() {
    // `.unavailable` must not collapse into `.available([])` — the distinction
    // the typed result exists to protect, now checked for the new entry point.
    for prefilter in [true, false] {
      let scan = TerminalProcessScanner.sweep(
        prefilterByTerminal: prefilter,
        pids: { nil },
        holdsTerminal: { _ in true },
        path: { _ in "/bin/zsh" },
        argumentsAndEnvironment: { _ in ([], [:]) })
      #expect(scan == .unavailable, "prefilter=\(prefilter) lost the unavailable distinction")
    }
  }

  @Test("The filtered sweep returns only processes holding a controlling terminal")
  func filteredSweepReportsOnlyTerminalHolders() {
    guard case .available(let snapshots) = TerminalProcessScanner.liveTerminalSnapshot() else {
      Issue.record("process enumeration was unavailable")
      return
    }
    // Environment-independent: true on a runner that finds none, and the
    // contract that lets `isAttachedToTerminal: true` be hard-coded in the sweep.
    // Counted outside the macro because `allSatisfy` is `rethrows`, which
    // `#expect` cannot prove non-throwing; counts also name the offender.
    let detached = snapshots.filter { $0.isAttachedToTerminal == false }.count
    let pathless = snapshots.filter { $0.executablePath.isEmpty }.count
    #expect(detached == 0, "\(detached) of \(snapshots.count) filtered snapshots hold no terminal")
    #expect(pathless == 0, "\(pathless) of \(snapshots.count) filtered snapshots have no path")
  }

  @Test(
    "The filtered sweep still finds a CLI the unfiltered sweep finds",
    .enabled(if: machineHasATerminalProcess()))
  func filteredSweepFindsWhatTheFullSweepFinds() {
    // The fixture test above proves the PREDICATE is veto-neutral. This proves
    // the SWEEP implements that predicate and nothing more — a filter that
    // dropped too much would pass the fixture test and fail here.
    guard case .available(let full) = TerminalProcessScanner.liveSnapshot(),
      case .available(let filtered) = TerminalProcessScanner.liveTerminalSnapshot()
    else {
      Issue.record("process enumeration was unavailable")
      return
    }

    // Compared per surface on the VETO's answer rather than on raw process sets,
    // because the two sweeps are taken microseconds apart and an unrelated
    // process starting or exiting between them is not a defect. A supported CLI
    // is long-lived, so its membership does not turn over in that window.
    for surface in TerminalSurface.allCases {
      let fromFull = Set(
        TerminalProcessScanner.supportedCLIs(in: full, hostedBy: surface)
          .map(\.processIdentifier))
      let fromFiltered = Set(
        TerminalProcessScanner.supportedCLIs(in: filtered, hostedBy: surface)
          .map(\.processIdentifier))
      #expect(
        fromFull == fromFiltered,
        "\(surface): unfiltered found \(fromFull.sorted()), filtered found \(fromFiltered.sorted())"
      )
    }

    // The filtered sweep must be a genuine reduction, or it is not the fix.
    #expect(filtered.count <= full.count)
  }

}
