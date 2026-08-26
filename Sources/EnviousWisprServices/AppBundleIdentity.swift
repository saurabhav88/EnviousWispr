import Foundation

/// Every bundle identifier THIS APPLICATION ships under.
///
/// **A family, not a string, because the two builds do not share one.** `Project.swift:175` gives the
/// dev build `com.enviouswispr.app.dev` and `:201` gives release `com.enviouswispr.app`, so
/// `Bundle.main.bundleIdentifier == other.bundleIdentifier` answers NOT OURS for the one pair that
/// matters on a development machine — a dev build looking at an installed release build, which is
/// the ordinary state of this machine. #2413's self-read guard shipped with exactly that hole and
/// cloud review found it.
///
/// **The set is CLOSED and `Project.swift` is the authority.** Every other identifier there is
/// unreachable as a frontmost application: `com.enviouswispr.asrservice[.dev]` is an XPC service
/// with no UI, and the test hosts (`com.enviouswispr.tests`, `com.enviouswispr.asrtests`) build
/// products that carry the PRODUCTION identifier, so they are already covered by `production`.
public enum AppBundleIdentity {
  /// The shipped app.
  public static let production = "com.enviouswispr.app"
  /// The development build, which runs side by side with the shipped app on this machine.
  public static let development = "com.enviouswispr.app.dev"

  /// Both, as one family.
  public static let all: Set<String> = [production, development]

  /// Whether an identifier belongs to this application, whichever build is asking.
  ///
  /// Takes an optional because every real caller reads it off an `NSRunningApplication`, where it is
  /// optional — and a missing identifier is NOT ours, since we always have one.
  public static func isOurs(_ bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return all.contains(bundleIdentifier)
  }
}
