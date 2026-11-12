import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4525 §3.1: the Mac's memory in use, as the EG-1 size cards' bar shows it. When this fails,
/// the gray part of the bar shows a wrapped or impossible number instead of disappearing.
@Suite("MacMemoryReader: app + wired + compressed, nil on inconsistent counters (#4525)",
  .tags(.productOutcome))
struct MacMemoryReaderTests {
  @Test("app memory (internal minus purgeable) plus wired plus compressed, times the page size")
  func formula() {
    let bytes = MacMemoryReader.usedBytes(
      internalPages: 1000, purgeablePages: 100, wiredPages: 200, compressorPages: 50,
      pageSize: 16_384)
    #expect(bytes == 1150 * 16_384)
  }

  @Test("more purgeable than app pages reads nil, never a wrapped huge number")
  func underflowIsNil() {
    #expect(
      MacMemoryReader.usedBytes(
        internalPages: 10, purgeablePages: 11, wiredPages: 0, compressorPages: 0,
        pageSize: 16_384) == nil)
  }

  @Test("an overflowing total reads nil")
  func overflowIsNil() {
    #expect(
      MacMemoryReader.usedBytes(
        internalPages: .max, purgeablePages: 0, wiredPages: 1, compressorPages: 0,
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
