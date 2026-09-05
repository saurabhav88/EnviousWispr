import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

// #2664: the hinted advisory reaches the pill and VoiceOver with the device
// named, while the pipeline's own vocabulary (`OverlayIntent`) never learns the
// hint. When this fails, the user sees the generic sentence after a silent take
// on their interface, or hears a different sentence than the one on screen.
@MainActor
@Suite("Advisory hint routing through the overlay — #2664", .tags(.productOutcome))
struct AdvisoryHintRoutingTests {

  private static let hint = MultiInputAdvisoryHint(deviceName: "Scarlett 2i2 USB")
  private static let hinted =
    "Audio isn't capturing from Scarlett 2i2 USB. Try a different input under Settings > Microphone."

  @Test(
    "the catalog renders the hinted sentence, at the same width and dwell as the plain advisory")
  func catalogRendersHintedSentence() throws {
    let plain = try #require(
      PillCatalog.entry(for: .advisory(reason: .zeroSignal), id: PresentationID()).definition)
    let hinted = try #require(
      PillCatalog.entry(for: .advisory(reason: .zeroSignal, hint: Self.hint), id: PresentationID())
        .definition)
    guard case .notice(let plainNotice) = plain.content,
      case .notice(let hintedNotice) = hinted.content
    else {
      Issue.record("the advisory is no longer a notice")
      return
    }
    #expect(hintedNotice.text == Self.hinted)
    #expect(plainNotice.text == DictationNarrator.copy(for: TerminalAdvisoryReason.zeroSignal))
    #expect(hinted.requestedWidth == plain.requestedWidth)
    #expect(hinted.expiry == plain.expiry)
  }

  @Test("VoiceOver reads the sentence the pill shows, with no Error prefix")
  func announcementMatchesPill() throws {
    let spoken = try #require(
      PillCatalog.announcement(for: .advisory(reason: .zeroSignal, hint: Self.hint)))
    #expect(spoken == .high(Self.hinted))
    // Two-way control: the plain request still speaks the locked sentence.
    let plain = try #require(PillCatalog.announcement(for: .advisory(reason: .zeroSignal)))
    #expect(plain == .high(DictationNarrator.copy(for: TerminalAdvisoryReason.zeroSignal)))
  }

  @Test("the intent conversion DROPS the hint and the reverse conversion supplies none, by design")
  func intentConversionsAreHintFree() {
    let request = PillCatalogRequest.advisory(reason: .vadGateNoSpeech, hint: Self.hint)
    #expect(request.matchingIntent == .advisory(reason: .vadGateNoSpeech))
    let back = PillCatalogRequest(nonRecording: .advisory(reason: .vadGateNoSpeech))
    #expect(back == .advisory(reason: .vadGateNoSpeech, hint: nil))
    #expect(back != request, "a hint cannot survive a trip through OverlayIntent")
  }

  @Test("the reducer's advisory event presents the hinted sentence through the pipeline arm")
  func reducerPresentsHintedSentence() throws {
    var reducer = OverlayReducer()
    let plan = reducer.reduce(.advisory(reason: .zeroSignal, hint: Self.hint))
    let presentation = try #require(plan.presentation)
    guard case .notice(let notice) = presentation.content else {
      Issue.record("the advisory is no longer a notice")
      return
    }
    #expect(notice.text == Self.hinted)
    #expect(plan.didChange)
    // VoiceOver hears the device name too: the announcement comes from the
    // hinted request, not from the reason-only intent.
    #expect(plan.announcement == .high(Self.hinted))
    // It occupies the slot as a PIPELINE advisory: a repeated plain advisory for
    // the same reason is the dedup'd no-op the pipeline arm has always produced.
    let repeat_ = reducer.reduce(.pipeline(.advisory(reason: .zeroSignal)))
    #expect(repeat_.presentation == nil)
    #expect(repeat_.didChange == false)
    #expect(repeat_.announcement == nil)
  }

  @Test("a director resolves the hint at admission from its composition-root closure")
  func directorResolvesHintAtAdmission() throws {
    let (director, host) = OverlayTestDouble.headlessDirectorWithHost(
      advisoryHint: { reason in reason == .zeroSignal ? Self.hint : nil })
    director.present(.advisory(reason: .zeroSignal))
    let shown = try #require(director.renderModel.state.presentation)
    guard case .notice(let notice) = shown.content else {
      Issue.record("the advisory is no longer a notice")
      return
    }
    #expect(notice.text == Self.hinted)
    _ = host
  }
}
