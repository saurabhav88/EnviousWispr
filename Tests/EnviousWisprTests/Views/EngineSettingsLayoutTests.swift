import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: when this fails, a long Engine row moves its switch below its siblings,
/// a Ready badge certifies a missing language, or Reset loses its full explanation.
@MainActor
@Suite("Engine settings layout and readiness", .tags(.productOutcome))
struct EngineSettingsLayoutTests {
  init() { _ = NSApplication.shared }

  @Test("small controls stay trailing even when the Engine short line wraps")
  func compactSwitchStaysTrailing() throws {
    for width: CGFloat in [432, 502, 982] {
      let frame = try LivePreviewSettingsLayoutTests.frame(width: width) { probe in
        SettingsRow(icon: "face.smiling", resolvedTitle: "Convert spoken emoji (e.g. thumbs up emoji)",
          resolvedShort: "Say a phrase followed by emoji to get its symbol. This longer translation must wrap.",
          resolvedHelp: "Bare words never convert.") {
          Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(BrandedToggleStyle()).fixedSize()
            .background(probe)
        }
      }
      print("ENGINE-SWITCH width=\(width) visible=true frame=\(frame)")
      #expect(abs(frame.maxX - width) < 1)
      #expect(frame.width > 20 && frame.width < 80)
    }
  }

  @Test("Fast readiness follows the current admission result, including unknown")
  func fastReadiness() {
    #expect(EngineSummaryPresentation.fastModelStatus(admitted: true).label == "Model ready")
    #expect(EngineSummaryPresentation.fastModelStatus(admitted: false).tone == .needsSetup)
    #expect(EngineSummaryPresentation.fastModelStatus(admitted: nil).tone == .unavailable)
  }

  @Test("Apple Ready needs current language capability, no stale value and no running install")
  func previewReadiness() {
    let ready = LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple,
      appleSupported: true, universalExists: false, universalState: .notReady,
      heartIsStreaming: false, active: .ready(tag: "de-DE", name: "German"))
    #expect(EngineSummaryPresentation.previewStatus(ready).label == "Ready")
    for blocked in [
      LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple, appleSupported: true,
        universalExists: false, universalState: .notReady, heartIsStreaming: false,
        active: .needsDownload(name: "German")),
      LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple, appleSupported: true,
        universalExists: false, universalState: .notReady, heartIsStreaming: false,
        active: .ready(tag: "de-DE", name: "German"), anInstallIsInFlight: true),
      LivePreviewStatusMapping.summary(isEnabled: true, engine: .apple, appleSupported: true,
        universalExists: false, universalState: .notReady, heartIsStreaming: false,
        active: .ready(tag: "de-DE", name: "German"), activeDescribesAnotherLanguage: true),
    ] {
      #expect(EngineSummaryPresentation.previewStatus(blocked).tone != .ready)
      #expect(EngineSummaryPresentation.showsDetail(blocked))
    }
  }
}
