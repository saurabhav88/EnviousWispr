import EnviousWisprCore
import Foundation
import Testing

/// #2650 — a provider's display name has ONE owner, `LLMProvider.displayName`,
/// and every site that shows it reads it from there.
///
/// Before this freeze the same string was typed out in four places: the sidebar
/// polish label, the settings rail catalog, the onboarding checklist, and the
/// local-engine descriptor, each restating "EG-1" or "Apple Intelligence" as a
/// literal. Nothing was wrong on screen; the defect was structural, and #2649
/// showed the shape of the failure it invites. That change added S1-mini under
/// a licence that requires one exact spelling wherever the model is identified,
/// and a fifth restatement would have been a licence breach that compiled
/// cleanly and read fine to a reviewer who did not know the term existed.
///
/// So this is a STRUCTURAL freeze on the class rather than a check of the
/// instances: a new site that restates a display name fails the build instead
/// of waiting for a rename or a licence audit to find it.
///
/// The rule: no non-comment line under `Sources/` outside the owner file may
/// contain a quoted literal equal to any `LLMProvider.displayName` value. The
/// literal is matched exactly — `"EG-1"` including both quotes — so a longer
/// sentence that MENTIONS a provider ("EG-1 is not installed") is not a
/// restatement of its name and does not fire.
///
/// Drift Guard: when this fails, no user sees anything — every site still
/// shows the right string today. What is at risk is the next rename, and the
/// licence-bound spelling the next third-party model will bring.
@Suite("LLMProvider display-name owner freeze (#2650)", .tags(.driftGuard))
struct LLMProviderDisplayNameFreezeTests {

  /// The one file allowed to spell the names: it is where `displayName` lives.
  private static let owner = "Sources/EnviousWisprCore/LLMResult.swift"

  /// Lines outside the owner that legitimately carry one of the strings, keyed
  /// by repo-relative file. Each exception is bound to the exact construct that
  /// carries the literal — the argument label and the quoted name together, as
  /// they appear on the line — with the reason it is NOT a restatement of the
  /// provider's display name. Binding the whole construct rather than the bare
  /// name is deliberate: `"EG-1"` is allowed in the dictionary file only as a
  /// `canonical:` vocabulary spelling, so a NEW `"EG-1"` in the same file that
  /// is anything else (a label, a description, an alert) still fails. Adding an
  /// entry is a deliberate act: state what else the string is doing there.
  private static let permitted: [String: [(construct: String, reason: String)]] = [
    // Built-in dictionary corrections. The string is a VOCABULARY entry — the
    // canonical spelling a recogniser's mishearing is corrected to, keyed by a
    // stable `id` and bound to its own alias list — in a table that also holds
    // brands with no provider at all ("EnviousWispr"). Tying it to the settings
    // enum would couple the spoken-word dictionary to the polish picker.
    "Sources/EnviousWisprPostProcessing/CustomWordsManager.swift": [
      ("canonical: \"EG-1\"", "built-in dictionary canonical spelling, a vocabulary entry"),
      ("canonical: \"OpenAI\"", "built-in dictionary canonical spelling, a vocabulary entry"),
      ("canonical: \"Claude\"", "built-in dictionary canonical spelling, a vocabulary entry"),
    ],
    // A log CATEGORY. It names the subsystem a diagnostic line belongs to, is an
    // observability key rather than anything a user reads, and matches the
    // display name by coincidence of both being the product's name.
    "Sources/EnviousWisprAppKit/App/PipelineSettingsSync.swift": [
      ("category: \"Ollama\"", "diagnostic log category, an observability key")
    ],
    "Sources/EnviousWisprPipeline/LLMPolishStep.swift": [
      ("category: \"Ollama\"", "diagnostic log category, an observability key")
    ],
  ]

  /// Every name the owner defines, quoted the way a Swift literal restating it
  /// would appear. Derived from the enum so a new case is guarded the moment it
  /// exists, without anyone remembering to extend a list here.
  private static var quotedDisplayNames: [(name: String, quoted: String)] {
    LLMProvider.allCases.map { ($0.displayName, "\"\($0.displayName)\"") }
  }

  @Test("no source file outside the owner restates a provider display name")
  func onlyTheOwnerSpellsADisplayName() throws {
    let root = RepoRoot.url
    let sources = root.appendingPathComponent("Sources")
    let names = Self.quotedDisplayNames

    var offenders: [String] = []
    let files = FileManager.default.enumerator(
      at: sources, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    while let item = files?.nextObject() as? URL {
      guard item.pathExtension == "swift" else { continue }
      let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
      guard relative != Self.owner else { continue }
      let allowed = (Self.permitted[relative] ?? []).map { $0.construct }
      let source = try String(contentsOf: item, encoding: .utf8)
      for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let text = String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Comment-only lines may mention a name in prose; the freeze is about
        // code that would show it, so those are skipped the way the other
        // source-scanning freezes in this directory skip them.
        if trimmed.hasPrefix("//") { continue }
        for entry in names where text.contains(entry.quoted) {
          // An exception covers THIS line only when the line carries the whole
          // permitted construct, not merely the name it contains.
          let excused = allowed.contains { construct in
            construct.contains(entry.quoted) && text.contains(construct)
          }
          if !excused {
            offenders.append("\(relative):\(idx + 1): \(trimmed)")
          }
        }
      }
    }

    #expect(
      offenders.isEmpty,
      """
      These lines restate a provider display name that `LLMProvider.displayName` \
      already owns. Read it from there (`LLMProvider.egOne.displayName`, or \
      `provider.displayName`) so a rename or a licence-bound spelling changes in \
      one place, or add the exact construct on that line to `permitted` with the \
      reason the string is something other than the provider's name:
      \(offenders.sorted().joined(separator: "\n"))
      """)
  }

  /// The two-way control. A freeze whose pattern matches nothing is
  /// indistinguishable from a clean repo, and would keep passing after the
  /// owner moved or the names were rewritten as something the scan cannot see.
  @Test("the owner file still spells every display name the scan looks for")
  func ownerStillSpellsEveryName() throws {
    let text = try String(contentsOf: RepoRoot.sourceURL(Self.owner), encoding: .utf8)
    for entry in Self.quotedDisplayNames {
      #expect(
        text.contains(entry.quoted),
        """
        \(Self.owner) no longer contains \(entry.quoted). Either `displayName` \
        moved — point `owner` at its new home — or the name is no longer a plain \
        literal there and this freeze is checking a spelling it cannot find.
        """)
    }
  }

  /// Every permitted exception must still name a real file that still carries
  /// the exact construct, and the construct must quote a real display name, so
  /// a rename or a cleanup turns into a failure here rather than silently
  /// widening the allow-list to cover nothing — or narrowing it to a construct
  /// the scan would never match.
  @Test("every permitted exception still names a real file carrying its construct")
  func permittedEntriesAreLive() throws {
    let quoted = Self.quotedDisplayNames.map { $0.quoted }
    for (path, entries) in Self.permitted {
      let url = RepoRoot.sourceURL(path)
      #expect(
        FileManager.default.fileExists(atPath: url.path),
        "permitted exception no longer exists: \(path)")
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      for entry in entries {
        #expect(
          quoted.contains { entry.construct.contains($0) },
          """
          permitted construct \(entry.construct) quotes no display name \
          (\(entry.reason)): \(path)
          """)
        #expect(
          text.contains(entry.construct),
          "permitted exception no longer carries \(entry.construct) (\(entry.reason)): \(path)")
      }
    }
  }
}
