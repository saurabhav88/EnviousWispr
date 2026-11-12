import EnviousWisprCore
import EnviousWisprLocalPolish
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4473: the three EG-1 size cards: the measured-facts file, the presenter's card values and
/// the card copy. The view only draws these values.
@Suite("EG-1 size cards (#4473)", .tags(.productOutcome))
struct EGOneSizeCardTests {

  // MARK: - Helpers

  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Settings
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  private static let factsURL = repoRoot.appendingPathComponent(
    "Sources/EnviousWispr/Resources/eg1-size-facts.json")

  private static func measured(_ value: Int64) -> EGOneSizeFacts.Measured {
    .init(value: value, receipt: "r.json:x", measures: "m")
  }

  private static func size(
    polish: Int64? = nil, memory: Int64? = nil, english: Int64? = nil
  ) -> EGOneSizeFacts.Size {
    .init(
      englishPercent: english.map(measured), internationalPercent: nil,
      polishMilliseconds: polish.map(measured), memoryBytes: memory.map(measured))
  }

  private static func inputs(
    preferred: EGOneSize = .full,
    surfaceUsesEGOne: Bool = true,
    allowsRuntimeActivation: Bool = true,
    recommendation: EGOneSize = .full,
    installStates: [EGOneSize: EGOneInstallState] = [:],
    displayVersions: [EGOneSize: String] = [:],
    facts: EGOneSizeFacts = .none,
    physicalMemoryBytes: UInt64 = 16 << 30
  ) -> EGOneSizeCardPresenter.Inputs {
    .init(
      preferred: preferred, surfaceUsesEGOne: surfaceUsesEGOne,
      allowsRuntimeActivation: allowsRuntimeActivation, recommendation: recommendation,
      installStates: installStates, displayVersions: displayVersions, downloadBytes: [:],
      facts: facts, physicalMemoryBytes: physicalMemoryBytes)
  }

  private static func card(
    _ size: EGOneSize = .full, _ inputs: EGOneSizeCardPresenter.Inputs
  ) throws -> EGOneSizeCard {
    try #require(EGOneSizeCardPresenter.cards(inputs).first { $0.size == size })
  }

  private static let allInstallStates: [EGOneInstallState] = [
    .notInstalled,
    .downloading(fractionCompleted: 0.5, upgrade: nil),
    .verifying,
    .installed(version: "1.3"),
    .paused,
    .updatePaused(resumable: true, targetVersion: nil),
    .updatePaused(resumable: false, targetVersion: nil),
    .failed(.network),
  ]

  // MARK: - 1. The bundled facts file

  // A user would see a number on a card that nobody measured, or one with no receipt.
  @Test func bundledFactsDecodeAndNameExactlyTheThreeSizes() throws {
    let data = try Data(contentsOf: Self.factsURL)
    _ = try JSONDecoder().decode(EGOneSizeFacts.self, from: data)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let sizes = try #require(root["sizes"] as? [String: Any])
    #expect(Set(sizes.keys) == Set(EGOneSize.allCases.map(\.rawValue)))
  }

  // A user would see a number on a card that nobody measured, or one with no receipt.
  @Test func everyBundledNumberCarriesAReceiptAndPlausibleValue() throws {
    let data = try Data(contentsOf: Self.factsURL)
    let facts = try JSONDecoder().decode(EGOneSizeFacts.self, from: data)
    for size in EGOneSize.allCases {
      let f = facts.facts(for: size)
      let all: [(String, EGOneSizeFacts.Measured?)] = [
        ("englishPercent", f.englishPercent), ("internationalPercent", f.internationalPercent),
        ("polishMilliseconds", f.polishMilliseconds), ("memoryBytes", f.memoryBytes),
      ]
      for (name, m) in all {
        guard let m else { continue }
        #expect(!m.receipt.isEmpty, "\(size) \(name) needs a receipt")
        #expect(!m.measures.isEmpty, "\(size) \(name) needs a measures line")
        #expect(m.value > 0, "\(size) \(name) must be positive")
      }
      for (name, m) in [
        ("englishPercent", f.englishPercent), ("internationalPercent", f.internationalPercent),
      ] {
        if let m { #expect((1...100).contains(m.value), "\(size) \(name) is a percent") }
      }
    }
  }

  // MARK: - 2. Resource registration

  // A user would get a build with no numbers on the cards, because the file never shipped.
  @Test func factsFileIsAnAppResource() throws {
    let project = try String(
      contentsOf: Self.repoRoot.appendingPathComponent("Project.swift"), encoding: .utf8)
    #expect(project.contains("\"Sources/EnviousWispr/Resources/eg1-size-facts.json\""))
  }

  // MARK: - 3. Presenter

  // A user would see the cards in a shuffled order or two highlighted cards.
  @Test func orderIsFullMiniMicroWithOneSelectedAndOneRecommended() {
    let cards = EGOneSizeCardPresenter.cards(Self.inputs(preferred: .mini, recommendation: .micro))
    #expect(cards.map(\.size) == [.full, .mini, .micro])
    #expect(cards.filter(\.isSelected).map(\.size) == [.mini])
    #expect(cards.filter(\.isRecommended).map(\.size) == [.micro])
  }

  // A user would see a download that looks like it is idle, or a finished one that looks broken.
  @Test func stateMappingCoversEveryInstallState() throws {
    let expected: [(EGOneInstallState, EGOneSizeCard.State)] = [
      (.notInstalled, .notDownloaded),
      (.downloading(fractionCompleted: 0.25, upgrade: nil), .downloading(fraction: 0.25)),
      (.verifying, .verifying),
      (.installed(version: "1.3"), .installed),
      (.paused, .paused),
      (.updatePaused(resumable: true, targetVersion: nil), .updatePaused(resumable: true)),
      (.updatePaused(resumable: false, targetVersion: "1.4"), .updatePaused(resumable: false)),
      (.failed(.network), .failed(.network)),
    ]
    for (install, state) in expected {
      #expect(EGOneSizeCardPresenter.state(install) == state)
      let card = try Self.card(.mini, Self.inputs(installStates: [.mini: install]))
      #expect(card.state == state)
    }
  }

  // A user would see a size we cannot run on this build as broken instead of "not downloaded".
  @Test func sizeMissingFromInstallStatesReadsAsNotDownloaded() {
    let cards = EGOneSizeCardPresenter.cards(Self.inputs(installStates: [.full: .paused]))
    #expect(cards.first { $0.size == .micro }?.state == .notDownloaded)
    #expect(cards.first { $0.size == .full }?.state == .paused)
  }

  // A user would be offered the wrong button, or none.
  @Test func actionsMatchEachState() {
    typealias P = EGOneSizeCardPresenter
    #expect(
      P.actions(.notDownloaded, isSelected: true, allowsRuntimeActivation: true) == [.download])
    #expect(
      P.actions(.downloading(fraction: 0.3), isSelected: false, allowsRuntimeActivation: true) == [
        .cancel
      ])
    #expect(P.actions(.verifying, isSelected: true, allowsRuntimeActivation: true) == [])
    #expect(P.actions(.paused, isSelected: false, allowsRuntimeActivation: true) == [.resume])
    #expect(
      P.actions(.updatePaused(resumable: true), isSelected: false, allowsRuntimeActivation: true)
        == [.resumeUpgrade])
    #expect(
      P.actions(.updatePaused(resumable: false), isSelected: false, allowsRuntimeActivation: true)
        == [.finishUpgrade])
    #expect(
      P.actions(.failed(.network), isSelected: false, allowsRuntimeActivation: true) == [.tryAgain])
    #expect(
      P.actions(.installed, isSelected: true, allowsRuntimeActivation: true) == [
        .testLive, .remove,
      ])
    #expect(P.actions(.installed, isSelected: true, allowsRuntimeActivation: false) == [.remove])
    #expect(
      P.actions(.installed, isSelected: false, allowsRuntimeActivation: true) == [.remove])
    #expect(
      P.actions(.installed, isSelected: false, allowsRuntimeActivation: false) == [.remove])
  }

  // A user would see a separate "Use" button on a card again, instead of clicking the card to
  // choose it (founder 2026-11-11). The full table, written out with literals.
  @Test func noCardStateEverListsUseAndTheTableIsPinned() {
    typealias P = EGOneSizeCardPresenter
    let rows: [(EGOneSizeCard.State, Bool, Bool, [EGOneSizeCard.Action])] = [
      (.notDownloaded, true, true, [.download]), (.notDownloaded, true, false, [.download]),
      (.notDownloaded, false, true, [.download]), (.notDownloaded, false, false, [.download]),
      (.downloading(fraction: 0.5), true, true, [.cancel]),
      (.downloading(fraction: 0.5), true, false, [.cancel]),
      (.downloading(fraction: 0.5), false, true, [.cancel]),
      (.downloading(fraction: 0.5), false, false, [.cancel]),
      (.verifying, true, true, []), (.verifying, true, false, []),
      (.verifying, false, true, []), (.verifying, false, false, []),
      (.paused, true, true, [.resume]), (.paused, true, false, [.resume]),
      (.paused, false, true, [.resume]), (.paused, false, false, [.resume]),
      (.updatePaused(resumable: true), true, true, [.resumeUpgrade]),
      (.updatePaused(resumable: true), true, false, [.resumeUpgrade]),
      (.updatePaused(resumable: true), false, true, [.resumeUpgrade]),
      (.updatePaused(resumable: true), false, false, [.resumeUpgrade]),
      (.updatePaused(resumable: false), true, true, [.finishUpgrade]),
      (.updatePaused(resumable: false), true, false, [.finishUpgrade]),
      (.updatePaused(resumable: false), false, true, [.finishUpgrade]),
      (.updatePaused(resumable: false), false, false, [.finishUpgrade]),
      (.failed(.network), true, true, [.tryAgain]), (.failed(.network), true, false, [.tryAgain]),
      (.failed(.network), false, true, [.tryAgain]), (.failed(.network), false, false, [.tryAgain]),
      (.installed, true, true, [.testLive, .remove]), (.installed, true, false, [.remove]),
      (.installed, false, true, [.remove]), (.installed, false, false, [.remove]),
    ]
    #expect(rows.count == 7 * 4 + 4)
    for (state, selected, allows, expected) in rows {
      let actual = P.actions(state, isSelected: selected, allowsRuntimeActivation: allows)
      #expect(actual == expected, "\(state) selected=\(selected) allows=\(allows)")
      #expect(!actual.contains(.use), "\(state) selected=\(selected) allows=\(allows) lists .use")
    }
  }

  // A user on a small Mac would find a card with no way forward, even though every size works there.
  @Test func everyCardOffersAWayForwardWhateverTheRecommendation() throws {
    for recommendation in EGOneSize.allCases {
      for preferred in EGOneSize.allCases {
        for allows in [true, false] {
          for install in Self.allInstallStates {
            for size in EGOneSize.allCases {
              let inputs = Self.inputs(
                preferred: preferred, allowsRuntimeActivation: allows,
                recommendation: recommendation, installStates: [size: install])
              let card = try Self.card(size, inputs)
              if card.state != .verifying {
                #expect(
                  !card.actions.isEmpty,
                  "\(size) \(install) rec=\(recommendation) pref=\(preferred) has no action")
              }
            }
          }
        }
      }
    }
  }

  // A user would be told a size is "in use" when it is not polishing.
  @Test func inUseNeedsSelectedInstalledAndEGOneSurface() throws {
    func inUse(preferred: EGOneSize, install: EGOneInstallState, surface: Bool) throws -> Bool {
      try Self.card(
        .mini,
        Self.inputs(
          preferred: preferred, surfaceUsesEGOne: surface, installStates: [.mini: install])
      ).isInUse
    }
    #expect(try inUse(preferred: .mini, install: .installed(version: nil), surface: true))
    #expect(try !inUse(preferred: .full, install: .installed(version: nil), surface: true))
    #expect(try !inUse(preferred: .mini, install: .paused, surface: true))
    #expect(try !inUse(preferred: .mini, install: .installed(version: nil), surface: false))
  }

  // A user would see a made-up number, or a "fastest" mark that compares nothing.
  @Test func nullFactsGiveNilNumbersAndFastestNeedsAllThree() throws {
    let none = EGOneSizeCardPresenter.cards(Self.inputs())
    for card in none {
      #expect(card.englishPercent == nil && card.polishMilliseconds == nil && card.memory == nil)
      #expect(!card.isFastest && !card.isLightest)
    }

    let all = EGOneSizeFacts(
      measuredOn: "Mac",
      sizes: [
        .full: Self.size(polish: 107, english: 95), .mini: Self.size(polish: 59),
        .micro: Self.size(polish: 46),
      ])
    let cards = EGOneSizeCardPresenter.cards(Self.inputs(facts: all))
    #expect(cards.filter(\.isFastest).map(\.size) == [.micro])
    #expect(cards.first { $0.size == .full }?.englishPercent == 95)
    #expect(cards.first { $0.size == .full }?.polishMilliseconds == 107)

    let missingOne = EGOneSizeFacts(
      measuredOn: "Mac", sizes: [.full: Self.size(polish: 107), .micro: Self.size(polish: 46)])
    #expect(
      EGOneSizeCardPresenter.cards(Self.inputs(facts: missingOne)).allSatisfy { !$0.isFastest })
  }

  // A user would see a "lightest" mark that compares nothing, or a wrong memory warning.
  @Test func lightestNeedsAllThreeAndTightMeansMoreThanHalfTheMac() throws {
    let facts = EGOneSizeFacts(
      measuredOn: "Mac",
      sizes: [
        .full: Self.size(memory: 4_900_000_000), .mini: Self.size(memory: 3_000_000_000),
        .micro: Self.size(memory: 2_000_000_000),
      ])
    let small = EGOneSizeCardPresenter.cards(
      Self.inputs(facts: facts, physicalMemoryBytes: 8 << 30))
    #expect(small.filter(\.isLightest).map(\.size) == [.micro])
    #expect(small.first { $0.size == .full }?.memory?.warning == .tight)
    #expect(small.first { $0.size == .micro }?.memory?.warning == nil)

    let big = EGOneSizeCardPresenter.cards(Self.inputs(facts: facts, physicalMemoryBytes: 64 << 30))
    #expect(big.allSatisfy { $0.memory?.warning == nil })

    let partial = EGOneSizeFacts(
      measuredOn: "Mac", sizes: [.full: Self.size(memory: 4_900_000_000)])
    #expect(EGOneSizeCardPresenter.cards(Self.inputs(facts: partial)).allSatisfy { !$0.isLightest })
  }

  // MARK: - Live memory bar (#4525)

  private static func memory(
    peak: Int64, mac: UInt64, used: UInt64?,
    activity: LocalPolishRuntime.ServerActivity = .inactive
  ) -> EGOneSizeCard.Memory {
    .init(bytes: peak, macBytes: mac, systemUsedBytes: used, activity: activity)
  }

  // A user with no live figure would see a different bar from today's, or one past its track.
  @Test func noLiveFigureKeepsTodaysBarAndRule() {
    let quarter = Self.memory(peak: 1, mac: 4, used: nil)
    #expect(quarter.usedFraction == 0 && quarter.peakStart == 0 && quarter.peakFraction == 0.25)
    #expect(quarter.warning == nil)
    let over = Self.memory(peak: 10, mac: 4, used: nil)
    #expect(over.peakFraction == 1)
    #expect(over.warning == .tight)
  }

  // A user would see the size's need drawn over memory already in use, or past the track's end.
  @Test func aSizeNotRunningStacksAfterMemoryInUse() {
    let half = Self.memory(peak: 2, mac: 16, used: 8)
    #expect(half.usedFraction == 0.5 && half.peakStart == 0.5 && half.peakFraction == 0.125)
    let full = Self.memory(peak: 4, mac: 16, used: 15)
    #expect(full.peakFraction == 0.0625)
    #expect(full.peakStart + full.peakFraction == 1)
  }

  // A user would see a running size counted twice, or warned that it will not fit.
  @Test(arguments: [LocalPolishRuntime.ServerActivity.starting, .ready])
  func aStartingOrRunningSizeAddsNoPurpleAndNoWarning(activity: LocalPolishRuntime.ServerActivity) {
    let card = Self.memory(peak: 4, mac: 16, used: 15, activity: activity)
    #expect(card.usedFraction == 15.0 / 16)
    #expect(card.peakFraction == 0)
    #expect(card.warning == nil)
    // A failed live read does not bring back the more-than-half warning for it either.
    #expect(Self.memory(peak: 6, mac: 8, used: nil, activity: activity).warning == nil)
    #expect(Self.memory(peak: 6, mac: 8, used: nil).warning == .tight)
  }

  // A user would be told a size will not fit when it will, or not told when it will not.
  @Test func wontFitNowMeansMoreThanNinetyPercentWhenLive() {
    #expect(Self.memory(peak: 10, mac: 100, used: 79).warning == nil)  // 89%
    #expect(Self.memory(peak: 10, mac: 100, used: 80).warning == nil)  // exactly 90%
    #expect(Self.memory(peak: 10, mac: 100, used: 81).warning == .wontFitNow)  // 91%
    // Live data replaces the more-than-half rule: 60% of the Mac with room left warns nothing.
    #expect(Self.memory(peak: 60, mac: 100, used: 0).warning == nil)
  }

  // A user would see the live figure or a size's running state on the wrong card.
  @Test func presenterCarriesTheLiveFigureAndEachSizesActivity() throws {
    let facts = EGOneSizeFacts(
      measuredOn: "Mac",
      sizes: [
        .full: Self.size(memory: 4_900_000_000), .mini: Self.size(memory: 3_000_000_000),
        .micro: Self.size(memory: 2_000_000_000),
      ])
    var inputs = Self.inputs(facts: facts, physicalMemoryBytes: 64 << 30)
    inputs.systemUsedBytes = 40 << 30
    inputs.activity = [.mini: .ready]
    let cards = EGOneSizeCardPresenter.cards(inputs)
    #expect(cards.allSatisfy { $0.memory?.systemUsedBytes == 40 << 30 })
    #expect(try Self.card(.mini, inputs).memory?.activity == .ready)
    #expect(try Self.card(.full, inputs).memory?.activity == .inactive)
    #expect(try Self.card(.micro, inputs).memory?.activity == .inactive)
  }

  // A user would see a dangling "V" with no number.
  @Test func emptyDisplayVersionBecomesNil() throws {
    let cards = EGOneSizeCardPresenter.cards(
      Self.inputs(displayVersions: [.full: "", .mini: "1.3"]))
    #expect(cards.first { $0.size == .full }?.displayVersion == nil)
    #expect(cards.first { $0.size == .mini }?.displayVersion == "1.3")
    #expect(cards.first { $0.size == .micro }?.displayVersion == nil)
  }

  // MARK: - 4. Copy

  // A user would read a wrong download size.
  @Test func byteCountFormatsDecimalUnits() {
    // The decimal separator follows the locale, so accept either mark between the digits.
    for (bytes, pattern) in [
      (Int64(4_707_411_269), #"^4[.,]7 GB$"#), (2_074_163_194, #"^2[.,]1 GB$"#),
    ] {
      #expect(
        EGOneSizeCardCopy.byteCount(bytes).range(of: pattern, options: .regularExpression) != nil)
    }
    #expect(EGOneSizeCardCopy.byteCount(805_133_748) == "805 MB")
  }

  private func card(version: String?, bytes: Int64?) -> EGOneSizeCard {
    EGOneSizeCard(
      size: .full, isRecommended: false, isSelected: false, state: .installed, isInUse: false,
      actions: [], displayVersion: version, downloadBytes: bytes, englishPercent: nil,
      internationalPercent: nil, polishMilliseconds: nil, isFastest: false, memory: nil,
      isLightest: false)
  }

  // A user would see a stray separator when the version or size is unknown.
  @Test func versionAndSizeJoinsAndDropsMissingParts() {
    let both = EGOneSizeCardCopy.versionAndSize(card(version: "1.3", bytes: 805_133_748))
    #expect(both == "V1.3 · 805 MB")
    #expect(EGOneSizeCardCopy.versionAndSize(card(version: "1.3", bytes: nil)) == "V1.3")
    #expect(EGOneSizeCardCopy.versionAndSize(card(version: nil, bytes: 805_133_748)) == "805 MB")
    #expect(EGOneSizeCardCopy.versionAndSize(card(version: nil, bytes: nil)) == "")
  }

  // A user would read the wrong memory for their Mac.
  @Test func thisMacNamesTheMemory() {
    #expect(EGOneSizeCardCopy.thisMac(physicalMemoryBytes: 64 << 30).contains("64"))
  }

  // A user would not be able to tell the size in use from one that is merely downloaded.
  @Test func statusTellsInUseFromInstalledAndShowsDownloadPercent() {
    func status(_ state: EGOneSizeCard.State, inUse: Bool = false) -> String {
      EGOneSizeCardCopy.status(
        EGOneSizeCard(
          size: .full, isRecommended: false, isSelected: inUse, state: state, isInUse: inUse,
          actions: [], displayVersion: nil, downloadBytes: nil, englishPercent: nil,
          internationalPercent: nil, polishMilliseconds: nil, isFastest: false, memory: nil,
          isLightest: false))
    }
    #expect(status(.installed, inUse: true) != status(.installed, inUse: false))
    #expect(status(.downloading(fraction: 0.42)).contains("42"))
  }
}
