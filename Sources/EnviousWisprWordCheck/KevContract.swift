import Foundation

/// `kev-contract.json`, shipped inside the admitted model folder (#3242). It carries everything
/// that must match how the checkpoint was trained and qualified, so the app hard-codes none of
/// it: the approval cutoff, the exact question wording (Kev binds the instruction and option
/// strings it was fine-tuned on), and the five reused Qwen control tokens that frame a record.
public struct KevContract: Codable, Sendable, Equatable {
  public struct Question: Codable, Sendable, Equatable {
    public let instructions: String
    public let no: String
    public let yes: String
  }

  public struct SpecialTokens: Codable, Sendable, Equatable {
    public let state: String
    public let question: String
    public let optionOpen: String
    public let optionClose: String
    public let decide: String
  }

  public let format: String
  public let revision: String
  public let threshold: Double
  public let question: Question
  public let specialTokens: SpecialTokens
  public let headDim: Int

  public static let supportedFormat = "kev-mlx-v1"

  public enum ContractError: Error, Equatable {
    case unsupportedFormat(String)
    case thresholdOutOfRange
    case headDimInvalid
  }

  public static func load(from folder: URL) throws -> KevContract {
    let data = try Data(contentsOf: folder.appendingPathComponent("kev-contract.json"))
    let contract = try JSONDecoder().decode(KevContract.self, from: data)
    try contract.validate()
    return contract
  }

  public func validate() throws {
    guard format == Self.supportedFormat else { throw ContractError.unsupportedFormat(format) }
    guard threshold.isFinite, (0...1).contains(threshold) else {
      throw ContractError.thresholdOutOfRange
    }
    guard headDim > 0 else { throw ContractError.headDimInvalid }
  }
}
