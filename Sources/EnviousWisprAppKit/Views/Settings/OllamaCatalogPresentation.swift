import EnviousWisprLLM
import Foundation

/// #1914: how the **Manage Models** list is split for display, and what each row
/// may show.
///
/// This is the list where models are downloaded and deleted. It is NOT the model
/// selection dropdown, which renders `LLMModelInfo` from discovery and gains its
/// own grouping in a later change.
///
/// Lives in AppKit rather than in `EnviousWisprLLM` because it is presentation
/// policy — grouping, column visibility and heading copy. Putting it beside the
/// daemon client would widen that module's public API with UI concerns and let
/// a non-UI caller depend on a heading string.
///
/// It is nonetheless PRODUCTION code rather than an inline filter in the view.
/// An earlier version of these tests wrote their own `isRemote` predicate, so
/// they proved only that the copy worked; changing the real split could not fail
/// them. Now a mutation to this type does fail them.
///
/// The boundary that buys, stated exactly: these tests protect the GROUPING AND
/// VISIBILITY POLICY. They do NOT protect the SwiftUI wiring — if the view
/// stopped calling this type, or rendered the hosted group in the wrong place,
/// the tests would still pass. That half is a Live UAT item.
enum OllamaCatalogPresentation {

  /// The Manage Models list, split for display.
  struct Groups {
    /// Rows that run on this Mac. Keep their existing order and metadata.
    let local: [OllamaModelCatalogEntry]
    /// Rows Ollama proxies to its own servers, shown under their own heading.
    let hosted: [OllamaModelCatalogEntry]
  }

  /// Heading for the hosted group. A statement of where the model runs, not a
  /// warning: per the founder's 2026-08-01 doctrine correction there is no
  /// interstitial and no discouragement of the hosted path.
  static let hostedGroupTitle = "Runs on Ollama's servers"

  static func groups(from catalog: [OllamaModelCatalogEntry]) -> Groups {
    Groups(
      local: catalog.filter { !$0.isRemote },
      hosted: catalog.filter(\.isRemote)
    )
  }

  /// Size and quality are meaningless for a model that is not on this disk. A
  /// hosted row's reported `size` is manifest-only (316 bytes for a
  /// 158-billion-parameter model, measured 2026-08-01), so showing it is worse
  /// than showing nothing.
  static func showsSizeAndQuality(_ entry: OllamaModelCatalogEntry) -> Bool {
    !entry.isRemote
  }
}
