import Foundation
import Testing

@testable import EnviousWispr

/// #2772 chunk 1 — source-spelling tripwires for the provider setup extraction.
///
/// These checks detect the listed markers appearing in another readable Swift source
/// file. They do NOT prove unique editor ownership: renamed implementations, receiver
/// aliases, duplicate implementations inside `ProviderSetup.swift` itself, and unreadable
/// files can all escape detection. The subject check detects a missing expected file, not
/// an incomplete scan.
///
/// **What they are for anyway.** The cheap shortcut in chunk 3 is to paste a second key
/// field into the import wizard rather than reuse this one. Two copies pass every
/// behavioural test in the suite, because both copies work; they diverge later, when a
/// Keychain fix lands in one and a new provider in the other, and the two screens
/// disagree about whether the user has a key. No runtime assertion can see that, so a
/// spelling tripwire on the obvious shortcut is worth more than nothing and less than a
/// proof. Named as such, per the limits above.
///
/// Two-way controlled: verified failing on 2026-09-10 against a deliberate second
/// `activeKeyDescriptor` in a scratch file, which it named in its failure message.
@Suite("Provider setup ownership (#2772)", .tags(.driftGuard))
struct ProviderSetupOwnershipTests {
  /// The repository root, derived from this file rather than from the working directory:
  /// a relative path would scan whichever checkout happens to be current, and this repo
  /// routinely has four worktrees open at once.
  static var sourceRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Settings
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources")
  }

  /// Every `.swift` file under `Sources/`, as (path, contents).
  static var swiftFiles: [(path: String, text: String)] {
    guard
      let walker = FileManager.default.enumerator(
        at: sourceRoot, includingPropertiesForKeys: nil)
    else { return [] }
    var out: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      out.append((url.lastPathComponent, text))
    }
    return out
  }

  @Test("the scanner can see its subject")
  func theScannerCanSeeItsSubject() {
    let files = Self.swiftFiles
    #expect(files.count > 100, "the scan found \(files.count) files, which is not this repo")
    #expect(
      files.contains { $0.path == "ProviderSetup.swift" },
      "the scan cannot see ProviderSetup.swift, so every result below is vacuous")
  }

  /// The API key FIELD — the thing a user types a secret into — is rendered in exactly one
  /// place. `LLMModelDiscoveryCoordinator` and `StandingSnapshotBuilder` also name the key
  /// ids, and neither renders a field; the marker here is the editor's own row, not the id.
  @Test("only one view offers a key field")
  func onlyOneViewOffersAKeyField() {
    let owners = Self.swiftFiles
      .filter { $0.text.contains("activeKeyDescriptor") }
      .map(\.path)
      .sorted()
    #expect(
      owners == ["ProviderSetup.swift"],
      "the key field must have one owner; found \(owners)")
  }

  /// The two halves of the #1950 download confirmation stay in one namespace. A view that
  /// calls `pullModel` directly has skipped the verdict check, which is the exact defect
  /// #1956 had to patch onto a second control after a sweep missed it.
  @Test("the local download funnel has one owner")
  func theLocalDownloadFunnelHasOneOwner() {
    let callers = Self.swiftFiles
      .filter { $0.text.contains("ollamaSetup.pullModel(") }
      .map(\.path)
      .sorted()
    #expect(
      callers == ["ProviderSetup.swift"],
      "pullModel must be reached through ProviderSetupDownloads; found \(callers)")
  }

  /// The three Keychain WRITE paths live with the editor. A second writer is how one
  /// screen would save a key the other never learns about.
  @Test("only one view writes a provider key")
  func onlyOneViewWritesAProviderKey() {
    let writers = Self.swiftFiles
      .filter { $0.text.contains("keychainManager.store(") }
      .map(\.path)
      .sorted()
    #expect(
      writers == ["ProviderSetup.swift"],
      "provider keys must be written in one place; found \(writers)")
  }
}
