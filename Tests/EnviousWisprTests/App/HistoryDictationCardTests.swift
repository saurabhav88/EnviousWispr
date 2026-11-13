import EnviousWisprCore
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3147 §3.4: the dictation card's drawing rules. What fails when these fail is a marked word
/// that opens the wrong change (or none), a removed word that is not struck through, a screen
/// reader that hears marks as nothing, or a comparison from another version of the text.
@MainActor
@Suite("History dictation card (#3147)", .tags(.productOutcome))
struct HistoryDictationCardTests {

  typealias P = HistoryDictationPresentation

  private static func texts(_ original: String, _ polished: String) -> P.Texts {
    P.Texts(original: original, polished: polished, language: nil)
  }

  @Test("each marked run links to its own change, and only that change")
  func changeLinks() throws {
    let prepared = P.prepare(Self.texts("we gonna ship it", "We are going to ship it"))
    let text = HistoryParagraphText.attributed(prepared.markedUp)
    var linked: [Int: String] = [:]
    for run in text.runs {
      guard let url = run.link else { continue }
      let index = try #require(HistoryParagraphText.changeIndex(from: url))
      linked[index, default: ""] += String(text[run.range].characters)
    }
    #expect(linked.keys.sorted() == [0])
    #expect(linked[0] == "we gonnaWe are going to")
    // Another scheme is never treated as a change.
    #expect(
      HistoryParagraphText.changeIndex(from: try #require(URL(string: "https://x.test/0"))) == nil)
    #expect(HistoryParagraphText.changeURL(7).flatMap(HistoryParagraphText.changeIndex) == 7)
  }

  @Test("removed words are struck in the removal colour; added words are tinted and bold")
  func markStyles() {
    let prepared = P.prepare(Self.texts("so um yes", "so yes indeed"))
    let text = HistoryParagraphText.attributed(prepared.markedUp)
    var struck = ""
    var added = ""
    for run in text.runs {
      let words = String(text[run.range].characters)
      if run.strikethroughStyle != nil {
        struck += words
        #expect(run.foregroundColor == MarkUpPalette.removed)
      }
      if run.backgroundColor != nil {
        added += words
        #expect(run.backgroundColor == MarkUpPalette.changedBackground)
        #expect(run.inlinePresentationIntent == MarkUpPalette.changedIntent)
        // Weight by intent, never a font that would resize the run.
        #expect(run.font == nil)
      }
    }
    #expect(struck == "um")
    #expect(added == "indeed")
  }

  @Test("a screen reader hears the marks as words and gets one action per change")
  func accessibility() {
    let prepared = P.prepare(Self.texts("so um yes", "so yes indeed"))
    let spoken = HistoryParagraphText.accessibilityText(prepared.markedUp)
    #expect(spoken.contains("um"))
    #expect(spoken.contains("indeed"))
    #expect(spoken.contains("so"))
    #expect(HistoryParagraphText.changeIndices(prepared.markedUp) == [0, 1])
    #expect(
      HistoryParagraphText.accessibilityActionName(prepared.markedUp, change: 0).contains("um"))
  }

  @Test("the inspector quotes each side and names an empty one")
  func inspectorQuotes() {
    #expect(HistoryChangeInspector.quoted("gonna", empty: "nothing") == "“gonna”")
    #expect(HistoryChangeInspector.quoted("", empty: "nothing") == "(nothing)")
  }

  @Test("the comparison cache answers only for the exact texts, and forgets the oldest first")
  func diffCache() {
    let cache = HistoryDiffCache(limit: 2)
    let a = Self.texts("a um", "a")
    let b = Self.texts("b um", "b")
    let c = Self.texts("c um", "c")
    cache.store(P.prepare(a))
    cache.store(P.prepare(b))
    #expect(cache.result(for: a)?.texts == a)  // touching a makes b the oldest
    cache.store(P.prepare(c))
    #expect(cache.count == 2)
    #expect(cache.result(for: b) == nil)
    #expect(cache.result(for: a) != nil)
    // Another Unicode spelling of the same words is other content: no hit.
    let composed = Self.texts("caf\u{00E9}", "caf\u{00E9}!")
    cache.store(P.prepare(composed))
    #expect(cache.result(for: Self.texts("caf\u{00E9}", "cafe\u{0301}!")) == nil)
  }

  @Test("the background preparation returns the same comparison as the direct one")
  func backgroundPreparation() async {
    let t = Self.texts("so um the numbers are up", "So the numbers are up.")
    let background = await P.prepareInBackground(t)
    #expect(background == P.prepare(t))
  }
}
