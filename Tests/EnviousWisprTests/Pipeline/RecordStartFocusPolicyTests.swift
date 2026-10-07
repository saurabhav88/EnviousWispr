import AppKit
import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// Product Outcome (#3423): which application a dictation is pasted into, decided at record start.
///
/// When this fails, a person who started dictating in a floating launcher panel (Raycast) gets
/// "Copied" because the paste was aimed at the app behind the panel; or a helper process (a
/// browser's content process, a save-panel service) becomes the target and the front app's paste
/// policies stop applying to it.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordStartFocusPolicyTests {
  let field = AXUIElementCreateApplication(10_042)

  /// Two distinct, live applications: the front one, and the one owning the focus.
  func apps() throws -> (front: NSRunningApplication, owner: NSRunningApplication) {
    let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
    try #require(running.count >= 2, "two live applications")
    return (running[0], running[1])
  }

  func record(
    front: NSRunningApplication?, focus: KeyboardFocusRead,
    owner: NSRunningApplication?, eligible: Bool, ownPID: pid_t = -2,
    context: KernelSessionContext = KernelSessionContext()
  ) -> (KernelSessionContext, String?) {
    let bundle = context.recordStartTarget(
      front: front, focus: focus, trusted: true, captureWindow: { _ in nil },
      ownerApplication: { _ in owner }, isEligibleOwner: { _ in eligible }, ownPID: ownPID)
    return (context, bundle)
  }

  @Test("the owner of the focused field becomes the target only when it is another eligible app")
  func ownerSubstitution() throws {
    let (front, owner) = try apps()
    let launcher: KeyboardFocusRead = .focused(element: field, ownerPID: owner.processIdentifier)

    let (agree, agreeBundle) = record(
      front: front, focus: .focused(element: field, ownerPID: front.processIdentifier),
      owner: owner, eligible: true)
    #expect(agree.focusOwnerState == .agree)
    #expect(agree.targetApp == front)
    #expect(agreeBundle == front.bundleIdentifier)

    let (disagree, disagreeBundle) = record(
      front: front, focus: launcher, owner: owner, eligible: true)
    #expect(disagree.focusOwnerState == .disagree)
    #expect(disagree.targetApp == owner, "the launcher's own app is the target")
    #expect(disagree.targetElement == field)
    #expect(disagreeBundle == owner.bundleIdentifier)

    let (noFront, _) = record(front: nil, focus: launcher, owner: owner, eligible: true)
    #expect(noFront.focusOwnerState == .disagree)
    #expect(noFront.targetApp == owner)
  }

  @Test(
    "a helper, a service, a gone owner or our own process keeps the front app and the field",
    arguments: ["ineligible", "unresolved", "own"])
  func ownerKeptFront(_ kind: String) throws {
    let (front, owner) = try apps()
    let (context, _) = record(
      front: front, focus: .focused(element: field, ownerPID: owner.processIdentifier),
      owner: kind == "unresolved" ? nil : owner, eligible: kind != "ineligible",
      ownPID: kind == "own" ? owner.processIdentifier : -2)
    #expect(context.focusOwnerState == .disagreeKeptFront)
    #expect(context.targetApp == front, "the front app's paste policies still apply")
    #expect(context.targetElement == field, "the captured field is kept, as before")
  }

  @Test("no element, an unreadable read and an unreadable owner keep today's target")
  func unconfirmedKeepsToday() throws {
    let (front, owner) = try apps()
    let (none, _) = record(front: front, focus: .noElement, owner: owner, eligible: true)
    #expect(none.focusOwnerState == .noElement)
    #expect(none.targetApp == front)
    #expect(none.targetElement == nil)

    let (failed, _) = record(front: front, focus: .unreadable, owner: owner, eligible: true)
    #expect(failed.focusOwnerState == .unreadable)
    #expect(failed.targetApp == front)
    #expect(failed.targetElement == nil)

    let (ownerless, bundle) = record(
      front: front, focus: .ownerUnreadable(element: field), owner: owner, eligible: true)
    #expect(ownerless.focusOwnerState == .unreadable)
    #expect(ownerless.targetApp == front)
    #expect(ownerless.targetElement == field, "the element is kept for paste classification")
    #expect(bundle == nil)
  }

  @Test("without a captured field, the front app supplies the recorded window")
  func windowFollowsTheFrontWithoutAField() throws {
    let (front, _) = try apps()
    var asked: [pid_t] = []
    let context = KernelSessionContext()
    context.recordStartTarget(
      front: front, focus: .noElement, trusted: true,
      captureWindow: {
        asked.append($0)
        return nil
      },
      ownerApplication: { _ in nil }, isEligibleOwner: { _ in true }, ownPID: -2)
    #expect(context.targetApp == front)
    #expect(context.focusOwnerState == .noElement)
    #expect(asked == [front.processIdentifier])
  }

  @Test("only a running regular or accessory application may become the target")
  func eligibilityTable() {
    let table: [(NSApplication.ActivationPolicy, Bool, Bool)] = [
      (.regular, false, true), (.accessory, false, true), (.prohibited, false, false),
      (.regular, true, false), (.accessory, true, false), (.prohibited, true, false),
    ]
    for (policy, terminated, eligible) in table {
      #expect(
        KernelSessionContext.isEligibleOwner(activationPolicy: policy, isTerminated: terminated)
          == eligible, "policy \(policy.rawValue) terminated \(terminated)")
    }
  }

  /// Launchers whose panels take the focus without becoming front, as named in #3423.
  static let launcherBundleIDs: Set<String> = [
    "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.apple.Spotlight",
    "at.obdev.LaunchBar",
  ]

  @Test("no bundle-keyed paste or landing policy names a launcher, so substitution adds none")
  func noPolicyNamesALauncher() {
    let policyBundles =
      PasteDeliveryPolicy.directWriteSkippedBundleIDs
      .union(PasteLandingPolicy.slowRevealDeadlinesMs.keys)
      .union(PasteLandingPolicy.excludedRoutes.map(\.bundleID))
    #expect(policyBundles.count >= 3, "the tables were read")
    #expect(policyBundles.isDisjoint(with: Self.launcherBundleIDs))
  }
}
