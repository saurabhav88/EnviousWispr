import Foundation
import Testing

@testable import EnviousWisprLLM

/// Binds every shipped local-model label to the measurement it claims to come from.
///
/// Why this exists: the labels are a factual claim about twelve models, and the only thing that
/// made them true was a benchmark run whose receipts are gitignored. Without this suite a
/// re-benchmark, a hand edit, or a well-meaning "this model feels better now" could relabel a model
/// with nothing failing — and the label is what a user reads before trusting their dictation to it.
///
/// The comparison runs against a TRACKED fixture rather than the receipts themselves. Reading
/// `scripts/eval/runs/` would pass on the machine that produced it and silently verify nothing in
/// CI, where the directory does not exist: a test whose scope is empty is worse than no test,
/// because it reports success. Regenerating the fixture after a re-benchmark is therefore a visible
/// diff, and a relabel has to be a deliberate edit in two places rather than a quiet drift in one.
@Suite("Measured verdicts match the frozen benchmark (#1950)")
struct MeasuredModelVerdictFixtureTests {

  // The published bands, as executable code rather than prose in a comment. Ordered high to low and
  // read by `expectedVerdict` below, so a band edit cannot disagree with itself.
  //
  // Boundaries are INCLUSIVE at the lower edge, which is load-bearing for `qwen3:0.6b`: the
  // confirming judge put it at exactly 30.0%, so ">= 30" and "> 30" ship different labels for it.
  static let bands: [(floor: Double, verdict: OllamaModelVerdict)] = [
    (30.0, .recommended),
    (14.0, .mixed),
    (0.1, .unreliable),
    (0.0, .notRecommended),
  ]

  static func expectedVerdict(forPassRate rate: Double) -> OllamaModelVerdict {
    for band in bands where rate >= band.floor { return band.verdict }
    return .notRecommended
  }

  struct Fixture: Decodable {
    struct Model: Decodable {
      let passRatePct: Double
      let s4Count: Int
      let totalScored: Int
      let confirmingJudgePassRatePct: Double

      enum CodingKeys: String, CodingKey {
        case passRatePct = "pass_rate_pct"
        case s4Count = "s4_count"
        case totalScored = "total_scored"
        case confirmingJudgePassRatePct = "confirming_judge_pass_rate_pct"
      }
    }
    let primaryJudge: String
    let corpusCases: Int
    let models: [String: Model]

    enum CodingKeys: String, CodingKey {
      case primaryJudge = "primary_judge"
      case corpusCases = "corpus_cases"
      case models
    }
  }

  static let fixtureURL = RepoRoot.url.appending(
    path: "Tests/EnviousWisprTests/LLM/Fixtures/measured-local-model-scores-2026-08-11.json")

  static func loadFixture() throws -> Fixture {
    let data = try Data(contentsOf: fixtureURL)
    return try JSONDecoder().decode(Fixture.self, from: data)
  }

  @Test("the fixture is readable and covers a full corpus run")
  func fixtureLoads() throws {
    let f = try Self.loadFixture()
    // Fail loudly on an empty or truncated fixture rather than passing a loop over nothing, which
    // is how a per-row check reports success on zero rows.
    #expect(f.models.count == 12, "expected twelve measured arms, got \(f.models.count)")
    #expect(f.corpusCases == 20)
    #expect(!f.primaryJudge.isEmpty)
  }

  @Test("every shipped verdict is the one its measured pass rate implies")
  func everyVerdictFollowsItsMeasurement() throws {
    let f = try Self.loadFixture()
    for (model, m) in f.models.sorted(by: { $0.key < $1.key }) {
      let expected = Self.expectedVerdict(forPassRate: m.passRatePct)
      let actual = OllamaModelVerdicts.verdict(for: model)
      #expect(
        actual == expected,
        """
        \(model) measured \(m.passRatePct)% (\(m.totalScored) scored, \(m.s4Count) S4), \
        which is the \(expected) band, but ships as \(actual). Either the label is wrong or the \
        fixture is stale; do not change one to match the other without re-reading the receipts.
        """)
    }
  }

  @Test("the measured set and the fixture describe the same twelve models")
  func fixtureAndAuthorityAgreeOnMembership() throws {
    let f = try Self.loadFixture()
    let fixtureModels = Set(f.models.keys)
    let authorityModels = Set(OllamaModelVerdicts.measuredModelIDs)
    // Both directions. A one-way check passes when the authority quietly gains an arm the
    // benchmark never measured, which is exactly the "labelled from a feeling" case.
    #expect(
      fixtureModels == authorityModels,
      """
      fixture-only: \(fixtureModels.subtracting(authorityModels).sorted()); \
      authority-only: \(authorityModels.subtracting(fixtureModels).sorted())
      """)
  }

  @Test("no shipped label depends on which judge graded it")
  func labelsSurviveTheConfirmingJudge() throws {
    let f = try Self.loadFixture()
    for (model, m) in f.models.sorted(by: { $0.key < $1.key }) {
      let primary = Self.expectedVerdict(forPassRate: m.passRatePct)
      let confirming = Self.expectedVerdict(forPassRate: m.confirmingJudgePassRatePct)
      #expect(
        primary == confirming,
        """
        \(model) would be labelled \(primary) from the primary judge (\(m.passRatePct)%) but \
        \(confirming) from the confirming judge (\(m.confirmingJudgePassRatePct)%). A label that \
        flips with the judge is not a measurement of the model.
        """)
    }
  }

  @Test("the band table is exhaustive and ordered, including at every boundary")
  func bandTableIsTotalAndOrdered() {
    // A band table read top-down only works if it is sorted descending; an unsorted one returns a
    // plausible wrong band with nothing failing.
    let floors = Self.bands.map(\.floor)
    #expect(floors == floors.sorted(by: >), "bands must be ordered high to low: \(floors)")

    // Exactly at each floor, and just below it, so an inclusive/exclusive slip is caught. 30.0 is
    // the real-world case: the confirming judge put qwen3:0.6b exactly there.
    #expect(Self.expectedVerdict(forPassRate: 100.0) == .recommended)
    #expect(Self.expectedVerdict(forPassRate: 30.0) == .recommended)
    #expect(Self.expectedVerdict(forPassRate: 29.9) == .mixed)
    #expect(Self.expectedVerdict(forPassRate: 14.0) == .mixed)
    #expect(Self.expectedVerdict(forPassRate: 13.9) == .unreliable)
    #expect(Self.expectedVerdict(forPassRate: 0.1) == .unreliable)
    #expect(Self.expectedVerdict(forPassRate: 0.0) == .notRecommended)
  }
}
