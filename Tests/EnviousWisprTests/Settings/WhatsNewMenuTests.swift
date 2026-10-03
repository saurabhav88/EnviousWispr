import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("What's New menu", .tags(.productOutcome))
struct WhatsNewMenuTests {
  @Test("Current release retains every entry in source order, with compact descriptions")
  func currentRelease() {
    let entries = WhatsNewMenuPresentation.entries()
    #expect(
      entries.map(\.id) == [
        "privacy-controls", "word-check-memory", "help-before-feedback",
        "keybind-conflict-warning", "clipboard-restored-in-chrome",
        "paste-to-starting-chrome-window", "longer-undo-for-learned-words",
        "self-learning-skips-punctuation",
      ])
    #expect(
      entries.first?.description
        == "Choose usage metrics and crash reports in App Settings > Privacy. Feedback lets you choose diagnostics."
    )
    #expect(WhatsNewMenuPresentation.entries(version: "no-such-release").isEmpty)
  }

  @Test("Compact and full fallback copy both use localized entry keys")
  func localizedCopyAndFallback() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ew-gift-\(UUID()).bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appending(path: "en.lproj")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let table = [
      "whatsNew.privacy-controls.title": "Translated title",
      "whatsNew.privacy-controls.compactDescription": "Translated compact description",
      "whatsNew.future-entry.description": "Translated full description",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: table, format: .binary, options: 0)
    try data.write(to: resources.appending(path: "Localizable.strings"))
    let bundle = try #require(Bundle(url: root))
    let known = try #require(WhatsNewContent.entries.first { $0.id == "privacy-controls" })
    let future = WhatsNewContent.Entry(
      id: "future-entry", icon: "gift", title: "Future", description: "Full English description",
      version: "2.5.2")
    let rows = WhatsNewMenuPresentation.entries(from: [known, future], bundle: bundle)
    #expect(rows.map(\.title) == ["Translated title", "Future"])
    #expect(
      rows.map(\.description) == ["Translated compact description", "Translated full description"])
    #expect(
      WhatsNewMenuPresentation.entries(from: [future]).first?.description
        == "Full English description")
  }

  @Test("Toolbar rendering and an unfulfilled open request leave unread notes intact")
  func renderingDoesNotMarkSeen() throws {
    _ = NSApplication.shared
    let defaults = try #require(TestDefaults.suite("ew.gift.\(UUID().uuidString)"))
    defaults.set("old-version", forKey: WhatsNewConstants.lastSeenVersionDefaultsKey)
    let settings = SettingsManager(defaults: defaults)
    let host = NSHostingView(
      rootView: WhatsNewToolbarButton()
        .environment(settings).environment(UpdateCoordinatorHolder()))
    _ = host.fittingSize
    var presentation = WhatsNewMenuPresentation()
    presentation.didOpen(settings: settings)
    presentation.requestOpen()
    #expect(settings.hasUnreadWhatsNew == true)
    #expect(defaults.string(forKey: WhatsNewConstants.lastSeenVersionDefaultsKey) == "old-version")
  }

  @Test("Actual open clears and persists unread; dismissal and reopening are harmless")
  func seenOnOpen() throws {
    let defaults = try #require(TestDefaults.suite("ew.gift.\(UUID().uuidString)"))
    defaults.set("old-version", forKey: WhatsNewConstants.lastSeenVersionDefaultsKey)
    let settings = SettingsManager(defaults: defaults)
    var presentation = WhatsNewMenuPresentation()
    presentation.requestOpen()
    presentation.didOpen(settings: settings)
    #expect(settings.hasUnreadWhatsNew == false)
    #expect(defaults.string(forKey: WhatsNewConstants.lastSeenVersionDefaultsKey) == "2.5.2")
    presentation.dismiss()
    #expect(presentation.isPresented == false)
    presentation.requestOpen()
    presentation.didOpen(settings: settings)
    #expect(settings.lastSeenWhatsNewVersion == "2.5.2")
  }

  @Test("Update copy states only what the availability service knows")
  func honestUpdateStatus() {
    #expect(WhatsNewMenuPresentation.updateStatus(nil) == .unavailable)
    #expect(
      WhatsNewMenuPresentation.updateStatus(UpdateAvailabilityService.UpdateState.none)
        == .checkPrompt)
    #expect(WhatsNewMenuPresentation.updateStatus(.resolving) == .opening)
    let update = UpdateAvailabilityService.AvailableUpdate(
      versionString: "2503", displayVersion: "2.5.3", isCriticalUpdate: false)
    #expect(WhatsNewMenuPresentation.updateStatus(.available(update)) == .available("2.5.3"))
    #expect(WhatsNewMenuPresentation.UpdateStatus.unavailable.canCheck == false)
    #expect(WhatsNewMenuPresentation.UpdateStatus.opening.canCheck == false)
    #expect(WhatsNewMenuPresentation.UpdateStatus.checkPrompt.canCheck == true)
    #expect(WhatsNewMenuPresentation.UpdateStatus.available("2.5.3").canCheck == true)
  }
}
