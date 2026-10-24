import Darwin
import Foundation

/// The macOS "System Audio Recording" permission that EnviousMeet's call sound needs (#4017 R2).
///
/// macOS has no public API to read or request this permission: it asks the first time a process
/// tap starts recording. This reads and requests it through TCC's private functions
/// `TCCAccessPreflight` and `TCCAccessRequest` for `kTCCServiceAudioCapture`, loaded at run time
/// (the technique AudioCap documents, github.com/insidegui/AudioCap). EnviousWispr ships with a
/// Developer ID, not through the App Store. A missing symbol or an unexpected answer is
/// `.unknown`, never `.granted`, so a later macOS that changes these functions degrades to
/// "we cannot tell", and the first recording still makes macOS ask.
public enum SystemAudioPermission {
  public enum Status: String, Sendable, Equatable {
    case granted
    case denied
    /// Never asked, or the answer cannot be read.
    case unknown
  }

  private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

  private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
  private typealias RequestFunction =
    @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void

  // Read-only after first use; the loaded image stays for the process lifetime.
  nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

  private static let preflightFunction: PreflightFunction? = {
    guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
    return unsafeBitCast(symbol, to: PreflightFunction.self)
  }()

  private static let requestFunction: RequestFunction? = {
    guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
    return unsafeBitCast(symbol, to: RequestFunction.self)
  }()

  /// Whether the private functions loaded on this macOS.
  public static var isAvailable: Bool { preflightFunction != nil && requestFunction != nil }

  /// The current answer, without asking. 0 is granted and 1 is denied; anything else (including
  /// "not asked yet") is unknown.
  public static func status() -> Status {
    guard let preflightFunction else { return .unknown }
    switch preflightFunction(service, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .unknown
    }
  }

  /// Makes macOS ask, without starting any capture. Returns the answer macOS gave, or `.unknown`
  /// when the function is missing. macOS shows its prompt only once; after a refusal this
  /// returns `.denied` at once and the user changes it in System Settings.
  public static func request() async -> Status {
    guard let requestFunction else { return .unknown }
    let granted = await withCheckedContinuation {
      (continuation: CheckedContinuation<Bool, Never>) in
      requestFunction(service, nil) { granted in continuation.resume(returning: granted) }
    }
    return granted ? .granted : .denied
  }
}
