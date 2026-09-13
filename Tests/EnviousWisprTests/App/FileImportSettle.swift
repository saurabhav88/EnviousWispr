import Foundation

/// #2854: the one bounded wait the three file-import suites share.
///
/// The coordinator runs its decode, speaker analysis and turn assembly in
/// DETACHED tasks, so the moment a condition becomes true is set by CPU time on
/// whatever machine runs the suite, not by how many times the main actor
/// yields. The yield-count settle those suites carried (`for _ in 0..<500`)
/// passed on a dev machine with spare cores and, on the hosted runner, ran out
/// of yields before a detached decode finished: a different case failed on each
/// of five CI runs in one night, with the coordinator still mid-flight.
///
/// This waits on the CONDITION under a wall-clock deadline instead. The deadline
/// is a fail-fast bound, never something the suites assert on, and on expiry
/// the caller's own `#expect` names the state it found. The short sleep between
/// probes is a settle tick so a hot yield loop cannot starve the very actor hop
/// it is waiting for (`test-timing.md`); it is not the mechanism. Not a count:
/// there is no parameter here that a slower runner can prove too small.
@MainActor
func settleUntilObserved(
  deadline: Duration = .seconds(10),
  _ condition: @MainActor () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let end = clock.now + deadline
  while clock.now < end {
    if await condition() { return true }
    await Task.yield()
    // settle: give detached work and the coordinator's own continuations a turn
    try? await Task.sleep(for: .milliseconds(2))
  }
  return await condition()
}
