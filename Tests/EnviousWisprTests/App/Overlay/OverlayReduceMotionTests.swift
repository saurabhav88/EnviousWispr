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
  func rainbowHairlineHoldsStill() throws {
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
  func distressHairlineHoldsStill() throws {
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

  // MARK: - The policy, and the seam that lets these rows exist

  @Test("an ambient loop runs only while Reduce Motion is off")
  func ambientLoopFollowsTheSetting() {
    #expect(OverlayMotion.showsAmbientLoop(reduceMotion: false))
    #expect(OverlayMotion.showsAmbientLoop(reduceMotion: true) == false)
  }

  @Test("a discrete state change keeps its animation off, and becomes instant on")
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
    var setters: [String] = []
    var scanned = 0
    while let url = files?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      guard text.contains("overlayReduceMotionOverride") else { continue }
      // The declaration itself is the one legitimate mention.
      if url.lastPathComponent == "OverlayMotion.swift" { continue }
      for line in text.split(separator: "\n") where line.contains("overlayReduceMotionOverride") {
        let mention = line.trimmingCharacters(in: .whitespaces)
        // Reading it is what every pill does. Only a WRITE breaks the property.
        if mention.hasPrefix("@Environment(") { continue }
        setters.append("\(url.lastPathComponent): \(mention)")
      }
    }
    #expect(scanned > 0, "the sweep read no Swift files, so its silence means nothing")
    #expect(setters.isEmpty, "shipped code writes the override: \(setters)")
  }
}
