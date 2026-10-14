@testable import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #3275: the on-device concern split's own decisions (fit, language) and its hand-off to the
/// help check. The model itself is exercised by the benchmark kit, not here.
@Suite("Help concern split (#3275)", .tags(.productOutcome))
struct HelpConcernDecomposerTests {

  @Test(
    "A full 4,000-character message fits macOS 26's 4,096-token window; a longer prompt does not")
  func contextFit() {
    // 4,000 Latin characters by the connector's conservative estimate: about 1,334 tokens.
    let message = String(repeating: "paste fails ", count: 334).prefix(4000)
    let prompt = HelpConcernDecomposer.prompt(for: String(message))
    let promptTokens = AppleIntelligenceConnector.heuristicAFMTokens(prompt, lang: "en")
    let instructionTokens = AppleIntelligenceConnector.heuristicAFMTokens(
      HelpConcernDecomposer.instructions, lang: nil)
    #expect(
      HelpConcernDecomposer.fits(
        instructionTokens: instructionTokens, promptTokens: promptTokens, contextTokens: 4096))
    // The same arithmetic at the boundary: one token too many does not fit.
    let room =
      4096 - HelpConcernDecomposer.reservedTokens
      - AppleIntelligenceConnector.afmContextSafetyMarginTokens
    #expect(
      HelpConcernDecomposer.fits(instructionTokens: 0, promptTokens: room, contextTokens: 4096))
    #expect(
      !HelpConcernDecomposer.fits(instructionTokens: 0, promptTokens: room + 1, contextTokens: 4096)
    )
    // 4,000 unsegmented characters (about one token each) do not fit macOS 26 and go whole-message.
    let cjk = String(repeating: "粘贴失败", count: 1000)
    let cjkTokens = AppleIntelligenceConnector.heuristicAFMTokens(
      HelpConcernDecomposer.prompt(for: cjk), lang: "zh")
    #expect(
      !HelpConcernDecomposer.fits(
        instructionTokens: instructionTokens, promptTokens: cjkTokens, contextTokens: 4096))
  }

  @Test("The whole message is split, never a prefix of it")
  func noTruncation() {
    let message = String(repeating: "a", count: 3999) + "Z"
    #expect(HelpConcernDecomposer.prompt(for: message).hasSuffix("Z"))
  }

  @Test("Short or unknown text is not judged by language; an unsupported language fails")
  func languageGate() {
    #expect(HelpConcernDecomposer.languageIsSupported(nil, supported: ["en"]))
    #expect(HelpConcernDecomposer.languageIsSupported("de", supported: ["en", "de"]))
    #expect(!HelpConcernDecomposer.languageIsSupported("hi", supported: ["en", "de"]))
    #expect(HelpConcernDecomposer.detectedBase("paste fails") == nil)
    #expect(
      HelpConcernDecomposer.detectedBase(
        "Seit dem Update startet die Aufnahme, aber es wird nichts in Slack eingefügt.") == "de")
  }

  @Test("Every split outcome reaches the help check; an unknown kind is kept as other")
  func wiring() {
    let concern = HelpConcernDecomposer.Concern(summary: "s", evidence: "e", kind: "rant")
    #expect(
      HelpCheckWiring.decomposition(.concerns([concern], hitCap: true))
        == .concerns([HelpCheckConcern(summary: "s", evidence: "e", kind: .other)], hitCap: true))
    #expect(HelpCheckWiring.decomposition(.failed(.unavailable)) == .unavailable(.afmUnavailable))
    #expect(
      HelpCheckWiring.decomposition(.failed(.unsupportedLanguage)) == .unavailable(.afmUnavailable))
    #expect(HelpCheckWiring.decomposition(.failed(.tooLong)) == .unavailable(.afmUnavailable))
    #expect(HelpCheckWiring.decomposition(.failed(.refused)) == .unavailable(.afmRefused))
    #expect(HelpCheckWiring.decomposition(.failed(.error)) == .unavailable(.afmError))
  }

  @Test("The terminal event reads Share usage metrics when the check ends")
  @MainActor
  func terminalRespectsMetricsSwitch() throws {
    var metricsOn = true
    var emitted = 0
    let sink = HelpCheckWiring.terminalSink(usageMetrics: { metricsOn }, emit: { _ in emitted += 1 })
    let record = try #require(
      FeedbackHelpOutcome(
        terminalOutcome: .stillSent, failureReason: nil, mode: .decomposed, overflow: false,
        coveragePassed: nil, versions: nil, shownCardCount: 0, issues: []))
    let terminal = HelpCheckTerminal(
      .stillSent, record: record, splitFailure: nil, splitPrewarmed: false, checkSeconds: 1)
    sink(terminal)
    #expect(emitted == 1)
    // Turned off while a check was running: the end of that check sends nothing.
    metricsOn = false
    sink(terminal)
    #expect(emitted == 1)
  }

  // MARK: - Split prepared before Send (#3739)

  final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
  }

  @Test("A prepared session is used only when it was built with today's instructions")
  func chooseSession() {
    let instructions = HelpConcernDecomposer.instructions
    let matching = HelpConcernDecomposer.PreparedSplit(session: "prepared", instructions: instructions)
    let used = Count()
    #expect(
      HelpConcernDecomposer.chooseSession(
        offered: matching, instructions: instructions, fresh: { "fresh" }, onConsumed: used.add)
        == "prepared")
    #expect(used.value == 1)
    // Built with other instructions, of another session type, or none offered: a fresh session.
    let stale = HelpConcernDecomposer.PreparedSplit(session: "prepared", instructions: "older")
    let other = HelpConcernDecomposer.PreparedSplit(session: 7, instructions: instructions)
    for offered in [stale as (any Sendable)?, other, nil, "prepared"] {
      #expect(
        HelpConcernDecomposer.chooseSession(
          offered: offered, instructions: instructions, fresh: { "fresh" }, onConsumed: used.add)
          == "fresh")
    }
    #expect(used.value == 1)
  }

  final class Forwarded: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: [String?] = []
    var all: [String?] { lock.withLock { prepared } }
    func add(_ value: String?) { lock.withLock { prepared.append(value) } }
  }

  @Test("The live check passes the prepared session and the use callback through to the split")
  func makeForwardsPreparedSession() async {
    let forwarded = Forwarded()
    let check = HelpCheckWiring.make(appVersion: "2.6.0") { _, prepared, onConsumed in
      forwarded.add(prepared as? String)
      onConsumed()
      return .failed(.refused)
    }
    let used = Count()
    let split = await check.decompose("Paste fails.", "s1", used.add)
    #expect(forwarded.all == ["s1"])
    #expect(used.value == 1)
    #expect(split == .unavailable(.afmRefused))
  }

  @Test("Install puts the split preparation on the shared submission")
  @MainActor
  func installSetsPreparation() async throws {
    let suite = "HelpConcernDecomposerTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let settings = SettingsManager(defaults: try #require(TestDefaults.suite(suite)))
    let submission = FeedbackSubmission(
      store: FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! }),
      save: { _, _, _, _ in .saved(offline: false) })
    let calls = Count()
    HelpCheckWiring.install(on: submission, settings: settings) {
      calls.add()
      return "prepared"
    }
    #expect(submission.helpCheck != nil)
    let prepare = try #require(submission.prepareSplit)
    #expect(await prepare() as? String == "prepared")
    #expect(calls.value == 1)
  }
}
