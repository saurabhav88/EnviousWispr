import AppKit
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import EnviousWisprAppKit
import EnviousWisprStorage

/// #4799: when these fail, a History More menu offers Save audio for an item with no audio,
/// hides it for one that has audio, lets a second save of the same item start, or a commit
/// check misreads a deleted recording as saved. The menu rows are the ones the dictation card,
/// the meeting card and the meeting page put in their menus.
@MainActor
@Suite("History Save audio offering", .tags(.productOutcome))
struct HistoryAudioOfferingTests {
  private func export(destination: URL? = nil) -> HistoryAudioExport {
    HistoryAudioExport(
      effects: HistoryAudioExport.Effects(
        chooseURL: { _ in destination }, reveal: { _ in }, notify: { _, _ in }))
  }

  @Test("no audio to save: no Save audio row")
  func hiddenWithoutAudio() {
    let export = export()
    #expect(export.menuItem(.dictation(UUID()), offered: false, start: {}) == nil)
    #expect(export.menuItem(.meeting(UUID()), offered: false, start: {}) == nil)
  }

  @Test("audio to save: an enabled Save audio row that starts the save")
  func offeredWithAudio() throws {
    let export = export()
    var started = 0
    let item = try #require(
      export.menuItem(.meeting(UUID()), offered: true, start: { started += 1 }))
    #expect(item.id == "save-audio")
    #expect(item.title == HistoryAudioExport.saveTitle)
    #expect(item.systemImage == "waveform")
    #expect(item.isEnabled)
    #expect(item.isDestructive == false)
    guard case .action(let run) = item.kind else {
      Issue.record("Save audio is an action row")
      return
    }
    run()
    #expect(started == 1)
  }

  @Test("while the item is saving, its row reads Saving audio… and cannot start another save")
  func busyWhileSaving() async throws {
    let export = export()  // The panel is cancelled: the save ends at once.
    let id = UUID()
    let request = HistoryAudioExport.Request(
      key: .meeting(id), defaultName: "Meeting", admit: { nil }, check: { .deliverable })

    // The claim is taken in the same turn as the press, before the save runs.
    let task = try #require(export.save(request))
    let busy = try #require(export.menuItem(.meeting(id), offered: true, start: {}))
    #expect(busy.title == HistoryAudioExport.savingTitle)
    #expect(busy.isEnabled == false)
    let other = try #require(export.menuItem(.meeting(UUID()), offered: true, start: {}))
    #expect(other.isEnabled, "only the item being saved is busy")

    #expect(await task.value == .cancelled)
    let after = try #require(export.menuItem(.meeting(id), offered: true, start: {}))
    #expect(after.isEnabled)
    #expect(after.title == HistoryAudioExport.saveTitle)
  }

  @Test("a dictation card offers Save audio only while its recording is available")
  func dictationOfferFollowsStatus() {
    let export = export()
    let id = UUID()
    let available = DictationRecordingStatus.available(
      url: URL(filePath: "/tmp/x.m4a"), durationMs: 1_000, pinned: false)
    #expect(export.dictationMenuItem(rowID: id, status: available, start: {}) != nil)
    #expect(export.dictationMenuItem(rowID: id, status: nil, start: {}) == nil, "not read yet")
    #expect(export.dictationMenuItem(rowID: id, status: .unreadable, start: {}) == nil)
    #expect(
      export.dictationMenuItem(
        rowID: id, status: .absent(RecordedAbsence(.deleted)), start: {}) == nil)
    #expect(export.dictationMenuItem(rowID: id, status: .absent(nil), start: {}) == nil)
  }

  @Test("the save panel suggests an .m4a name, not .mp4 (#4799 Live UAT)")
  func panelSuggestsM4A() {
    #expect(HistoryAudioExport.m4aType.preferredFilenameExtension == "m4a")
    #expect(HistoryAudioExport.m4aType.conforms(to: .audio))
  }

  @Test("a dictation commit check maps the recording owner's answer one to one")
  func dictationCheckMapping() {
    #expect(HistoryAudioExport.sourceCheck(.deliverable) == .deliverable)
    #expect(HistoryAudioExport.sourceCheck(.deleted) == .deleted)
    #expect(HistoryAudioExport.sourceCheck(.changed) == .changed)
  }
}
