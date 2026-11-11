import EnviousWisprCore
import EnviousWisprEG1Engine
import EnviousWisprLLM
import EnviousWisprLlamaEngine
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import Foundation
import os

/// The local polish models that have a learned-word checker of their own (#3105, #4473). One
/// table for delivery (manifest, folder, host prefix), eligibility and the Debug adapter
/// door, so the models cannot drift apart. Exhaustive: a model added here must state every
/// row.
///
/// The key is the exact MODEL: each EG-1 size has its own adapter, trained on that size, with
/// its own qualified threshold. A size is a key here whether or not its checker is published;
/// `published` is the separate list of the ones this build registers and delivers.
enum LearnedWordCheckerEngine: Hashable, Sendable {
  case egOne(EGOneSize)
  case s1Mini

  /// The checkers this build registers and delivers: one per EG-1 size, and S1-mini's.
  static let published: [LearnedWordCheckerEngine] = [
    .egOne(.full), .egOne(.mini), .egOne(.micro), .s1Mini,
  ]

  /// The checker of an exact model; nil for every model that has none of its own.
  init?(model: LocalPolishModelID) {
    switch model.provider {
    case .egOne:
      guard let size = model.size else { return nil }
      self = .egOne(size)
    case .s1Mini: self = .s1Mini
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none: return nil
    }
  }

  /// Whether a provider's models are checked by their own adapter (EG-1, S1-mini) and not by
  /// the shared word check. A question about the PROVIDER: it names no size.
  static func hasOwnChecker(_ provider: LLMProvider) -> Bool {
    switch provider {
    case .egOne, .s1Mini: true
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none: false
    }
  }

  var model: LocalPolishModelID {
    switch self {
    case .egOne(let size): .egOne(size)
    case .s1Mini: .singleModel(for: .s1Mini)
    }
  }

  var provider: LLMProvider { model.provider }

  /// The model whose admission owes this engine its checker download: the engine's OWN model,
  /// so an EG-1 size is never answered with another size's identity.
  func baseIdentity(
    egOne: (EGOneSize) -> ModelIdentity?, s1Mini: ModelIdentity?
  ) -> ModelIdentity? {
    switch self {
    case .egOne(let size): egOne(size)
    case .s1Mini: s1Mini
    }
  }

  var checkerFamily: ModelFamily {
    switch self {
    case .egOne(let size): EGOneArtifactCatalog.checker(size).family
    case .s1Mini: .s1MiniChecker
    }
  }

  /// The bundled, signed delivery manifest (`Project.swift` lists each published one).
  var manifestResource: String {
    switch self {
    case .egOne(.full): "eg1-mlx-checker-delivery-manifest"
    case .egOne(.mini): "eg1-mini-checker-delivery-manifest"
    case .egOne(.micro): "eg1-micro-checker-delivery-manifest"
    case .s1Mini: "s1-checker-delivery-manifest"
    }
  }

  /// Beside the base's own folder under `Application Support/EnviousWispr`.
  var installFolder: String {
    switch self {
    case .egOne(let size): "Models/" + EGOneArtifactCatalog.checker(size).installFolder
    case .s1Mini: "Models/s1-mini-checker"
    }
  }

  /// The R2 custom domain's prefix the base model already downloads from.
  var hostPathPrefix: String {
    switch self {
    case .egOne: "/eg1/"
    case .s1Mini: "/s1/"
    }
  }

  /// The checker for this model at `threshold`, asking on `runtime`. Each implementation takes
  /// its own lease for a whole request and reads the endpoint again under it.
  /// - EG-1: its adapter runs in the EnviousDecode helper (`POST /v1/wordcheck`).
  /// - S1-mini: its LoRA on llama-server, with the named-language question it was scored on.
  @MainActor
  func makeChecker(threshold: Double, language: String?, runtime: LocalPolishRuntime)
    -> any LearnedWordChecking
  {
    switch self {
    case .egOne:
      EnviousDecodeWordChecker(threshold: threshold) {
        await EnviousDecodeWordChecker.hold(on: runtime)
      }
    case .s1Mini:
      LlamaLearnedWordChecker(threshold: threshold, style: .s1Mini(language: language)) {
        await LlamaLearnedWordChecker.hold(on: runtime)
      }
    }
  }
}

/// Remembers whether each delivery identity was last seen admitted, so an
/// observer acts on a change of admission, never on a repeat of the same state.
/// Called synchronously from the delivery observer, in event order: updating it
/// from separately scheduled tasks could apply an older `.admitted` after a
/// newer removal (confirming review of #3227).
final class AdmissionEdges: Sendable {
  private let admitted = OSAllocatedUnfairLock<[ModelIdentity: Bool]>(initialState: [:])

  /// True when `isAdmitted` differs from the last value seen for `identity`
  /// (the first value seen counts as a change).
  func changed(_ identity: ModelIdentity, admitted isAdmitted: Bool) -> Bool {
    admitted.withLock { seen in
      defer { seen[identity] = isAdmitted }
      return seen[identity] != isAdmitted
    }
  }
}
