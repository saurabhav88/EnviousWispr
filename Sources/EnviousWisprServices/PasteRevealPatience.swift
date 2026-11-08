import Foundation

/// How long a key paste into one app may take to become visible to the arrival reader on THIS Mac,
/// learned from this Mac's own pastes (#4426).
///
/// Why it exists: many apps reveal pasted text to Accessibility after the 300 ms landing decision
/// (fleet, 30 days to 2026-11-07: 1,666 late sightings after an `absent` decision, p50 491 ms, p99
/// 1,556 ms, mostly Chrome, Claude and Codex). Keeping the dictation on the clipboard and showing
/// "Copied" for those is a false notice. Each paste freezes an effective patience from this learned
/// estimate (floored by the app's deadline, capped at 2,500 ms); a potential miss is not kept
/// before that scheduled moment, and a sighting within it never keeps.
///
/// One rule, "grow fast, shrink slowly", per bundle id:
/// - start at `defaultMs`;
/// - each admitted sample x proposes target = clamp(1.5 x, `floorMs`, `capMs`);
/// - a larger target is adopted at once, also during warm-up;
/// - a smaller one is adopted only after `warmUpSamples` admitted samples, and then by at most 10%
///   per sample.
/// No sample history is kept, so one wrong sample (of any origin) can lower patience by at most
/// 10% and can never evict earlier evidence. Grounded review r4 rejected a rolling window because a
/// single contaminated sample could evict the slow maximum and drop 2,400 ms to 750 ms.
///
/// Overlapping key pastes: every key-paste dispatch takes a per-bundle sequence number. A sighting
/// whose dispatch is no longer the newest for its bundle is not admitted, because the text seen may
/// belong to the newer paste. Other writers (AX direct insertion, Paste Last) are not tracked; a
/// sample they contaminate is still bounded by the 10% step.
///
/// In memory only: nothing is persisted, and the table restarts at `defaultMs` on every launch.
/// Not a singleton: production creates one instance at bootstrap and injects it; tests make their own.
@MainActor
package final class PasteRevealPatience {

  /// Today's late-hit shadow; covers 1,642 of the 1,666 fleet late sightings within the window
  /// that measured them.
  nonisolated package static let defaultMs = 1500
  /// The landing decision's own default deadline: patience never resolves sooner than it.
  nonisolated package static let floorMs = 300
  /// The cleanup's 3.0 s decision bound minus a 500 ms margin.
  nonisolated package static let capMs = 2500
  /// Admitted samples before patience may shrink.
  nonisolated package static let warmUpSamples = 10
  /// Patience proposed for a sample, as a multiple of it.
  nonisolated package static let margin = 1.5
  /// The most patience keeps per shrinking sample.
  nonisolated package static let shrinkFactor = 0.9

  /// One key-paste dispatch, issued by `recordDispatch(bundleID:)` before the paste is posted.
  package struct DispatchToken: Equatable, Sendable {
    package let bundleID: String
    package let sequence: UInt64
  }

  private struct AppState {
    /// Kept unrounded, so repeated 10% steps are exact; read through `patienceMs`.
    var patience = Double(PasteRevealPatience.defaultMs)
    var admitted = 0
  }

  private var apps: [String: AppState] = [:]
  private var newestDispatch: [String: UInt64] = [:]
  private var nextSequence: UInt64 = 0

  package init() {}

  /// The patience for the next paste into `bundleID`, in whole milliseconds. An app that cannot be
  /// named gets the default and teaches nothing.
  package func patienceMs(bundleID: String?) -> Int {
    guard let bundleID, let app = apps[bundleID] else { return Self.defaultMs }
    return Int(app.patience.rounded())
  }

  /// Marks a key-paste dispatch to `bundleID` as the newest for that app. Nil for an unnamed app.
  package func recordDispatch(bundleID: String?) -> DispatchToken? {
    guard let bundleID else { return nil }
    nextSequence &+= 1
    newestDispatch[bundleID] = nextSequence
    return DispatchToken(bundleID: bundleID, sequence: nextSequence)
  }

  /// Learns from the first sighting of a paste, `revealMs` after its dispatch. Returns whether the
  /// sample was admitted. A sighting from a dispatch that a newer one to the same app has since
  /// replaced, or a negative time, is refused and changes nothing.
  @discardableResult
  package func recordSighting(_ token: DispatchToken, revealMs: Int) -> Bool {
    guard revealMs >= 0, newestDispatch[token.bundleID] == token.sequence else { return false }
    var app = apps[token.bundleID] ?? AppState()
    app.admitted += 1
    let target = min(
      Double(Self.capMs), max(Double(Self.floorMs), Self.margin * Double(revealMs)))
    if target > app.patience {
      app.patience = target
    } else if app.admitted >= Self.warmUpSamples {
      app.patience = max(target, Self.shrinkFactor * app.patience)
    }
    apps[token.bundleID] = app
    return true
  }
}
