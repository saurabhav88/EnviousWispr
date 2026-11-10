import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Why a session refused a request's instruction prefix. The request did not run.
package enum EnviousDecodeInstructionPrefixRefusal: Equatable, Sendable {
  case empty
  /// The request is not longer than the prefix: there would be nothing left to prefill.
  case notShorterThanPrompt(prefix: Int, prompt: Int)
  /// The request does not start with the prefix tokens.
  case notAPrefix(firstDifference: Int)
}

package enum EnviousDecodeSessionError: Error, Equatable, Sendable {
  /// The folder's model is not one this engine can run with a draft model. Nothing else is
  /// loaded in its place.
  case targetUnsupported(modelType: String)
  /// The request cannot run. `reason` names the rule that failed, for a log line.
  case requestRefused(reason: String)
  case instructionPrefixRefused(EnviousDecodeInstructionPrefixRefusal)
}

/// What one request produced.
package struct EnviousDecodeResult: Equatable, Sendable {
  /// Every generated token in order. RAW: when the request ended on a stop token, that token
  /// is the last entry.
  package let tokenIDs: [Int]
  /// True when a stop token ended the request; false when the output cap did.
  package let endedOnStopToken: Bool
  /// Prompt tokens that came from the instruction snapshot and were not prefilled again.
  /// 0 for a request with no instruction prefix.
  package let restoredPrefixTokens: Int
}

/// One loaded pair of models (the polish model and its matched draft model) and the saved
/// state of the instruction text the last request named. This is the helper's only way into
/// the engine: it gives and takes token ids and plain values, never arrays, models or caches.
///
/// NOT thread-safe, on purpose. It holds no lock and starts no task. Its owner must run every
/// operation one after another: two requests at once would write the same model state. The
/// owner also sets the process's MLX memory limits before `load`; this type changes no
/// global setting.
///
/// The models cannot be replaced: a session is one pair for its whole life. The snapshot
/// belongs to that pair and is discarded before the models are released.
package final class EnviousDecodeSession {
  private let target: any DFlashTargetModel
  private let draft: DFlashDraftModel
  /// At most one: the state after the instruction prefix of the last request that named one.
  private var instructionSnapshot: DFlashPrefixSnapshot?

  private init(target: any DFlashTargetModel, draft: DFlashDraftModel) {
    self.target = target
    self.draft = draft
  }

  deinit {
    // The snapshot holds state of these two models: it goes first.
    instructionSnapshot = nil
  }

  /// Loads the pair from two local folders. Nothing is downloaded and nothing is substituted:
  /// the polish model is the type its own `config.json` names, built by the library's model
  /// registry, and every weight file must fit it exactly (the library's strict loader, which
  /// also applies the folder's quantization settings); the draft model is loaded by
  /// `DFlashDraftLoader`. Any failure is thrown.
  ///
  /// Async only because the library's registry is an actor. It starts no task of its own.
  package static func load(
    targetDirectory: URL, draftDirectory: URL
  ) async throws -> EnviousDecodeSession {
    let configuration = try Data(
      contentsOf: targetDirectory.appendingPathComponent("config.json"))
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: configuration)
    let model = try await LLMTypeRegistry.shared.createModel(
      configuration: configuration, modelType: base.modelType)
    guard let target = model as? any DFlashTargetModel else {
      throw EnviousDecodeSessionError.targetUnsupported(modelType: base.modelType)
    }
    try await loadWeights(
      modelDirectory: targetDirectory, model: model, quantization: base.quantization,
      perLayerQuantization: base.perLayerQuantization, weightFileSelection: .allFilesPresent)
    let draft = try DFlashDraftLoader.load(from: draftDirectory)
    // Inference mode, before any snapshot or request. The library runs its fast gated-delta
    // kernel only when the model is not in training mode.
    target.train(false)
    draft.train(false)
    return EnviousDecodeSession(target: target, draft: draft)
  }

  /// True when both models are in inference mode. For tests.
  var modelsAreInInferenceMode: Bool {
    !target.training && !draft.training
  }

  /// The tokens of the instruction prefix whose state is saved now, if any. For tests.
  var savedInstructionPrefix: [Int]? { instructionSnapshot?.tokenIDs }

  /// Runs one request to its end and returns its tokens.
  ///
  /// - Parameters:
  ///   - promptTokenIDs: the whole prompt.
  ///   - maxNewTokens: the output cap; a stop token counts.
  ///   - stopTokenIDs: tokens that end the request.
  ///   - suppressTokenIDs: tokens that are never generated.
  ///   - instructionPrefixTokenIDs: the prompt's leading tokens that are the instruction text.
  ///     nil runs the request cold and leaves the saved snapshot as it is. With a prefix, the
  ///     request starts from that prefix's saved state: the saved one when the tokens are
  ///     exactly the same, otherwise a new one that REPLACES it. Only this named prefix is ever
  ///     saved, never the request's own text. A prefix that does not fit the request is
  ///     refused and the request does not run: it is never run cold instead.
  /// - Throws: `EnviousDecodeSessionError`; `CancellationError` when the surrounding task is
  ///   cancelled (the saved snapshot stays usable).
  package func generate(
    promptTokenIDs: [Int], maxNewTokens: Int, stopTokenIDs: [Int],
    suppressTokenIDs: [Int]? = nil, instructionPrefixTokenIDs: [Int]? = nil
  ) throws -> EnviousDecodeResult {
    var snapshot: DFlashPrefixSnapshot?
    if let prefix = instructionPrefixTokenIDs {
      // Checked against this request before anything is captured or replaced, so a prefix
      // that does not fit leaves the saved snapshot untouched.
      guard !prefix.isEmpty else {
        throw EnviousDecodeSessionError.instructionPrefixRefused(.empty)
      }
      guard prefix.count < promptTokenIDs.count else {
        throw EnviousDecodeSessionError.instructionPrefixRefused(
          .notShorterThanPrompt(prefix: prefix.count, prompt: promptTokenIDs.count))
      }
      if let firstDifference = zip(prefix, promptTokenIDs).enumerated().first(where: {
        $0.element.0 != $0.element.1
      })?.offset {
        throw EnviousDecodeSessionError.instructionPrefixRefused(
          .notAPrefix(firstDifference: firstDifference))
      }
      if instructionSnapshot?.tokenIDs != prefix {
        // Another instruction text: the old state is dropped before the new one is made, so
        // the two are never held together and a failed capture leaves none.
        instructionSnapshot = nil
        instructionSnapshot = try Self.mapped {
          try DFlashPrefixSnapshot.capture(target: target, draft: draft, tokens: prefix)
        }
      }
      snapshot = instructionSnapshot
    }

    var tokenIDs: [Int] = []
    var summary: DFlashSummary?
    try Self.mapped {
      try DFlashRuntime.generateStreaming(
        targetModel: target, draftModel: draft, promptTokens: promptTokenIDs,
        maxNewTokens: maxNewTokens, stopTokenIDs: stopTokenIDs,
        suppressTokenIDs: suppressTokenIDs, prefixSnapshot: snapshot,
        yield: { event in
          if case .token(let tokenID, _, _, _) = event { tokenIDs.append(tokenID) }
          if case .summary(let value) = event { summary = value }
        })
    }
    guard let summary else {
      throw EnviousDecodeSessionError.requestRefused(reason: "the run ended with no summary")
    }
    let endedOnStopToken =
      switch summary.finishReason {
      case .stop: true
      case .length: false
      }
    return EnviousDecodeResult(
      tokenIDs: tokenIDs, endedOnStopToken: endedOnStopToken,
      restoredPrefixTokens: summary.restoredPrefixTokens)
  }

  /// Runs `body` and turns the engine's own error types into the session's. The engine's types
  /// stay inside the kit. Every other error (cancellation, a library error) passes unchanged.
  private static func mapped<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as DFlashRuntimeError {
      throw EnviousDecodeSessionError.requestRefused(reason: String(describing: error))
    } catch let error as DFlashPrefixSnapshotError {
      switch error {
      case .emptyPrefix:
        throw EnviousDecodeSessionError.instructionPrefixRefused(.empty)
      case .promptNotLongerThanPrefix(let prefix, let prompt):
        throw EnviousDecodeSessionError.instructionPrefixRefused(
          .notShorterThanPrompt(prefix: prefix, prompt: prompt))
      case .prefixMismatch(let firstDifference):
        throw EnviousDecodeSessionError.instructionPrefixRefused(
          .notAPrefix(firstDifference: firstDifference))
      case .modelMismatch:
        throw EnviousDecodeSessionError.requestRefused(
          reason: "the instruction snapshot belongs to other models")
      }
    }
  }
}
