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

    static func install(
      kernelDriver: KernelDictationDriver,
      whisperKitKernelDriver: KernelDictationDriver
    ) {
      guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return }
      guard let words = parseApprovedWords(raw) else {
        log("learned-check UAT door REJECTED: empty list")
        return
      }
      let checker = ScriptedLearnedWordChecker(approvedWords: words)
      kernelDriver.learnedWordCheck.checker = checker
      whisperKitKernelDriver.learnedWordCheck.checker = checker
      log("learned-check UAT door ACTIVE: approve=\(words.count) words")
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

  /// Launch-only EG-1 adapter bench. The adapter is deliberately outside the
  /// production model-delivery path until its measured gate passes.
  @MainActor
  enum LearnedWordCheckEGOneDoor {
    static func configuration(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL, threshold: Double)? {
      let path = environment["EW_LEARNED_CHECK_EG1_ADAPTER"]
      let rawThreshold = environment["EW_LEARNED_CHECK_EG1_THRESHOLD"]
      guard path != nil || rawThreshold != nil else { return nil }
      guard let path, path.hasPrefix("/"), !path.isEmpty,
        URL(fileURLWithPath: path).pathExtension.lowercased() == "gguf"
      else {
        log("learned-check EG-1 door REJECTED: adapter must be an absolute .gguf path")
        return nil
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path)
      else {
        log("learned-check EG-1 door REJECTED: adapter file is missing or unreadable")
        return nil
      }
      guard let rawThreshold, let threshold = Double(rawThreshold),
        threshold.isFinite, (0...1).contains(threshold)
      else {
        log("learned-check EG-1 door REJECTED: threshold must be 0..1")
        return nil
      }
      log("learned-check EG-1 door ACTIVE: threshold=\(threshold)")
      return (URL(fileURLWithPath: path), threshold)
    }

    private static func log(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "Pipeline") }
    }
  }
#endif
