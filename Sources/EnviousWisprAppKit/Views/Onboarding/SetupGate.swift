import EnviousWisprCore
import EnviousWisprServices
import Foundation
import SwiftUI

/// Downloads and Getting ready's words and cards (#4528 D4a.2, plan M83; mockup `isGate`,
/// `gateCards`, `gateMic`, `warmTitle`/`warmSub`, copy verbatim where the live facts support it).
/// One pure mapping from `OnboardingDownloadsPresentation`: nothing here reads an owner, starts
/// work or decides a step. Unsupported mockup claims are left out on purpose: no percent for a
/// paused or failed transfer (no retained fraction), no claim about who stopped it, no ETA (no
/// owner estimate), and disk space from the measured requirement.
enum SetupGate {
  enum Screen: Equatable { case downloads, gettingReady }

  enum Tone: Equatable { case pending, working, done, error }

  /// A card's own action. Only actions that act on that one card's model live in a card;
  /// both-download Retry/Cancel are the shared row (`sharedControls`).
  enum CardAction: Equatable {
    case retryWarmup, retryPolish, turnPolishOn, changePolish
  }

  struct Card: Equatable, Identifiable {
    var id: String
    var eyebrow: String
    var name: String
    var tone: Tone
    var status: String
    /// Shown only for a measured transfer.
    var percent: Int?
    /// nil hides the bar; a value draws it; `indeterminate` animates it.
    var fraction: Double?
    var showsBar: Bool
    var indeterminate: Bool
    var action: CardAction?
    var actionTitle: String?
  }

  /// A permission row on Getting ready (shown only when that grant is missing, or the microphone
  /// as the mockup's ready row).
  struct PermissionRow: Equatable, Identifiable {
    var id: String
    var title: String
    var status: String
    var done: Bool
  }

  enum SharedControl: Equatable { case retryDownloads, cancelDownloads }

  /// Names and sizes from the owners, supplied by the screen (never literals here).
  struct Names {
    var speech: (ASRBackendType) -> String
    var speechBytes: (ASRBackendType) -> Int64?
    var polish: (String) -> String
    var polishBytes: (String) -> Int64?
    var cloudProvider: String?
  }

  // MARK: Problems

  enum Problem: Equatable { case disk(needed: Int64), download, engine, polish }

  static func problem(_ p: OnboardingDownloadsPresentation, screen: Screen) -> Problem? {
    if case .insufficientDisk(let needed, _)? = p.block { return .disk(needed: needed) }
    if p.block != nil || stopped(p.speechPhase) || p.polishPreparation == .downloadStopped {
      return .download
    }
    if screen == .gettingReady, p.warmFailed { return .engine }
    if screen == .gettingReady, p.polishPreparation == .failed { return .polish }
    return nil
  }

  static func stopped(_ phase: OnboardingDownloadPhase?) -> Bool {
    switch phase {
    case .paused?, .failed?, .unavailable?: true
    default: false
    }
  }

  /// Both downloads at once, never inside one card.
  static func sharedControls(_ p: OnboardingDownloadsPresentation) -> [SharedControl] {
    if p.block != nil || stopped(p.speechPhase) || p.polishPreparation == .downloadStopped {
      return [.retryDownloads]
    }
    let speechMoving: Bool = {
      if case .downloading? = p.speechPhase { return true }
      return p.speechPhase == .verifying
    }()
    return speechMoving || p.polishPreparation == .downloading ? [.cancelDownloads] : []
  }

  // MARK: Words

  static func badge(_ screen: Screen) -> String {
    screen == .downloads
      ? String(localized: "Download", comment: "Setup Downloads: the eyebrow above the title.")
      : String(
        localized: "Finishing up", comment: "Setup Getting ready: the eyebrow above the title.")
  }

  static func twoModels(_ p: OnboardingDownloadsPresentation) -> Bool { p.polishPhase != nil }

  static func title(_ p: OnboardingDownloadsPresentation, screen: Screen, names: Names) -> String {
    switch problem(p, screen: screen) {
    case .disk?:
      return String(
        localized: "Free up space to continue", comment: "Setup Downloads title: disk short.")
    case .download?:
      return String(
        localized: "Resume your download", comment: "Setup Downloads title: a download stopped.")
    case .engine?:
      return String(
        localized: "Start dictation again", comment: "Setup Getting ready title: warm-up failed.")
    case .polish?:
      return String(
        localized: "AI polish did not start",
        comment: "Setup Getting ready title: the polish model failed to load.")
    case nil:
      break
    }
    guard screen == .downloads else {
      return String(localized: "Almost ready", comment: "Setup Getting ready title.")
    }
    let speechName = p.speech.map(names.speech) ?? ""
    if p.downloadsFinished {
      return twoModels(p)
        ? String(
          localized: "Your models are ready",
          comment: "Setup Downloads title: both models are on this Mac.")
        : String(
          localized: "\(speechName) is ready",
          comment: "Setup Downloads title: the speech model is on this Mac.")
    }
    return twoModels(p)
      ? String(localized: "Downloading your models", comment: "Setup Downloads title: both models.")
      : String(
        localized: "Downloading \(speechName)", comment: "Setup Downloads title: the speech model.")
  }

  /// #4845 D-C: Getting ready's time-left line, shown only while the polish model is actually
  /// transferring with a known estimate and nothing is wrong. nil hides it.
  static func timeLeft(
    _ p: OnboardingDownloadsPresentation, screen: Screen, secondsLeft: Double?
  ) -> String? {
    guard screen == .gettingReady, problem(p, screen: screen) == nil,
      p.polishPreparation == .downloading, case .downloading? = p.polishPhase,
      let seconds = secondsLeft, seconds.isFinite, seconds >= 0
    else { return nil }
    if seconds < 60 {
      return String(
        localized: "Less than a minute left.",
        comment: "Setup Getting ready: the AI polish download should finish within a minute.")
    }
    if seconds < 90 {
      return String(
        localized: "About a minute left.",
        comment: "Setup Getting ready: about one minute of AI polish download is left.")
    }
    let minutes = Int((seconds / 60).rounded())
    return String(
      localized: "About \(minutes) minutes left.",
      comment:
        "Setup Getting ready: the AI polish download time left. %lld is a whole number of minutes, 2 or more.")
  }

  static func subtitle(
    _ p: OnboardingDownloadsPresentation, screen: Screen, secondsLeft: Double? = nil
  ) -> String {
    switch problem(p, screen: screen) {
    case .disk(let needed)?:
      let size = EGOneSizeCardCopy.byteCount(needed)
      return String(
        localized:
          "This Mac needs \(size) free for these downloads.\nMake room, then press Try again.",
        comment:
          "Setup Downloads subtitle: disk short. %@ is the measured space needed, such as 2.4 GB.")
    case .download?:
      return String(
        localized:
          "The download stopped.\nPress Resume downloads to try again.",
        comment: "Setup Downloads subtitle: a download stopped.")
    case .engine?:
      return String(
        localized: "Dictation needs one more start.\nPress Try again below.",
        comment: "Setup Getting ready subtitle: warm-up failed.")
    case .polish?:
      return String(
        localized:
          "Press Try again, or continue without AI polish.\nYou can turn it on later in Settings.",
        comment: "Setup Getting ready subtitle: the polish model failed to load.")
    case nil:
      break
    }
    guard screen == .downloads else {
      let starts = String(
        localized: "Your first dictation starts the moment this finishes.",
        comment: "Setup Getting ready subtitle.")
      guard let left = timeLeft(p, screen: screen, secondsLeft: secondsLeft) else { return starts }
      return left + "\n" + starts
    }
    if p.downloadsFinished {
      let done = String(
        localized: "Everything you picked is on this Mac now.",
        comment: "Setup Downloads subtitle: finished.")
      guard p.isCountingDown else { return done }
      return done + "\n"
        + String(
          localized: "Taking you to the next step.",
          comment: "Setup Downloads: the 1.6 s countdown runs.")
    }
    let keepGoing = String(
      localized: "You can keep setting up while this runs.",
      comment: "Setup Downloads subtitle: downloading.")
    guard p.isNetworkSlow else { return keepGoing }
    return String(
      localized: "Your internet is slow right now.",
      comment: "Setup Downloads: the slow-network notice.")
      + " " + keepGoing
  }

  static func note(_ p: OnboardingDownloadsPresentation) -> String {
    if p.downloadsFinished {
      return String(
        localized: "Nothing else to wait for.", comment: "Setup Downloads footer note: finished.")
    }
    if problem(p, screen: .downloads) != nil {
      return String(
        localized: "You can keep setting up and resume later.",
        comment: "Setup Downloads footer note: a problem.")
    }
    return String(
      localized: "The download keeps going on every screen.",
      comment: "Setup Downloads footer note: downloading.")
  }

  // MARK: Cards

  static func cards(
    _ p: OnboardingDownloadsPresentation, screen: Screen, names: Names
  ) -> [Card] {
    var cards: [Card] = []
    if let speech = p.speech {
      cards.append(speechCard(p, speech: speech, screen: screen, names: names))
    }
    if let card = polishCard(p, screen: screen, names: names) { cards.append(card) }
    return cards
  }

  static func speechCard(
    _ p: OnboardingDownloadsPresentation, speech: ASRBackendType, screen: Screen, names: Names
  ) -> Card {
    let eyebrow = String(localized: "Speech model", comment: "Setup Downloads card eyebrow.")
    var card = Card(
      id: "speech", eyebrow: eyebrow, name: names.speech(speech), tone: .working,
      status: gettingStarted, percent: nil, fraction: nil, showsBar: true, indeterminate: true,
      action: nil, actionTitle: nil)
    if case .insufficientDisk(let needed, _)? = p.block {
      card.tone = .error
      card.status = String(
        localized: "Needs about \(EGOneSizeCardCopy.byteCount(needed)) of free space.",
        comment: "Setup Downloads card: disk short. %@ is the measured space needed.")
      card.showsBar = false
      return card
    }
    switch p.speechPhase {
    case .downloading(let fraction?)?:
      card.fraction = fraction
      card.indeterminate = false
      card.percent = Int((fraction * 100).rounded(.down))
      if let total = names.speechBytes(speech) {
        let done = EGOneSizeCardCopy.byteCount(Int64(Double(total) * fraction))
        card.status = String(
          localized: "Downloading · \(done) of \(EGOneSizeCardCopy.byteCount(total))",
          comment: "Setup Downloads card: %1$@ downloaded of %2$@.")
      } else {
        card.status = downloading
      }
    case .verifying?:
      card.status = installing
    case .paused?, .failed?, .unavailable?:
      card.tone = .error
      card.status = stoppedText
      card.showsBar = false
    case .installed?:
      card.showsBar = false
      if screen == .downloads {
        card.tone = .done
        card.status = String(
          localized: "Downloaded and installed", comment: "Setup Downloads card: done.")
      } else if p.warmFailed {
        card.tone = .error
        card.status = String(
          localized: "Installed. Dictation needs one more start.",
          comment: "Setup Getting ready card: warm-up failed.")
        card.action = .retryWarmup
        card.actionTitle = tryAgain
      } else if p.engineWarm {
        card.tone = .done
        card.status = String(
          localized: "Ready to dictate", comment: "Setup Getting ready card: warm.")
      } else {
        card.status = String(
          localized: "Installed. Getting dictation ready…",
          comment: "Setup Getting ready card: warming.")
      }
    case .downloading(nil)?, .unknown?, .notStarted?, nil:
      break
    }
    return card
  }

  static func polishCard(
    _ p: OnboardingDownloadsPresentation, screen: Screen, names: Names
  ) -> Card? {
    let eyebrow = String(localized: "AI polish", comment: "Setup Downloads card eyebrow.")
    let base = Card(
      id: "polish", eyebrow: eyebrow, name: p.polish.map(names.polish) ?? "", tone: .pending,
      status: "", percent: nil, fraction: nil, showsBar: false, indeterminate: false, action: nil,
      actionTitle: nil)
    let size = p.polish.flatMap(names.polishBytes).map { EGOneSizeCardCopy.byteCount($0) }
    var card = base
    switch p.polishPreparation {
    case .none:
      return nil
    case .off:
      card.name = String(
        localized: "Turned off", comment: "Setup Downloads card: AI polish skipped.")
      card.status = String(
        localized: "Your words are typed as you said them.",
        comment: "Setup Downloads card: AI polish off.")
      if screen == .downloads {
        card.action = .turnPolishOn
        card.actionTitle = String(
          localized: "Turn on", comment: "Setup Downloads card: turn AI polish back on.")
      }
    case .appleIntelligence(let available):
      card.tone = available ? .done : .error
      card.status =
        available
        ? String(
          localized: "Built into your Mac. Nothing to download.",
          comment: "Setup Downloads card: Apple Intelligence ready.")
        : String(
          localized: "Apple Intelligence is not available right now.",
          comment: "Setup Downloads card: Apple Intelligence cannot run now; no reason claimed.")
      if !available, screen == .downloads {
        card.action = .changePolish
        card.actionTitle = changePolish
      }
    case .cloud(let passed):
      card.name = names.cloudProvider ?? card.name
      card.tone = passed ? .done : .error
      card.status =
        passed
        ? String(
          localized: "Your key works. Ready.", comment: "Setup Downloads card: cloud key passed.")
        : String(
          localized: "Your key needs checking again.",
          comment: "Setup Downloads card: the cloud key check no longer passes.")
      if !passed, screen == .downloads {
        card.action = .changePolish
        card.actionTitle = changePolish
      }
    case .queued:
      card.status =
        size.map {
          String(
            localized: "Starts right after the speech model · \($0)",
            comment: "Setup Downloads card: polish waits for speech. %@ is its size.")
        }
        ?? String(
          localized: "Starts right after the speech model", comment: "Setup Downloads card.")
    case .waiting:
      card.tone = .working
      card.status = gettingStarted
      card.showsBar = true
      card.indeterminate = true
    case .downloading:
      card.tone = .working
      card.showsBar = true
      if case .downloading(let fraction?)? = p.polishPhase {
        card.fraction = fraction
        card.percent = Int((fraction * 100).rounded(.down))
      } else {
        card.indeterminate = true
      }
      card.status =
        p.polishPhase == .verifying
        ? installing
        : (size.map {
          String(
            localized: "Downloading · \($0)",
            comment: "Setup Downloads card: polish downloading. %@ is its size.")
        } ?? downloading)
    case .downloadStopped:
      card.tone = .error
      card.status = stoppedText
    case .loading:
      if screen == .downloads {
        card.tone = .done
        card.status = String(
          localized: "Downloaded", comment: "Setup Downloads card: polish on this Mac.")
      } else {
        card.tone = .working
        card.status = String(
          localized: "Downloaded. Loading the model…",
          comment: "Setup Getting ready card: polish loading.")
      }
    case .ready:
      card.tone = .done
      card.status =
        screen == .downloads
        ? String(localized: "Downloaded", comment: "Setup Downloads card: polish on this Mac.")
        : String(
          localized: "Downloaded, loaded and ready to polish",
          comment: "Setup Getting ready card: polish ready.")
    case .failed:
      card.tone = .error
      card.status = String(
        localized: "Downloaded. The model did not start.",
        comment: "Setup Getting ready card: the polish model failed to load.")
      card.action = .retryPolish
      card.actionTitle = tryAgain
    }
    return card
  }

  /// Getting ready's permission rows: the microphone always (mockup `gateMic`), Accessibility
  /// only when it is off (a revoked grant needs the way back).
  static func permissionRows(_ p: OnboardingDownloadsPresentation) -> [PermissionRow] {
    var rows = [
      PermissionRow(
        id: "microphone",
        title: String(localized: "Microphone", comment: "Setup Getting ready row."),
        status: p.microphoneGranted
          ? String(
            localized: "Allowed. Ready to hear you.", comment: "Setup Getting ready: microphone on."
          )
          : String(localized: "Needs your OK.", comment: "Setup Getting ready: microphone off."),
        done: p.microphoneGranted)
    ]
    if !p.accessibilityGranted {
      rows.append(
        PermissionRow(
          id: "accessibility",
          title: String(localized: "Accessibility", comment: "Setup Getting ready row."),
          status: String(
            localized: "Needs your OK.", comment: "Setup Getting ready: accessibility off."),
          done: false))
    }
    return rows
  }

  /// Getting ready's ways forward besides the main button: back to Permissions when a grant is
  /// off; continue without AI polish when polish cannot get ready.
  static func gettingReadyRoutes(_ p: OnboardingDownloadsPresentation) -> (
    permissions: Bool, withoutPolish: Bool
  ) {
    let permissions = !p.microphoneGranted || !p.accessibilityGranted
    let withoutPolish: Bool = {
      switch p.polishPreparation {
      case .failed, .downloadStopped: return true
      case .appleIntelligence(let available): return !available
      case .cloud(let passed): return !passed
      default: return false
      }
    }()
    return (permissions, withoutPolish)
  }

  struct RecoveryAction {
    let title: LocalizedStringKey
    let event: OnboardingEvent
  }

  static func recoveryActions(_ p: OnboardingDownloadsPresentation) -> [RecoveryAction] {
    let routes = gettingReadyRoutes(p)
    var actions: [RecoveryAction] = []
    if routes.permissions {
      actions.append(.init(title: "Review permissions", event: .reviewPermissions))
    }
    if p.warmFailed || p.block != nil || stopped(p.speechPhase) {
      actions.append(.init(title: "Change speech model", event: .changeSpeech))
    }
    if routes.withoutPolish {
      if case .cloud(passed: false) = p.polishPreparation {
        actions.append(.init(title: "Check AI polish key", event: .reviewCloudKey))
      }
      actions.append(.init(title: "Change AI polish", event: .changePolish))
      actions.append(.init(title: "Continue without AI polish", event: .continueWithoutPolish))
    }
    return actions
  }

  // MARK: Skip ahead (#4845)

  static let offerTitle = String(
    localized: "This download is taking longer than expected.",
    comment: "Setup Getting ready: the Skip ahead card's title while AI polish downloads slowly.")
  static let offerBody = String(
    localized:
      "You can skip ahead and start dictating now. AI polish keeps downloading in the background and turns on by itself when it is done.",
    comment: "Setup Getting ready: the Skip ahead card's explanation.")
  static let skipAhead = String(
    localized: "Skip ahead",
    comment: "Setup Getting ready: button that opens practice now while AI polish downloads.")
  static let keepWaiting = String(
    localized: "Keep waiting",
    comment: "Setup Getting ready: button that keeps waiting for the AI polish download.")
  /// One sentence so translators can order it; the bold words are the action.
  static var ratherNotWait: LocalizedStringKey { "Rather not wait? **Skip ahead**" }
  /// The same sentence for VoiceOver, without the emphasis marks.
  static let ratherNotWaitLabel = String(
    localized: "Rather not wait? Skip ahead",
    comment: "Setup Getting ready: VoiceOver label of the one-line Skip ahead button.")

  // MARK: Shared words

  static let gettingStarted = String(
    localized: "Getting started…", comment: "Setup Downloads card: preparing.")
  static let downloading = String(localized: "Downloading…", comment: "Setup Downloads card.")
  static let installing = String(
    localized: "Installing…", comment: "Setup Downloads card: verifying.")
  static let stoppedText = String(
    localized: "The download stopped.",
    comment: "Setup Downloads card: paused, failed or unavailable; no cause claimed.")
  static let tryAgain = String(
    localized: "Try again", comment: "Setup Downloads: retry one card's step.")
  static let changePolish = String(
    localized: "Change AI polish", comment: "Setup Downloads card: back to the polish choice.")
}
