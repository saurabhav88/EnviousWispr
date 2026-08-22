import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2292 chunk C4b. The presentation transaction.
///
/// **Product Outcome.** When these fail the user sees a pill dismissed by a
/// timer belonging to a dictation that already ended, a button that does nothing
/// because its handler was dropped, or an Undo that pastes the wrong transcript.
///
/// **No clock anywhere.** The scheduler is a seam: the test holds the armed work
/// and fires it itself, so "the timer fired" is an event the test causes rather
/// than something it waits for. `never-guess-when-the-subject-is-finished`
/// forbids waiting on time; here there is nothing to wait for.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayDirectorTests {

  init() { _ = NSApplication.shared }

  private final class Armed {
    var work: OverlayScheduledWork?
  }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  private static func director() -> (OverlayDirector, Armed) {
    let armed = Armed()
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { screen } })
    let d = OverlayDirector(
      host: host, scheduler: .manual { armed.work = $0 })
    return (d, armed)
  }

  // MARK: - Exactly one expiry

  /// **The defect `PresentationID` exists to close.** Seven independently owned
  /// staleness mechanisms in the shipped code each answered "is this deferred
  /// work still valid" their own way, and nothing held them to the same answer.
  @Test("a timer armed for a dismissed pill cannot dismiss its replacement")
  func staleTimerCannotDismissTheLivePill() {
    let (d, armed) = Self.director()
    d.send(.pipeline(.warning(reason: .polishFailed)))
    let staleTimer = try! #require(armed.work)

    d.send(.pipeline(.recording(audioLevel: 0.4)))
    let live = try! #require(d.currentPresentationForTesting?.id)

    staleTimer.fireForTesting()

    #expect(
      d.currentPresentationForTesting?.id == live,
      "a timer from a finished notice closed the live recording pill")
  }

  /// A new occupant REPLACES the armed expiry rather than leaving it running.
  @Test("arming a new expiry cancels the previous one")
  func armingReplacesTheArmedExpiry() {
    let (d, armed) = Self.director()
    d.send(.pipeline(.warning(reason: .polishFailed)))
    let first = try! #require(armed.work)

    d.send(.pipeline(.error(reason: .asrFailed)))

    #expect(first.isCancelled, "the previous pill's timer was left running")
    #expect(armed.work !== first, "a second timer was armed without replacing the first")
  }

  /// A persistent presentation cancels rather than inheriting.
  @Test("a persistent pill leaves no timer armed")
  func persistentPillDisarms() {
    let (d, armed) = Self.director()
    d.send(.pipeline(.warning(reason: .polishFailed)))
    let notice = try! #require(armed.work)

    d.send(.pipeline(.recording(audioLevel: 0.2)))

    #expect(notice.isCancelled)
    #expect(d.hasArmedExpiryForTesting == false, "the recording pill armed a dismissal")
  }

  /// The paired accepted case: a timed pill's OWN timer must still work, or
  /// every guard above is satisfied by a director that never dismisses anything.
  @Test("a pill's own timer dismisses it")
  func ownTimerDismisses() {
    let (d, armed) = Self.director()
    d.send(.pipeline(.warning(reason: .polishFailed)))

    try! #require(armed.work).fireForTesting()

    #expect(d.currentPresentationForTesting == nil)
  }

  // MARK: - Exactly one action binding

  @Test("an action reaches the feature that owns the live pill")
  func actionReachesItsOwner() {
    let (d, _) = Self.director()
    d.send(.pipeline(.accessibilityToast))
    let id = try! #require(d.currentPresentationForTesting?.id)

    var delivered: [OverlayAction] = []
    d.bindActions(for: id) { delivered.append($0) }
    d.send(.action(id, .grantAccessibility))

    #expect(delivered == [.grantAccessibility])
  }

  /// **A binding must not outlive its pill.** The shipped panel keeps eight
  /// handler closures alive for the app's lifetime whether or not the pill that
  /// uses them is showing.
  @Test("a binding is dropped when its pill is replaced")
  func bindingDiesWithItsPill() {
    let (d, _) = Self.director()
    d.send(.pipeline(.accessibilityToast))
    let toast = try! #require(d.currentPresentationForTesting?.id)
    var delivered: [OverlayAction] = []
    d.bindActions(for: toast) { delivered.append($0) }

    d.send(.pipeline(.recording(audioLevel: 0.3)))

    #expect(d.hasActiveBindingForTesting == false)
    d.send(.action(toast, .grantAccessibility))
    #expect(delivered.isEmpty, "an action from a dismissed pill reached its old handler")
  }

  @Test("a binding for a pill that is not current is refused")
  func bindingForAStalePillIsRefused() {
    let (d, _) = Self.director()
    d.send(.pipeline(.accessibilityToast))
    let stale = try! #require(d.currentPresentationForTesting?.id)
    d.send(.pipeline(.recording(audioLevel: 0.1)))

    d.bindActions(for: stale) { _ in }

    #expect(d.hasActiveBindingForTesting == false)
  }

  // MARK: - Payload custody

  /// The payload is taken ONCE. A second Undo press must find nothing rather
  /// than paste the transcript again.
  @Test("the cancelled transcript is handed over exactly once")
  func payloadIsTakenOnce() {
    let (d, _) = Self.director()
    let transcript = UUID()
    d.presentEscapeRecovery(
      CancelUndoPayload(transcriptID: transcript, targetApp: nil, targetElement: nil),
      transcriptID: transcript)

    #expect(d.takeEscapeRecoveryPayload(matching: transcript) != nil)
    #expect(
      d.takeEscapeRecoveryPayload(matching: transcript) == nil,
      "the payload was handed over twice — a double press would paste twice")
  }

  @Test("a payload is never handed to a different transcript")
  func payloadIsKeyedToItsTranscript() {
    let (d, _) = Self.director()
    let mine = UUID()
    d.presentEscapeRecovery(
      CancelUndoPayload(transcriptID: mine, targetApp: nil, targetElement: nil),
      transcriptID: mine)

    #expect(d.takeEscapeRecoveryPayload(matching: UUID()) == nil)
  }

  /// Custody ends with the pill. Otherwise a payload outlives the dictation it
  /// belongs to and the next Undo could reach it.
  @Test("the payload is released when the pill goes")
  func payloadIsReleasedWithThePill() {
    let (d, _) = Self.director()
    let transcript = UUID()
    d.presentEscapeRecovery(
      CancelUndoPayload(transcriptID: transcript, targetApp: nil, targetElement: nil),
      transcriptID: transcript)
    #expect(d.holdsEscapeRecoveryPayloadForTesting)

    d.send(.pipeline(.hidden))

    #expect(
      d.holdsEscapeRecoveryPayloadForTesting == false,
      "a cancelled transcript outlived the pill offering to restore it")
  }
}
