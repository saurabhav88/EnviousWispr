import Foundation

/// #3027: the `asr_failed` capture for a raw CoreML error kept only the numeric
/// code (0, "generic") and dropped Apple's own description, so 35 events across
/// 6 users could not say whether inference failed on ANE compile, input shape,
/// or memory. These keys ride in the capture's extra UNCLIPPED: the beforeSend
/// sanitizer (`SentryEventSanitizer`) is the privacy authority and its
/// whole-value redaction of any non-URL string over 100 characters is deliberate
/// defence-in-depth (sentry-operations.md FACT: server-side-data-scrubbing), so
/// a producer must not shorten a value to slip under it. When Apple's prose is
/// long, `coreml.code`, `coreml.underlying` and `coreml.description_chars` still
/// survive. Apple text only; no transcript can reach an NSError raised inside
/// CoreML inference.
enum CoreMLFailureExtras {
  /// Empty when `error` is not a `com.apple.CoreML` NSError, so callers can
  /// merge unconditionally.
  static func build(_ error: any Error) -> [String: Any] {
    let ns = error as NSError
    guard ns.domain == "com.apple.CoreML" else { return [:] }
    var extra: [String: Any] = [
      "coreml.code": ns.code,
      "coreml.description": ns.localizedDescription,
      "coreml.description_chars": ns.localizedDescription.count,
    ]
    if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
      extra["coreml.failure_reason"] = reason
    }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
      extra["coreml.underlying"] = "\(underlying.domain)#\(underlying.code)"
    }
    return extra
  }
}
