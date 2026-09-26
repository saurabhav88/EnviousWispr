#if DEBUG
  import EnviousWisprCore
  import EnviousWisprLLM
  import EnviousWisprPipeline
  import EnviousWisprServices
  import Foundation

  /// A launch-only scripted checker for live dictation drills before a model qualifies.
  @MainActor
  enum LearnedWordCheckUATDoor {
    static let environmentKey = "EW_LEARNED_CHECK_UAT_APPROVE"

    static func parseApprovedWords(_ raw: String) -> Set<String>? {
      let words = Set(
        raw.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
      return words.isEmpty ? nil : words
    }

    static func configuration(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScriptedLearnedWordChecker? {
      guard let raw = environment[environmentKey] else { return nil }
      guard let words = parseApprovedWords(raw) else {
        log("learned-check UAT door REJECTED: empty list")
        return nil
      }
      let checker = ScriptedLearnedWordChecker(approvedWords: words)
      log("learned-check UAT door ACTIVE: words=\(words.count)")
      for engine in LearnedWordCheckerEngine.allCases
      where environment[engine.adapterKey] != nil || environment[engine.thresholdKey] != nil {
        log("learned-check UAT door WINS over \(engine.label) adapter door")
      }
      return checker
    }

    private static func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "Pipeline") }
    }
  }

  struct ScriptedLearnedWordChecker: LearnedWordChecking {
    let approvedWords: Set<String>
    let armName = "uat_scripted"
    let scoresAreComparable = false

    func decide(_ questions: [LearnedWordCheckQuestion]) async throws -> [LearnedWordCheckDecision]
    {
      questions.map { question in
        LearnedWordCheckDecision(
          questionID: question.id,
          approved: approvedWords.contains(question.word)
            && String(question.sentence[question.range]) != question.word)
      }
    }
  }

  /// Launch-only adapter bench for each bundled engine's word check (#3105: EG-1's
  /// eg1c, S1-mini's D5): a local adapter file in place of the delivered one.
  @MainActor
  enum LearnedWordCheckAdapterDoor {
    static func configuration(
      _ engine: LearnedWordCheckerEngine, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL, threshold: Double)? {
      let path = environment[engine.adapterKey]
      let rawThreshold = environment[engine.thresholdKey]
      guard path != nil || rawThreshold != nil else { return nil }
      guard let path, path.hasPrefix("/"), !path.isEmpty,
        URL(fileURLWithPath: path).pathExtension.lowercased() == "gguf"
      else {
        log("learned-check \(engine.label) door REJECTED: adapter must be an absolute .gguf path")
        return nil
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path)
      else {
        log("learned-check \(engine.label) door REJECTED: adapter file is missing or unreadable")
        return nil
      }
      guard let rawThreshold, let threshold = Double(rawThreshold),
        threshold.isFinite, (0...1).contains(threshold)
      else {
        log("learned-check \(engine.label) door REJECTED: threshold must be 0..1")
        return nil
      }
      log("learned-check \(engine.label) door ACTIVE: threshold=\(threshold)")
      return (URL(fileURLWithPath: path), threshold)
    }

    private static func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "Pipeline") }
    }
  }

  /// The Debug door's keys per engine. The drills set and clear exactly these
  /// (`CHECKER_DOOR_KEYS` in `learn_from_edits_uat.py`, `ENGINES` in
  /// `auto_dictionary_bench.py`).
  extension LearnedWordCheckerEngine {
    var adapterKey: String {
      switch self {
      case .egOne: "EW_LEARNED_CHECK_EG1_ADAPTER"
      case .s1Mini: "EW_LEARNED_CHECK_S1_ADAPTER"
      }
    }
    var thresholdKey: String {
      switch self {
      case .egOne: "EW_LEARNED_CHECK_EG1_THRESHOLD"
      case .s1Mini: "EW_LEARNED_CHECK_S1_THRESHOLD"
      }
    }
    /// The drills wait for this name in the ACTIVE line; it is the provider's
    /// own display name (#2650 freeze), never a restatement.
    var label: String { provider.displayName }
    /// `learned_check_checker_identity` for a door-supplied adapter; the values
    /// PR 1 shipped, so dev analytics keep one vocabulary.
    var debugDoorIdentity: String {
      switch self {
      case .egOne: "uat_adapter"
      case .s1Mini: "uat_adapter_s1"
      }
    }
  }
#endif
