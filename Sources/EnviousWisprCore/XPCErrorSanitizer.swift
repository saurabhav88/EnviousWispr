import Foundation

/// Converts an `Error` into an `NSError` whose userInfo contains exactly
/// one key (`NSLocalizedDescriptionKey`), safe to cross an `NSXPCConnection`
/// without `NSXPCInterface.setClasses(_:for:argumentIndex:ofReply:)` registration.
///
/// The `NSLocalizedDescriptionKey` value is the flattened `localizedDescription`
/// of the error plus every `NSUnderlyingErrorKey` ancestor, joined by ` <- `.
/// Preserves OSStatus / AVFoundation diagnostic chains that would otherwise
/// be lost when userInfo is stripped. When there is no underlying chain but
/// `NSLocalizedFailureReasonErrorKey` is present and differs from the top
/// description, the failure reason is appended (preserves Cocoa-style errors
/// that encode detail only in `failureReason`).
///
/// Invariants:
/// - Output userInfo keys == [NSLocalizedDescriptionKey] exactly.
/// - Output domain == (error as NSError).domain.
/// - Output code == (error as NSError).code.
/// - Output is securely codable over XPC by construction.
///
/// Note: this sanitizer targets service→host XPC reply boundaries today. If
/// future XPC methods pass `NSError` host→service (as a method argument, not
/// a reply), those arguments must also be sanitized or the service will crash
/// on decode. The CI check `scripts/check-xpc-error-hygiene.sh` guards against
/// raw `safeReply(error as NSError)` regressions.
public enum XPCErrorSanitizer {
  /// Maximum depth of `NSUnderlyingErrorKey` ancestry to flatten. Real-world
  /// chains are usually ≤ 3-4; 8 is a failsafe against pathological recursion.
  private static let maxChainDepth = 8

  public static func sanitizeForXPC(_ error: any Error) -> NSError {
    let ns = error as NSError
    var descriptions: [String] = [ns.localizedDescription]
    var cursor = ns

    for _ in 0..<maxChainDepth {
      guard let underlying = cursor.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
      descriptions.append(underlying.localizedDescription)
      cursor = underlying
    }

    // If no underlying chain was walked and `failureReason` adds signal,
    // append it so callers still see the detail on Cocoa-style errors.
    if descriptions.count == 1,
      let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
      !reason.isEmpty,
      reason != ns.localizedDescription
    {
      descriptions.append(reason)
    }

    return NSError(
      domain: ns.domain,
      code: ns.code,
      userInfo: [NSLocalizedDescriptionKey: descriptions.joined(separator: " <- ")]
    )
  }
}
