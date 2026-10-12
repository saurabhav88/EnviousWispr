import Testing

@testable import EnviousWisprAppKit

/// #3252, plan 3.4 / T2 (the state machine): the one owner of "may this process quit for a move".
/// When this fails the person's app can quit by itself after they started using it, or a move can
/// never finish. The expected outcome of every pair is typed out below.
@MainActor
@Suite("HandoffAuthority (#3252)", .tags(.productOutcome))
struct HandoffAuthorityTests {

  enum Step: String, CaseIterable, Sendable { case commit, release }

  private func apply(_ step: Step, to authority: HandoffAuthority) -> Bool {
    step == .commit ? authority.commit() : authority.release()
  }

  @Test("It starts pending")
  func startsPending() {
    let authority = HandoffAuthority()
    #expect(authority.state == .pending)
    #expect(authority.isPending)
  }

  @Test("Commit from pending succeeds once and is terminal")
  func commitIsTerminal() {
    let authority = HandoffAuthority()
    #expect(authority.commit() == true)
    #expect(authority.state == .committed)
    #expect(authority.isPending == false)
    #expect(authority.commit() == false)
    #expect(authority.release() == false)
    #expect(authority.state == .committed)
  }

  @Test("Release from pending succeeds once and is terminal")
  func releaseIsTerminal() {
    let authority = HandoffAuthority()
    #expect(authority.release() == true)
    #expect(authority.state == .released)
    #expect(authority.isPending == false)
    #expect(authority.release() == false)
    #expect(authority.commit() == false)
    #expect(authority.state == .released)
  }

  @Test(
    "Every ordered pair: only the first call ever wins, and the final state never reverses",
    arguments: [
      (Step.commit, Step.commit, true, false, HandoffAuthority.State.committed),
      (.commit, .release, true, false, .committed),
      (.release, .commit, true, false, .released),
      (.release, .release, true, false, .released),
    ])
  func firstCallWins(
    first: Step, second: Step, firstWins: Bool, secondWins: Bool, final: HandoffAuthority.State
  ) {
    let authority = HandoffAuthority()
    #expect(apply(first, to: authority) == firstWins)
    #expect(apply(second, to: authority) == secondWins)
    #expect(authority.state == final)
  }
}
