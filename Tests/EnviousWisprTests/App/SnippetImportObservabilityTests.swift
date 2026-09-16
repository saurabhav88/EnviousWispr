import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2997 — what an import attempt sends, and what it never sends.
///
/// `.observabilityContract`: when this fails the adoption insight lies, a crash arrives
/// without the import path that preceded it, the one app-owned error is filed for a user
/// condition (or not filed for ours), or a trigger reaches a vendor.
///
/// The payload is asserted as an exact ALLOWLIST (key set, value type, closed raw-value
/// sets), derived from the real property dictionary through `testEventHook`, so a stray
/// description or a key added later fails here rather than in a name-based grep.
#if DEBUG

  @MainActor
  @Suite("Snippet import observability (#2997)", .tags(.observabilityContract), .serialized)
  struct SnippetImportObservabilityTests {
    /// Distinctive on purpose: a substring search must be able to fail loudly.
    private static let secretTrigger = "zzsecrettriggerzz"
    private static let secretExpansion = "zzsecretexpansionzz"

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private(set) var events: [CapturedTelemetryEvent] = []
      /// The COMPLETE dictionaries handed to the SDK, untyped.
      private(set) var raw: [(String, [String: Any])] = []
      func add(raw row: (String, [String: Any])) { lock.withLock { raw.append(row) } }
      private(set) var crumbs: [(String, String, [String: Any]?)] = []
      private(set) var errors: [(any Error, SentryBreadcrumb.ErrorCategory, String, [String: Any]?)] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { events.append(e) } }
      func add(crumb: (String, String, [String: Any]?)) { lock.withLock { crumbs.append(crumb) } }
      func add(error: (any Error, SentryBreadcrumb.ErrorCategory, String, [String: Any]?)) {
        lock.withLock { errors.append(error) }
      }
    }

    private func observe(_ body: () async -> Void) async -> EventBox {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { box.add($0) }
      TelemetryService.shared.testRawPropertiesHook = { box.add(raw: ($0, $1)) }
      SentryBreadcrumb.breadcrumbDelegate = { stage, message, _, data in
        box.add(crumb: (stage, message, data))
      }
      SentryBreadcrumb.captureErrorDelegate = { error, category, stage, extra in
        box.add(error: (error, category, stage, extra))
      }
      defer {
        TelemetryService.shared.testEventHook = nil
        TelemetryService.shared.testRawPropertiesHook = nil
        SentryBreadcrumb.breadcrumbDelegate = nil
        SentryBreadcrumb.captureErrorDelegate = nil
      }
      await body()
      return box
    }

    private static let countKeys: Set<String> = [
      "candidates", "added", "skipped_existing", "skipped_duplicate_batch", "skipped_unticked",
      "excluded",
    ]

    /// The allowlist over the COMPLETE untyped dictionary: every violation, as sentences. An
    /// empty answer is the pass. Checked on the raw hook, so a value of any type an emitter
    /// might add later (an array, a nested dictionary, a URL) is judged, not dropped.
    static func violations(in props: [String: Any]) -> [String] {
      var problems: [String] = []
      let allowedStrings: [String: Set<String>] = [
        "source": Set(SnippetImportTelemetrySource.allCases.map(\.rawValue)),
        "outcome": Set(SnippetImportTelemetryOutcome.allCases.map(\.rawValue)),
        "failure": Set(SnippetImportTelemetryFailure.allCases.map(\.rawValue)),
      ]
      for (key, value) in props {
        if let allowed = allowedStrings[key] {
          guard let string = value as? String else {
            problems.append("\(key) is not a String: \(type(of: value))")
            continue
          }
          if !allowed.contains(string) { problems.append("\(key) carries a value outside its closed set: \(string)") }
        } else if countKeys.contains(key) {
          if !(value is Int) { problems.append("\(key) is not an Int: \(type(of: value))") }
        } else {
          problems.append("unexpected key \(key) (\(type(of: value)))")
        }
      }
      for required in countKeys.union(["source", "outcome"]) where props[required] == nil {
        problems.append("missing \(required)")
      }
      if props["outcome"] as? String == "failed", props["failure"] == nil { problems.append("failed without failure") }
      if props["outcome"] as? String != "failed", props["failure"] != nil { problems.append("failure on a non-failed outcome") }
      return problems
    }

    /// The exact allowlist for one row.
    private func assertShape(
      _ event: CapturedTelemetryEvent, source: String, outcome: String, failure: String?,
      sourceLocation: SourceLocation = #_sourceLocation
    ) {
      #expect(event.name == "snippets.imported", sourceLocation: sourceLocation)
      var strings: Set<String> = ["source", "outcome"]
      if failure != nil { strings.insert("failure") }
      #expect(Set(event.stringProps.keys) == strings, sourceLocation: sourceLocation)
      #expect(Set(event.intProps.keys) == Self.countKeys, sourceLocation: sourceLocation)
      #expect(event.boolProps.isEmpty && event.doubleProps.isEmpty, sourceLocation: sourceLocation)
      #expect(event.stringProps["source"] == source, sourceLocation: sourceLocation)
      #expect(event.stringProps["outcome"] == outcome, sourceLocation: sourceLocation)
      #expect(event.stringProps["failure"] == failure, sourceLocation: sourceLocation)
      #expect(
        SnippetImportTelemetrySource(rawValue: event.stringProps["source"] ?? "") != nil,
        sourceLocation: sourceLocation)
      #expect(
        SnippetImportTelemetryOutcome(rawValue: event.stringProps["outcome"] ?? "") != nil,
        sourceLocation: sourceLocation)
      if let failure = event.stringProps["failure"] {
        #expect(SnippetImportTelemetryFailure(rawValue: failure) != nil, sourceLocation: sourceLocation)
      }
    }

    private func report(
      _ source: SnippetImportTelemetrySource, _ outcome: SnippetImportTelemetryOutcome,
      failure: SnippetImportTelemetryFailure? = nil
    ) -> SnippetImportAttemptReport {
      var r = SnippetImportAttemptReport(source: source, outcome: outcome)
      r.candidates = 5
      r.added = 2
      r.skippedExisting = 1
      r.skippedDuplicateBatch = 1
      r.skippedUnticked = 1
      r.excluded = 3
      r.failure = failure
      return r
    }

    @Test("Every outcome × source sends exactly the allowlisted keys, with closed vocabularies and counts")
    func payloadPerOutcome() async {
      // The full cross product, with every failure value exercised on the `failed` outcome.
      var cases: [(SnippetImportTelemetrySource, SnippetImportTelemetryOutcome, SnippetImportTelemetryFailure?)] = []
      for source in SnippetImportTelemetrySource.allCases {
        for outcome in SnippetImportTelemetryOutcome.allCases where outcome != .failed {
          cases.append((source, outcome, nil))
        }
      }
      for (index, failure) in SnippetImportTelemetryFailure.allCases.enumerated() {
        let sources = SnippetImportTelemetrySource.allCases
        cases.append((sources[index % sources.count], .failed, failure))
      }
      let box = await observe {
        let reporter = SnippetImportReporter.live()
        for (source, outcome, failure) in cases {
          reporter.report(attempt: UUID(), report(source, outcome, failure: failure))
        }
      }
      #expect(box.events.count == cases.count)
      for (event, (source, outcome, failure)) in zip(box.events, cases) {
        assertShape(event, source: source.rawValue, outcome: outcome.rawValue, failure: failure?.rawValue)
        #expect(event.intProps["candidates"] == 5)
        #expect(event.intProps["added"] == 2)
        #expect(event.intProps["excluded"] == 3)
      }
      // The complete dictionaries, untyped: nothing but the allowlist, whatever the type.
      #expect(box.raw.count == cases.count)
      for (name, props) in box.raw {
        #expect(name == "snippets.imported")
        #expect(Self.violations(in: props).isEmpty, Comment(rawValue: Self.violations(in: props).joined(separator: "; ")))
      }
      // One breadcrumb per row, same stage, EXACTLY the row's keys and values, literal message.
      #expect(box.crumbs.count == cases.count)
      for (crumb, (source, outcome, failure)) in zip(box.crumbs, cases) {
        #expect(crumb.0 == "snippets_import")
        #expect(crumb.1 == "import \(outcome.rawValue)")
        var expectedKeys = Self.countKeys.union(["source", "outcome"])
        if failure != nil { expectedKeys.insert("failure") }
        #expect(Set(crumb.2?.keys.map { $0 } ?? []) == expectedKeys)
        #expect(crumb.2?["source"] as? String == source.rawValue)
        #expect(crumb.2?["outcome"] as? String == outcome.rawValue)
        #expect(crumb.2?["failure"] as? String == failure?.rawValue)
        #expect(crumb.2?["candidates"] as? Int == 5)
        #expect(crumb.2?["excluded"] as? Int == 3)
      }
      #expect(box.errors.isEmpty, "no outcome files an error by itself")
    }

    @Test("The allowlist checker refuses a smuggled array, dictionary, wrong type, or open value")
    func allowlistCheckerRefusesSmuggledValues() {
      var good: [String: Any] = [
        "source": "paste", "outcome": "failed", "failure": "not_ours", "candidates": 1, "added": 0,
        "skipped_existing": 0, "skipped_duplicate_batch": 0, "skipped_unticked": 0, "excluded": 0,
      ]
      #expect(Self.violations(in: good).isEmpty)
      var smuggledArray = good
      smuggledArray["content"] = ["zzsecrettriggerzz"]
      #expect(Self.violations(in: smuggledArray) == ["unexpected key content (Array<String>)"])
      var smuggledDictionary = good
      smuggledDictionary["extra"] = ["trigger": "x"]
      #expect(Self.violations(in: smuggledDictionary).count == 1)
      var wrongType = good
      wrongType["candidates"] = "1"
      #expect(Self.violations(in: wrongType) == ["candidates is not an Int: String"])
      var openValue = good
      openValue["source"] = "/Users/me/Downloads/snippets.csv"
      #expect(Self.violations(in: openValue).count == 1)
      good["failure"] = nil
      #expect(Self.violations(in: good) == ["failed without failure"])
    }

    @Test("An attempt is reported once, however many times its terminal is reached")
    func attemptLatches() async {
      let box = await observe {
        let reporter = SnippetImportReporter.live()
        let attempt = UUID()
        reporter.report(attempt: attempt, report(.paste, .completed))
        reporter.report(attempt: attempt, report(.paste, .completed))
        reporter.report(attempt: UUID(), report(.paste, .stale))
      }
      #expect(box.events.map { $0.stringProps["outcome"] } == ["completed", "stale"])
    }

    @Test("The one app-owned error is filed through captureError with counts only and a pinned identity")
    func reviewCommitMismatchFilesError() async {
      let box = await observe {
        SnippetImportReporter.live().fileReviewCommitMismatch(approved: 4, baseline: 12)
      }
      #expect(box.errors.count == 1)
      let filed = box.errors[0]
      #expect(filed.0 is SnippetImportReviewCommitMismatch)
      #expect(filed.1 == .stateMismatch)
      #expect(filed.2 == "snippets_import")
      #expect(filed.3?["approved"] as? Int == 4)
      #expect(filed.3?["baseline"] as? Int == 12)
      let identity = SnippetImportReviewCommitMismatch(approved: 4, baseline: 12)
      #expect(identity.sentryFingerprintDescriptor == "SnippetImportReviewCommitMismatch")
      #expect(identity.sentrySemanticID == "snippets.import.review_commit_mismatch")
      #expect(box.events.isEmpty, "filing the error is not a PostHog row; the flow reports that separately")
    }

    // MARK: - Through the flow

    private func flow(
      existing: [Snippet], commit: @escaping @MainActor (SnippetsCoordinator.SnippetImportCommitPlan) async -> SnippetsCoordinator.SnippetImportCommitOutcome
    ) -> SnippetImportFlowModel {
      SnippetImportFlowModel(
        dependencies: .live(existingSnippets: { existing }, commit: commit))
    }

    private func settle(_ condition: () -> Bool) async {
      for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
      }
      Issue.record("Timed out waiting for the flow")
    }

    @Test("A whole import through the live reporter carries no trigger or expansion anywhere")
    func flowCarriesNoContent() async {
      let existing = Snippet(trigger: Self.secretTrigger + " have", expansion: Self.secretExpansion)
      let box = await observe {
        let model = flow(existing: [existing]) { plan in
          .committed(
            SnippetImportReceipt(
              vocabulary: SnippetVocabulary(snippets: [], keyword: "backslash", generation: 1),
              addedIDs: plan.additions.map(\.id)))
        }
        model.select(.paste)
        model.begin(
          with: PasteSnippetsImportSource(
            text: "\(Self.secretTrigger) = \(Self.secretExpansion)\n\(Self.secretTrigger) have = x\nno separator"))
        await settle { model.step == .review }
        model.confirm()
        await settle { if case .result = model.step { return true }; return false }
      }
      #expect(box.events.count == 1)
      let event = box.events[0]
      assertShape(event, source: "paste", outcome: "completed", failure: nil)
      #expect(box.raw.count == 1)
      #expect(Self.violations(in: box.raw[0].1).isEmpty)
      #expect(event.intProps["candidates"] == 2)
      #expect(event.intProps["added"] == 1)
      #expect(event.intProps["skipped_existing"] == 1)
      #expect(event.intProps["excluded"] == 1)
      let values =
        event.stringProps.values.map { $0 } + event.intProps.values.map { "\($0)" }
        + box.crumbs.flatMap { $0.2?.values.map { "\($0)" } ?? [] }
        + box.crumbs.map(\.1)
      for value in values {
        #expect(!value.contains(Self.secretTrigger), "a trigger reached a vendor in: \(value)")
        #expect(!value.contains(Self.secretExpansion), "an expansion reached a vendor in: \(value)")
      }
    }

    @Test("A duplicate refused at commit despite a matching baseline files the error and reports invariant_violation")
    func mismatchAtCommitReportsBoth() async {
      let box = await observe {
        let model = flow(existing: []) { _ in .failed(.validation(.duplicateTrigger(existing: "sig"))) }
        model.select(.paste)
        model.begin(with: PasteSnippetsImportSource(text: "sig = hi"))
        await settle { model.step == .review }
        model.confirm()
        await settle { if case .result = model.step { return true }; return false }
      }
      #expect(box.events.count == 1)
      assertShape(box.events[0], source: "paste", outcome: "failed", failure: "invariant_violation")
      #expect(box.errors.count == 1)
      #expect(box.errors[0].0 is SnippetImportReviewCommitMismatch)
    }

    @Test("Repeated staleness is an outcome every time, never an error")
    func repeatedStaleIsNeverAnError() async {
      let box = await observe {
        let model = flow(existing: []) { _ in .stale }
        model.select(.paste)
        model.begin(with: PasteSnippetsImportSource(text: "sig = hi"))
        await settle { model.step == .review }
        model.confirm()
        await settle { model.step == .review && model.staleNotice != nil }
        model.confirm()
        await settle { model.step == .review && model.staleNotice != nil }
      }
      #expect(box.events.map { $0.stringProps["outcome"] } == ["stale", "stale"])
      #expect(box.errors.isEmpty)
    }

    @Test("An attempt abandoned before any terminal emits nothing")
    func abandonedImportEmitsNothing() async {
      let box = await observe {
        let model = flow(existing: []) { _ in .stale }
        model.select(.paste)
        model.begin(with: PasteSnippetsImportSource(text: "sig = hi"))
        await settle { model.step == .review }
        model.cancel()
        for _ in 0..<50 { await Task.yield() }
      }
      #expect(box.events.isEmpty)
      #expect(box.errors.isEmpty)
    }

    @Test("A store failure at commit is a failed row with the store's reason, and no error")
    func storeFailureIsAnOutcome() async {
      let box = await observe {
        let model = flow(existing: []) { _ in .failed(.store(.busy)) }
        model.select(.paste)
        model.begin(with: PasteSnippetsImportSource(text: "sig = hi"))
        await settle { model.step == .review }
        model.confirm()
        await settle { if case .result = model.step { return true }; return false }
      }
      #expect(box.events.count == 1)
      assertShape(box.events[0], source: "paste", outcome: "failed", failure: "store_busy")
      #expect(box.errors.isEmpty)
    }
  }

#endif
