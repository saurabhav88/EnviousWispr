import Foundation

/// The Parakeet model a load request names (#3546).
///
/// Only `v3` exists until the shipping FluidAudio pin can load another model,
/// so no request can name a model the loader would quietly replace with v3.
/// `EnviousWisprASR` is the only module that maps this to a FluidAudio version.
package enum ParakeetModel: String, Sendable, Equatable {
  case v3

  /// The shipped v3 set's byte total, for the one caller with no manifest to
  /// read it from: the engine adapter when the bundled manifest failed to load.
  /// A test pins it to the bundled manifest's `totalBytes`.
  package static let v3ShippedBytes: Int64 = 483_256_769
}

/// One complete Parakeet load request (#3546).
///
/// It replaces two separately set manager properties, `parakeetCacheOnly` and
/// `parakeetModelDirectory`, which could be read in a state where only one of
/// them had been written. A load now reads one of these, so the directory and
/// the mode it loads with always come from the same decision.
package struct ParakeetModelSelection: Sendable, Equatable {
  package let model: ParakeetModel
  /// The model revision, or `nil` when no manifest was loaded to name it.
  package let revision: String?
  /// The install directory the host chose. Never FluidAudio's shared cache.
  package let directory: URL
  /// Delivery-managed load: the host admitted verified bytes first, and the
  /// loader may never download.
  package let cacheOnly: Bool
  /// The byte total shown in download progress.
  package let displayBytes: Int64
  /// Whether a failed cache-only load may get the delivery repair pass.
  package let repairable: Bool
  /// Which `select` call produced this request.
  package let generation: UInt64

  package init(
    model: ParakeetModel, revision: String?, directory: URL, cacheOnly: Bool,
    displayBytes: Int64, repairable: Bool, generation: UInt64
  ) {
    self.model = model
    self.revision = revision
    self.directory = directory
    self.cacheOnly = cacheOnly
    self.displayBytes = displayBytes
    self.repairable = repairable
    self.generation = generation
  }
}

/// Holds the current Parakeet load request (#3546).
///
/// One instance is shared by the engine adapter, which writes it, and the ASR
/// manager, which reads it at every physical load, including loads that do not
/// pass through the adapter (`ActiveEngineOperation.load`). It holds the request
/// only; it owns no fetching, loading or retry policy.
///
/// `nil` means nobody has said where the model is, or the location was REFUSED.
/// Both make the load throw `ParakeetModelDirectoryUnsetError` rather than guess
/// a directory (#2697).
@MainActor
package final class ParakeetSelectionProvider {
  package private(set) var current: ParakeetModelSelection?
  private var lastGeneration: UInt64 = 0

  package init() {}

  /// Publishes one complete request and returns it.
  @discardableResult
  package func select(
    model: ParakeetModel, revision: String?, directory: URL, cacheOnly: Bool,
    displayBytes: Int64, repairable: Bool
  ) -> ParakeetModelSelection {
    lastGeneration &+= 1
    let selection = ParakeetModelSelection(
      model: model, revision: revision, directory: directory, cacheOnly: cacheOnly,
      displayBytes: displayBytes, repairable: repairable, generation: lastGeneration)
    current = selection
    return selection
  }

  /// Removes the request, so no later load can reuse a location that was
  /// refused. The generation counter keeps counting.
  package func clear() {
    current = nil
  }
}
