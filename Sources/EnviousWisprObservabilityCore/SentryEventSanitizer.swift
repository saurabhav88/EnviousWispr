import Foundation
import Sentry

/// The single privacy sanitizer shared by every EnviousWispr process — the main
/// app and both XPC helper processes. Moved verbatim from
/// `EnviousWisprServices.ObservabilityBootstrap` (#1174) so all three processes
/// run the IDENTICAL redactor: one source of truth, no copy to drift. The
/// redaction tripwire (#1095) guards the exact output; `ObservabilityBootstrap`
/// keeps thin forwarders so its call sites + the existing tests stay
/// byte-identical.
public enum SentryEventSanitizer {

  /// Sanitize a Sentry event in place and return it. This is the EXACT body the
  /// SDK `beforeSend` runs — the FINAL payload seam (#1095). Asserted by the
  /// redaction tripwire so dictation text can never reach the wire payload.
  /// Pure, idempotent, and never throws (a limb — heart path is unaffected).
  public static func sanitize(_ event: Event) -> Event {
    // Redact event message (SentryMessage wraps formatted + raw strings)
    if let sentryMsg = event.message {
      let redacted = redactString(sentryMsg.formatted)
      if redacted != sentryMsg.formatted {
        event.message = SentryMessage(formatted: redacted)
      }
    }

    // Redact extra context values
    if let extra = event.extra {
      event.extra = redactDict(extra)
    }

    // Redact breadcrumb messages and data
    if let crumbs = event.breadcrumbs {
      for crumb in crumbs {
        if let msg = crumb.message {
          crumb.message = redactString(msg)
        }
        if let data = crumb.data {
          crumb.data = redactDict(data)
        }
      }
    }

    // Redact exception value + mechanism data. Sentry's native crash
    // handler captures the formatted exception message into
    // `event.exceptions[].value`; without this pass, a future
    // `fatalError("transcript=\(text)")` would leak. Verified during V3
    // audit (#566): no current call sites interpolate transcript-typed
    // values into fatal traps, but defense-in-depth — a regression
    // would be invisible until users started crashing.
    if let exceptions = event.exceptions {
      for exception in exceptions {
        if let value = exception.value {
          exception.value = redactString(value)
        }
        if let mechData = exception.mechanism?.data {
          exception.mechanism?.data = redactDict(mechData)
        }
      }
    }

    // Redact context dictionaries (arbitrary nested string values).
    // Current contexts are diagnostic counts/statuses, but context is
    // the natural place where future diagnostic strings would land —
    // protect it now so a future change doesn't bypass redaction.
    if let context = event.context {
      var redactedContext: [String: [String: Any]] = [:]
      for (key, inner) in context {
        redactedContext[key] = redactDict(inner)
      }
      event.context = redactedContext
    }

    // Redact tag values. Current tags are low-cardinality strings
    // (build_type, app_version), but cheap defense-in-depth against
    // a future tag whose value bleeds transcript-shaped data.
    if let tags = event.tags {
      var redactedTags: [String: String] = [:]
      for (key, value) in tags {
        redactedTags[key] = redactString(value)
      }
      event.tags = redactedTags
    }

    // #1095 Layer C — native-crash surfaces. Hard crashes (segfault /
    // NSException) are written to disk and replayed through `beforeSend` on
    // next launch carrying stack frames + `debugMeta` (and no `message`). These
    // fields hold image/source paths, not dictation, but a release build's
    // paths can embed the developer/user home directory (`/Users/<name>/…`).
    // Clear the host identifier and scrub the username segment from every
    // stack-frame and debug-image path so a crash report carries no identity.
    // Frames live in three serialized surfaces — `event.stacktrace`, each
    // `thread.stacktrace`, and each `exception.stacktrace` (the SDK sets the
    // crashed thread's stacktrace directly on the exception for native crashes)
    // — so cover all three, not just `threads`.
    event.serverName = nil
    redactUserPaths(in: event.stacktrace)
    for thread in event.threads ?? [] {
      redactUserPaths(in: thread.stacktrace)
    }
    for exception in event.exceptions ?? [] {
      redactUserPaths(in: exception.stacktrace)
    }
    for meta in event.debugMeta ?? [] {
      if let codeFile = meta.codeFile { meta.codeFile = redactUserPath(codeFile) }
    }

    return event
  }

  /// Scrub `/Users/<name>/` usernames from every frame's path fields in a
  /// stacktrace, in place. No-op for a nil stacktrace. (#1095 Layer C helper.)
  private static func redactUserPaths(in stacktrace: SentryStacktrace?) {
    guard let frames = stacktrace?.frames else { return }
    for frame in frames {
      if let package = frame.package { frame.package = redactUserPath(package) }
      if let fileName = frame.fileName { frame.fileName = redactUserPath(fileName) }
    }
  }

  /// Replace the username segment of a macOS home path (`/Users/<name>/…`)
  /// with a placeholder, leaving the rest of the path intact for triage.
  /// No-op when the string contains no such segment. Idempotent; never throws.
  /// Mirrors the server-side "Usernames in filepaths" scrubbing rule (#1095).
  public static func redactUserPath(_ input: String) -> String {
    input.replacingOccurrences(
      of: #"/Users/[^/]+"#,
      with: "/Users/[REDACTED]",
      options: .regularExpression
    )
  }

  /// Keys whose String value is content-free BY CONSTRUCTION and would otherwise
  /// trip a heuristic below (#2965). Each is named by what produces it, so a
  /// reader can check the value cannot carry user text:
  /// - `trace_id`, `span_id`, `parent_span_id`: Sentry SDK trace context, 32/16
  ///   hex. Blanking `trace_id` made the server discard the value and record two
  ///   `invalid_data` ingestion errors on EVERY event.
  /// - `kernel_version`: Sentry SDK OS context, the Darwin kernel banner (>100
  ///   chars).
  /// - `device_app_hash`: Sentry SDK app context, a 40-hex hash; the `app.device`
  ///   tag Sentry derives from it arrived `[REDACTED]`.
  /// - `revision`: the model delivery manifest's git SHA
  ///   (`ModelDeliveryTelemetryBridge`), a 40-hex value on ~5,000 PostHog rows a
  ///   month.
  /// The exemption is by KEY only and only for a String value; a nested container
  /// under one of these keys is still walked. A future emitter that reuses one of
  /// these names for free text gets no scrubbing, so the names stay this specific.
  public static let contentFreeKeys: Set<String> = [
    "trace_id", "span_id", "parent_span_id", "kernel_version", "device_app_hash", "revision",
  ]

  /// Redact every String value in a `[String: Any]` dictionary recursively,
  /// leaving non-string scalar values untouched. Shared by Sentry beforeSend redaction
  /// of `event.extra`, `breadcrumb.data`, `event.context`, and
  /// `exception.mechanism.data`, and by the PostHog property bag. Key-aware: a
  /// String under a `contentFreeKeys` name passes through verbatim.
  public static func redactDict(_ input: [String: Any]) -> [String: Any] {
    var output: [String: Any] = [:]
    for (key, value) in input {
      if contentFreeKeys.contains(key), let str = value as? String {
        output[key] = str
      } else {
        output[key] = redactValue(value)
      }
    }
    return output
  }

  public static func redactValue(_ value: Any) -> Any {
    if let str = value as? String {
      return redactString(str)
    }
    if let dict = value as? [String: Any] {
      return redactDict(dict)
    }
    if let array = value as? [Any] {
      return array.map(redactValue)
    }
    return value
  }

  /// Redacts a string if it matches known PII patterns:
  /// - Long strings (> 100 chars) that are not URLs (likely transcript content)
  /// - API key patterns: sk-*, phc_*, sntrys_*, key_*, or >= 32 contiguous hex chars
  /// - Email-like patterns
  /// Returns `[REDACTED]` if EITHER the raw input or its username-scrubbed form
  /// matches a pattern, else the scrubbed form (#2965). Both forms are judged
  /// because the scrub changes the length: a short username grows to
  /// `[REDACTED]` and a long one shrinks, and either direction could flip the
  /// length or hex verdict on its own. Judging both keeps every pre-#2965
  /// redaction and keeps the function idempotent (a second pass sees an
  /// already-scrubbed string whose two forms are identical). The scrub exists
  /// because the frame/debug-image scrub covers only the native-crash surfaces,
  /// and a short `String(describing:)` in an extra or a PostHog property can
  /// carry a home path.
  /// Never throws — any regex failure is silently ignored.
  public static func redactString(_ raw: String) -> String {
    let scrubbed = redactUserPath(raw)
    if matchesDenylist(raw) || matchesDenylist(scrubbed) {
      return "[REDACTED]"
    }
    return scrubbed
  }

  /// The pattern set behind `redactString`; pure, no rewriting.
  private static func matchesDenylist(_ input: String) -> Bool {
    // Long non-URL strings (transcript content heuristic)
    if input.count > 100 {
      let lower = input.lowercased()
      if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
        return true
      }
    }

    // API key patterns
    let apiKeyPrefixes = ["sk-", "phc_", "sntrys_", "key_"]
    for prefix in apiKeyPrefixes {
      if input.lowercased().hasPrefix(prefix) && input.count >= 20 {
        return true
      }
    }

    // 32+ contiguous hex characters (generic secret/token heuristic)
    if let hexRange = input.range(of: "[0-9a-fA-F]{32,}", options: .regularExpression),
      hexRange == input.startIndex..<input.endIndex || input.count <= input[hexRange].count + 8
    {
      return true
    }

    // Email pattern: something@something.something
    if input.range(
      of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
      options: .regularExpression) != nil
    {
      return true
    }

    return false
  }
}
