import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013: when these fail, a Zoom call in the browser names the wrong person as talking, reads
/// a tile size as talking when the layout does not support it, or mixes names from another tab.
///
/// Fixture provenance: the class `video-avatar__avatar-name`, the names and the heights 71 and
/// 19 are SURVEY values from the 2026-10-27 Zoom web call
/// (`docs/audits/2026-10-27-4013/zoom-web-names-findings.md`), rebuilt as small trees. Layout
/// evidence (Speaker view, pinning) is SUPPLIED by each test: no detector for it exists yet.
@Suite("Zoom web speaker reader", .tags(.productOutcome))
struct ZoomWebSpeakerReaderTests {

  private let callURL = "https://app.zoom.us/wc/73849291262/join?pwd=x"
  private let speakerView = ZoomWebLayoutEvidence(
    isSpeakerView: true, hasPinnedOrSpotlightedTile: false)

  private func tile(_ name: String, height: Double?) -> CallAXNode {
    CallAXNode(
      role: "AXGroup", domClassList: ["video-avatar__avatar-name"],
      children: [CallAXNode(role: "AXStaticText", value: name, height: height)])
  }

  private func page(_ url: String?, _ tiles: [CallAXNode]) -> CallAXDocument {
    CallAXDocument(url: url, root: CallAXNode(role: "AXWebArea", children: tiles))
  }

  /// SURVEY: Priya's name is the main tile; everyone else is a thumbnail.
  @Test("Speaker view: the one much taller name is the talker; all tiles form the roster")
  func speakerViewTalker() throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(
        documents: [
          page(
            callURL,
            [
              tile("Saurabh Web", height: 19), tile("Priya Shah", height: 19),
              tile("Saurabh A Vaish", height: 18), tile("Alex Rivera", height: 19),
              tile("Priya Shah", height: 71),
            ])
        ], layout: speakerView))
    #expect(reading.speaking == ["Priya Shah"])
    #expect(
      reading.roster.names == ["Saurabh Web", "Priya Shah", "Saurabh A Vaish", "Alex Rivera"])
    #expect(reading.roster.selfNames.isEmpty)
    #expect(!reading.rosterFromParticipantList)
  }

  /// SUPPLIED layout: unknown, gallery, or a pinned tile. The same sizes are not evidence.
  @Test(
    "without proven Speaker view and no pin, size is not talking evidence",
    arguments: [
      ZoomWebLayoutEvidence.unknown,
      ZoomWebLayoutEvidence(isSpeakerView: false, hasPinnedOrSpotlightedTile: false),
      ZoomWebLayoutEvidence(isSpeakerView: true, hasPinnedOrSpotlightedTile: true),
      ZoomWebLayoutEvidence(isSpeakerView: true, hasPinnedOrSpotlightedTile: nil),
    ])
  func layoutNotProven(layout: ZoomWebLayoutEvidence) throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(
        documents: [
          page(callURL, [tile("Alex Rivera", height: 71), tile("Priya Shah", height: 19)])
        ],
        layout: layout))
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])
  }

  /// SYNTHETIC: ties, a missing height, and a single tile give no talker.
  @Test("a tie, a missing height or a lone tile gives no talker")
  func ambiguousSizes() throws {
    let cases: [[CallAXNode]] = [
      [
        tile("Alex Rivera", height: 71), tile("Priya Shah", height: 71),
        tile("Dana Lee", height: 19),
      ],
      [tile("Alex Rivera", height: 71), tile("Priya Shah", height: nil)],
      [tile("Alex Rivera", height: 71)],
    ]
    for tiles in cases {
      let reading = try #require(
        ZoomWebSpeakerReader.read(documents: [page(callURL, tiles)], layout: speakerView))
      #expect(reading.speaking.isEmpty)
    }
  }

  /// SYNTHETIC: a name with punctuation, a text outside a name group, and the wrong class.
  @Test("names keep punctuation; texts outside name groups are ignored")
  func namesAndContext() throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(
        documents: [
          page(
            callURL,
            [
              tile("Lee, Dana (she/her)", height: 71), tile("Alex Rivera", height: 19),
              CallAXNode(role: "AXStaticText", value: "Priya Shah", height: 90),
              CallAXNode(
                role: "AXGroup", domClassList: ["video-avatar__avatar-footer"],
                children: [CallAXNode(role: "AXStaticText", value: "Dana Lee", height: 18)]),
            ])
        ], layout: speakerView))
    #expect(reading.speaking == ["Lee, Dana (she/her)"])
    #expect(reading.roster.names == ["Lee, Dana (she/her)", "Alex Rivera"])
  }

  /// SYNTHETIC: other tabs are never read; two Zoom call tabs, or none, are not read at all.
  @Test("only the single Zoom call page is read")
  func documentSelection() throws {
    let other = page("https://docs.google.com/document/d/1", [tile("Somebody Else", height: 19)])
    let call = page(callURL, [tile("Alex Rivera", height: 71), tile("Priya Shah", height: 19)])
    let reading = try #require(
      ZoomWebSpeakerReader.read(documents: [other, call], layout: speakerView))
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])

    let secondCall = page("https://app.zoom.us/wc/join/99999999", [tile("Dana Lee", height: 71)])
    #expect(ZoomWebSpeakerReader.read(documents: [call, secondCall], layout: speakerView) == nil)
    #expect(ZoomWebSpeakerReader.read(documents: [other], layout: speakerView) == nil)
    #expect(
      ZoomWebSpeakerReader.read(
        documents: [page(nil, [tile("Alex Rivera", height: 71)])], layout: speakerView)
        == nil)
  }
}
