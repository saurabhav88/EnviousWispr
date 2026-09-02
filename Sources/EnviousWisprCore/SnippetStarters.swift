import Foundation

/// The example snippets a brand-new install starts with (#628, founder 2026-09-01).
///
/// A feature whose first screen is empty has to be explained; a feature whose first screen is
/// already full of working examples explains itself. These six are written to the store once,
/// on the first launch that finds no `snippets.json`, and are ordinary snippets from that
/// moment on — editable, deletable, and never re-seeded. Deleting them all is a decision the
/// store remembers, because the file then exists and is empty.
///
/// Every one of them FIRES. A decorative example the user cannot try is a screenshot, not an
/// example, so the catalog is held to the same rules the edit sheet enforces and is checked
/// against them by its own test rather than by inspection.
///
/// Two constraints the catalog must keep, both mechanically tested:
///
/// - **No two starters collide.** `SnippetsManager.validate` refuses a duplicate trigger, so a
///   colliding pair would make the seeded file un-editable: every later save re-validates the
///   whole list and would fail on a clash the user never created.
/// - **Every expansion is one line.** A snippet carrying a newline is delivered to the
///   clipboard rather than typed in place, because in a terminal a newline submits the command.
///   That is correct behaviour and a poor first impression, so no starter has one.
public enum SnippetStarters {

  /// The canonical text of one starter, and the reason this is a separate type from `Snippet`:
  /// the id and the text are FIXED, while a `Snippet` carries a `createdAt` that is not.
  struct Starter {
    let id: UUID
    let trigger: String
    let expansion: String
  }

  /// The six, in the order a new user sees them.
  ///
  /// Every trigger begins with "my" and ends in a single common word. That is a matching
  /// decision, not a style one: the matcher compares transcript tokens literally, so a trigger
  /// whose words the speech engine might run together ("sign off" heard as "signoff") would be
  /// an example that silently does not work.
  ///
  /// The text is deliberately, visibly fictional. `example.com` is reserved for exactly this
  /// (RFC 2606) and the 555-01xx phone range is reserved for fiction, so a starter pasted into
  /// a real message by mistake reads as a placeholder rather than as someone's real address.
  static let catalog: [Starter] = [
    Starter(
      id: UUID(uuidString: "9F1C7A20-4E6B-4C31-9E2A-1D5B8F0A3C71")!,
      trigger: "my email",
      expansion: "john.doe@example.com"),
    Starter(
      id: UUID(uuidString: "3B84D0E5-6A17-4F92-8C0D-7E2A9B4F1D63")!,
      trigger: "my phone",
      expansion: "(555) 010-4477"),
    Starter(
      id: UUID(uuidString: "C6E29B14-8D3F-4A70-B5E8-2F91C7D04A56")!,
      trigger: "my address",
      expansion: "1600 Example Way, Suite 200, Springfield, IL 62704"),
    Starter(
      id: UUID(uuidString: "5A0D3F81-2C94-4E6D-A17B-8B36E5C920F4")!,
      trigger: "my calendar",
      expansion: "https://cal.example.com/john-doe"),
    Starter(
      id: UUID(uuidString: "72B4E8C0-1F5A-4D39-96C7-4A0E2D8B7F15")!,
      trigger: "my signature",
      expansion: "Thanks so much. John Doe, Product at Example Co."),
    Starter(
      id: UUID(uuidString: "E8137C6A-9B02-4F58-8D41-6C3A5E90B2D7")!,
      trigger: "my intro",
      expansion:
        "Hi, I'm John Doe. I lead product at Example Co, and I'm happy to help however I can."),
  ]

  /// The starters as storable snippets, stamped with the moment they are read.
  ///
  /// `createdAt` is the only field not fixed by the catalog, and it is deliberately taken at
  /// call time rather than frozen: the store writes these once, so the honest value is when the
  /// user's install created them.
  public static var all: [Snippet] {
    catalog.map { Snippet(id: $0.id, trigger: $0.trigger, expansion: $0.expansion) }
  }

  /// True when this snippet is a starter the user has not touched yet.
  ///
  /// Derived from the catalog rather than stored on `Snippet`, which is what keeps the badge
  /// honest with no schema field and no migration: the answer is recomputed from the text on
  /// screen, so the first edit clears it and nothing has to remember to.
  ///
  /// Both fields are compared. Matching on the id alone would keep calling a snippet an example
  /// after the user had replaced its expansion with their own address, which is the one moment
  /// the badge must be gone.
  public static func isUneditedExample(_ snippet: Snippet) -> Bool {
    guard let starter = catalog.first(where: { $0.id == snippet.id }) else { return false }
    return starter.trigger == snippet.trigger && starter.expansion == snippet.expansion
  }
}
