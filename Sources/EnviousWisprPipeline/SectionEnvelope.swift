import Foundation

/// File-import transport only. Cleanup instructions remain the existing cloud prompt.
/// Mirrors scripts/eval/section_envelope.py; malformed replies never yield partial mappings.
enum SectionEnvelope {
  private static let literal = expression(#"<(/?)(\\*)s(\d+)>"#)
  private static let escaped = expression(#"<(/?)(\\+)s(\d+)>"#)
  private static let tag = expression(#"</?s(\d+)>"#)
  private static let section = expression(#"<s(\d+)>(.*?)</s\1>"#, options: .dotMatchesLineSeparators)

  private static func expression(
    _ pattern: String, options: NSRegularExpression.Options = []
  ) -> NSRegularExpression {
    do { return try NSRegularExpression(pattern: pattern, options: options) }
    catch { preconditionFailure("Invalid section transport grammar: \(error)") }
  }

  private static func transformLiterals(_ text: String, escaping: Bool) -> String {
    let regex = escaping ? literal : escaped
    var result = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: result),
        let slash = Range(match.range(at: 1), in: text),
        let escapes = Range(match.range(at: 2), in: text),
        let number = Range(match.range(at: 3), in: text)
      else { preconditionFailure("Section literal match has invalid ranges") }
      let backslashes = escaping ? "\\" + text[escapes] : String(text[escapes].dropFirst())
      result.replaceSubrange(range, with: "<" + text[slash] + backslashes + "s" + text[number] + ">")
    }
    return result
  }

  static func wrap(_ sections: [String]) -> String {
    precondition(!sections.isEmpty, "A section envelope requires at least one section")
    return sections.enumerated().map { index, text in
      "<s\(index + 1)>\(transformLiterals(text, escaping: true))</s\(index + 1)>"
    }.joined(separator: "\n")
  }

  static func addendum(count: Int) -> String {
    "\n\nThe text contains \(count) sections, each between <sK> and </sK> for K from 1 to \(count). "
      + "Clean each section on its own. Return all sections, in the same order, with the same "
      + "tags, and nothing outside the tags. Never merge, drop, reorder or add a section."
  }

  static func unwrap(_ text: String, expected: Int) -> [String]? {
    guard expected > 0 else { return nil }
    let matches = section.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard matches.count == expected else { return nil }
    var cursor = text.startIndex
    var bodies: [String] = []
    for (index, match) in matches.enumerated() {
      guard let range = Range(match.range, in: text),
        let id = Range(match.range(at: 1), in: text),
        let bodyRange = Range(match.range(at: 2), in: text),
        text[id] == String(index + 1),
        text[cursor..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      let body = String(text[bodyRange])
      guard tag.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) == nil else {
        return nil
      }
      bodies.append(transformLiterals(body, escaping: false).trimmingCharacters(in: .whitespacesAndNewlines))
      cursor = range.upperBound
    }
    guard text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return bodies
  }
}
