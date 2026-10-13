import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3703: what the Recording mode "?" lists. When one of these fails the user is told about a gesture
/// their dictation key cannot use, is not told about one it can, or reads a cancel claim that is false
/// on the hold-plus-Space path.
///
/// The key codes are written out here (they are the nine bare modifier keys the listener accepts,
/// `KeySymbols`), not read from `ShortcutBinding.isBareModifier`, so the expectation does not use the
/// predicate it checks.
@Suite("Recording mode help (#3703)", .tags(.productOutcome))
struct RecordingModeHelpTests {

  /// Left and right Command, Option, Shift and Control, and Fn/Globe (63).
  private static let bareModifierKeyCodes: [UInt16] = [55, 54, 58, 61, 56, 60, 59, 62, 63]

  private static let pushToTalkWithSpace: [RecordingModeHelpContent.Line] = [
    .hold, .doublePress, .holdAndSpace, .closing,
  ]
  private static let pushToTalkWithoutSpace: [RecordingModeHelpContent.Line] = [
    .hold, .doublePress, .closing,
  ]

  @Test(
    "Push to Talk with a single modifier key lists hold, double-press, hold plus Space and the closing line",
    arguments: bareModifierKeyCodes)
  func bareModifierListsSpace(keyCode: UInt16) {
    let record = ShortcutBinding.keyboard(keyCode: keyCode, modifiers: [])
    #expect(
      RecordingModeHelpContent.lines(isPushToTalk: true, record: record)
        == Self.pushToTalkWithSpace)
  }

  @Test("Push to Talk with a key combination never lists hold plus Space")
  func chordHidesSpace() {
    let chords: [ShortcutBinding] = [
      .keyboard(keyCode: 49, modifiers: [.command]),  // Command+Space
      .keyboard(keyCode: 41, modifiers: [.option]),  // Option+;
      .keyboard(keyCode: 61, modifiers: [.shift]),  // a modifier key carrying another modifier
    ]
    for record in chords {
      #expect(
        RecordingModeHelpContent.lines(isPushToTalk: true, record: record)
          == Self.pushToTalkWithoutSpace,
        "\(record)")
    }
  }

  @Test("Caps Lock and the second Globe code are not single modifier keys for this list")
  func capsLockAndGlobe179HideSpace() {
    for keyCode: UInt16 in [57, 179] {
      let record = ShortcutBinding.keyboard(keyCode: keyCode, modifiers: [])
      #expect(
        RecordingModeHelpContent.lines(isPushToTalk: true, record: record)
          == Self.pushToTalkWithoutSpace,
        "key code \(keyCode)")
    }
  }

  @Test("Toggle mode shows its one sentence for either kind of key")
  func toggleShowsOneSentence() {
    let bare = ShortcutBinding.keyboard(keyCode: 61, modifiers: [])
    let chord = ShortcutBinding.keyboard(keyCode: 49, modifiers: [.command])
    #expect(RecordingModeHelpContent.lines(isPushToTalk: false, record: bare) == [.toggle])
    #expect(RecordingModeHelpContent.lines(isPushToTalk: false, record: chord) == [.toggle])
  }

  @Test("Only the ways to record are bullets")
  func bulletsAreTheWaysToRecord() {
    #expect(Self.pushToTalkWithSpace.filter(\.isBullet) == [.hold, .doublePress, .holdAndSpace])
    #expect(RecordingModeHelpContent.Line.closing.isBullet == false)
    #expect(RecordingModeHelpContent.Line.toggle.isBullet == false)
  }

  /// A hold-plus-Space lock bypasses the triple-press cancel (`RecordGesture`), so the cancel claim
  /// belongs to the double-press line alone, and no line promises an instant stop.
  @Test("The cancel claim is made only on the double-press line")
  func cancelClaimIsPathSpecific() {
    func text(_ line: RecordingModeHelpContent.Line) -> String { String(localized: line.copy) }
    #expect(text(.doublePress).contains("Triple-press to cancel"))
    for line in [RecordingModeHelpContent.Line.hold, .holdAndSpace, .closing, .toggle] {
      #expect(text(line).localizedCaseInsensitiveContains("cancel") == false, "\(line)")
    }
    #expect(text(.closing).localizedCaseInsensitiveContains("instant") == false)
  }

  @Test("The English copy keeps the wording the German and the help page were written against")
  func englishCopyIsPinned() {
    #expect(
      String(localized: RecordingModeHelpCopy.hold)
        == "Hold the keybind to record. Release to stop.")
    #expect(
      String(localized: RecordingModeHelpCopy.doublePress)
        == "Double-press the keybind to go hands-free. Triple-press to cancel instead.")
    #expect(
      String(localized: RecordingModeHelpCopy.holdAndSpace)
        == "Hold only the keybind and press Space to go hands-free.")
    #expect(
      String(localized: RecordingModeHelpCopy.closing)
        == "To stop a hands-free recording, press the keybind once.")
    #expect(
      String(localized: RecordingModeHelpCopy.toggle)
        == "Press once to start recording. Press again to stop.")
  }

  @Test("The Watch link goes to the Push to Talk help page")
  func watchLinkTarget() {
    #expect(
      RecordingModeHelpCopy.learnMoreURL?.absoluteString
        == "https://enviouswispr.com/help/push-to-talk-mode/")
  }

  @Test("No line carries a dash character (brand rule)")
  func noDashes() {
    let lines: [RecordingModeHelpContent.Line] = [
      .hold, .doublePress, .holdAndSpace, .closing, .toggle,
    ]
    for line in lines {
      let text = String(localized: line.copy)
      #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(line)")
    }
  }
}
