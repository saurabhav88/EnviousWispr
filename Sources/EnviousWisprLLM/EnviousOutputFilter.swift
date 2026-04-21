import Foundation

/// Defense-in-depth post-processor for AFM plain-string polish output.
///
/// The on-device model is non-deterministic and occasionally:
///   1. Executes imperatives in the transcript (e.g. writes a Python script
///      when the user dictates "please write a Python script").
///   2. Emits conversational preambles like "Sure, here is the cleaned
///      transcript:\n\n<actual content>".
///
/// Pipeline (applied in order):
///   1. Preamble strip via `String.strippingLLMPreamble()` (shared shape-based
///      helper used by all cloud connectors, covered by `PreambleStrippingTests`).
///   2. Code-shape detection on the stripped body. If the output body looks
///      like code (fenced, code-keyword lines, or high brace density) AND the
///      input didn't, AFM executed instead of cleaned. Fall back to raw input.
///   3. Length backstop — if stripped body is > 1.5x input + 50 chars, assume
///      AFM generated a novel/essay. Fall back to raw input.
public enum EnviousOutputFilter {

  public struct Result: Equatable, Sendable {
    public let polished: String
    public let fellBackToRaw: Bool
    public let tripped: String?
  }

  public static func filter(input: String, output: String) -> Result {
    let rawInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

    let shouldStripPreamble =
      rawOutput.contains("\n\n")
      || firstLine(of: rawOutput).hasSuffix(":")
    let stripped =
      shouldStripPreamble
      ? rawOutput.strippingLLMPreamble()
      : strippingTranscriptWrapperOnly(from: rawOutput)
    let preambleStripped = stripped != rawOutput

    if looksLikeCode(stripped) && !looksLikeCode(rawInput) {
      return Result(polished: rawInput, fellBackToRaw: true, tripped: "code_shape_guard")
    }

    if looksLikeStructuredData(stripped) && !looksLikeStructuredData(rawInput) {
      return Result(polished: rawInput, fellBackToRaw: true, tripped: "structured_output_guard")
    }

    if droppedRiskyImperative(input: rawInput, output: stripped) {
      return Result(polished: rawInput, fellBackToRaw: true, tripped: "imperative_execution_guard")
    }

    let lengthCeiling = Int(Double(rawInput.count) * 1.5) + 50
    if stripped.count > lengthCeiling {
      return Result(polished: rawInput, fellBackToRaw: true, tripped: "length_guard")
    }

    // Aggressive shortening guard. When AFM drops descriptive framing and
    // emits just the inner quoted/executed content (e.g. "The menu item
    // should read AI Polish not Apple Intelligence" → "AI Polish"), the
    // output is dramatically shorter than the input. Threshold set at 40%
    // with a 30-char input floor so normal filler cleanup ("So, um, yeah,
    // the meeting went well" → "The meeting went well.") doesn't trip.
    if rawInput.count >= 30 && stripped.count > 0
      && Double(stripped.count) < Double(rawInput.count) * 0.4
    {
      return Result(
        polished: rawInput, fellBackToRaw: true, tripped: "aggressive_shortening_guard")
    }

    return Result(
      polished: stripped,
      fellBackToRaw: false,
      tripped: preambleStripped ? "preamble_stripped" : nil
    )
  }

  private static func firstLine(of text: String) -> String {
    String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func strippingTranscriptWrapperOnly(from text: String) -> String {
    text.replacingOccurrences(
      of: "</?transcript>",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func looksLikeCode(_ text: String) -> Bool {
    if text.hasPrefix("```") { return true }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

    let codeLinePatterns = [
      #"^\s*import\s+[\w\.]+$"#,
      #"^\s*from\s+[\w\.]+\s+import\s"#,
      #"^\s*import\s+.+\s+from\s+["'][^"']+["'];?\s*$"#,
      #"^\s*def\s+\w+\s*\("#,
      #"^\s*class\s+\w+[\s{:(]"#,
      #"^\s*func\s+\w+\s*\("#,
      #"^\s*(public|private|internal|fileprivate)\s+(class|struct|func|enum|var|let)\s"#,
      #"^\s*(let|var|const)\s+\w+\s*="#,
      #"^\s*#!/"#,
      #"^\s*#include\s+[<\"]"#,
      #"^\s*select\b.+\bfrom\b.+$"#,
      #"^\s*(insert|update|delete)\b.+$"#,
      #"^\s*if\s+.*:$"#,
      #"^\s*for\s+\w+\s+in\s+.*:$"#,
    ]

    var codeLineHits = 0
    for line in lines {
      let lineStr = String(line)
      for pattern in codeLinePatterns {
        if lineStr.range(of: pattern, options: .regularExpression) != nil {
          codeLineHits += 1
          break
        }
      }
      if codeLineHits >= 2 { return true }
    }

    if text.count > 50 {
      let codeChars = text.filter { "{};".contains($0) }.count
      if Double(codeChars) / Double(text.count) > 0.08 { return true }
    }

    return false
  }

  private static func looksLikeStructuredData(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return false }
    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return true }
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return true }
    return false
  }

  private static func droppedRiskyImperative(input: String, output: String) -> Bool {
    let inputLower = input.lowercased()
    let outputLower = output.lowercased()

    let guards: [(trigger: String, requiredToken: String)] = [
      ("write a sql query", "query"),
      ("draft a cron expression", "cron expression"),
      ("answer this question", "answer"),
      ("explain the difference", "explain"),
      ("translate this", "translate"),
      ("summarize this", "summarize"),
      ("rewrite this", "rewrite"),
      ("convert this into json", "convert"),
      ("respond with only markdown", "respond"),
      ("turn this into", "turn this"),
      ("write a poem", "poem"),
      ("brainstorm", "brainstorm"),
      // Preservation-intent triggers — when the user explicitly asks for
      // verbatim preservation, AFM must not transform.
      ("dictate the words", "dictate"),
      ("preserve the words", "preserve"),
      ("keep the words", "keep"),
      ("keep the phrase", "keep"),
      // Code-artifact creation triggers that execute when missed upstream.
      ("create a regex", "regex"),
      ("generate a regex", "regex"),
      ("write a regex", "regex"),
      ("create a pattern", "pattern"),
    ]

    for entry in guards where inputLower.contains(entry.trigger) {
      if !outputLower.contains(entry.requiredToken) {
        return true
      }
    }
    return false
  }
}
