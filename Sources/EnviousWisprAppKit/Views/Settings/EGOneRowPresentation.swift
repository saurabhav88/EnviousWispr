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

  /// `engine` is the model's display name, and it is REQUIRED rather than
  /// defaulted. Two bundled engines render through this one value now, and a
  /// default would let a caller silently inherit the other model's name — the
  /// same fail-open shape removed from the health-probe spec earlier in #2649.
  /// For S1-mini the name is licence-bound and must arrive exactly as
  /// `LLMProvider.s1Mini.displayName` spells it.
  /// The sentence above a download's progress bar, whole, chosen by what is arriving: a first
  /// install, an upgrade to a named version, or an upgrade whose version is unknown (#3142).
  static func downloadingLine(
    engine: String, upgrade: EGOneUpgradeContext?, downloadSize: String
  ) -> String {
    switch upgrade {
    case nil:
      return String(
        localized: "Downloading \(engine) (\(downloadSize))",
        comment:
          "Settings > AI Polish, local model row: first download. the first %@ is the model name, the second its size."
      )
    case .named(let version):
      return String(
        localized: "Upgrading to \(engine) V\(version) (\(downloadSize))",
        comment:
          "Settings > AI Polish, local model row: upgrade download. the %@ values are the model name, its version and the size, in order."
      )
    case .unnamed:
      return String(
        localized: "Upgrading to the new \(engine) (\(downloadSize))",
        comment:
          "Settings > AI Polish, local model row: upgrade download, version unknown. the first %@ is the model name, the second the size."
      )
    }
  }

  static func forState(_ state: EGOneInstallState, engine: String) -> EGOneRowPresentation {
    switch state {
    case .notInstalled:
      return .init(
        message: "",
        primaryAction: String(
          localized: "Download \(engine)",
          comment:
            "Settings > AI Polish, local model row: button. %@ is the model name, such as EG-1."),
        showsRemove: false, versionLabel: nil)
    case .paused:
      return .init(
        message: String(
          localized: "Download paused. Resume anytime.",
          comment: "Settings > AI Polish, local model row: the user paused the model download."),
        primaryAction: String(
          localized: "Resume",
          comment: "Settings > AI Polish, local model row: button that resumes the download."),
        showsRemove: false, versionLabel: nil)
    case .updatePaused(let resumable, let targetVersion):
      // Composed from the manifest's version, never a literal. A new revision
      // ships as a manifest edit with no Swift change, so a hard-coded "V1.1"
      // would keep naming the previous model after the real one moved on —
      // confidently wrong, which is worse than saying nothing.
      // Four whole sentences, never a name phrase spliced into one (#3142).
      let message: String
      switch (resumable, targetVersion) {
      case (true, let version?):
        message = String(
          localized:
            "AI cleanup is paused. Your upgrade to \(engine) V\(version) stopped part-way.",
          comment:
            "Settings > AI Polish, local model row: an upgrade stopped. The first %@ is the model name, the second its version."
        )
      case (true, nil):
        message = String(
          localized: "AI cleanup is paused. Your upgrade to the new \(engine) stopped part-way.",
          comment:
            "Settings > AI Polish, local model row: an upgrade stopped. %@ is the model name; the version is unknown."
        )
      case (false, let version?):
        message = String(
          localized: "AI cleanup is paused until \(engine) V\(version) finishes installing.",
          comment:
            "Settings > AI Polish, local model row: an upgrade must finish. The first %@ is the model name, the second its version."
        )
      case (false, nil):
        message = String(
          localized: "AI cleanup is paused until the new \(engine) finishes installing.",
          comment:
            "Settings > AI Polish, local model row: an upgrade must finish. %@ is the model name; the version is unknown."
        )
      }
      return .init(
        message: message,
        primaryAction: resumable
          ? String(
            localized: "Resume upgrade", comment: "Settings > AI Polish, local model row: button.")
          : String(
            localized: "Finish upgrade", comment: "Settings > AI Polish, local model row: button."),
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
    case .downloading(_, let upgrade):
      // The progress row owns its own sentence (it needs the live fraction),
      // so `message` stays empty. But the VERSION belongs here with every
      // other version decision, so one test covers "blank display version
      // renders nothing" for this state too rather than only for installed.
      return .init(
        message: "",
        primaryAction: String(
          localized: "Cancel",
          comment: "Settings > AI Polish, local model row: button that stops the download."),
        showsRemove: false,
        versionLabel: upgrade.map {
          // `.unnamed` reuses the SAME fallback the paused row uses rather than
          // degrading into the first-install sentence, which is what the P2
          // was: an upgrade that stopped looking like one.
          switch $0 {
          case .named(let v):
            return String(
              localized: "\(engine) V\(v)",
              comment:
                "{R}: the installed model and its version, as in \"EG-1 V1.1\". The first %@ is the model name, the second the version."
            )
          case .unnamed:
            return String(
              localized: "the new \(engine)",
              comment:
                "Settings > AI Polish, local model row: names an upgrade whose version is unknown. %@ is the model name."
            )
          }
        })
    case .verifying:
      return .init(message: "", primaryAction: nil, showsRemove: false, versionLabel: nil)
    case .installed(let version):
      return .init(
        message: "", primaryAction: nil, showsRemove: true,
        versionLabel: version.flatMap {
          $0.isEmpty
            ? nil
            : String(
              localized: "\(engine) V\($0)",
              comment:
                "{R}: the installed model and its version, as in \"EG-1 V1.1\". The first %@ is the model name, the second the version."
            )
        })
    case .failed:
      return .init(
        message: "",
        primaryAction: String(
          localized: "Try Again",
          comment: "Settings > AI Polish, local model row: button after a failed download."),
        showsRemove: false, versionLabel: nil)
    }
  }
}
