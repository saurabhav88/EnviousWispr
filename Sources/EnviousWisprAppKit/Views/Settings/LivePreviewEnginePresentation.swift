import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import Foundation

/// #2123: what each engine card says, in every state the Mac can be in.
///
/// A TYPE rather than logic inside the view, for the reason
/// `LivePreviewPackPresentation` records: a view-local `if` chain can only be
/// checked by reading it, and the state space here is the whole point of the
/// chunk — engine × OS support × admission × download progress. This is the part
/// where "it says something sensible in every cell" is a claim that can be
/// tested, and where a missing cell is a user staring at a card with no next step.
///
/// **The boundary, stated exactly:** these tests protect WHAT EACH STATE SAYS and
/// WHICH ACTION IT OFFERS. They do NOT protect the SwiftUI wiring — if the view
/// stopped calling this, or drew the action button without hooking it up, the
/// tests would still pass. That half is a Live UAT item, declared in the plan.
enum LivePreviewEnginePresentation {

  /// The single action a card offers, or none.
  ///
  /// Closed on purpose: every action here has to be something the app can
  /// actually do. A build defect deliberately has NO action, because inventing
  /// one would point the user at a button that cannot help them.
  enum Action: Equatable {
    case download
    case cancelDownload
    case resumeDownload
    case retryDownload
    case remove
  }

  /// One rendered card.
  struct Card: Equatable {
    let title: String
    /// What this engine IS, in the user's terms. Present in EVERY state, because
    /// the Help article is routed to its own issue and a user meeting these two
    /// names for the first time has nothing else to go on.
    let description: String
    /// Why it cannot run right now, or nil when it can.
    let unavailability: String?
    let action: Action?
    /// Live progress, guaranteed finite and within `0...1`, or nil.
    ///
    /// Normalized rather than forwarded: manifest validation permits zero or
    /// non-positive sizes, so the delivery layer can produce a NaN or an
    /// out-of-range fraction, and a progress bar fed either draws nonsense. A
    /// value that cannot be rendered honestly becomes no bar at all.
    let progress: Double?
    let isSelected: Bool
  }

  /// Apple's card. No delivery state: its languages are the OS's business and the
  /// pack list below the picker owns them.
  static func appleCard(isSelected: Bool, isSupported: Bool) -> Card {
    Card(
      title: LivePreviewEngineCopy.appleTitle,
      description: LivePreviewEngineCopy.appleDescription,
      unavailability: isSupported ? nil : LivePreviewEngineCopy.appleNeedsNewerMacOS,
      // Apple's engine is never downloaded or removed by us: macOS owns it, and
      // its per-language packs have their own controls on this page already.
      action: nil,
      progress: nil,
      isSelected: isSelected)
  }

  /// The universal engine's card.
  ///
  /// `routeExists` is false only when the app was built without the engine's
  /// manifest or tokenizer. It is checked FIRST because in that state the
  /// delivery state is meaningless — there is nothing registered to download.
  static func universalCard(
    isSelected: Bool,
    routeExists: Bool,
    state: DeliveryState
  ) -> Card {
    guard routeExists else {
      return Card(
        title: LivePreviewEngineCopy.universalTitle,
        description: LivePreviewEngineCopy.universalDescription,
        unavailability: LivePreviewEngineCopy.unavailableInThisBuild,
        // No action ON PURPOSE. Nothing shipped for this engine, so no button
        // could supply it; the remedy is a release-build resource check, ours,
        // not the user's.
        action: nil,
        progress: nil,
        isSelected: isSelected)
    }

    let title = LivePreviewEngineCopy.universalTitle
    let description = LivePreviewEngineCopy.universalDescription

    switch state {
    case .admitted:
      return Card(
        title: title, description: description, unavailability: nil,
        action: .remove, progress: nil, isSelected: isSelected)

    case .downloading(let fraction, _, _):
      return Card(
        title: title, description: description, unavailability: nil,
        action: .cancelDownload, progress: Self.renderableProgress(fraction),
        isSelected: isSelected)

    // Preparing and verifying are both "work is happening, no fraction yet".
    // Separate cases rather than a shared one so the compiler asks again if
    // either ever needs its own sentence.
    case .preparing:
      return Card(
        title: title, description: description, unavailability: nil,
        action: .cancelDownload, progress: nil, isSelected: isSelected)
    case .verifying:
      return Card(
        title: title, description: description, unavailability: nil,
        action: .cancelDownload, progress: nil, isSelected: isSelected)

    case .failed:
      return Card(
        title: title, description: description,
        unavailability: LivePreviewEngineCopy.downloadFailed,
        action: .retryDownload, progress: nil, isSelected: isSelected)

    // **`resumable` decides the VERB and nothing more.**
    //
    // It reports whether STAGED PARTIALS exist, not whether the next attempt
    // starts from zero: the controller can still retain verified in-place
    // components and skip them on the next fetch. So "Resume" is honest when it
    // is true, and the false case must NOT promise a fresh start — an earlier
    // draft of this copy said "it will start again from the beginning", which
    // sounds careful and is wrong. It says the download stopped, and offers to
    // download, which is all we actually know.
    case .cancelled(let resumable):
      return Card(
        title: title, description: description,
        unavailability: resumable
          ? LivePreviewEngineCopy.downloadCancelled
          : LivePreviewEngineCopy.downloadStopped,
        action: resumable ? .resumeDownload : .download,
        progress: nil, isSelected: isSelected)

    case .notReady:
      return Card(
        title: title, description: description,
        unavailability: LivePreviewEngineCopy.notDownloadedYet,
        action: .download, progress: nil, isSelected: isSelected)
    }
  }

  /// A fraction the UI can draw, or nil.
  ///
  /// NaN and infinity are dropped rather than clamped: they mean the size was
  /// unknown, and inventing 0% would show a bar that never moves. A merely
  /// out-of-range finite value is clamped, since it is a real measurement that
  /// overshot.
  /// What the universal engine's language row says, and the reason it lives HERE
  /// rather than beside the strings it returns.
  ///
  /// It is a SELECTION, which is this type's job — the same argument the header
  /// makes for the cards: an `if` chain in the view body can only be checked by
  /// reading it. Keeping it in the copy file also left both paused strings
  /// referenced from nowhere outside that file, which is precisely what
  /// `LivePreviewPackCopyTests.everyStringIsActuallyUsed` exists to catch, and it
  /// caught them. That guard is right: a string reachable only from its own
  /// declaration file has no evidence of reaching a screen.
  ///
  /// Takes READINESS, never a single blocker. `engineWillProduceOutput` comes from
  /// `LivePreviewStatusMapping.universalWillProduceOutput`, the same answer the
  /// hero card derives its chip from. An earlier version took `heartIsStreaming`,
  /// one of six reasons the preview will not run, and promised output for the
  /// other five.
  static func universalRowLabel(languageName: String?, engineWillProduceOutput: Bool) -> String {
    switch (languageName, engineWillProduceOutput) {
    case (.some(let name), true): return LivePreviewSettingsCopy.universalLocked(name)
    case (.some(let name), false): return LivePreviewSettingsCopy.universalLockedPaused(name)
    case (.none, true): return LivePreviewSettingsCopy.universalAuto
    case (.none, false): return LivePreviewSettingsCopy.universalAutoPaused
    }
  }

  static func renderableProgress(_ fraction: Double) -> Double? {
    guard fraction.isFinite else { return nil }
    return min(max(fraction, 0), 1)
  }

  /// Should the page offer Apple's downloadable language packs?
  ///
  /// Both conditions, and the second one was missing (founder, 2026-08-17). The
  /// packs are APPLE's languages: the universal engine carries its own and has
  /// none to manage, so showing the manager beside it asks the user to configure
  /// something that cannot affect what they are about to see.
  ///
  /// Pulled out of the view body deliberately. It lived there as a two-term `if`
  /// whose own comment already said "still Apple's question" while the condition
  /// checked only the OS — the reasoning was written down and never implemented,
  /// and nothing but a human eye would have caught it. A comment cannot fail; a
  /// function can.
  ///
  /// `isAppleSupported` alone still governs whether the packs EXIST to manage —
  /// below macOS 26 there are none — so it stays as the first term rather than
  /// being folded into the engine check.
  static func showsApplePacks(isAppleSupported: Bool, isUsingApple: Bool) -> Bool {
    isAppleSupported && isUsingApple
  }
}

/// Copy for the engine picker, kept beside the presentation that uses it.
///
/// Separate from `LivePreviewCopy` (which the recording pill uses) because these
/// sentences are read while DECIDING, not while dictating, and the two audiences
/// want different lengths.
enum LivePreviewEngineCopy {
  static let sectionHeader = "Preview engine"

  /// #2154. The two engines differ in OS floor, language coverage and download
  /// size; a card cannot carry that comparison without becoming the article.
  /// This is the first link from a settings page to the Help Centre, so the
  /// destination has to exist before the link ships — it does, added in the same
  /// change (#2134).
  static let learnMoreLabel = "Learn more about engines"
  static let learnMoreURL = "https://enviouswispr.com/help/live-preview-words-on-screen/"

  static let appleTitle = "Apple"
  static let appleDescription =
    "Uses Apple's speech recognition. No separate preview-model download; some languages may "
    + "need an Apple language download. Needs macOS 26."
  static let appleNeedsNewerMacOS = "Needs macOS 26 or later."

  static let universalTitle = "Universal"
  static let universalDescription =
    "Works on macOS 14 and later, in more languages. Needs one optional 217 MB download."
  static let notDownloadedYet = "Not downloaded yet."
  static let downloadFailed = "The download did not finish."
  static let downloadCancelled = "Download paused. It will pick up where it stopped."
  /// The other half of a cancel: nothing usable was kept, so the honest verb is
  /// "download" rather than "resume".
  /// Deliberately claims NOTHING about what was kept. `resumable: false` means no
  /// staged partials, not "nothing on disk" — verified components can survive and
  /// be skipped next time, so any promise about starting over would be false.
  static let downloadStopped = "Download stopped."
  /// No remedy offered: a build shipped without the engine's files is ours to fix.
  static let unavailableInThisBuild =
    "This version of EnviousWispr cannot run that preview engine."
}
