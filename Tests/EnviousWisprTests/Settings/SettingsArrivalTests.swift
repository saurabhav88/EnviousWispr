import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Arrival after a search navigation (#3482 plan §3.4). When this fails, choosing a result opens
/// the right page but never shows the setting, rings the wrong control, replays an old arrival
/// after a remount, or lands on a fallback while the real control was only off screen.
@MainActor
@Suite("Settings search arrival (#3482)", .tags(.productOutcome))
struct SettingsArrivalTests {
  typealias Planner = SettingsArrivalPlanner

  static func reveal(_ entryID: String, token: Int = 1) throws -> SettingsReveal {
    let request = try #require(SettingsSearchRequest(entryID: entryID))
    return SettingsReveal(
      entryID: entryID, anchor: request.target, fallbacks: request.fallbacks, token: token)
  }

  @Test("nothing happens without a reveal, for a handled token, or on another page or tab")
  func noArrival() throws {
    let reveal = try Self.reveal("pauseDuration", token: 3)
    #expect(
      Planner.decide(
        reveal: nil, showing: true, mounted: [.pauseDuration], handledToken: nil,
        canMaterialize: false) == .none)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [.pauseDuration], handledToken: 3,
        canMaterialize: false) == .none, "a handled token arrived again")
    #expect(
      Planner.decide(
        reveal: reveal, showing: false, mounted: [.pauseDuration], handledToken: nil,
        canMaterialize: false) == .none, "arrived while another tab was showing")
  }

  @Test("an empty control inventory waits; it is never read as 'hidden'")
  func emptyInventoryWaits() throws {
    let reveal = try Self.reveal("pauseDuration")
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [], handledToken: nil, canMaterialize: false)
        == .wait)
  }

  @Test("the chosen control when it is on the page, else the first declared fallback on it")
  func anchorThenFallback() throws {
    let reveal = try Self.reveal("pauseDuration")
    try #require(!reveal.fallbacks.isEmpty, "pauseDuration declares a fallback")
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [reveal.anchor, reveal.fallbacks[0]],
        handledToken: nil, canMaterialize: false) == .arrive(reveal.anchor, isFallback: false))
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [reveal.fallbacks[0], .windowSearch],
        handledToken: nil, canMaterialize: false)
        == .arrive(reveal.fallbacks[0], isFallback: true))
  }

  @Test("lazy content is scrolled to its top before any fallback; then a missing place faults")
  func materializeBeforeFallback() throws {
    let reveal = try Self.reveal("yourWords.export")
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [.enableDictionary], handledToken: nil,
        canMaterialize: true) == .materialize)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [.enableDictionary], handledToken: nil,
        canMaterialize: false) == .fault)
  }

  @Test("a mounted fallback never wins while lazy content may still hold the chosen control")
  func lazyPrimaryBeatsMountedFallback() throws {
    let reveal = try Self.reveal("pauseDuration")
    let fallback = try #require(reveal.fallbacks.first)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [fallback], handledToken: nil,
        canMaterialize: true) == .materialize)
    #expect(
      Planner.decide(
        reveal: reveal, showing: true, mounted: [fallback], handledToken: nil,
        canMaterialize: false) == .arrive(fallback, isFallback: true))
  }

  @Test("every committed navigation and a window close move the navigation epoch")
  func epochMoves() throws {
    var state = SettingsNavigationState()
    let start = state.epoch
    state.selectSidebar(.keybinds)
    state.apply(try #require(SettingsSearchRequest(entryID: "pauseDuration")))
    state.apply(.snippets)
    state.endWindowSession()
    #expect(state.epoch == start + 4)
    #expect(state.reveal == nil)
  }

  @Test("acknowledging clears only the matching reveal; a newer one survives")
  func acknowledgeMatchesToken() throws {
    var state = SettingsNavigationState()
    let first = try #require(SettingsSearchRequest(entryID: "pauseDuration"))
    state.apply(first)
    let firstToken = try #require(state.reveal?.token)
    state.apply(first)
    let secondToken = try #require(state.reveal?.token)
    #expect(secondToken != firstToken, "choosing the same result again reused its token")
    state.acknowledgeReveal(token: firstToken)
    #expect(state.reveal?.token == secondToken, "a stale acknowledgement cleared the newer reveal")
    state.acknowledgeReveal(token: secondToken)
    #expect(state.reveal == nil)
  }

  @Test("a direct tab change ends the arrival and its ring; the tab a search opened does not")
  func tabChanges() throws {
    var state = SettingsNavigationState()
    state.apply(try #require(SettingsSearchRequest(entryID: "pauseDuration")))
    let afterSearch = state.epoch
    // The search request set the tab itself: its own arrival survives the tab-change hook.
    state.noteTabChange()
    #expect(state.reveal != nil)
    #expect(state.epoch == afterSearch)
    // The person picks another tab.
    state.dictationTab = state.dictationTab == .engine ? .microphone : .engine
    state.noteTabChange()
    #expect(state.reveal == nil, "the arrival survived a change to another tab")
    #expect(state.epoch == afterSearch + 1, "the ring would survive a direct tab change")
    // After an acknowledged arrival (no reveal left), a direct change still ends the ring.
    state.noteTabChange()
    #expect(state.epoch == afterSearch + 2)
  }

  @Test("the Dictionary tab is part of what 'showing' means")
  func dictionaryTabShowing() throws {
    var state = SettingsNavigationState()
    let request = try #require(SettingsSearchRequest(entryID: "quickAdd.shortcut"))
    state.apply(request)
    #expect(state.dictionaryTab == .quickAdd)
    #expect(state.isShowing(request.destination, dictionaryTab: request.dictionaryTab))
    state.dictionaryTab = .yourWords
    #expect(state.isShowing(request.destination, dictionaryTab: request.dictionaryTab) == false)
  }

  @Test("arrival announcements name the chosen place, and the fallback when one opened")
  func announcements() {
    #expect(SettingsSearchCopy.arrived("Pause duration") == "Showing Pause duration")
    #expect(
      SettingsSearchCopy.arrivedAtFallback(landed: "Stop recording", chosen: "Pause duration")
        == "Showing Stop recording for Pause duration")
  }
}
