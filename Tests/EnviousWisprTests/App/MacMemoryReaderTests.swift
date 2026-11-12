import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4525 §3.1: the Mac's memory in use, as the EG-1 size cards' bar shows it. When this fails,
/// the gray part of the bar shows a wrapped or impossible number instead of disappearing.
@Suite("MacMemoryReader: installed minus free and file-backed, nil on inconsistent counters (#4525)",
  .tags(.productOutcome))
struct MacMemoryReaderTests {
  @Test("installed memory minus free and file-backed pages, times the page size")
  func formula() {
    let bytes = MacMemoryReader.usedBytes(
      physicalBytes: 64 << 30, freePages: 1000, fileBackedPages: 500, speculativePages: 0,
      pageSize: 16_384)
    #expect(bytes == (64 << 30) - 1500 * 16_384)
  }

  // PR #4527 cloud review's example: 16 GiB Mac, 1 GiB truly free, 4 GiB file-backed of which
  // 2 GiB speculative (counted in both counters). In use is 11 GiB, not 9.
  @Test("speculative pages, counted in both free and file-backed, are subtracted once")
  func speculativeIsNotSubtractedTwice() {
    let gib: UInt64 = 1 << 30
    let page: UInt64 = 16_384
    let pagesPerGiB = gib / page
    let bytes = MacMemoryReader.usedBytes(
      physicalBytes: 16 * gib, freePages: 3 * pagesPerGiB, fileBackedPages: 4 * pagesPerGiB,
      speculativePages: 2 * pagesPerGiB, pageSize: page)
    #expect(bytes == 11 * gib)
  }

  // XNU reads file-backed a moment after speculative, so speculative can exceed it on a normal
  // Mac; the bar must stay, not turn into nil.
  @Test("more speculative than file-backed pages still reads a figure")
  func speculativeAboveFileBackedStillReads() {
    #expect(
      MacMemoryReader.usedBytes(
        physicalBytes: 16, freePages: 3, fileBackedPages: 1, speculativePages: 2, pageSize: 1)
        == 14)
  }

  @Test("inconsistent counters read nil, never a wrapped number")
  func inconsistentCountersAreNil() {
    // Free plus file-backed above the installed memory.
    #expect(
      MacMemoryReader.usedBytes(
        physicalBytes: 1000, freePages: 1, fileBackedPages: 1, speculativePages: 0,
        pageSize: 501) == nil)
    // More speculative pages than free pages (free always includes them).
    #expect(
      MacMemoryReader.usedBytes(
        physicalBytes: 1 << 30, freePages: 1, fileBackedPages: 5, speculativePages: 2,
        pageSize: 1) == nil)
    // An overflowing page count.
    #expect(
      MacMemoryReader.usedBytes(
        physicalBytes: .max, freePages: .max, fileBackedPages: 1, speculativePages: 0,
        pageSize: 1) == nil)
  }

  // A live read of this Mac's counters: the answer depends on live OS state.
  @Test(
    "a live read returns a figure above zero and below this Mac's installed memory",
    .tags(.realBoundary), .realBoundaryRun)
  func liveRead() throws {
    let used = try #require(MacMemoryReader.usedBytes())
    #expect(used > 0)
    #expect(used < ProcessInfo.processInfo.physicalMemory)
  }
}
