import Foundation

/// Generic secret/key resolver shared across every EnviousWispr process. Checks
/// the process `Info.plist` first (stamped at build time for release builds),
/// then falls back to the `~/.enviouswispr-keys/<fileName>` file (dev builds).
/// Moved verbatim from `EnviousWisprServices.ObservabilityBootstrap` (#1174) so
/// the app and the two XPC helpers resolve keys through the identical path — the
/// helpers already read `homeDirectoryForCurrentUser` successfully, so the file
/// fallback works in a non-sandboxed helper with zero new wiring.
public enum KeyResolver {

  /// Resolves a key by checking Info.plist first, then falling back to the file
  /// system path `~/.enviouswispr-keys/<fileName>`. Returns `nil` when neither
  /// source yields a non-empty value.
  public static func resolveKey(plistKey: String, fileName: String) -> String? {
    // Try Info.plist first (stamped at build time for release builds)
    if let plistValue = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
      !plistValue.isEmpty
    {
      return plistValue
    }

    // Fall back to file system (dev builds)
    let keysDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".enviouswispr-keys")
    let keyFile = keysDir.appendingPathComponent(fileName)
    if let value = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines),
      !value.isEmpty
    {
      return value
    }

    return nil
  }
}
