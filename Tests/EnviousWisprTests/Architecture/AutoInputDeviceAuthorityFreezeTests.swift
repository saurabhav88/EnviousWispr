import Foundation
import Testing

/// #2022 — freezes the one thing that change made possible to get wrong.
///
/// Before #2022, "the system default input" and "the device capture opens" were
/// the same device on Auto, so any consumer could answer "which microphone is in
/// use?" by reading the default. That is no longer true: a default PROVEN not to
/// be a microphone (virtual or aggregate) loses to a real one.
///
/// Cloud review found two consumers still reading the default, and they failed
/// in different ways — the settings pill would name the device we deliberately
/// refused, and the Bluetooth awareness card would answer "not Bluetooth" and
/// withhold itself from a user on a headset. Neither is a crash, both are
/// silent, and a runtime test would have to construct a virtual audio device to
/// see either.
///
/// So this is a STRUCTURAL freeze on the CLASS rather than a test of the two
/// instances: a new consumer reading the default must fail the build, not wait
/// for someone to notice their microphone name is wrong.
///
/// The rule: `resolvedAutoInputDeviceID()` is the only way to ask "what would
/// Auto open". `defaultInputDeviceID()` answers a different question — "what
/// does macOS currently call the default" — which stays legitimate for the few
/// files below that genuinely mean it.
@Suite struct AutoInputDeviceAuthorityFreezeTests {

  /// Files permitted to read the raw system default, each for a stated reason.
  /// Adding an entry is a deliberate act: state why the file means the SYSTEM
  /// DEFAULT rather than the device capture will open.
  private static let permitted: [String: String] = [
    // Defines it, and defines `defaultInputDeviceUID()` whose whole purpose is
    // to report the default so divergence can be measured in telemetry.
    "Sources/EnviousWisprAudio/AudioDeviceManager.swift":
      "declares the accessor and the deliberate system-default UID reporter",
    // The ladder itself — this is the code that decides whether the default wins.
    "Sources/EnviousWisprAudio/InputDeviceResolver.swift":
      "the selection ladder, which consumes the default as an input",
    // Route telemetry's PRE-BIND estimate, used only when the actual bound
    // transport is unavailable; it prefers `actualBoundTransport` when present.
    "Sources/EnviousWisprAudio/ResolvedRouteTransports.swift":
      "pre-bind route estimate, superseded by the actual bound transport",
    // DEBUG UAT seam that forces the no-default condition.
    "Sources/EnviousWisprAudio/AudioCaptureManager.swift":
      "DEBUG seam injecting a nil default to exercise the fallback",
  ]

  /// A plain substring, and precise enough BY MEASUREMENT rather than by
  /// assumption. The two identifiers that could collide do not:
  /// `resolvedAutoInputDeviceID(` does not contain this text (the stem is
  /// `AutoInputDeviceID`, not `defaultInputDeviceID`), and the
  /// `defaultInputDeviceIDProvider` seam is followed by `P`, not `(`. Swift
  /// regex literals reject lookbehind, and precision matters more than
  /// cleverness here — a freeze that fires on innocent names gets deleted
  /// rather than obeyed.
  private static let call = "defaultInputDeviceID("

  @Test("only the audio module's stated owners read the raw system default")
  func noConsumerDerivesTheInputFromTheSystemDefault() throws {
    let root = RepoRoot.url
    let sources = root.appendingPathComponent("Sources")

    var offenders: [String] = []
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    while let item = files?.nextObject() as? URL {
      guard item.pathExtension == "swift" else { continue }
      let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
      guard Self.permitted[relative] == nil else { continue }
      let text = try String(contentsOf: item, encoding: .utf8)
      if text.contains(Self.call) { offenders.append(relative) }
    }

    #expect(
      offenders.isEmpty,
      """
      These files ask macOS for the system default input to decide which \
      microphone is in use. Since #2022 that is not the device capture opens \
      when the default is virtual or aggregate — use \
      `AudioDeviceEnumerator.resolvedAutoInputDeviceID()`, or add the file to \
      `permitted` with the reason it genuinely means the system default:
      \(offenders.sorted().joined(separator: "\n"))
      """)
  }

  /// The two-way control. A freeze whose pattern matches nothing is
  /// indistinguishable from a clean repo, and would keep passing after someone
  /// renames the accessor.
  @Test("the freeze's own pattern still matches a known real call site")
  func patternMatchesAKnownCallSite() throws {
    let owner = RepoRoot.url
      .appendingPathComponent("Sources/EnviousWisprAudio/InputDeviceResolver.swift")
    let text = try String(contentsOf: owner, encoding: .utf8)
    #expect(
      text.contains(Self.call),
      """
      The resolver must still call defaultInputDeviceID(). If it does not, this \
      freeze is checking a name that no longer exists and proves nothing.
      """)
  }

  /// Every permitted file must still exist, so a rename or deletion turns into a
  /// failure here rather than silently widening the allow-list to cover nothing.
  @Test("every permitted exception still names a real file")
  func permittedFilesExist() {
    for (path, reason) in Self.permitted {
      let url = RepoRoot.url.appendingPathComponent(path)
      #expect(
        FileManager.default.fileExists(atPath: url.path),
        "permitted exception no longer exists (\(reason)): \(path)")
    }
  }
}
