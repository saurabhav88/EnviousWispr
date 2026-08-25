import CoreGraphics
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// **Table 3b: what the director captures and what the resulting composition
/// drives** (#2375 Phase 3).
///
/// Capability, selections and position are read through callbacks, so "read
/// once" is a countable fact rather than an argument. Provider gating and the
/// captured position live on the director and the render model, which is why
/// this cannot be a reducer test.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingDirectorCaptureTests {

  /// A counting rig. Every input the transaction reads is a closure that records
  /// having been asked.
  private final class Counts {
    var capability = 0
    var selections = 0
    var position = 0
    var bridge: [Bool] = []
    /// How many times the live preview DISPLAY provider was actually asked. The
    /// render model swaps in `{ .off }` when the pill cannot hold words, so this
    /// counts the real gate rather than a field beside it.
    var displayReads = 0
  }

  private static func makeDirector(
    _ counts: Counts,
    capabilityHasWords: Bool,
    selections: PillDesignSelections = .shipped,
    host: any OverlayWindowHosting = WindowlessOverlayHost(),
    // **`.bottom`, not `.top`, and that is the whole point of the parameter.**
    // `.top` is `OverlayRenderModel.recordingPosition`'s own default, so a
    // director that ignored the captured position entirely would still leave the
    // model reading `.top` and every assertion would pass. The fixture has to sit
    // somewhere the default is not.
    position: OverlayPillPosition = .bottom,
    scheduleReconciliation: @escaping (@escaping () -> Void) -> Void = { $0() }
  ) -> OverlayDirector {
    OverlayDirector(
      host: host,
      position: {
        counts.position += 1
        return position
      },
      announce: { _ in },
      livePreview: LivePreviewBridge(
        recordingDidChange: { counts.bridge.append($0) },
        isEnabledForGeometry: {
          counts.capability += 1
          return capabilityHasWords
        },
        display: {
          counts.displayReads += 1
          return .off
        }),
      grantAccessibility: {},
      selections: {
        counts.selections += 1
        return selections
      },
      deferFirstRender: { $0() },
      scheduleReconciliation: scheduleReconciliation)
  }

  private static func record(_ d: OverlayDirector, level: Float = 0, locked: Bool = false) {
    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: level,
          audioLevelProvider: { level },
          recordingElapsedProvider: { nil },
          isLocked: locked)))
  }

  // MARK: - Read once

  @Test(
    "a fresh recording reads capability, selections and position exactly once",
    arguments: [false, true])
  func freshRecordingReadsEachInputOnce(capabilityHasWords: Bool) {
    let counts = Counts()
    let d = Self.makeDirector(counts, capabilityHasWords: capabilityHasWords)

    Self.record(d)

    #expect(counts.capability == 1, "capability was read \(counts.capability) times, not once")
    #expect(counts.selections == 1, "selections were read \(counts.selections) times, not once")
    #expect(counts.position == 1, "position was read \(counts.position) times, not once")
  }

  /// **A same-id morph performs no second read**, which is the discipline that
  /// keeps a live pill from changing design because the user opened Settings
  /// mid-dictation. An `NSPanel` cannot grow mid-recording without a rebuild, and
  /// a rebuild is the #930 flicker.
  @Test("audio-level morphs read nothing at all")
  func morphsReadNothing() {
    let counts = Counts()
    let d = Self.makeDirector(counts, capabilityHasWords: true)

    Self.record(d)
    let afterFirst = (counts.capability, counts.selections, counts.position)

    for level in [Float(0.2), 0.5, 0.9] {
      Self.record(d, level: level)
    }

    #expect(counts.capability == afterFirst.0, "a morph re-read capability")
    #expect(counts.selections == afterFirst.1, "a morph re-read selections")
    #expect(counts.position == afterFirst.2, "a morph re-read position")
  }

  // MARK: - The frozen geometries, straight from the definition

  /// **recordingAdapterMatchesTheAcceptedDefinition was DELETED here** (#2375
  /// C3b), and the deletion is the plan's own instruction rather than a
  /// convenience.
  ///
  /// It existed to prove that OverlayRecordingLayout said exactly what the
  /// accepted definition said, so that deleting the layout could be shown to be a
  /// no-op instead of argued to be one. The layout is now gone. A test comparing
  /// a value against itself asserts nothing, and keeping it would leave a green
  /// row that reads as coverage.
  ///
  /// What it was really protecting — that the geometry on screen is the FROZEN
  /// geometry — survives here, now read from the one authority.
  @Test(
    "the composed recording carries the frozen geometry for its capability",
    arguments: [false, true])
  func composedRecordingMatchesTheFrozenGeometry(capabilityHasWords: Bool) throws {
    let counts = Counts()
    let host = WindowlessOverlayHost()
    let d = Self.makeDirector(counts, capabilityHasWords: capabilityHasWords, host: host)

    Self.record(d)

    let definition = try #require(d.renderModel.presentation, "no recording is showing")
    let design = try #require(definition.recordingDesign, "the accepted pill carries no design")
    let frozen = try #require(
      FrozenPillParity.recordingRows.first {
        $0.capability == (capabilityHasWords ? .withWords : .withoutWords)
      })

    #expect(definition.requestedWidth == .fixed(frozen.effectiveWidth))
    #expect(definition.reservesFixedHeight == frozen.fixedHeight)
    #expect(design.canHoldWords == frozen.usesPreviewLayout)
    // `.bottom` is not the model's default, so this fails against a director that
    // never installed the captured position at all.
    #expect(
      d.renderModel.recordingPosition == .bottom,
      "the render model did not keep the captured position")
    // **And the WINDOW was asked for that geometry, which is the thing the user
    // sees.** The definition carrying the right numbers is necessary and not
    // sufficient: `geometry(for:)` sits between the definition and the host, and
    // it is exactly where the deleted override used to substitute its own answer.
    // Without this the override could come back and every assertion above would
    // still pass.
    let asked = try #require(host.presented.last, "the host was never asked to present")
    #expect(
      asked.width == .fixed(frozen.effectiveWidth),
      "the window was sized to something other than the frozen width")
    #expect(
      asked.fixedHeight == frozen.fixedHeight,
      "the window reserved something other than the frozen height")
  }

  /// **Table 3b's actual subject: the CONSUMERS, not field agreement alone.**
  ///
  /// The geometry check above compares fields. This drives the two things those
  /// fields feed — the provider gate and the preview-growth callback — and asserts
  /// what they do. A pill that cannot hold words must not be reading a
  /// live preview at all, and must not resize itself when the content reports a
  /// height.
  @Test(
    "provider gating and preview growth follow the captured design",
    arguments: [false, true])
  func providersFollowTheCapturedDesign(capabilityHasWords: Bool) {
    let counts = Counts()
    let host = WindowlessOverlayHost()
    let d = Self.makeDirector(counts, capabilityHasWords: capabilityHasWords, host: host)

    Self.record(d)
    _ = d.renderModel.livePreviewProvider()
    d.renderModel.onContentHeightChange(123)

    #expect(
      counts.displayReads == (capabilityHasWords ? 1 : 0),
      "a pill that cannot hold words was still reading the live preview")
    #expect(
      host.resizes == (capabilityHasWords ? [CGSize(width: 400, height: 123)] : []),
      "preview growth did not follow the captured design")
  }

  /// **The discriminating pairing: a with-words DESIGN under a without-words
  /// CAPABILITY.**
  ///
  /// The case above uses the shipped selections, where design and capability move
  /// together — so it passes just as well against consumers that gate directly on
  /// capability, which is the arrangement this whole phase exists to remove.
  /// Separating them is the only way to tell which one the consumers actually
  /// follow.
  @Test("reading well drives its consumers even without word capability")
  func consumersFollowDesignRatherThanCapability() {
    let counts = Counts()
    let host = WindowlessOverlayHost()
    let selections = PillDesignSelections(withoutWords: .readingWell, withWords: .readingWell)
    let d = Self.makeDirector(
      counts, capabilityHasWords: false, selections: selections, host: host)

    Self.record(d)
    #expect(d.renderModel.presentation?.recordingDesign == .readingWell)
    _ = d.renderModel.livePreviewProvider()
    d.renderModel.onContentHeightChange(123)

    #expect(counts.displayReads == 1, "the consumers gated on capability, not on the design")
    #expect(
      host.resizes == [CGSize(width: 400, height: 123)],
      "preview growth followed capability rather than the captured design")
  }

  // MARK: - The bridge

  /// The effect reaches Live Preview BEFORE capability is read. That ordering is
  /// the reason the transaction exists, and reading the counter at the moment the
  /// capability closure runs is the only way to observe it.
  @Test("the recording effect is routed before capability is read")
  func effectPrecedesTheCapabilityRead() {
    let counts = Counts()
    var bridgeAtCapabilityRead: [Bool] = []
    let d = OverlayDirector(
      host: WindowlessOverlayHost(),
      position: { .top },
      announce: { _ in },
      livePreview: LivePreviewBridge(
        recordingDidChange: { counts.bridge.append($0) },
        isEnabledForGeometry: {
          bridgeAtCapabilityRead = counts.bridge
          return true
        },
        display: { .off }),
      grantAccessibility: {},
      selections: { .shipped },
      deferFirstRender: { $0() })

    Self.record(d)

    #expect(
      bridgeAtCapabilityRead == [true],
      "capability was read before the bridge was told a recording started — the ordering that gives a preview-sized window with no preview in it"
    )
  }
}
