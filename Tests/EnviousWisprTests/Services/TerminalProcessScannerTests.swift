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

  @Test("The terminal flag discriminates on live data, rather than being stuck")
  func terminalFlagDiscriminatesLive() {
    // A flag hard-stuck at false disables the feature everywhere; stuck at true
    // removes the precondition that makes name matching safe. Either failure
    // leaves every hand-built unit fixture green, so assert BOTH values appear
    // in real data. Measured baseline 2026-07-28: 63 attached of 732.
    guard case .available(let snapshots) = TerminalProcessScanner.liveSnapshot() else {
      Issue.record("process enumeration was unavailable")
      return
    }
    let attached = snapshots.filter(\.isAttachedToTerminal).count
    let detached = snapshots.count - attached
    #expect(attached > 0, "no process reported a controlling terminal — the flag is stuck false")
    #expect(detached > 0, "every process reported a terminal — the flag is stuck true")
  }

  @Test("The strict parser still accepts real kernel blobs at scale")
  func strictParserDoesNotRejectRealProcesses() throws {
    // The parser was tightened to fail closed on malformed input. A tightening
    // that also rejects HONEST blobs would disable the veto everywhere while
    // every unit test stayed green, because the unit fixtures are hand-built.
    // Measured baseline 2026-07-28: 705 of 710 paths and 456 environments read.
    // Assert the real distribution, not a single self-read.
    guard case .available(let snapshots) = TerminalProcessScanner.liveSnapshot() else {
      Issue.record("process enumeration was unavailable")
      return
    }
    let withEnvironment = snapshots.filter { $0.termProgram != nil }.count
    #expect(
      snapshots.count > 100,
      "only \(snapshots.count) processes parsed — the strict parser is rejecting real blobs")
    #expect(
      withEnvironment > 5,
      "only \(withEnvironment) processes exposed TERM_PROGRAM — environment parsing regressed")
  }
}
