import Darwin

/// #4525: the Mac's memory in use right now, system-wide, for the EG-1 size cards' live bar.
///
/// One `host_statistics64(HOST_VM_INFO64)` read (measured 0.55 µs on an M5 Max). Stateless apart
/// from the host port, which is taken once. It reads the whole system only: no process
/// footprint is subtracted and no child process is walked, because a process footprint is not
/// an exact share of the system figure (plan #4525 §2.1 G3).
///
/// Formula, candidate A of plan §2.5 item 5: app memory (`internal - purgeable`) + wired +
/// compressed (`compressor_page_count`, the physical pages the compressor occupies), the three
/// parts Activity Monitor lists under Memory Used. Adoption over candidate B waits on the
/// plan's paired Activity Monitor readings (§11.1 item 2).
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
      internalPages: UInt64(stats.internal_page_count),
      purgeablePages: UInt64(stats.purgeable_count),
      wiredPages: UInt64(stats.wire_count),
      compressorPages: UInt64(stats.compressor_page_count),
      pageSize: UInt64(pageSize))
  }

  /// The formula alone, so its arithmetic is testable. Nil on underflow (more purgeable pages
  /// than app pages) or overflow, never a wrapped huge number.
  nonisolated static func usedBytes(
    internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressorPages: UInt64,
    pageSize: UInt64
  ) -> UInt64? {
    guard internalPages >= purgeablePages else { return nil }
    let (withWired, o1) = (internalPages - purgeablePages).addingReportingOverflow(wiredPages)
    let (pages, o2) = withWired.addingReportingOverflow(compressorPages)
    let (bytes, o3) = pages.multipliedReportingOverflow(by: pageSize)
    guard !o1, !o2, !o3 else { return nil }
    return bytes
  }
}
