import ArgmaxOSS
import CryptoKit
import EnviousDecodeKit
import Foundation

/// The loaded model folder's tokenizer and template identity, in the form the kit's request
/// mapper takes. The kit holds no tokenizer: this is the one place the helper touches one.
///
/// The tokenizer is the folder's own `tokenizer.json`, read through the public Argmax surface
/// the app's word checker already uses. `strict: false` is that surface's own setting for a
/// tokenizer class name it does not list (the candidate folders say `Qwen2Tokenizer` or
/// `Qwen3_5Tokenizer` over the same `tokenizer.json`); no class name is rewritten here.
/// The chat template is not interpreted. Its file is hashed, and the kit renders a prompt only
/// for a template it knows by that hash.
enum HelperTokenizer {
  static let templateFileName = "chat_template.jinja"

  struct Loaded {
    let tokenizer: EnviousDecodeTokenizer
    let configuration: EnviousDecodeRequestConfiguration
  }

  /// - Throws: when the folder has no usable tokenizer or template file, when the template is
  ///   not one the kit knows, or when the tokenizer lacks a stop token.
  static func load(
    modelFolder: URL, modelName: String, contextTokens: Int
  ) async throws -> Loaded {
    let wrapper = try await AutoTokenizerWrapper.from(modelFolder: modelFolder, strict: false)
    let template = try Data(contentsOf: modelFolder.appendingPathComponent(templateFileName))
    let templateSHA256 = SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined()
    let configuration = try EnviousDecodeRequestConfiguration(
      modelName: modelName, templateSHA256: templateSHA256, contextTokens: contextTokens,
      tokenID: { wrapper.convertTokenToId($0) })
    return Loaded(
      tokenizer: EnviousDecodeTokenizer(
        encode: { wrapper.encode(text: $0, addSpecialTokens: false) },
        decode: { wrapper.decode(tokens: $0, skipSpecialTokens: false) }),
      configuration: configuration)
  }
}
