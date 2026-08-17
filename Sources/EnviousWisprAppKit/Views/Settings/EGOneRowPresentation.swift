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
    case .updatePaused(let resumable):
      return .init(
        message: resumable
          ? "AI cleanup is paused. Your upgrade to EG-1 V1.1 stopped part-way."
          : "AI cleanup is paused until EG-1 V1.1 finishes installing.",
        primaryAction: resumable ? "Resume upgrade" : "Finish upgrade",
        // A full model IS on disk and the help centre promises users can remove
        // models to reclaim storage. Withdrawing the control here would make
        // shipped documentation false.
        showsRemove: true,
        // No version label: the installed revision is the OLD one, whose
        // manifest this app bundle does not contain, so any number here would
        // be invented.
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
