import AVFoundation
import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 D4b (plan M81): Setup's Permissions screen.
///
/// **Product Outcome.** When this fails, a person on the Permissions screen sees the wrong card
/// for their microphone or Accessibility state, presses a button that asks macOS again when it
/// can no longer answer (so nothing happens), or waits on "Waiting…" with no way to reopen
/// System Settings.
@MainActor
@Suite(.tags(.productOutcome))
struct SetupPermissionsScreenTests {
  typealias P = SetupPermissions

  @Test("the live microphone status maps to not asked, allowed or turned off")
  func microphoneMapping() {
    #expect(P.Microphone(.notDetermined) == .notAsked)
    #expect(P.Microphone(.authorized) == .allowed)
    #expect(P.Microphone(.denied) == .turnedOff)
    #expect(
      P.Microphone(.restricted) == .turnedOff, "a managed Mac must get Settings, not a dead Allow")
  }

  @Test("each state shows the mockup's cards and copy, Accessibility second")
  func cardsPerState() {
    #expect(P.microphoneRow(.notAsked) == .ask)
    #expect(P.microphoneRow(.turnedOff) == .fix)
    #expect(P.microphoneRow(.allowed) == .allowed)
    #expect(P.accessibilityRow(microphone: .notAsked, accessibilityAllowed: false) == .later)
    #expect(P.accessibilityRow(microphone: .turnedOff, accessibilityAllowed: false) == .later)
    #expect(P.accessibilityRow(microphone: .allowed, accessibilityAllowed: false) == .ask)
    #expect(P.accessibilityRow(microphone: .notAsked, accessibilityAllowed: true) == .allowed)
    #expect(P.title(.notAsked, accessibilityAllowed: false) == "Two quick permissions")
    #expect(P.title(.turnedOff, accessibilityAllowed: false) == "One switch to flip")
    #expect(P.title(.allowed, accessibilityAllowed: false) == "Two quick permissions")
    #expect(P.title(.allowed, accessibilityAllowed: true) == "Permissions are set")
    #expect(P.subtitle(.allowed, accessibilityAllowed: true) == "Next, choose your dictation key.")
    #expect(
      P.subtitle(.notAsked, accessibilityAllowed: false)
        == "macOS asks before any app can listen or type.\nYou stay in control of both.")
    #expect(
      P.note(.allowed, accessibilityAllowed: false, waiting: false)
        == "Setup continues once both permissions are on.")
    #expect(
      P.note(.allowed, accessibilityAllowed: true, waiting: false)
        == "Taking you to your dictation key…")
    #expect(
      P.note(.turnedOff, accessibilityAllowed: false, waiting: true)
        == "Waiting for the switch in System Settings…")
    #expect(P.mood(.notAsked, accessibilityAllowed: false) == .idle)
    #expect(P.mood(.allowed, accessibilityAllowed: false) == .smile)
    #expect(P.mood(.allowed, accessibilityAllowed: true) == .triumph)
  }

  @Test("Allow only asks a never-asked microphone; every other press opens Settings and waits")
  func buttonsAndWaiting() {
    #expect(P.buttonTitle(row: .microphone, microphone: .notAsked, waiting: false) == "Allow")
    #expect(
      P.buttonAccessibilityName(row: .microphone, microphone: .notAsked, waiting: false)
        == "Allow microphone")
    #expect(
      P.buttonTitle(row: .microphone, microphone: .turnedOff, waiting: false) == "Open Settings")
    #expect(
      P.buttonTitle(row: .accessibility, microphone: .allowed, waiting: false) == "Open Settings")
    #expect(P.buttonTitle(row: .accessibility, microphone: .allowed, waiting: true) == "Waiting…")
    #expect(
      P.buttonAccessibilityName(row: .accessibility, microphone: .allowed, waiting: true)
        == "Open System Settings again")

    var waiting = P.Waiting()
    // The macOS prompt answers a never-asked microphone with a new state: no wait.
    let again1 = waiting.press(.microphone, microphone: .notAsked)
    #expect(again1 == false)
    #expect(waiting.isEmpty)
    // Turned off: Open Settings waits; a second press is a repeat that reopens Settings.
    let again2 = waiting.press(.microphone, microphone: .turnedOff)
    #expect(again2 == false)
    #expect(waiting.contains(.microphone))
    let again3 = waiting.press(.microphone, microphone: .turnedOff)
    #expect(again3)
    waiting.sync(microphone: .allowed, accessibilityAllowed: false)
    #expect(waiting.isEmpty, "the microphone kept waiting after it was allowed")
    // Accessibility: the first press asks macOS, the next reopens the pane, until it is on.
    let again4 = waiting.press(.accessibility, microphone: .allowed)
    #expect(again4 == false)
    let again5 = waiting.press(.accessibility, microphone: .allowed)
    #expect(again5)
    waiting.sync(microphone: .allowed, accessibilityAllowed: false)
    #expect(waiting.contains(.accessibility), "waiting ended before the switch was flipped")
    waiting.sync(microphone: .allowed, accessibilityAllowed: true)
    #expect(waiting.isEmpty)
  }

  @MainActor
  final class Calls {
    var requests = 0
    var prompts = 0
    var opened: [String] = []
  }

  private static func service(
    _ calls: Calls, microphone: AVAuthorizationStatus, accessibility: Bool = false
  ) -> PermissionsService {
    PermissionsService(
      accessibilityReader: { accessibility }, microphoneReader: { microphone },
      microphoneRequester: {
        await MainActor.run { calls.requests += 1 }
        return false
      },
      openMicrophoneSettings: { calls.opened.append($0.absoluteString) },
      accessibilityPrompter: {
        MainActor.assumeIsolated { calls.prompts += 1 }
        return false
      },
      calendarReader: { .notAsked })
  }

  @Test("the screen's actions reach the real owners: prompt, Microphone pane, Accessibility pane")
  func liveActions() async {
    let asked = Calls()
    await SetupPermissionsActions.live(Self.service(asked, microphone: .notDetermined))
      .microphone()
    #expect(asked.requests == 1 && asked.opened.isEmpty)

    let denied = Calls()
    let actions = SetupPermissionsActions.live(Self.service(denied, microphone: .denied))
    await actions.microphone()
    #expect(denied.requests == 0)
    #expect(
      denied.opened == [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
      ])

    actions.accessibility(false)
    #expect(denied.prompts == 1, "the first Accessibility press must ask macOS")
    actions.accessibility(true)
    #expect(denied.prompts == 1, "a repeat press asked macOS again instead of opening the pane")
    #expect(
      denied.opened.last
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  // MARK: - Render (evidence for visual review, in this checkout's ignored build folder)

  struct Shot {
    let name: String
    let microphone: P.Microphone
    let accessibility: Bool
    var waiting: Set<P.Permission> = []
  }

  static let shots: [Shot] = [
    Shot(name: "microphone-ask", microphone: .notAsked, accessibility: false),
    Shot(name: "microphone-turned-off", microphone: .turnedOff, accessibility: false),
    Shot(
      name: "microphone-waiting", microphone: .turnedOff, accessibility: false,
      waiting: [.microphone]),
    Shot(name: "accessibility-ask", microphone: .allowed, accessibility: false),
    Shot(
      name: "accessibility-waiting", microphone: .allowed, accessibility: false,
      waiting: [.accessibility]),
    Shot(name: "all-set", microphone: .allowed, accessibility: true),
  ]

  @Test("every state renders in light, dark and Reduce Motion")
  func renders() throws {
    _ = NSApplication.shared
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var seen: Set<Data> = []
    for shot in Self.shots {
      let light = try Self.png(shot, dark: false, reduceMotion: false)
      let dark = try Self.png(shot, dark: true, reduceMotion: false)
      let still = try Self.png(shot, dark: false, reduceMotion: true)
      #expect(light != dark, "\(shot.name): dark mode painted the same as light")
      try light.write(to: folder.appending(path: "setup-permissions-\(shot.name)-light.png"))
      try dark.write(to: folder.appending(path: "setup-permissions-\(shot.name)-dark.png"))
      try still.write(
        to: folder.appending(path: "setup-permissions-\(shot.name)-reduce-motion.png"))
      seen.insert(still)
    }
    #expect(seen.count == Self.shots.count, "two states painted the same screen")
  }

  private static func png(_ shot: Shot, dark: Bool, reduceMotion: Bool) throws -> Data {
    let screen = SetupPermissionsScreen(
      microphone: shot.microphone, accessibilityAllowed: shot.accessibility,
      dictationKey: "Right Option",
      actions: SetupPermissionsActions(microphone: {}, accessibility: { _ in }),
      onContinue: {}, onBack: {}, waiting: P.Waiting(shot.waiting)
    )
    .padding(.horizontal, SetupLayout.contentPadding)
    .padding(.bottom, SetupLayout.contentPadding)
    .frame(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    .background(Color.obCardBg)
    .environment(\.overlayReduceMotionOverride, reduceMotion)
    let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
    let host = NSHostingView(rootView: screen)
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    // The entrance rise and check pop (0.4 s, DesignMotion.firstRunRise) start on appear; let
    // them finish so the picture shows the resting screen. Under Reduce Motion they are already
    // at rest. This wait is why the render test takes a few seconds (12 moving captures).
    RunLoop.main.run(until: Date().addingTimeInterval(reduceMotion ? 0.05 : 0.5))
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return try #require(rep.representation(using: .png, properties: [:]))
  }
}
