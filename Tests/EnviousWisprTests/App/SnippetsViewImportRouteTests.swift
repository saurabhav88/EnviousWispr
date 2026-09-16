import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2997 — the Snippets page presents ONE sheet at a time through one route.
///
/// `.productOutcome`: when this fails the Import button opens nothing, or two sheets fight
/// for the same presentation.
@Suite("Snippets page sheet route (#2997)", .tags(.productOutcome))
struct SnippetsViewImportRouteTests {

  @Test("Every route has a distinct identity, and each edit request is its own presentation")
  func routeIdentities() {
    let importRoute = SnippetsSheetRoute.importSnippets
    let add = SnippetsSheetRoute.edit(SnippetDraft(snippet: nil))
    let edit = SnippetsSheetRoute.edit(SnippetDraft(snippet: Snippet(trigger: "sig", expansion: "x")))
    #expect(importRoute.id == "import")
    #expect(add.id != edit.id)
    #expect(add.id != importRoute.id)
    #expect(SnippetsSheetRoute.importSnippets.id == importRoute.id, "the import sheet is one presentation")
  }
}
