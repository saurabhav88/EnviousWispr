import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4473 plan §3.1.1 S9. Bug class: removing an EG-1 size leaves the app on a size that is
/// gone (polish silently stops), moves a user who removed a size they do not use, or picks a
/// bigger model than the Mac was advised. Encounter: every press of a size card's Remove.
@Suite("Removing an EG-1 size moves the preference by one rule (#4473)", .tags(.productOutcome))
@MainActor
struct EGOneSizeRemovalTests {
  typealias Outcome = EGOneSizeRemoval.Outcome

  @Test("removing a size that is not the preference changes nothing")
  func anUnusedSizeChangesNothing() {
    for preference in EGOneSize.allCases {
      for removing in EGOneSize.allCases where removing != preference {
        for recommendation in EGOneSize.allCases {
          #expect(
            EGOneSizeRemoval.outcome(
              removing: removing, preference: preference, installed: Set(EGOneSize.allCases),
              recommendation: recommendation) == .preferenceUnchanged)
        }
      }
    }
  }

  @Test("the recommended size takes over when it is installed, and never the removed size")
  func theRecommendationTakesOver() {
    #expect(
      EGOneSizeRemoval.outcome(
        removing: .full, preference: .full, installed: [.full, .mini, .micro],
        recommendation: .micro) == .moveTo(.micro))
    // The removed size is still on disk and is the recommendation: it is not a candidate.
    #expect(
      EGOneSizeRemoval.outcome(
        removing: .mini, preference: .mini, installed: [.full, .mini, .micro],
        recommendation: .mini) == .moveTo(.micro))
  }

  @Test("without the recommendation the nearest installed size takes over, the smaller on a tie")
  func theNearestSizeTakesOver() {
    // Mini removed, full and Micro both one step away: the smaller one.
    #expect(
      EGOneSizeRemoval.outcome(
        removing: .mini, preference: .mini, installed: [.full, .micro, .mini],
        recommendation: .mini) == .moveTo(.micro))
    // Micro removed, recommendation not installed: Mini is nearer than full.
    #expect(
      EGOneSizeRemoval.outcome(
        removing: .micro, preference: .micro, installed: [.full, .mini],
        recommendation: .micro) == .moveTo(.mini))
    #expect(
      EGOneSizeRemoval.outcome(
        removing: .full, preference: .full, installed: [.full, .micro],
        recommendation: .mini) == .moveTo(.micro))
  }

  @Test("with no other size installed EG-1 is left and the preference returns to the recommendation")
  func theLastSizeLeavesEGOne() {
    for removing in EGOneSize.allCases {
      #expect(
        EGOneSizeRemoval.outcome(
          removing: removing, preference: removing, installed: [removing],
          recommendation: .mini) == .leaveEGOne(resetPreferenceTo: .mini))
    }
    // No stored preference reads as the full size.
    #expect(
      EGOneSizeRemoval.outcome(
        removing: .full, preference: nil, installed: [.full], recommendation: .micro)
        == .leaveEGOne(resetPreferenceTo: .micro))
  }

  @Test("applying an outcome writes only what the outcome names")
  func applyingAnOutcome() throws {
    func settings() -> SettingsManager {
      let name = "ew.eg1.removal.\(UUID().uuidString)"
      let defaults = TestDefaults.suite(name)!
      defaults.removePersistentDomain(forName: name)
      let s = SettingsManager(defaults: defaults)
      s.llmProvider = .egOne
      s.fileImportLLMProvider = .egOne
      s.meetingSummaryLLMProvider = .openAI
      s.selectEGOneSize(.full)
      return s
    }
    let unchanged = settings()
    EGOneSizeActions.apply(.preferenceUnchanged, to: unchanged)
    #expect(unchanged.egOneSize == .full && unchanged.llmProvider == .egOne)

    let moved = settings()
    EGOneSizeActions.apply(.moveTo(.micro), to: moved)
    #expect(moved.egOneSize == .micro)
    #expect(moved.llmProvider == .egOne && moved.fileImportLLMProvider == .egOne)

    let left = settings()
    EGOneSizeActions.apply(.leaveEGOne(resetPreferenceTo: .mini), to: left)
    #expect(left.egOneSize == .mini)
    #expect(left.llmProvider == .appleIntelligence)
    #expect(left.fileImportLLMProvider == .appleIntelligence)
    #expect(left.meetingSummaryLLMProvider == .openAI)
  }
}
