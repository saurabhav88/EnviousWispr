import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
import os

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// Paste presses the key that means "v" on the keyboard layout (#3437). When this fails, a Dvorak
/// user's paste fires Command+K (physical V types "k" there) instead of pasting.
@MainActor
@Suite("The paste key follows the keyboard layout (#3437)", .tags(.productOutcome))
struct PasteKeyLayoutTests {

  /// An installed layout's data, read without selecting it, so the machine's input source never
  /// changes. System layouts are installed on every Mac; a missing one fails, never passes.
  private func layoutData(_ sourceID: String) throws -> Data {
    let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
    let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
    let source = try #require(list?.first, "layout \(sourceID) is not installed")
    let raw = try #require(
      TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
      "layout \(sourceID) has no key layout data")
    return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
  }

  private func key(_ character: Character, in sourceID: String) throws -> CGKeyCode? {
    SyntheticCopyChord.keyCode(
      for: character, layoutData: try layoutData(sourceID), keyboardType: UInt32(LMGetKbdType()))
  }

  @Test("US types v on physical V (9), and c on 8 for the copy chord")
  func usLayout() throws {
    #expect(try key("v", in: "com.apple.keylayout.US") == 9)
    #expect(try key("c", in: "com.apple.keylayout.US") == 8)
  }

  @Test("Dvorak types v on key 47, not physical V")
  func dvorakLayout() throws {
    #expect(try key("v", in: "com.apple.keylayout.Dvorak") == 47)
  }

  @Test("Dvorak - QWERTY Command types v on physical V while Command is held")
  func dvorakQwertyCommandLayout() throws {
    #expect(try key("v", in: "com.apple.keylayout.DVORAK-QWERTYCMD") == 9)
  }

  @Test("the paste key is the resolved one, and physical V with a log line when none resolves")
  func commandVKeyCodeFallback() {
    let logged = OSAllocatedUnfairLock(initialState: 0)
    let count: @Sendable () -> Void = { logged.withLock { $0 += 1 } }
    #expect(SyntheticCopyChord.commandVKeyCode(resolving: { 47 }, logFallback: count) == 47)
    #expect(logged.withLock { $0 } == 0)
    #expect(SyntheticCopyChord.commandVKeyCode(resolving: { nil }, logFallback: count) == 9)
    #expect(logged.withLock { $0 } == 1)
  }

  @Test("both posted key events carry the given key, Command and our marker")
  func commandVEventsCarryTheKey() throws {
    let source = try #require(CGEventSource(stateID: .combinedSessionState))
    let (down, up) = try #require(PasteService.commandVEvents(keyCode: 47, source: source))
    for (event, isDown) in [(down, true), (up, false)] {
      #expect(event.getIntegerValueField(.keyboardEventKeycode) == 47)
      #expect(event.type == (isDown ? .keyDown : .keyUp))
      #expect(event.flags.contains(.maskCommand))
      #expect(
        event.getIntegerValueField(.eventSourceUserData) == SyntheticKeyboardEventMarker.userData)
    }
  }
}
