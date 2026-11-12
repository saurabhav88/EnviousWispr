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
      physicalBytes: 64 << 30, freePages: 1000, fileBackedPages: 500, pageSize: 16_384)
    #expect(bytes == (64 << 30) - 1500 * 16_384)
  }

  @Test("free plus file-backed above the installed memory reads nil, never a wrapped number")
  func underflowIsNil() {
    #expect(
      MacMemoryReader.usedBytes(
        physicalBytes: 1000, freePages: 1, fileBackedPages: 1, pageSize: 501) == nil)
  }

  @Test("an overflowing page count reads nil")
  func overflowIsNil() {
    #expect(
      MacMemoryReader.usedBytes(
        physicalBytes: .max, freePages: .max, fileBackedPages: 1, pageSize: 1) == nil)
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
