import Foundation

/// What the app tells the helper on its command line. Every value but the word-check adapter is
/// required, and each is checked before any model file is read. The bearer token is not here
/// (#4493): it is the first line of the helper's standard input, read by `HelperSecret`, so it
/// never appears in the process's arguments.
struct HelperArguments: Equatable {
  /// The polish model's folder.
  let modelFolder: URL
  /// The draft model's folder.
  let draftFolder: URL
  /// The model name a request must ask for.
  let modelName: String
  /// The Unix socket path to listen on, inside the launch's private folder.
  let socketPath: String
  /// The most tokens a prompt and its answer may have together.
  let contextTokens: Int
  /// MLX's buffer cache limit, in bytes, set before a model is loaded.
  let cacheLimitBytes: Int
  /// The folder of the learned-word adapter for this polish model (`adapter_config.json` and
  /// `adapters.safetensors`), or nil when the helper serves no word check.
  let wordCheckAdapterFolder: URL?

  enum ParseError: Error, Equatable, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case repeated(String)
    case missing(String)
    case invalid(name: String, reason: String)

    var description: String {
      switch self {
      case .unknownArgument(let name): "unknown argument \(name)"
      case .missingValue(let name): "\(name) needs a value"
      case .repeated(let name): "\(name) is given twice"
      case .missing(let name): "\(name) is required"
      case .invalid(let name, let reason): "\(name): \(reason)"
      }
    }
  }

  static let usage =
    "usage: envious-decode --model <folder> --draft-model <folder> --model-name <name> "
    + "--socket <path> --ctx-size <tokens> --cache-limit-bytes <bytes> "
    + "[--word-check-adapter <folder>] (the bearer is the first line of standard input)"

  static let names: Set<String> = [
    "--model", "--draft-model", "--model-name", "--socket", "--ctx-size",
    "--cache-limit-bytes", wordCheckAdapterName,
  ]
  static let wordCheckAdapterName = "--word-check-adapter"

  static func parse(_ arguments: [String]) throws -> HelperArguments {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let name = arguments[index]
      guard names.contains(name) else {
        // A stray value could be the token in the wrong place, so only an option-like word is
        // named; anything else is reported by its position.
        let optionLike =
          name.hasPrefix("--") && name.dropFirst(2).allSatisfy { $0.isLetter || $0 == "-" }
        throw ParseError.unknownArgument(optionLike ? name : "at position \(index + 1)")
      }
      guard index + 1 < arguments.count else { throw ParseError.missingValue(name) }
      guard values[name] == nil else { throw ParseError.repeated(name) }
      values[name] = arguments[index + 1]
      index += 2
    }
    func value(_ name: String) throws -> String {
      guard let value = values[name] else { throw ParseError.missing(name) }
      return value
    }
    func folder(_ name: String) throws -> URL {
      let path = try value(name)
      var isDirectory: ObjCBool = false
      guard path.hasPrefix("/"),
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw ParseError.invalid(name: name, reason: "not an existing folder path") }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    func number(_ name: String, in range: ClosedRange<Int>) throws -> Int {
      guard let number = Int(try value(name)), range.contains(number) else {
        throw ParseError.invalid(
          name: name,
          reason: "must be a whole number from \(range.lowerBound) to \(range.upperBound)")
      }
      return number
    }
    let modelName = try value("--model-name")
    guard !modelName.isEmpty else {
      throw ParseError.invalid(name: "--model-name", reason: "is empty")
    }
    let socketPath = try value("--socket")
    // `sockaddr_un` holds 104 bytes with the terminator.
    guard socketPath.hasPrefix("/"), socketPath.utf8.count <= 103 else {
      throw ParseError.invalid(name: "--socket", reason: "must be an absolute path of at most 103 bytes")
    }
    return HelperArguments(
      modelFolder: try folder("--model"), draftFolder: try folder("--draft-model"),
      modelName: modelName, socketPath: socketPath,
      contextTokens: try number("--ctx-size", in: 1...1_048_576),
      cacheLimitBytes: try number("--cache-limit-bytes", in: 0...Int.max),
      wordCheckAdapterFolder: values[wordCheckAdapterName] == nil
        ? nil : try folder(wordCheckAdapterName))
  }
}
