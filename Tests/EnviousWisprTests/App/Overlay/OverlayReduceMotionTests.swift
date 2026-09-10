import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2303: the recording pill obeys macOS Reduce Motion.
///
/// **Product Outcome.** When these fail, a person who has told macOS to calm every app down is
/// still shown a hairline breathing on a two-second loop, a red one flashing three times a
/// second, or lips pulsing, on the surfaces they see during every dictation.
///
/// **These rows read PIXELS, because the whole subject is paint.** `RenderedPillHarness` records
/// that `fittingSize` is blind to colour and opacity, so no size assertion can see this change at
/// all. `AppearanceRenderHarness` established the mechanism used here.
///
/// **WHAT THESE ROWS DO NOT BIND, stated rather than left to be discovered.** No row constructs
/// `RecordingOverlayView`, so its two container gates — the lock transition and the notice
/// cross-fade — have only the helper's own row behind them; if a call site stopped passing the
/// helper, nothing here would go red. And no row proves a hairline VISIBLY breathes, stops, or
/// resumes: an off-screen `NSHostingView` does not advance a `repeatForever` (measured
/// 2026-09-09, three renders 0.4 s apart of a breathing capsule are byte-identical), so the
/// re-arm rows read the target the view reports instead. Both are Live UAT rows.
///
/// **Nothing here freezes an absolute reading.** Every row is a RELATION between renders taken in
/// ONE process, which is what survives another Mac's font metrics and rendering defaults
/// (`validation-discipline.md` RULE: measure-with-the-real-tool-never-a-simulation). Each
/// difference row is paired with a control proving the instrument is deterministic, so a renderer
/// returning noise would fail rather than pass.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayReduceMotionTests {

  init() { _ = NSApplication.shared }

  /// Paint one view at a fixed box and return the encoded pixels.
  private static func pixels(
    _ view: some View,
    reduceMotion: Bool,
    size: CGSize = CGSize(width: 200, height: 44)
  ) throws -> Data {
    let sized = view.frame(width: size.width, height: size.height)
    let host = NSHostingView(
      rootView: AnyView(sized.environment(\.overlayReduceMotionOverride, reduceMotion)))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let rep = try #require(
      host.bitmapImageRepForCachingDisplay(in: host.bounds),
      "the host produced no bitmap, so this row proved nothing")
    host.cacheDisplay(in: host.bounds, to: rep)
    let png: Data? = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    return try #require(png, "the bitmap did not encode, so this row proved nothing")
  }

  // MARK: - The rainbow hairline on the recording pill

  @Test("the recording pill's hairline is painted differently once Reduce Motion is on")
  func rainbowHairlinePaintsDifferently() throws {
    let moving = try Self.pixels(OverlayCapsuleBackground(), reduceMotion: false)
    let still = try Self.pixels(OverlayCapsuleBackground(), reduceMotion: true)
    #expect(
      moving != still,
      "the capsule painted identically either way, so the setting reached no pixel")
  }

  @Test("the same capsule painted twice is identical, so a difference means the setting")
  func rainbowHairlineInstrumentIsDeterministic() throws {
    let first = try Self.pixels(OverlayCapsuleBackground(), reduceMotion: false)
    let second = try Self.pixels(OverlayCapsuleBackground(), reduceMotion: false)
    #expect(
      first == second,
      "two identical renders differed, so the row above cannot attribute a difference to anything")
  }

  // MARK: - The red hairline on the interruption pill

  @Test("the interruption pill's red hairline is painted differently once Reduce Motion is on")
  func distressHairlinePaintsDifferently() throws {
    let moving = try Self.pixels(DistressCapsuleBackground(), reduceMotion: false)
    let still = try Self.pixels(DistressCapsuleBackground(), reduceMotion: true)
    #expect(
      moving != still,
      "the distress capsule painted identically either way, so the setting reached no pixel")
  }

  @Test("the same interruption capsule painted twice is identical")
  func distressHairlineInstrumentIsDeterministic() throws {
    let first = try Self.pixels(DistressCapsuleBackground(), reduceMotion: false)
    let second = try Self.pixels(DistressCapsuleBackground(), reduceMotion: false)
    #expect(
      first == second,
      "two identical renders differed, so the row above cannot attribute a difference to anything")
  }

  // MARK: - The warning lips

  /// A third of the pulse's own 0.7 s period.
  ///
  /// The lips' distress pulse is driven by the WALL CLOCK, so it is proven by taking renders at
  /// different TIMES rather than by comparing the two settings at one instant — at one instant
  /// the pulse can be passing through the still value and the two would agree by coincidence.
  /// Three samples make "all three equal" the signal, which no single coincidence produces.
  private static let pulseSampleGap: TimeInterval = 0.23

  /// Each sample builds a NEW host with an explicit override, so this reaches neither live
  /// system-setting delivery nor a mounted `TimelineView` being removed and restored.
  private static func lipSamples(reduceMotion: Bool) throws -> [Data] {
    var out: [Data] = []
    for index in 0..<3 {
      // settle: elapsed time IS this row's independent variable, not a wait for work to finish.
      if index > 0 { Thread.sleep(forTimeInterval: pulseSampleGap) }
      out.append(
        try pixels(
          RainbowLipsIcon(size: 24, audioLevel: 0, isDistress: true),
          reduceMotion: reduceMotion,
          size: CGSize(width: 24, height: 24)))
    }
    return out
  }

  @Test("the warning lips pulse over time while Reduce Motion is off")
  func warningLipsPulseWhenTheSettingIsOff() throws {
    let samples = try Self.lipSamples(reduceMotion: false)
    #expect(
      Set(samples).count > 1,
      "three renders spread across the pulse were identical, so the moving arm draws nothing")
  }

  @Test("the warning lips hold still once Reduce Motion is on")
  func warningLipsHoldStillWhenTheSettingIsOn() throws {
    let samples = try Self.lipSamples(reduceMotion: true)
    #expect(
      Set(samples).count == 1,
      "the lips changed across time with Reduce Motion on, so the pulse is still running")
  }

  // MARK: - Turning the setting OFF while the pill is on screen

  /// **Measured 2026-09-09: an off-screen `NSHostingView` does NOT advance a `repeatForever`.**
  /// Three renders 0.4 s apart of a capsule that has been breathing since it mounted are
  /// byte-identical, so "did the hairline start moving again" has no pixel answer in this
  /// process. That is why the rows below read the target opacity the view reports at the moment
  /// it arms or parks the loop, rather than reading paint like every other row in this suite.
  /// Whether the hairline visibly breathes is a Live UAT row and is claimed nowhere here.

  /// Holds the setting so a mounted pill can watch it change, the way the real environment does.
  @Observable final class MotionBox {
    var reduceMotion: Bool
    init(reduceMotion: Bool) { self.reduceMotion = reduceMotion }
  }

  final class TargetLog: @unchecked Sendable {
    private(set) var targets: [Double] = []
    func record(_ value: Double) { targets.append(value) }
  }

  /// A CONCRETE wrapper, never `AnyView`. `AnyView` can break SwiftUI's view identity, which
  /// would remount the capsule on the toggle and re-arm it for free — the exact defect this
  /// exists to catch would then pass.
  private struct ToggleHarness: View {
    let box: MotionBox
    let log: TargetLog
    var body: some View {
      OverlayCapsuleBackground(onGlowTarget: { log.record($0) })
        .environment(\.overlayReduceMotionOverride, box.reduceMotion)
        .frame(width: 200, height: 44)
    }
  }

  /// The interruption pill carries the identical mechanism, so it carries identical rows. One
  /// pill passing says nothing about the other: they are two `onChange` wirings, not one.
  private struct DistressToggleHarness: View {
    let box: MotionBox
    let log: TargetLog
    var body: some View {
      DistressCapsuleBackground(onGlowTarget: { log.record($0) })
        .environment(\.overlayReduceMotionOverride, box.reduceMotion)
        .frame(width: 200, height: 44)
    }
  }

  private static func distressTargetsAcrossToggle(
    startingReduced: Bool, thenReduced: Bool
  ) -> [Double] {
    let box = MotionBox(reduceMotion: startingReduced)
    let log = TargetLog()
    let host = NSHostingView(rootView: DistressToggleHarness(box: box, log: log))
    let size = CGSize(width: 200, height: 44)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    box.reduceMotion = thenReduced
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return log.targets
  }

  private static func targetsAcrossToggle(startingReduced: Bool, thenReduced: Bool) -> [Double] {
    let box = MotionBox(reduceMotion: startingReduced)
    let log = TargetLog()
    let host = NSHostingView(rootView: ToggleHarness(box: box, log: log))
    let size = CGSize(width: 200, height: 44)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    box.reduceMotion = thenReduced
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return log.targets
  }

  /// #2767 cloud review r1. Reduce Motion can be switched OFF while a pill is still mounted.
  /// Arming from `onAppear` runs once, so the hairline would sit at its dim starting value
  /// forever — dimmer than either state it is meant to have.
  @Test("turning Reduce Motion off re-arms the hairline without remounting the pill")
  func theGlowReArmsWhenTheSettingGoesOff() {
    let targets = Self.targetsAcrossToggle(startingReduced: true, thenReduced: false)
    #expect(
      targets.count == 2,
      "\(targets.count) glow decisions across the toggle, not two: it never saw the change")
    #expect(
      targets.last == 0.65,
      "last glow decision \(String(describing: targets.last)), not the bright endpoint: no re-arm")
  }

  /// The opposite direction, so a view that simply always arms cannot pass the row above.
  @Test("turning Reduce Motion on parks the hairline without remounting the pill")
  func theGlowParksWhenTheSettingGoesOn() {
    let targets = Self.targetsAcrossToggle(startingReduced: false, thenReduced: true)
    #expect(
      targets.count == 2,
      "the capsule reported \(targets.count) glow decisions across the toggle, not two")
    #expect(
      targets.last == 0.3,
      "last glow decision \(String(describing: targets.last)), not the dim endpoint")
  }

  @Test("turning Reduce Motion off re-arms the interruption pill without remounting it")
  func theDistressGlowReArmsWhenTheSettingGoesOff() {
    let targets = Self.distressTargetsAcrossToggle(startingReduced: true, thenReduced: false)
    #expect(targets.count == 2, "\(targets.count) glow decisions across the toggle, not two")
    #expect(
      targets.last == 0.6,
      "last glow decision \(String(describing: targets.last)), not the bright endpoint: no re-arm")
  }

  @Test("turning Reduce Motion on parks the interruption pill without remounting it")
  func theDistressGlowParksWhenTheSettingGoesOn() {
    let targets = Self.distressTargetsAcrossToggle(startingReduced: false, thenReduced: true)
    #expect(targets.count == 2, "\(targets.count) glow decisions across the toggle, not two")
    #expect(
      targets.last == 0.3,
      "last glow decision \(String(describing: targets.last)), not the dim endpoint")
  }

  // MARK: - What Reduce Motion must NOT change

  /// The lips are the pill's "I can hear you" signal. `OverlayMotion` records that stilling them
  /// would leave a Reduce Motion user with a muted microphone nothing to distinguish a working
  /// take from a silent one, so this is a row about what the change must NOT have done.
  @Test("the ordinary lips still react to the voice under Reduce Motion")
  func ordinaryLipsStayAudioReactive() throws {
    let box = CGSize(width: 24, height: 24)
    let silent = try Self.pixels(
      RainbowLipsIcon(size: 24, audioLevel: 0), reduceMotion: true, size: box)
    let speaking = try Self.pixels(
      RainbowLipsIcon(size: 24, audioLevel: 1), reduceMotion: true, size: box)
    #expect(silent != speaking, "the lips painted the same silent and loud, so they went deaf")

    let speakingUnreduced = try Self.pixels(
      RainbowLipsIcon(size: 24, audioLevel: 1), reduceMotion: false, size: box)
    #expect(
      speaking == speakingUnreduced,
      "Reduce Motion changed how loud lips are drawn, and it is meant to change nothing here")
  }

  /// #2201 and #2435 already chose two ways for a hairline to hold still, and neither is about
  /// Reduce Motion. A pill that was still for one of those reasons must paint identically with
  /// the setting on or off, or this change has quietly taken over their decision.
  @Test("the hairlines that already held still are unmoved by the setting")
  func existingStillChoicesAreUnaffected() throws {
    let previewPill = OverlayCapsuleBackground(cornerStyle: .rounded, animatesGlow: true)
    let frozenCapsule = OverlayCapsuleBackground(cornerStyle: .capsule, animatesGlow: false)
    for still in [AnyView(previewPill), AnyView(frozenCapsule)] {
      let off = try Self.pixels(still, reduceMotion: false)
      let on = try Self.pixels(still, reduceMotion: true)
      #expect(off == on, "a hairline that was already still changed when Reduce Motion came on")
    }
  }

  // MARK: - The policy, and the seam that lets these rows exist

  /// `showsAmbientLoop` needs no row of its own: every pixel and target row above reaches it
  /// through a real view, in both directions. `stateChange` does, because nothing else here
  /// constructs `RecordingOverlayView` — see the coverage note in this suite's header.
  @Test("the state-change helper returns an animation off, and nil on")
  func stateChangeFollowsTheSetting() {
    #expect(OverlayMotion.stateChange(.easeInOut(duration: 0.3), reduceMotion: false) != nil)
    #expect(OverlayMotion.stateChange(.easeInOut(duration: 0.3), reduceMotion: true) == nil)
  }

  /// The override above exists only because the system value is get-only. It is inert in the
  /// shipped app for one reason: **nothing sets it**. That is a property of the source, so it is
  /// asserted against the source rather than promised in a comment — if somebody wires it to a
  /// setting, a build flag or a debug menu, every pill silently stops reading the person's real
  /// macOS preference, and this row is what says so.
  @Test("no shipped code sets the override, so every real pill reads the system setting")
  func theOverrideIsInertInTheShippedApp() throws {
    let sources = RepoRoot.url.appending(path: "Sources")
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    var unexpected: [String] = []
    var scanned = 0
    var declarations = 0
    while let url = files?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      guard text.contains("overlayReduceMotionOverride") else { continue }
      for line in text.split(separator: "\n") where line.contains("overlayReduceMotionOverride") {
        let mention = line.trimmingCharacters(in: .whitespaces)
        // Prose about the key cannot set it.
        if mention.hasPrefix("///") || mention.hasPrefix("//") { continue }
        // Reading it is what every pill does. Only a WRITE would break the property.
        if mention.hasPrefix("@Environment(") { continue }
        // The declaration itself, and only in its own file. Skipping the WHOLE file — which an
        // earlier version of this row did — means a writer added beside the declaration passes,
        // which is exactly where somebody wiring this to a debug menu would put it.
        if url.lastPathComponent == "OverlayMotion.swift",
          mention == "var overlayReduceMotionOverride: Bool? {"
        {
          declarations += 1
          continue
        }
        unexpected.append("\(url.lastPathComponent): \(mention)")
      }
    }
    #expect(scanned > 0, "the sweep read no Swift files, so its silence means nothing")
    #expect(declarations == 1, "expected exactly one declaration, found \(declarations)")
    #expect(unexpected.isEmpty, "shipped code mentions the override unexpectedly: \(unexpected)")
  }
}
