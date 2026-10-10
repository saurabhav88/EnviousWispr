import CoreTransferable
import EnviousWisprCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

@MainActor
@Suite("History Share transfer (#3566)", .tags(.productOutcome))
struct DeliverableTextTests {
  @available(macOS 15.2, *)
  @Test(
    "Sharing from a background task reads the real History row safely",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3566", "History Share crash")
  )
  func backgroundExportReadsMainActorRow() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(text: "Share this draft.\nKeep the second line.")
      try coordinator.saveAndShow(row)
      let item = DeliverableText {
        MainActor.assertIsolated()
        return coordinator.currentRow(id: row.id)?.displayText
      }

      let data = try await Self.exportInBackground(item)
      #expect(data == Data("Share this draft.\nKeep the second line.".utf8))
    }
  }

  @available(macOS 15.2, *)
  @Test("Share resolves lazily and sees a row changed after the item was created")
  func lazyExportReadsUpdatedRow() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(text: "Earlier draft")
      try coordinator.saveAndShow(row)
      var reads = 0
      let item = DeliverableText {
        reads += 1
        return coordinator.currentRow(id: row.id)?.displayText
      }
      #expect(reads == 0, "Creating the Share item must not freeze its text")
      let updated = Transcript(id: row.id, text: "Revised draft")
      #expect(try coordinator.updateExistingRow(updated))

      let data = try await Self.exportInBackground(item)
      #expect(data == Data("Revised draft".utf8))
      #expect(reads > 0, "The actual transfer must request the resolver")
    }
  }

  @available(macOS 15.2, *)
  @Test("A History row deleted after opening Share is refused")
  func deletedRowRefusesExport() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(text: "Deleted draft")
      try coordinator.saveAndShow(row)
      let item = DeliverableText {
        coordinator.currentRow(id: row.id)?.displayText
      }
      coordinator.delete(row)
      #expect(coordinator.currentRow(id: row.id) == nil)

      await #expect(throws: (any Error).self) {
        try await Self.exportInBackground(item)
      }
    }
  }

  @available(macOS 15.2, *)
  @Test("Unavailable share text throws instead of exporting empty bytes")
  func unavailableTextRefusesExport() async {
    let item = DeliverableText { nil }
    await #expect(throws: (any Error).self) {
      try await Self.exportInBackground(item)
    }
  }

  @available(macOS 15.2, *)
  @Test("A held recovery that becomes expired before export is refused")
  func expiredRowRefusesExport() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(text: "A recoverable draft")
      try coordinator.saveAndShow(row)
      let item = DeliverableText {
        guard let current = coordinator.currentRow(id: row.id) else { return nil }
        return coordinator.textForDelivery(current)
      }
      let expired = Transcript(
        id: row.id, text: row.text,
        escapeRecoveredAt: Date().addingTimeInterval(-AppConstants.pendingTranscriptRetention - 3600),
        escapeRecoveryTakeID: "share-expiry-fixture")
      // Use the existing fixture seam: no wall-clock wait and no new expiry policy.
      coordinator.setTranscriptsForTesting([expired])
      #expect(coordinator.currentRow(id: row.id) != nil, "The unswept row still exists")
      #expect(coordinator.textForDelivery(expired) == nil)

      await #expect(throws: (any Error).self) {
        try await Self.exportInBackground(item)
      }
    }
  }

  @available(macOS 15.2, *)
  @Test("Repeated requests for the same Share item each read the current row")
  func repeatedExportReadsFreshRow() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(text: "First version")
      try coordinator.saveAndShow(row)
      let item = DeliverableText {
        coordinator.currentRow(id: row.id)?.displayText
      }
      let first = try await Self.exportInBackground(item)
      #expect(first == Data("First version".utf8))
      let updated = Transcript(id: row.id, text: "Second version")
      #expect(try coordinator.updateExistingRow(updated))

      let second = try await Self.exportInBackground(item)
      #expect(second == Data("Second version".utf8))
    }
  }

  @available(macOS 15.2, *)
  @concurrent
  private static func exportInBackground(_ item: DeliverableText) async throws -> Data {
    // Explicitly leave the suite's MainActor to exercise the system's background
    // transfer boundary, while keeping cancellation and completion structured.
    return try await item.exported(as: .plainText)
  }

  private func withCoordinator(
    _ operation: @MainActor (TranscriptCoordinator) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-share-3566-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: directory))
    try await operation(coordinator)
  }
}
