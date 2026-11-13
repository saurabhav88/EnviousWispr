import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("Setup Practice screen", .tags(.productOutcome))
struct SetupPracticeScreenTests {
  @Test("Continue needs a verified take and navigation waits for an in-flight take")
  func actions() {
    #expect(SetupPracticeState.waiting.canContinue(hasSucceeded: false) == false)
    #expect(SetupPracticeState.waiting.canSkip(hasSucceeded: false))
    #expect(SetupPracticeState.worked.canContinue(hasSucceeded: true))
    #expect(SetupPracticeState.worked.canSkip(hasSucceeded: true) == false)
    for state in [SetupPracticeState.listening(handsFree: false), .transcribing, .polishing] {
      #expect(state.canContinue(hasSucceeded: true) == false)
      #expect(state.canSkip(hasSucceeded: false) == false)
    }
    #expect(SetupPracticeState.preparing.canContinue(hasSucceeded: true) == false)
    #expect(SetupPracticeState.microphoneOff.canContinue(hasSucceeded: true) == false)
  }

  @Test("Practice renders each state in light, dark and Reduce Motion")
  func renders() throws {
    _ = NSApplication.shared
    let folder = RepoRoot.url.appending(path: "build/design-render/practice-d6b")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew.tests.practice-render.\(UUID())")))
    let states: [(String, SetupPracticeState, SetupPracticePolish)] = [
      ("preparing", .preparing, .live), ("waiting", .waiting, .live),
      ("listening", .listening(handsFree: false), .live),
      ("hands-free", .listening(handsFree: true), .live),
      ("transcribing", .transcribing, .live), ("polishing", .polishing, .live),
      ("worked", .worked, .live), ("worked-off", .worked, .off),
      ("worked-cloud-later", .worked, .cloudLater(providerName: "Claude")),
      ("no-speech", .noSpeech, .live),
      ("missed-box", .missedBox(copiedToClipboard: false), .live),
      ("copied", .missedBox(copiedToClipboard: true), .live),
      ("pipeline-failed", .pipelineFailed, .live),
      ("microphone-off", .microphoneOff, .live), ("accessibility-off", .accessibilityOff, .live),
    ]
    let appearances: [(String, ColorScheme, Bool)] = [
      ("light", .light, false), ("dark", .dark, false), ("reduce-motion", .light, true),
    ]
    for (name, state, polish) in states {
      for (variant, scheme, reduceMotion) in appearances {
        let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
        let host = NSHostingView(
          rootView: SetupPracticeScreen(
            state: state,
            text: .constant(state == .worked ? "I think we should meet tomorrow morning." : ""),
            hasSucceeded: state == .worked, key: "Right ⌥", polish: polish,
            settings: settings, devices: [], onSucceeded: {}, onSkip: {}, onBack: {},
            onOpenPermissions: {}, showPillPicture: true
          )
          .padding(SetupLayout.contentPadding)
          .frame(width: size.width, height: size.height)
          .background(Color.obCardBg)
          .environment(\.colorScheme, scheme)
          .environment(\.overlayReduceMotionOverride, reduceMotion)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.size == size)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "\(name)-\(variant).png"))
      }
    }
  }
}
