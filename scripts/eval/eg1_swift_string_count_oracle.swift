import Darwin
import Foundation

// Long-lived stdin/stdout oracle for Swift/Foundation Unicode parity.
// Request: operation<TAB>base64-encoded UTF-8. Response: operation<TAB>payload.
while let line = readLine() {
  let request = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
  guard request.count == 2,
    let data = Data(base64Encoded: String(request[1])),
    let value = String(data: data, encoding: .utf8)
  else {
    print("error")
    fflush(stdout)
    continue
  }
  let operation = String(request[0])
  switch operation {
  case "count":
    print("count\t\(value.count)")
  case "text-metrics":
    let metrics: [String: Int] = [
      "nonWhitespaceScalarCount": value.unicodeScalars.filter { !$0.properties.isWhitespace }.count,
      "wordCount": value.split(whereSeparator: \.isWhitespace).count,
    ]
    guard let result = try? JSONSerialization.data(withJSONObject: metrics) else {
      print("error")
      fflush(stdout)
      continue
    }
    print("text-metrics\t\(result.base64EncodedString())")
  case "question-words":
    let words = value.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    let records = words.map {
      [$0, $0.trimmingCharacters(in: .punctuationCharacters)]
    }
    guard let result = try? JSONSerialization.data(withJSONObject: records) else {
      print("error")
      fflush(stdout)
      continue
    }
    print("question-words\t\(result.base64EncodedString())")
  case "trim-whitespace-newlines":
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    print("trim-whitespace-newlines\t\(Data(result.utf8).base64EncodedString())")
  case "trim-whitespace-lowercase":
    let result = value.trimmingCharacters(in: .whitespaces).lowercased()
    print("trim-whitespace-lowercase\t\(Data(result.utf8).base64EncodedString())")
  default:
    print("error")
  }
  fflush(stdout)
}
