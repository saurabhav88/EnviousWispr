import Darwin
import Foundation

/// #4525: the Mac's memory in use right now, system-wide, for the EG-1 size cards' live bar.
///
/// One `host_statistics64(HOST_VM_INFO64)` read (measured 0.55 µs on an M5 Max). Stateless apart
/// from the host port, which is taken once. It reads the whole system only: no process
/// footprint is subtracted and no child process is walked, because a process footprint is not
/// an exact share of the system figure (plan #4525 §2.1 G3).
///
/// Formula, candidate B of plan §2.5 item 5: installed memory minus free pages minus file-backed
/// pages (Activity Monitor's "Physical Memory − Cached Files − free"). Speculative pages sit in
/// BOTH counters (XNU: `vm_stats` folds them into `free_count`, and `vm_page_speculate` also
/// counts them as external, file-backed pages), so they are added back once (PR #4527 cloud
/// review). Measured 2026-11-11 on an M5 Max, 64 GB, paired with Activity Monitor: the
/// app + wired + compressed sum read about 1.5 GB below Activity Monitor's headline "Memory
/// Used"; this formula, recomputed from the same paired reading, came to 31.43 GB against the
/// headline's 31.40 GB.
enum MacMemoryReader {
  /// `mach_host_self()` returns a send right each call; one is enough for the process.
  nonisolated(unsafe) private static let host = mach_host_self()

  /// Memory in use now, in bytes; nil when the system read fails or a counter is inconsistent.
  nonisolated static func usedBytes() -> UInt64? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    var pageSize: vm_size_t = 0
    guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0
    else { return nil }
    return usedBytes(
      physicalBytes: ProcessInfo.processInfo.physicalMemory,
      freePages: UInt64(stats.free_count),
      fileBackedPages: UInt64(stats.external_page_count),
      speculativePages: UInt64(stats.speculative_count),
      pageSize: UInt64(pageSize))
  }

  /// The formula alone, so its arithmetic is testable: `(free − speculative) + file-backed`, the
  /// form fastfetch uses. Speculative pages are counted in both `freePages` and
  /// `fileBackedPages`, so they are subtracted once, not twice. Only `freePages` bounds them:
  /// XNU folds the same sampled speculative value into free, but reads the file-backed count a
  /// moment later, so a normal Mac can report more speculative than file-backed pages and must
  /// not lose its bar for it. Nil on overflow, on more speculative pages than `freePages`, or
  /// when the unused memory exceeds the installed memory, never a wrapped huge number.
  nonisolated static func usedBytes(
    physicalBytes: UInt64, freePages: UInt64, fileBackedPages: UInt64, speculativePages: UInt64,
    pageSize: UInt64
  ) -> UInt64? {
    guard speculativePages <= freePages else { return nil }
    let (pages, o1) = (freePages - speculativePages)
      .addingReportingOverflow(fileBackedPages)
    let (unused, o2) = pages.multipliedReportingOverflow(by: pageSize)
    guard !o1, !o2, unused <= physicalBytes else { return nil }
    return physicalBytes - unused
  }
}
