import EnviousWisprCore
import Testing

@testable import EnviousWisprServices

/// #4013 r5: when these fail, a Zoom call in the browser names the wrong person as talking,
/// counts the large tile as another person, loses an unnamed talker, or mixes names from another
/// tab.
///
/// Fixture provenance: the frame classes, `video-avatar__avatar-footer`, the host tile without
/// `video-avatar__avatar-name` and the names are SURVEY values from the C1 Zoom web run of
/// 2026-10-28 (`docs/audits/2026-10-27-4013/c1w-receipt.txt`), rebuilt as small trees; SYNTHETIC
/// cases vary them.
@Suite("Zoom web speaker reader", .tags(.productOutcome))
struct ZoomWebSpeakerReaderTests {

  private let callURL = "https://app.zoom.us/wc/73849291262/join?pwd=x"
  private let good = CallCaptureContext(completeness: .complete, scope: .resolved)

  private func avatar(_ name: String?, footerOnly: Bool = false) -> [CallAXNode] {
    let footer = CallAXNode(
      role: "AXGroup", domClassList: ["video-avatar__avatar-footer"],
      children: name.map { [CallAXNode(role: "AXStaticText", value: $0)] } ?? [])
    if footerOnly { return [footer] }
    return [
      CallAXNode(
        role: "AXGroup", domClassList: ["video-avatar__avatar-name"],
        children: name.map { [CallAXNode(role: "AXStaticText", value: $0)] } ?? []),
      footer,
    ]
  }

  private func thumbnail(_ name: String?, active: Bool = false, footerOnly: Bool = false)
    -> CallAXNode
  {
    CallAXNode(
      role: "AXGroup",
      domClassList: ["speaker-bar-container__video-frame"]
        + (active ? ["speaker-bar-container__video-frame--active"] : []),
      children: avatar(name, footerOnly: footerOnly))
  }

  private func mainTile(_ name: String) -> CallAXNode {
    CallAXNode(
      role: "AXGroup", domClassList: ["speaker-active-container__video-frame"],
      children: avatar(name))
  }

  private func page(_ url: String?, _ nodes: [CallAXNode]) -> CallAXDocument {
    CallAXDocument(url: url, root: CallAXNode(role: "AXWebArea", children: nodes))
  }

  /// SURVEY: Sam (the Mac's own browser), Alex talking, Priya, the host with a footer only, and
  /// the large tile repeating Alex.
  @Test("Speaker view: the active thumbnail is the talker; the large tile is not another person")
  func activeThumbnail() throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(documents: [
        page(
          callURL,
          [
            thumbnail("Sam Test"), thumbnail("Alex Rivera", active: true), thumbnail("Priya Shah"),
            thumbnail("Saurabh A Vaish", footerOnly: true), mainTile("Alex Rivera"),
          ])
      ]))
    #expect(reading.speaking == ["Alex Rivera"])
    #expect(reading.roster.names == ["Sam Test", "Alex Rivera", "Priya Shah", "Saurabh A Vaish"])
    #expect(reading.participants.count == 4)
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: good) == ["Alex Rivera"])
    #expect(!reading.rosterFromParticipantList)
  }

  @Test("SYNTHETIC: two thumbnails named Alex make a talking Alex ambiguous")
  func duplicateNames() throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(documents: [
        page(callURL, [thumbnail("Alex Rivera", active: true), thumbnail("Alex Rivera")])
      ]))
    #expect(
      CallSpeakerAdmission.admission(of: reading, context: good) == .withheld(.ambiguousTalker))
  }

  @Test("SYNTHETIC: an active thumbnail without a name withholds the reading")
  func unnamedTalker() throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(documents: [
        page(callURL, [thumbnail(nil, active: true), thumbnail("Priya Shah", active: true)])
      ]))
    #expect(
      CallSpeakerAdmission.admission(of: reading, context: good) == .withheld(.unnamedTalker))
  }

  @Test("SYNTHETIC: with no thumbnail frames nobody is named, but the names serve the rename list")
  func otherLayout() throws {
    let reading = try #require(
      ZoomWebSpeakerReader.read(documents: [
        page(callURL, avatar("Alex Rivera") + avatar("Priya Shah"))
      ]))
    #expect(reading.speaking.isEmpty)
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])
    #expect(
      CallSpeakerAdmission.admission(of: reading, context: good)
        == .withheld(.identityUnestablished))
  }

  @Test("SYNTHETIC: a nested thumbnail's name and flag stay its own")
  func nestedFrames() throws {
    var outer = thumbnail("Alex Rivera")
    outer = CallAXNode(
      role: outer.role, domClassList: outer.domClassList,
      children: outer.children + [thumbnail("Priya Shah", active: true)])
    let reading = try #require(ZoomWebSpeakerReader.read(documents: [page(callURL, [outer])]))
    #expect(reading.speaking == ["Priya Shah"])
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])
  }

  @Test("SYNTHETIC: an unnamed outer thumbnail never borrows the name of a thumbnail nested in its footer")
  func nestedNameBoundary() throws {
    let outer = CallAXNode(
      role: "AXGroup", domClassList: ["speaker-bar-container__video-frame"],
      children: [
        CallAXNode(
          role: "AXGroup", domClassList: ["video-avatar__avatar-footer"],
          children: [thumbnail("Priya Shah", active: true)])
      ])
    let reading = try #require(ZoomWebSpeakerReader.read(documents: [page(callURL, [outer])]))
    #expect(reading.participants.map(\.name) == [nil, "Priya Shah"])
    #expect(reading.sharedNames.isEmpty)
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: good) == ["Priya Shah"])
  }

  /// SYNTHETIC: other tabs are never read; two Zoom call tabs, or none, are not read at all.
  @Test("only the single Zoom call page is read")
  func documentSelection() throws {
    let other = page("https://docs.google.com/document/d/1", [thumbnail("Somebody Else")])
    let call = page(callURL, [thumbnail("Alex Rivera", active: true), thumbnail("Priya Shah")])
    let reading = try #require(ZoomWebSpeakerReader.read(documents: [other, call]))
    #expect(reading.roster.names == ["Alex Rivera", "Priya Shah"])

    let secondCall = page("https://app.zoom.us/wc/join/99999999", [thumbnail("Dana Lee")])
    #expect(ZoomWebSpeakerReader.read(documents: [call, secondCall]) == nil)
    #expect(ZoomWebSpeakerReader.read(documents: [other]) == nil)
    #expect(ZoomWebSpeakerReader.read(documents: [page(nil, [thumbnail("Alex Rivera")])]) == nil)
  }
}
