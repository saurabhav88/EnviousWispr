// XcodeBuildTopologyFreezeTests — locks the #913 Xcode/Tuist build-engine
// topology so a future change can't silently regress it back toward SwiftPM.
// Scans real repo files and fails on actual offenders (never a tautology).
// Repo-root is resolved from #filePath so it works under both `swift test`
// (CWD=repo root) and `xcodebuild test` (CWD=/).

import Foundation
import Testing

@Suite struct XcodeBuildTopologyFreezeTests {
  enum Invariant: String, CaseIterable, CustomStringConvertible {
    case tuistManifestsPresent
    case generatedProjectIgnored
    case canonicalScriptsPresent
    case legacyScriptsDeleted
    case arm64OnlyBuildSettings
    case buildCheckContextName
    case postProcessingResourceAccessor
    case devBuildKillIsWorktreeScoped

    var description: String { rawValue }
  }

  @Test("Xcode build topology invariant", arguments: Invariant.allCases)
  func xcodeBuildTopologyInvariant(_ invariant: Invariant) throws {
    let failures = try Self.failures(for: invariant)
    #expect(
      failures.isEmpty,
      """
      Xcode build topology invariant failed: \(invariant)
      \(failures.joined(separator: "\n"))
      """)
  }

  private static func failures(for invariant: Invariant) throws -> [String] {
    switch invariant {
    case .tuistManifestsPresent:
      // Committed Tuist manifests drive CLI generation; no committed project files.
      return [
        requiredFile("Project.swift"),
        requiredFile("Tuist.swift"),
        requiredFile("Package.swift"),
      ].compactMap { $0 }

    case .generatedProjectIgnored:
      let gi = try read(".gitignore")
      return [
        requireContains(gi, "*.xcodeproj/", ".gitignore must ignore the generated Xcode project"),
        requireContains(
          gi, "*.xcworkspace", ".gitignore must ignore the generated Xcode workspace"),
        requireNoContains(gi, "!*.xcodeproj", ".gitignore must not re-allow the generated project"),
        requireNoContains(
          gi, "!*.xcworkspace", ".gitignore must not re-allow the generated workspace"),
      ].compactMap { $0 }

    case .canonicalScriptsPresent:
      // The three Xcode-engine entry points (#913): dev bundle, release DMG, tests.
      return [
        requiredFile("scripts/build-dev-app.sh"),
        requiredFile("scripts/build-release-dmg.sh"),
        requiredFile("scripts/xcode-test.sh"),
      ].compactMap { $0 }

    case .legacyScriptsDeleted:
      // The retired SwiftPM-era scripts must stay gone.
      return [
        forbiddenFile("scripts/build-dmg.sh"),
        forbiddenFile("scripts/bundle-dev.sh"),
        forbiddenFile("scripts/swift-test.sh"),
      ].compactMap { $0 }

    case .arm64OnlyBuildSettings:
      let project = try read("Project.swift")
      var failures = [
        requireContains(project, "ARCHS", "Project.swift must set ARCHS"),
        requireContains(project, "VALID_ARCHS", "Project.swift must set VALID_ARCHS"),
        requireContains(project, "ONLY_ACTIVE_ARCH", "Project.swift must set ONLY_ACTIVE_ARCH"),
        requireContains(project, "arm64", "Project.swift must enforce arm64"),
        requireNoContains(project, "x86_64", "Project.swift must not opt into x86_64"),
      ].compactMap { $0 }
      // Every direct xcodebuild build/test/archive invocation must pin arm64.
      // release.yml is intentionally excluded: it only runs `xcodebuild -version`
      // and delegates the archive to scripts/build-release-dmg.sh (checked here,
      // and where the release arm64 flags actually live).
      for path in [
        "scripts/build-dev-app.sh",
        "scripts/build-release-dmg.sh",
        "scripts/xcode-test.sh",
        ".github/workflows/pr-check.yml",
        ".github/workflows/cache-warm.yml",
      ] {
        failures.append(contentsOf: try arm64InvocationFailures(path: path))
      }
      // #3729: the CI Release build-for-testing lives in one script that the PR
      // gate and the main cache warm both run. Only its one `xcodebuild
      // build-for-testing` command counts: the script's self-test spells the
      // same flags as expected arguments, and those must not stand in for the
      // real ones. No command, or two, fails, so deleting it cannot read as
      // "nothing to check". Each caller must RUN it: a line that starts with
      // the script path, so a `paths:` filter entry naming it does not count.
      let sharedRelease = "scripts/ci/build-for-testing-release.sh"
      let commands = xcodebuildCommands(
        verb: "build-for-testing", in: executableText(try read(sharedRelease)))
      if commands.count == 1 {
        failures.append(contentsOf: arm64FlagFailures(commands[0], path: sharedRelease))
      } else {
        failures.append(
          "\(sharedRelease) must hold exactly one xcodebuild build-for-testing command, found \(commands.count)"
        )
      }
      for caller in [".github/workflows/pr-check.yml", ".github/workflows/cache-warm.yml"] {
        let runsIt = executableText(try read(caller)).split(separator: "\n").contains {
          $0.split(whereSeparator: \.isWhitespace).first == Substring(sharedRelease)
        }
        if !runsIt {
          failures.append("\(caller) must build for testing by running \(sharedRelease)")
        }
      }
      return failures

    case .buildCheckContextName:
      let wf = try read(".github/workflows/pr-check.yml")
      return [
        requireContains(
          wf, "\n  build-check:", "Required PR gate job id must remain exactly build-check"),
        requireContains(wf, "needs:", "build-check must remain an aggregator over the build lanes"),
      ].compactMap { $0 }

    case .postProcessingResourceAccessor:
      // The reason for the whole migration: SwiftPM-resource Bundle.module must
      // resolve in the signed .app, so the PostProcessing package + processed
      // resources + the bundle-URL accessor must all stay intact.
      let pkg = try read("Package.swift")
      let emoji = try read("Sources/EnviousWisprPostProcessing/EmojiFormatter.swift")
      let project = try read("Project.swift")
      return [
        requireContains(
          pkg, #"name: "EnviousWisprPostProcessing""#,
          "Package.swift must keep the PostProcessing target"),
        requireContains(
          pkg, #".process("Resources")"#,
          "Package.swift must keep PostProcessing resources processed"),
        requiredFile("Sources/EnviousWisprPostProcessing/Resources/emoji-dictionary.json"),
        requireContains(
          emoji, "Bundle.module",
          "EmojiFormatter must load through the Bundle.module resource accessor"),
        requireContains(
          project, "EnviousWisprPostProcessing",
          "Project.swift must include the PostProcessing module"),
      ].compactMap { $0 }

    case .devBuildKillIsWorktreeScoped:
      // The dev build script must stop ONLY this worktree's app by executable
      // path — never a global `pkill -x EnviousWispr` and never a shared
      // `.dev` bundle-id quit (both hit sibling worktrees / the live app).
      let dev = try read("scripts/build-dev-app.sh")
      return [
        requireNoContains(
          dev, "pkill -9 -x \"EnviousWispr\"", "dev build must not pkill by global process name"),
        requireNoContains(
          dev, "pkill -x \"EnviousWispr\"", "dev build must not pkill by global process name"),
        requireNoContains(
          dev, #"tell application id "com.enviouswispr.app.dev" to quit"#,
          "dev build must not quit by the shared .dev bundle id"),
        requireContains(
          dev, "pgrep -f",
          "dev build must scope process matching to this worktree's executable path"),
      ].compactMap { $0 }
    }
  }

  private static func arm64InvocationFailures(path: String) throws -> [String] {
    let code = executableText(try read(path))
    guard code.contains("xcodebuild") else { return [] }
    return arm64FlagFailures(code, path: path)
  }

  private static func arm64FlagFailures(_ code: String, path: String) -> [String] {
    // Whole tokens, so `VALID_ARCHS=arm64` cannot stand in for `ARCHS=arm64`.
    let tokens = Set(code.split(whereSeparator: \.isWhitespace).map(String.init))
    return [
      tokens.contains("ARCHS=arm64") ? nil : "\(path) must pass ARCHS=arm64 to xcodebuild",
      tokens.contains("VALID_ARCHS=arm64")
        ? nil : "\(path) must pass VALID_ARCHS=arm64 to xcodebuild",
      tokens.contains { $0.hasPrefix("ONLY_ACTIVE_ARCH=") }
        ? nil : "\(path) must pass ONLY_ACTIVE_ARCH on xcodebuild invocations",
    ].compactMap { $0 }
  }

  /// Each shell command that runs `xcodebuild <verb>`: the line holding those
  /// two tokens plus every `\`-continued line after it.
  private static func xcodebuildCommands(verb: String, in code: String) -> [String] {
    let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var commands: [String] = []
    var index = 0
    while index < lines.count {
      let tokens = lines[index].split(whereSeparator: \.isWhitespace).map(String.init)
      let starts = zip(tokens, tokens.dropFirst()).contains { $0 == "xcodebuild" && $1 == verb }
      guard starts else {
        index += 1
        continue
      }
      var command = [lines[index]]
      while command.last?.hasSuffix("\\") == true, index + 1 < lines.count {
        index += 1
        command.append(lines[index])
      }
      commands.append(command.joined(separator: "\n"))
      index += 1
    }
    return commands
  }

  /// The source with shell/YAML comments removed: a whole `#` line, and the
  /// rest of a line from a `#` that starts a word. A comment that mentions a
  /// flag cannot satisfy the check for it.
  private static func executableText(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
      var previous: Character = " "
      for index in line.indices {
        if line[index] == "#", previous.isWhitespace { return line[..<index] }
        previous = line[index]
      }
      return line
    }.joined(separator: "\n")
  }

  private static func requiredFile(_ path: String) -> String? {
    FileManager.default.fileExists(atPath: RepoRoot.url.appendingPathComponent(path).path)
      ? nil : "Missing required file: \(path)"
  }

  private static func forbiddenFile(_ path: String) -> String? {
    FileManager.default.fileExists(atPath: RepoRoot.url.appendingPathComponent(path).path)
      ? "Legacy file must stay deleted: \(path)" : nil
  }

  private static func read(_ path: String) throws -> String {
    try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
  }

  private static func requireContains(_ source: String, _ needle: String, _ message: String)
    -> String?
  {
    source.contains(needle) ? nil : message
  }

  private static func requireNoContains(_ source: String, _ needle: String, _ message: String)
    -> String?
  {
    source.contains(needle) ? message : nil
  }
}
