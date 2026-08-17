import EnviousWisprLLM

/// What the EG-1 settings row SAYS and OFFERS for a given install state (#2109).
///
/// Extracted from the inline `switch` in `AIPolishSettingsView` for one reason:
/// the row and the provider-rail chip render the SAME state through two
/// independent code paths, and compile-time exhaustiveness forces both to
/// HANDLE every case while doing nothing to make them AGREE. A user meeting a
/// calm chip beside an alarmed row learns to distrust the screen, which is
/// worse than either surface being wrong alone.
///
/// A pure value makes that agreement assertable. Mirrors the existing
/// `egOneFailureCopy` precedent in the same file: copy decisions are data, not
/// view code.
struct EGOneRowPresentation: Equatable {
  /// The sentence shown under the row. Empty for states whose copy is owned by
  /// the view's own progress or status chrome (downloading, verifying,
  /// installed, failed).
  let message: String
  /// The primary button's title, or nil when the row offers no primary action.
  let primaryAction: String?
  /// Whether `Remove Model` is reachable. True only when a usable model is
  /// actually on disk.
  let showsRemove: Bool
  /// The version label to render, already composed, or nil when there is
  /// nothing honest to show. Owned here rather than in the view so it is
  /// covered by the same tests as the rest of the row: a blank or missing
  /// display version must render NOTHING, never "EG-1 V" with an empty tail.
  let versionLabel: String?

  static func forState(_ state: EGOneInstallState) -> EGOneRowPresentation {
    switch state {
    case .notInstalled:
      return .init(
        message: "", primaryAction: "Download EG-1", showsRemove: false, versionLabel: nil)
    case .paused:
      return .init(
        message: "Download paused. Resume anytime.",
        primaryAction: "Resume", showsRemove: false, versionLabel: nil)
    case .updatePaused(let resumable, let targetVersion):
      // Composed from the manifest's version, never a literal. A new revision
      // ships as a manifest edit with no Swift change, so a hard-coded "V1.1"
      // would keep naming the previous model after the real one moved on —
      // confidently wrong, which is worse than saying nothing.
      let target = targetVersion.map { "EG-1 V\($0)" } ?? "the new EG-1"
      return .init(
        message: resumable
          ? "AI cleanup is paused. Your upgrade to \(target) stopped part-way."
          : "AI cleanup is paused until \(target) finishes installing.",
        primaryAction: resumable ? "Resume upgrade" : "Finish upgrade",
        // NO Remove button here, and this reverses an earlier decision of mine.
        // I added it arguing the help centre promises users can remove models
        // to reclaim storage. That promise is real, but `remove()` deletes the
        // CURRENT manifest's files and marker — and in this state the current
        // revision is precisely what is NOT installed. Pressing it would leave
        // the older model's gigabytes and its marker untouched and return the
        // row to this same state: a button that visibly does nothing, which is
        // the exact defect fixed for Resume elsewhere in this change.
        //
        // Hiding it restores the behaviour that shipped before this change
        // (there was no Remove button in this state), so no promise is broken
        // that was not already. Reclaiming a superseded revision on demand
        // needs prior-marker removal, which does not exist yet — tracked
        // rather than faked.
        showsRemove: false,
        // No version label: the INSTALLED revision is the old one, whose
        // manifest this bundle does not contain, so any number here would be
        // invented. The target version above is a different thing.
        versionLabel: nil)
    case .downloading:
      return .init(message: "", primaryAction: "Cancel", showsRemove: false, versionLabel: nil)
    case .verifying:
      return .init(message: "", primaryAction: nil, showsRemove: false, versionLabel: nil)
    case .installed(let version):
      return .init(
        message: "", primaryAction: nil, showsRemove: true,
        versionLabel: version.flatMap { $0.isEmpty ? nil : "EG-1 V\($0)" })
    case .failed:
      return .init(message: "", primaryAction: "Try Again", showsRemove: false, versionLabel: nil)
    }
  }
}
