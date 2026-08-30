import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG

  /// A one-shot signal the injected warm-up fires when it is genuinely
  /// RUNNING. Replaces a yield-count settle, which guessed at the scheduler:
  /// under contention the guess can expire before the subject has run, so a
  /// negative assertion passes having exercised nothing.
  @MainActor
  private final class EntrySignal {
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    private var fired = false

    /// Called from inside the warm-up, before it suspends.
    func fire() {
      guard !fired else { return }
      fired = true
      let resumable = waiters
      waiters = []
      for w in resumable { w.1.resume(returning: true) }
    }

    /// Returns once the warm-up has actually been entered, or gives up after
    /// `timeout` so a regression that never invokes the warm-up produces a
    /// FAILING assertion instead of a wedged run. Cancellation does not resume
    /// a checked continuation, so the suite time limit alone would leave the
    /// process hung (local Codex r3; test-timing.md — write the deadline when
    /// you write the waiter).
    /// - Returns: true if the subject entered, false if the deadline won.
    func awaitEntry(timeout: Duration = .seconds(5)) async -> Bool {
      if fired { return true }
      let id = UUID()
      return await withCheckedContinuation { continuation in
        waiters.append((id, continuation))
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          await self?.expire(id)
        }
      }
    }

    /// Resumes a still-parked waiter with `false`. Removed first, so the real
    /// signal arriving later cannot resume it a second time.
    private func expire(_ id: UUID) {
      guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
      let waiter = waiters.remove(at: index)
      waiter.1.resume(returning: false)
    }
  }

  /// #2196 — the onboarding practice step, all of it.
  ///
  /// ONE serialized parent, because the children emit `engine_warm_gate` and
  /// capture it through the process-global `TelemetryService.shared.testEventHook`.
  /// `.serialized` orders tests WITHIN a suite; it says nothing about two
  /// SIBLING suites, so a sibling's events landed in this suite's capture and a
  /// count assertion read three completions where it expected one. Nesting is
  /// what actually orders them against each other (local Codex r3).
  @MainActor
  @Suite("Onboarding practice step", .serialized)
  struct OnboardingPracticeStepSuite {

    @MainActor
    @Suite("behaviour", .tags(.productOutcome), .timeLimit(.minutes(1)))
    struct OnboardingWarmingGateTests {

      @MainActor
      private final class Counter { var value = 0 }

      /// A view model parked on the gate, as the Ready button leaves it.
      private func makeGatedViewModel() -> OnboardingV2ViewModel {
        let vm = OnboardingV2ViewModel()
        vm.currentScreen = .warmingUp
        return vm
      }

      @Test("the gate stays shut while the warm-up is still running")
      func gateHoldsUntilTheEngineAnswers() async {
        let vm = makeGatedViewModel()
        // Signal-gated, never timed: the warm-up suspends until this test
        // releases it, so "still running" is a state the test creates rather
        // than one it waits out.
        let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)

        let entered = EntrySignal()
        vm.kickWarmingIfNeeded(
          warmUp: {
            entered.fire()
            var it = gate.makeAsyncIterator()
            _ = await it.next()
            return .ready
          }, displayFloor: 0)
        let task = vm.warmingTask
        // The subject says it is running; nothing here guesses that it is.
        #expect(await entered.awaitEntry(), "the warm-up was never entered")

        #expect(vm.warmingOutcome == .waiting, "the gate opened before the engine answered")

        gateCont.yield(())
        gateCont.finish()
        await task?.value

        #expect(vm.warmingOutcome == .ready)
      }

      @Test("a failed warm-up never opens the gate")
      func failureNeverOpensTheGate() async {
        let vm = makeGatedViewModel()
        struct Boom: Error {}

        vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
        await vm.warmingTask?.value

        #expect(vm.warmingOutcome != .ready)
        #expect(vm.warmingOutcome == .failed(OnboardingV2ViewModel.warmingFailureCopy))
      }

      /// A `.cancelled` can only arrive from a Cancel pressed on the CHECKLIST
      /// that raced the gate's own single-flighted call. The engine is not ready,
      /// so the gate must treat it exactly like a failure rather than waving it
      /// through as "the user chose this".
      @Test("a cancelled warm-up never opens the gate")
      func cancellationNeverOpensTheGate() async {
        let vm = makeGatedViewModel()

        vm.kickWarmingIfNeeded(warmUp: { .cancelled }, displayFloor: 0)
        await vm.warmingTask?.value

        #expect(vm.warmingOutcome != .ready)
      }

      @Test("retry re-arms the gate and a second attempt can open it")
      func retryReArms() async {
        let vm = makeGatedViewModel()
        struct Boom: Error {}
        let calls = Counter()

        vm.kickWarmingIfNeeded(
          warmUp: {
            calls.value += 1
            return calls.value == 1 ? .failed(Boom()) : .ready
          }, displayFloor: 0)
        await vm.warmingTask?.value
        #expect(vm.warmingOutcome != .ready)

        vm.retryWarming()
        #expect(vm.warmingOutcome == .waiting)
        #expect(vm.warmingRetryCount == 1)

        vm.kickWarmingIfNeeded(
          warmUp: {
            calls.value += 1
            return calls.value == 1 ? .failed(Boom()) : .ready
          }, displayFloor: 0)
        await vm.warmingTask?.value

        #expect(vm.warmingOutcome == .ready)
        #expect(calls.value == 2)
      }

      @Test("a re-kick while an attempt is live is a no-op (window churn)")
      func reKickIsSingleFlight() async {
        let vm = makeGatedViewModel()
        let calls = Counter()
        let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)
        let entered = EntrySignal()
        let warmUp: @MainActor () async -> EngineWarmupOutcome = {
          calls.value += 1
          entered.fire()
          var it = gate.makeAsyncIterator()
          _ = await it.next()
          return .ready
        }

        vm.kickWarmingIfNeeded(warmUp: warmUp, displayFloor: 0)
        let first = vm.warmingTask
        // Without this the re-kick could land before the first attempt ran.
        #expect(await entered.awaitEntry(), "the warm-up was never entered")
        vm.kickWarmingIfNeeded(warmUp: warmUp, displayFloor: 0)

        // Found by the mutation battery, not by review: dropping the
        // single-flight guard left this test GREEN. A second `Task` does not
        // begin executing at the moment it is created, so reading `calls.value`
        // straight after the re-kick reads an instant at which the evidence
        // cannot exist yet — the assertion could never have caught the thing it
        // names. What IS decided synchronously is whether the live attempt was
        // REPLACED, so assert that first.
        #expect(
          vm.warmingTask == first,
          "a re-kick replaced the live attempt instead of standing down")

        gateCont.yield(())
        gateCont.finish()
        await first?.value

        // And the count, now read after the run has finished, so any second
        // attempt has had its chance to execute.
        #expect(calls.value == 1, "a re-kick started a second warm-up")
        #expect(vm.warmingOutcome == .ready)
      }

      @Test("the gate does not run from any other screen")
      func doesNotKickOffScreen() async {
        let vm = OnboardingV2ViewModel()
        vm.currentScreen = .ready
        let calls = Counter()

        vm.kickWarmingIfNeeded(
          warmUp: {
            calls.value += 1
            return .ready
          }, displayFloor: 0)
        await vm.warmingTask?.value

        #expect(calls.value == 0)
        #expect(vm.warmingOutcome == .waiting)
      }

      /// Found by self-review, and it survives a green suite because nothing
      /// resets `warmingOutcome` when a visit ENDS: a reopened onboarding
      /// inherits the last visit's `ready`, the gate's `onAppear` fires straight
      /// through, and the engine is never asked — on a machine where it may have
      /// been unloaded since.
      @Test("a reopened onboarding cannot inherit the last visit's ready")
      func reopeningReArmsTheGate() async {
        let vm = makeGatedViewModel()
        vm.kickWarmingIfNeeded(warmUp: { .ready }, displayFloor: 0)
        await vm.warmingTask?.value
        #expect(vm.warmingOutcome == .ready)

        // Setup finished and was reopened: recovery parks it back on Ready, and
        // the person presses the button again.
        vm.currentScreen = .ready
        vm.beginWarmingGate()

        #expect(vm.currentScreen == .warmingUp)
        #expect(
          vm.warmingOutcome == .waiting,
          "the gate opened on a stale answer from a previous visit")

        let calls = Counter()
        vm.kickWarmingIfNeeded(
          warmUp: {
            calls.value += 1
            return .ready
          }, displayFloor: 0)
        await vm.warmingTask?.value
        #expect(calls.value == 1, "the second visit never asked the engine")
      }

      /// The skip does NOT cancel the shared warm-up — that load is
      /// single-flighted, so cancelling it to leave a screen would cancel it for
      /// every other waiter. The consequence this locks: the abandoned attempt
      /// still resolves, and it must not then open a gate nobody is standing at.
      @Test("skipping leaves the in-flight warm-up alone and its late answer opens nothing")
      func skipDoesNotCancelAndLateReadyIsInert() async {
        let vm = makeGatedViewModel()
        let calls = Counter()
        let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)

        let entered = EntrySignal()
        vm.kickWarmingIfNeeded(
          warmUp: {
            calls.value += 1
            entered.fire()
            var it = gate.makeAsyncIterator()
            _ = await it.next()
            return .ready
          }, displayFloor: 0)
        let task = vm.warmingTask
        #expect(await entered.awaitEntry(), "the warm-up was never entered")

        vm.skipWarmingGate()
        gateCont.yield(())
        gateCont.finish()
        await task?.value

        #expect(calls.value == 1, "the warm-up never ran")
        #expect(
          vm.warmingOutcome == .waiting,
          "a skipped gate opened later on an answer nobody was waiting for")
      }
    }

    /// #2196 chunk 1 — what the gate reports. When these fail the onboarding
    /// funnel lies about where people stop: `engine_warm_gate` is the step that
    /// separates "waited and got a warm engine" from "did not wait".
    @MainActor
    @Suite("telemetry", .tags(.observabilityContract), .timeLimit(.minutes(1)))
    struct OnboardingWarmingGateTelemetryTests {

      final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CapturedTelemetryEvent] = []
        func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
        var all: [CapturedTelemetryEvent] { lock.withLock { stored } }
        /// Only this step's rows, so an unrelated suite emitting onto the shared
        /// hook cannot be read as one of ours.
        func gateRows(_ name: String) -> [CapturedTelemetryEvent] {
          all.filter { $0.name == name && $0.stringProps["step"] == "engine_warm_gate" }
        }
      }

      private func makeGatedViewModel() -> OnboardingV2ViewModel {
        let vm = OnboardingV2ViewModel()
        vm.currentScreen = .warmingUp
        return vm
      }

      private func withHook<T>(_ body: (Events) async throws -> T) async rethrows -> T {
        let events = Events()
        TelemetryService.shared.testEventHook = { @Sendable e in events.add(e) }
        defer { TelemetryService.shared.testEventHook = nil }
        return try await body(events)
      }

      @Test("a warmed gate completes the step once, with a duration")
      func readyCompletesOnce() async {
        await withHook { events in
          let vm = makeGatedViewModel()
          vm.kickWarmingIfNeeded(warmUp: { .ready }, displayFloor: 0)
          await vm.warmingTask?.value

          let rows = events.gateRows("onboarding.step_completed")
          #expect(rows.count == 1)
          #expect(rows.first?.stringProps["result"] == "ready")
          // The already-warm case and a real wait are told apart by this, which
          // is why the gate carries no separate already_ready result value.
          #expect(rows.first?.stringProps["duration_seconds"] != nil)
          #expect(events.gateRows("onboarding.step_blocked").isEmpty)
        }
      }

      @Test("a failed warm-up blocks the step, and does not also complete it")
      func failureBlocks() async {
        await withHook { events in
          struct Boom: Error {}
          let vm = makeGatedViewModel()
          vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
          await vm.warmingTask?.value

          let blocked = events.gateRows("onboarding.step_blocked")
          #expect(blocked.count == 1)
          #expect(blocked.first?.stringProps["reason"] == "warmup_failed")
          #expect(events.gateRows("onboarding.step_completed").isEmpty)
        }
      }

      @Test("a checklist cancel that races the gate is reported as its own reason")
      func cancellationBlocksWithItsOwnReason() async {
        await withHook { events in
          let vm = makeGatedViewModel()
          vm.kickWarmingIfNeeded(warmUp: { .cancelled }, displayFloor: 0)
          await vm.warmingTask?.value

          let blocked = events.gateRows("onboarding.step_blocked")
          #expect(blocked.count == 1)
          #expect(blocked.first?.stringProps["reason"] == "warmup_cancelled")
        }
      }

      /// The one-shot latch, stated as a funnel property: one visit to the gate
      /// produces exactly one row. Without it a skipped gate whose abandoned
      /// warm-up later resolves would report BOTH skipped and ready, and the
      /// share-who-skipped number would be quietly wrong in the flattering
      /// direction.
      @Test("skip then a late ready reports exactly one row, and it is the skip")
      func skipReportsOnce() async {
        await withHook { events in
          let vm = makeGatedViewModel()
          let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)
          let entered = EntrySignal()
          vm.kickWarmingIfNeeded(
            warmUp: {
              entered.fire()
              var it = gate.makeAsyncIterator()
              _ = await it.next()
              return .ready
            }, displayFloor: 0)
          let task = vm.warmingTask
          #expect(await entered.awaitEntry(), "the warm-up was never entered")

          vm.skipWarmingGate()
          gateCont.yield(())
          gateCont.finish()
          await task?.value

          let rows = events.gateRows("onboarding.step_completed")
          #expect(rows.count == 1)
          #expect(rows.first?.stringProps["result"] == "skipped")
        }
      }

      /// Local Codex review, adopted: one latch guarded both the warm-up's answer
      /// and the visit's exit, so a failed attempt consumed it and the Skip link
      /// still offered beneath the failure panel then reported nothing. A
      /// failed-then-skipped visit was indistinguishable from a failed-then-
      /// abandoned one, and the skip rate undercounted exactly the people the
      /// gate had already failed.
      @Test("skipping after a failed warm-up still records the skip")
      func skipAfterFailureIsRecorded() async {
        await withHook { events in
          struct Boom: Error {}
          let vm = makeGatedViewModel()
          vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
          await vm.warmingTask?.value

          vm.skipWarmingGate()

          let blocked = events.gateRows("onboarding.step_blocked")
          #expect(blocked.count == 1)
          #expect(blocked.first?.stringProps["reason"] == "warmup_failed")
          let completed = events.gateRows("onboarding.step_completed")
          #expect(completed.count == 1, "the skip after a failure was never recorded")
          #expect(completed.first?.stringProps["result"] == "skipped")
        }
      }

      /// The other direction of the same split: once the person has left, a
      /// warm-up answer that arrives afterwards is not their block to carry.
      @Test("a failure landing after the skip adds no row")
      func lateFailureAfterSkipIsSilent() async {
        await withHook { events in
          struct Boom: Error {}
          let vm = makeGatedViewModel()
          let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)
          let entered = EntrySignal()
          vm.kickWarmingIfNeeded(
            warmUp: {
              entered.fire()
              var it = gate.makeAsyncIterator()
              _ = await it.next()
              return .failed(Boom())
            }, displayFloor: 0)
          let task = vm.warmingTask
          #expect(await entered.awaitEntry(), "the warm-up was never entered")

          vm.skipWarmingGate()
          gateCont.yield(())
          gateCont.finish()
          await task?.value

          #expect(events.gateRows("onboarding.step_blocked").isEmpty)
          let completed = events.gateRows("onboarding.step_completed")
          #expect(completed.count == 1)
          #expect(completed.first?.stringProps["result"] == "skipped")
        }
      }

      /// A retry is not an exit: two real attempts produce two blocks, and the
      /// visit still produces exactly one completion when it finally ends.
      @Test("retry then skip reports two blocks and exactly one completion")
      func retryThenSkipReportsOnce() async {
        await withHook { events in
          struct Boom: Error {}
          let vm = makeGatedViewModel()
          vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
          await vm.warmingTask?.value

          vm.retryWarming()
          vm.kickWarmingIfNeeded(warmUp: { .failed(Boom()) }, displayFloor: 0)
          await vm.warmingTask?.value

          vm.skipWarmingGate()

          #expect(events.gateRows("onboarding.step_blocked").count == 2)
          let completed = events.gateRows("onboarding.step_completed")
          #expect(completed.count == 1)
          #expect(completed.first?.stringProps["result"] == "skipped")
        }
      }

      /// Chunk 4. Without these the funnel cannot tell a person who practised
      /// from one who bailed — both exits called the same no-argument finish, so
      /// `practice_dictation` never appeared at all.
      @Test("finishing after a successful take reports completed")
      func practiceCompletedIsReported() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()
          vm.practiceTakeStarted()
          vm.setPracticeText("hey Mike pick up Emma from school today")
          vm.practiceTakeEnded()

          vm.reportPracticeExit()

          let rows = events.all.filter {
            $0.name == "onboarding.step_completed" && $0.stringProps["step"] == "practice_dictation"
          }
          #expect(rows.count == 1)
          #expect(rows.first?.stringProps["result"] == "completed")
        }
      }

      /// `no_speech` and `skipped` are deliberately different: one person tried
      /// and got silence, the other never tried. Collapsing them would hide the
      /// 20.3% case inside the skip rate.
      @Test("leaving after a silent take reports no_speech, not skipped")
      func silentThenLeaveReportsNoSpeech() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()
          vm.practiceTakeStarted()
          vm.practiceTakeEnded()

          vm.reportPracticeExit()

          let rows = events.all.filter {
            $0.name == "onboarding.step_completed" && $0.stringProps["step"] == "practice_dictation"
          }
          #expect(rows.first?.stringProps["result"] == "no_speech")
        }
      }

      /// The funnel must not repeat the screen's own mistake where nobody can
      /// see it: someone who dictated and missed the box DID dictate, and
      /// filing them under silence would hide a one-click UX problem inside the
      /// most common genuine outcome.
      @Test("a missed box is reported as its own thing, not as silence")
      func missedBoxHasItsOwnResult() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()
          vm.practiceTakeStarted(boxFocused: false, transcriptCount: 0)
          vm.practiceTakeEnded(transcriptCount: 1)

          vm.reportPracticeExit()

          let rows = events.all.filter {
            $0.name == "onboarding.step_completed" && $0.stringProps["step"] == "practice_dictation"
          }
          #expect(rows.first?.stringProps["result"] == "missed_box")
        }
      }

      /// `pipeline_failed` is its own reason, never folded into `no_speech`:
      /// one is us failing and the other is a quiet room, and a funnel that
      /// cannot tell them apart will read our own breakage as people not
      /// speaking.
      @Test("a pipeline failure blocks the step with its own reason")
      func failureReportsItsOwnReason() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()
          vm.practiceTakeStarted(boxFocused: true, transcriptCount: 0)
          vm.practiceTakeEnded(transcriptCount: 0, pipelineFailed: true)

          vm.reportPracticeExit()

          let blocked = events.all.filter {
            $0.name == "onboarding.step_blocked" && $0.stringProps["step"] == "practice_dictation"
          }
          #expect(blocked.count == 1)
          #expect(blocked.first?.stringProps["reason"] == "pipeline_failed")
          #expect(
            events.all.filter {
              $0.name == "onboarding.step_completed"
                && $0.stringProps["step"] == "practice_dictation"
            }.isEmpty)
        }
      }

      @Test("leaving without ever trying reports skipped")
      func neverTriedReportsSkipped() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()

          vm.reportPracticeExit()

          let rows = events.all.filter {
            $0.name == "onboarding.step_completed" && $0.stringProps["step"] == "practice_dictation"
          }
          #expect(rows.first?.stringProps["result"] == "skipped")
        }
      }

      @Test("a blocked permission reports blocked with its permission named")
      func blockedPermissionIsReported() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()
          vm.applyPracticePosture(micGranted: false, accessibilityGranted: true)

          vm.reportPracticeExit()

          let blocked = events.all.filter {
            $0.name == "onboarding.step_blocked" && $0.stringProps["step"] == "practice_dictation"
          }
          #expect(blocked.count == 1)
          #expect(blocked.first?.stringProps["reason"] == "mic_denied")
          #expect(blocked.first?.stringProps["permission"] == "microphone")
          #expect(
            events.all.filter {
              $0.name == "onboarding.step_completed"
                && $0.stringProps["step"] == "practice_dictation"
            }.isEmpty)
        }
      }

      @Test("one visit to the box reports exactly once, however it ends")
      func practiceExitReportsOnce() async {
        await withHook { events in
          let vm = OnboardingV2ViewModel()
          vm.beginPractice()
          vm.setPracticeText("remember soccer jersey and cleats for tomorrow")

          vm.reportPracticeExit()
          vm.reportPracticeExit()

          #expect(
            events.all.filter {
              $0.name == "onboarding.step_completed"
                && $0.stringProps["step"] == "practice_dictation"
            }.count == 1)
        }
      }

      @Test("a second skip press cannot report twice")
      func doubleSkipReportsOnce() async {
        await withHook { events in
          let vm = makeGatedViewModel()
          vm.skipWarmingGate()
          vm.skipWarmingGate()
          #expect(events.gateRows("onboarding.step_completed").count == 1)
        }
      }
    }

    /// #2196 chunk 2 — the box.
    ///
    /// When these fail a new person reaches the end of setup without ever
    /// seeing the product work, which is the whole defect #2196 exists to fix:
    /// 51 people in 90 days whose entire experience was the clipboard notice.
    /// The box's contents are the SUBJECT's own signal — the paste cascade
    /// writes them — so nothing here waits on a clock.
    @MainActor
    @Suite("the box", .tags(.productOutcome), .timeLimit(.minutes(1)))
    struct OnboardingPracticeBoxTests {

      private func makePracticeViewModel() -> OnboardingV2ViewModel {
        let vm = OnboardingV2ViewModel()
        vm.beginPractice()
        return vm
      }

      @Test("words landing in the box are what unlocks the end of setup")
      func wordsInTheBoxUnlockFinish() {
        let vm = makePracticeViewModel()
        #expect(vm.practiceSucceeded == false)

        // What the cascade does when it finds a text target: it types.
        vm.setPracticeText("tell grandma I love her and will call Sunday after church")

        #expect(vm.practiceSucceeded)
      }

      /// The screen must not congratulate someone for a stray newline. `no_speech`
      /// is 20.3% of real first takes, so an empty-ish box is the COMMON case and
      /// treating it as success would tell a fifth of new people the product
      /// worked when they never heard from it.
      @Test("whitespace alone is not a successful dictation")
      func whitespaceIsNotSuccess() {
        let vm = makePracticeViewModel()
        vm.setPracticeText("   \n  \t ")
        #expect(vm.practiceSucceeded == false)
      }

      /// Deliberately sticky. Someone who dictates and then selects-all-deletes
      /// has still SEEN the product work; taking FINISH SETUP away at that moment
      /// would be the screen punishing them for tidying up.
      @Test("clearing the box does not take the finish button away again")
      func successIsStickyAcrossAClear() {
        let vm = makePracticeViewModel()
        vm.setPracticeText("running 15 min late got stuck on the client call")
        #expect(vm.practiceSucceeded)

        vm.setPracticeText("")

        #expect(vm.practiceText.isEmpty)
        #expect(vm.practiceSucceeded, "a cleared box revoked a success that had already happened")
      }

      /// Same reason `beginWarmingGate` resets: a reopened onboarding must not
      /// inherit a previous visit's success and offer FINISH SETUP to someone who
      /// has not dictated in THIS one.
      @Test("a reopened onboarding cannot inherit the last visit's dictation")
      func reopeningClearsTheBox() {
        let vm = makePracticeViewModel()
        vm.setPracticeText("hey Mike pick up Emma from school today")
        #expect(vm.practiceSucceeded)

        vm.beginPractice()

        #expect(vm.currentScreen == .tryItOut)
        #expect(vm.practiceText.isEmpty)
        #expect(vm.practiceSucceeded == false, "the box opened already believing it had succeeded")
      }

      /// The gate's ready exit opens the box; it no longer ends setup. If this
      /// regresses, the warm gate silently becomes the last screen again and the
      /// entire feature is absent while every other test still passes.
      /// Local Codex chunk-2 review, P1: Skip after releasing the key but
      /// BEFORE transcription finishes closed the window while the ordinary
      /// cascade still targeted the practice editor — so the words landed on
      /// the clipboard behind the very notice this feature removes, or in
      /// whatever app was behind us. The screen was blind to a take entirely.
      @Test("a take in flight is a state the screen can see")
      func aTakeInFlightIsObservable() {
        let vm = makePracticeViewModel()
        #expect(vm.practiceState == .waiting)

        vm.practiceTakeStarted()

        #expect(vm.practiceState == .listening, "the screen cannot tell a take is running")
      }

      /// The 20.3% case, and the reason it is a state rather than an error: a
      /// take that produces nothing must be acknowledged, or the screen just
      /// keeps asking and the person concludes the product ignored them.
      @Test("a take that produces nothing lands in all-quiet, not in success")
      func silentTakeIsAcknowledged() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted()

        vm.practiceTakeEnded()

        #expect(vm.practiceState == .saidNothing)
        #expect(vm.practiceSucceeded == false)
      }

      @Test("a take that produces words lands in success")
      func productiveTakeWorks() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted()
        vm.setPracticeText("Emma the birthday card is in the mail happy 7th sweetie")

        vm.practiceTakeEnded()

        #expect(vm.practiceState == .worked)
        #expect(vm.practiceSucceeded)
      }

      /// A SECOND take is scored on its own words, never on the first take's.
      /// Comparing against empty instead of against the take's own start would
      /// score every later silent take as a success.
      @Test("a silent second take is not credited to the first take's words")
      func secondTakeIsScoredOnItsOwn() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted()
        vm.setPracticeText("running 15 min late got stuck on the client call")
        vm.practiceTakeEnded()
        #expect(vm.practiceState == .worked)

        vm.practiceTakeStarted()
        vm.practiceTakeEnded()

        #expect(
          vm.practiceState == .saidNothing, "a silent take inherited the previous take's words")
      }

      /// FOUNDER-FOUND IN LIVE UAT, 2026-08-24, and the most valuable finding
      /// of the day because no test would have produced it: he dictated with
      /// the box unfocused and the screen said "All quiet". The app had heard
      /// him perfectly — `RAW ASR "Testing one two three."` — and the words
      /// went to the clipboard because the cascade classified `.nonText`. The
      /// screen accused his microphone of a fault it did not have and sent him
      /// to check hardware when the fix was one click.
      @Test("a take that missed the box is not reported as silence")
      func missedBoxIsNotSilence() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: false, transcriptCount: 3)

        // A transcript appeared, so words genuinely existed — they just had
        // nowhere here to land.
        vm.practiceTakeEnded(transcriptCount: 4)

        #expect(vm.practiceState == .missedTheBox)
        #expect(
          vm.practiceState != .saidNothing,
          "the screen told someone it heard nothing when it heard them fine")
      }

      /// **The twin of the case above, with the focus flag the other way — and
      /// the flag is the ONLY thing keeping the wrong advice off this screen.**
      ///
      /// Words existed and the box did not grow, exactly as above. The
      /// difference is that the box WAS focused, so "you missed the box" is
      /// advice that cannot be right: they were typing into it. The code falls
      /// through to `saidNothing` for precisely that reason.
      ///
      /// **Nothing bound it.** #2371 row 16 replaces
      /// `boxWasFocusedAtTakeStart = boxFocused` with `= false`, which turns
      /// this case into `missedTheBox`, and the whole suite stayed green. The
      /// row named three silence cases, and no silence case can ever see it:
      /// silence means `producedWords` is false, which short-circuits the flag
      /// before it is read. Only a take that PRODUCED words can observe it, and
      /// this is the only such take with the box focused.
      @Test("a focused box that words missed is not called a missed box")
      func focusedBoxIsNeverBlamedForMissing() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: true, transcriptCount: 3)

        // The same shape as `missedBoxIsNotSilence`: a transcript appeared, so
        // words genuinely existed, and none of them reached this box.
        vm.practiceTakeEnded(transcriptCount: 4)

        #expect(
          vm.practiceState != .missedTheBox,
          """
          the screen told someone they missed a box they were focused on, which sends \
          them to click somewhere they already were.
          """)

        // **THE `saidNothing` THIS CURRENTLY FALLS THROUGH TO IS NOT ASSERTED,
        // DELIBERATELY.** Its screen says "We just did not hear anything"
        // (`PracticeScreen.swift:138-142`), and this setup has just proved the
        // opposite by growing the transcript. Pinning it would cement a second
        // piece of wrong advice as the expected answer, and a later change that
        // gave this state an honest message would fail a test for improving it.
        //
        // The property this row exists for is the one above: a focused box is
        // never blamed for missing. That alone kills #2371 row 16, which turns
        // this case into `missedTheBox`.
        //
        // What the screen SHOULD say for a focused take whose words went
        // elsewhere is a product question, open as #2527. Cloud review raised it
        // on this PR.
      }

      /// Cloud review, and it is the founder's own defect pointed the other way,
      /// inside the fix for it: losing focus says where words WOULD go, never
      /// whether any existed. Without the transcript evidence this take was
      /// classified `missedTheBox` and the screen said "We heard you" about
      /// somebody who had said nothing at all.
      @Test("an unfocused SILENT take is silence, not a missed box")
      func unfocusedSilenceIsNotAMissedBox() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: false, transcriptCount: 3)

        // No transcript appeared: nothing was heard.
        vm.practiceTakeEnded(transcriptCount: 3)

        #expect(
          vm.practiceState == .saidNothing,
          "the screen claimed it heard someone who said nothing")
      }

      /// The other half, and why the copy was not simply replaced: real silence
      /// is 20.3% of first takes, and telling THAT person to click a box they
      /// already clicked is the same wrong advice pointed the other way.
      @Test("a silent take with the box focused is still all-quiet")
      func focusedSilenceIsStillSilence() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: true)

        vm.practiceTakeEnded()

        #expect(vm.practiceState == .saidNothing)
      }

      /// Words arriving is what decides success, whatever the focus flag said
      /// at the start — a take that lands text has plainly not missed.
      @Test("a productive take is success even if focus was uncertain at the start")
      func wordsBeatTheFocusFlag() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: false)
        vm.setPracticeText("tell grandma I love her and will call Sunday")

        vm.practiceTakeEnded()

        #expect(vm.practiceState == .worked)
      }

      /// Cloud review, and the SAME class a fourth time: a failed take produces
      /// no text and no transcript, so without this it fell through to
      /// `saidNothing` and the screen said "Your microphone is working. We just
      /// did not hear anything." Both halves false, and it sends someone to try
      /// harder at a thing that is broken.
      @Test("a pipeline failure is not reported as silence")
      func failureIsNotSilence() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: true, transcriptCount: 0)

        vm.practiceTakeEnded(transcriptCount: 0, pipelineFailed: true)

        #expect(vm.practiceState == .somethingBroke)
        #expect(
          vm.practiceState != .saidNothing,
          "the screen blamed a quiet room for our own failure")
      }

      /// The other half: a genuinely quiet room must NOT be dressed up as our
      /// failure, or the most common first-take outcome starts reading as the
      /// product breaking.
      @Test("silence with a healthy pipeline is still silence")
      func healthySilenceIsStillSilence() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: true, transcriptCount: 0)

        vm.practiceTakeEnded(transcriptCount: 0, pipelineFailed: false)

        #expect(vm.practiceState == .saidNothing)
      }

      /// A failure outranks every other reading, because no text and no
      /// transcript are SYMPTOMS of it — classifying on them first would
      /// describe the symptom and hide the cause.
      @Test("a failure outranks a missed box")
      func failureOutranksMissedBox() {
        let vm = makePracticeViewModel()
        vm.practiceTakeStarted(boxFocused: false, transcriptCount: 0)

        vm.practiceTakeEnded(transcriptCount: 1, pipelineFailed: true)

        #expect(vm.practiceState == .somethingBroke)
      }

      @Test("a denied microphone is named rather than left as a dead screen")
      func deniedMicIsNamed() {
        let vm = makePracticeViewModel()
        vm.applyPracticePosture(micGranted: false, accessibilityGranted: true)
        #expect(vm.practiceState == .cannotHear(reason: "mic_denied", permission: "microphone"))
      }

      /// The known limit of this route: Tier 1 writes through Accessibility, so
      /// without it the person would meet the raw clipboard notice. Named
      /// instead.
      @Test("denied accessibility is named rather than left to the clipboard notice")
      func deniedAccessibilityIsNamed() {
        let vm = makePracticeViewModel()
        vm.applyPracticePosture(micGranted: true, accessibilityGranted: false)
        #expect(
          vm.practiceState
            == .cannotHear(reason: "accessibility_denied", permission: "accessibility"))
      }

      @Test("granting the permission afterwards clears the blocked state")
      func grantingClearsTheBlock() {
        let vm = makePracticeViewModel()
        vm.applyPracticePosture(micGranted: false, accessibilityGranted: false)
        vm.applyPracticePosture(micGranted: true, accessibilityGranted: true)
        #expect(vm.practiceState == .waiting)
      }

      /// A take cannot start while the screen is telling someone their
      /// microphone is off — otherwise the honest message is replaced by
      /// "Listening…" on a machine that cannot hear.
      @Test("a blocked screen does not pretend to listen")
      func blockedScreenDoesNotListen() {
        let vm = makePracticeViewModel()
        vm.applyPracticePosture(micGranted: false, accessibilityGranted: true)
        vm.practiceTakeStarted()
        #expect(vm.practiceState == .cannotHear(reason: "mic_denied", permission: "microphone"))
      }

      @Test("a warmed gate opens the box rather than ending setup")
      func warmGateOpensTheBox() {
        let vm = OnboardingV2ViewModel()
        vm.currentScreen = .warmingUp
        vm.beginPractice()
        #expect(vm.currentScreen == .tryItOut)
      }
    }

  }

#endif  // DEBUG
