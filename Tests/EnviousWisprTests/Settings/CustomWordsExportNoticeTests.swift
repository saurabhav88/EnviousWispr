import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1703 — pins the outcome-to-message mapping extracted from
/// `YourWordsView`'s previously private `ExportNotice`, shared with
/// `BulkDeleteConfirmSheet`.
@Suite("CustomWordsExportNotice")
struct CustomWordsExportNoticeTests {

  @Test("cancelled and exported map to nil — nothing to say")
  func noOpOutcomesMapToNil() {
    #expect(CustomWordsExportNotice.forOutcome(.cancelled) == nil)
    #expect(CustomWordsExportNotice.forOutcome(.exported) == nil)
  }

  @Test("refusedUnsafeLibrary maps to a failure notice")
  func refusedUnsafeLibraryIsFailure() throws {
    let notice = try #require(CustomWordsExportNotice.forOutcome(.refusedUnsafeLibrary))
    guard case .failure = notice else {
      Issue.record("expected .failure, got \(notice)")
      return
    }
  }

  @Test("nothingToExport maps to an info notice, not a failure")
  func nothingToExportIsInfo() throws {
    let notice = try #require(CustomWordsExportNotice.forOutcome(.nothingToExport))
    guard case .info = notice else {
      Issue.record("expected .info, got \(notice)")
      return
    }
  }

  @Test("libraryChanged maps to an info notice, not a failure")
  func libraryChangedIsInfo() throws {
    let notice = try #require(CustomWordsExportNotice.forOutcome(.libraryChanged))
    guard case .info = notice else {
      Issue.record("expected .info, got \(notice)")
      return
    }
  }

  @Test("failed(message:) maps to a failure notice carrying that exact message")
  func failedCarriesMessage() throws {
    let notice = try #require(CustomWordsExportNotice.forOutcome(.failed(message: "disk full")))
    #expect(notice == .failure("disk full"))
  }

  @Test("failure and info notices have distinct titles")
  func titlesDistinguishFailureFromInfo() {
    #expect(CustomWordsExportNotice.failure("x").title == "Export didn't finish")
    #expect(CustomWordsExportNotice.info("x").title == "Nothing was exported")
  }
}
