import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #2649 §3.6.1, founder-added scope. Every on-device engine's "Why use"
/// section states how long a dictation it handles.
///
/// **A number on a settings screen is a public claim with no compiler.** Two of
/// these sentences borrow #2648's measurements rather than this change's own
/// runs, so if that harness re-measures, this copy is a thing it has to update.
/// This suite is the reminder: it fails loudly rather than letting a stale
/// number sit on screen unnoticed.
@Suite("Polish length copy (#2649)", .tags(.driftGuard))
struct PolishLengthCopyTests {
  static var settingsSource: String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Settings
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    return (try? String(
      contentsOf: root.appendingPathComponent(
        "Sources/EnviousWisprAppKit/Views/Settings/AIPolishSettingsView.swift"),
      encoding: .utf8)) ?? ""
  }

  @Test("every on-device engine states its dictation length")
  func everyLocalEngineStatesItsCeiling() {
    let source = Self.settingsSource
    #expect(!source.isEmpty, "a check that cannot reach its subject is not a check")

    for sentence in [
      "Handles dictations up to about 20 minutes.",            // EG-1
      "Best for dictations up to about 12 minutes.",           // S1-mini
      "Handles dictations up to about 8 minutes.",             // Apple Intelligence
      "How long a dictation it handles depends on the model you choose.",  // Ollama
    ] {
      #expect(source.contains(sentence), "missing length copy: \(sentence)")
    }
  }

  /// "About" is what makes these survive a 10% re-measurement. A bare number
  /// would be a promise of a hard cutoff, which none of them is.
  @Test("the numbers are approximate, never a hard cutoff")
  func numbersAreApproximate() {
    let source = Self.settingsSource
    for exact in [
      "up to 20 minutes", "up to 12 minutes", "up to 8 minutes",
    ] {
      #expect(
        !source.contains(exact),
        "\(exact) reads as a hard cutoff; the measured ceilings are approximate")
    }
  }

  /// Founder 2026-09-04: one short sentence each, no follow-up clause about what
  /// happens past the limit. That behaviour is real and lives in the length
  /// guard, where it is executable; on screen it is padding.
  @Test("no engine explains what happens past its limit")
  func noSecondClause() {
    let source = Self.settingsSource
    for padding in ["past that", "beyond that", "longer than that", "if you go over"] {
      #expect(!source.contains(padding))
    }
  }

  /// The cloud engines deliberately get NO sentence: their long-dictation
  /// failure is a fixed deadline, not a length ceiling, so a sentence here would
  /// describe an open bug as a documented limit. Asserted so a future "let us be
  /// consistent" edit has to read this reason first.
  @Test("the cloud engines are deliberately given no length sentence")
  func cloudEnginesAreExcluded() {
    let source = Self.settingsSource
    // Split on the DECLARATION, not the name: the name also appears where the
    // body is used, so splitting on it finds two boundaries and the check reads
    // as a broken subject rather than a broken claim.
    let cloudBody = source.components(separatedBy: "private var cloudProviderExplainer: some View")
    #expect(cloudBody.count == 2, "the cloud explainer body was renamed or removed")
    let after = (cloudBody.last ?? "").prefix(2500)
    #expect(
      !after.contains("minutes"),
      "a cloud length claim would describe an unfixed deadline as a documented limit")
  }
}
