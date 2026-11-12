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
/// pages (Activity Monitor's "Physical Memory − Cached Files − free"). `free_count` already
/// includes speculative pages (XNU `vm_statistics.h`), so they are not subtracted again.
/// Measured 2026-11-11 on an M5 Max, 64 GB, paired with Activity Monitor: candidate A (app +
/// wired + compressed) matched the three parts Activity Monitor lists within 0.1 GB, but its
/// headline "Memory Used" read about 1.5 GB above that sum; candidate B came within about
/// 0.5 GB of the headline and never below candidate A, so the bar never shows more room than
/// the Mac has.
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
      pageSize: UInt64(pageSize))
  }

  /// The formula alone, so its arithmetic is testable. Nil on overflow or when free plus
  /// file-backed memory exceeds the installed memory, never a wrapped huge number.
  nonisolated static func usedBytes(
    physicalBytes: UInt64, freePages: UInt64, fileBackedPages: UInt64, pageSize: UInt64
  ) -> UInt64? {
    let (pages, o1) = freePages.addingReportingOverflow(fileBackedPages)
    let (unused, o2) = pages.multipliedReportingOverflow(by: pageSize)
    guard !o1, !o2, unused <= physicalBytes else { return nil }
    return physicalBytes - unused
  }
}
