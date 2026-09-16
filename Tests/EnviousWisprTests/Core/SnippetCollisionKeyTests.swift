import Foundation
import Testing

@testable import EnviousWisprCore

/// #2997 — `Snippet.collisionKey` is the one definition of "the same spoken words".
///
/// `.driftGuard`: `collidesWith` is re-expressed through the key, and the import's review
/// builder and locked commit index on it. This pins that the key agrees with the token-array
/// compare it replaced, so the two can never drift; the user-facing outcome (a duplicate
/// refused, an expansion firing) is carried by the store and expander suites.
@Suite("Snippet collision key (#2997)", .tags(.driftGuard))
struct SnippetCollisionKeyTests {

  /// Written out here rather than borrowed from `SnippetExpanderTests`: that suite's
  /// triggers are its own fixtures and this suite must not depend on their shape. Each
  /// entry is a class of input `SnippetText.normalize` treats differently (case, leading
  /// and trailing punctuation, doubled whitespace, quotes, sentence enders, joined words,
  /// symbols, line breaks, and the empty forms).
  private static let corpus: [String] = [
    "my email address", "My Email Address", "\"my email address\"", "my email address.",
    "my  email   address", " my email address ", "(my email address)", "sign off",
    "signoff", "my email", "address", "...", "", "   ", "\u{201C}quoted\u{201D}",
    "line one\nline two", "C++", "e-mail", "email!", "email?",
  ]

  @Test("collidesWith equals key equality over the trigger corpus, both directions")
  func collidesWithEqualsKeyEquality() {
    let snippets = Self.corpus.map { Snippet(trigger: $0, expansion: "x") }
    for a in snippets {
      for b in snippets {
        let byKey = a.collisionKey != nil && a.collisionKey == b.collisionKey
        #expect(a.collidesWith(b) == byKey, Comment(rawValue: "\(a.trigger) vs \(b.trigger)"))
        // The token-array definition this replaced, kept here as the oracle.
        let byTokens = !a.triggerTokens.isEmpty && a.triggerTokens == b.triggerTokens
        #expect(byKey == byTokens, Comment(rawValue: "\(a.trigger) vs \(b.trigger)"))
      }
    }
  }

  @Test("A trigger with no spoken tokens has no key and collides with nothing, itself included")
  func emptyTriggerHasNoKey() {
    for trigger in ["", "   ", "...", "\"\"", "()"] {
      let snippet = Snippet(trigger: trigger, expansion: "x")
      #expect(snippet.collisionKey == nil, Comment(rawValue: trigger))
      #expect(snippet.collidesWith(snippet) == false, Comment(rawValue: trigger))
    }
  }

  @Test("The key is injective over token arrays: joining cannot merge two different arrays")
  func keyIsInjective() {
    // Every token is non-empty and whitespace-free, so a single space is an unambiguous
    // separator. Two arrays that differ produce different keys.
    let a = Snippet(trigger: "my email", expansion: "x")
    let b = Snippet(trigger: "myemail", expansion: "x")
    let c = Snippet(trigger: "my e mail", expansion: "x")
    #expect(a.collisionKey == "my email")
    #expect(b.collisionKey == "myemail")
    #expect(c.collisionKey == "my e mail")
    #expect(Set([a.collisionKey, b.collisionKey, c.collisionKey].compactMap { $0 }).count == 3)
  }
}
