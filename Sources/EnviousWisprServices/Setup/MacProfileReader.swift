import EnviousWisprCore
import Foundation

/// Builds a `MacProfile` from this Mac (#4528 plan §3.2, M20). The one place advice reads memory,
/// the macOS version, the chip name, free disk space and the Mac's language list.
///
/// Every system read is an injectable closure, so tests hand in a pretend Mac. Live in-use memory
/// for the size cards' warnings is a different question and stays with `MacMemoryReader`.
public struct MacProfileReader: Sendable {
  public var physicalMemoryBytes: @Sendable () -> UInt64
  public var macOSMajor: @Sendable () -> Int
  public var chipName: @Sendable () -> String?
  public var freeDiskBytes: @Sendable () -> Int64?
  /// The Mac's own preferred languages, from the global domain, never the app's interface override
  /// (plan M20: `Locale.current` and `Bundle.main` follow the app language, AppLanguagePreference.swift).
  public var systemLanguages: @Sendable () -> [String]

  /// A reader with every system read handed in (tests, and the live factory below).
  public init(
    physicalMemoryBytes: @escaping @Sendable () -> UInt64,
    macOSMajor: @escaping @Sendable () -> Int,
    chipName: @escaping @Sendable () -> String?,
    freeDiskBytes: @escaping @Sendable () -> Int64?,
    systemLanguages: @escaping @Sendable () -> [String]
  ) {
    self.physicalMemoryBytes = physicalMemoryBytes
    self.macOSMajor = macOSMajor
    self.chipName = chipName
    self.freeDiskBytes = freeDiskBytes
    self.systemLanguages = systemLanguages
  }

  /// The reader for this Mac.
  public static var live: MacProfileReader {
    MacProfileReader(
      physicalMemoryBytes: { ProcessInfo.processInfo.physicalMemory },
      macOSMajor: { ProcessInfo.processInfo.operatingSystemVersion.majorVersion },
      chipName: { chipBrandString() },
      freeDiskBytes: { startupVolumeFreeBytes() },
      systemLanguages: { globalPreferredLanguages() })
  }

  /// Bytes per binary gigabyte; Macs report whole GiB of installed memory.
  static let bytesPerGiB: UInt64 = 1 << 30

  /// One profile. `appleIntelligence` comes from the availability report's own mapping (M24).
  public func read(appleIntelligence: AppleIntelligenceSetupState) -> MacProfile {
    MacProfile(
      memoryGiB: Int(physicalMemoryBytes() / Self.bytesPerGiB),
      chipName: chipName(),
      macOSMajor: macOSMajor(),
      appleIntelligence: appleIntelligence,
      macLanguages: systemLanguages(),
      freeDiskBytes: freeDiskBytes())
  }

  // MARK: Live system reads

  /// The global-domain `AppleLanguages` list, the same source `AppLanguagePreference.systemPreferences`
  /// reads in the app.
  private static func globalPreferredLanguages() -> [String] {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
      as? [String] ?? []
  }

  private static func chipBrandString() -> String? {
    let name = "machdep.cpu.brand_string"
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func startupVolumeFreeBytes() -> Int64? {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }
}
