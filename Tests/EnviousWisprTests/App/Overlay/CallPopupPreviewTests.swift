#if DEBUG
  import EnviousWisprServices
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// The call pop-up rows of Pill Preview (#4232).
  ///
  /// **A Harness Contract.** When these fail, a developer sees a missing card, a card that stays
  /// the wrong time, or a preview that covers a real call pop-up in Settings > Diagnostics. No
  /// customer ever sees this surface (it is `#if DEBUG`).
  @MainActor
  @Suite(.tags(.harnessContract))
  struct CallPopupPreviewTests {

    final class FakePanel: CallPromptPresenting {
      var isShowing = false
      var content: CallPromptContent?
      var actions = CallPromptActions()
      var shown: [CallPromptContent] = []

      func show(_ content: CallPromptContent, actions: CallPromptActions) {
        self.content = content
        self.actions = actions
        isShowing = true
        shown.append(content)
      }

      func hide() {
        isShowing = false
        content = nil
      }
    }

    @MainActor
    final class Rig {
      let panel = FakePanel()
      var realShowing = false
      var clock = Date(timeIntervalSinceReferenceDate: 1_000)
      lazy var controller = CallPopupPreviewController(
        presenter: panel, realPopupIsShowing: { [unowned self] in self.realShowing },
        now: { [unowned self] in self.clock }, usesTimer: false)

      func play(_ id: String) {
        controller.selectedID = id
        controller.play()
      }

      func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        controller.tick()
      }
    }

    /// Exhaustive: a new card kind does not compile until it is named here.
    private static func caseName(_ content: CallPromptContent) -> String {
      switch content {
      case .ask: "ask"
      case .switchMeeting: "switchMeeting"
      case .countdown: "countdown"
      case .stopped: "stopped"
      case .stoppedByUser: "stoppedByUser"
      case .endConfirmation: "endConfirmation"
      case .switchNotConfirmed: "switchNotConfirmed"
      case .needsAttention: "needsAttention"
      case .couldNotStart: "couldNotStart"
      case .firstTip: "firstTip"
      case .lastTip: "lastTip"
      }
    }

    @Test("every call pop-up kind has exactly one row, with a unique id")
    func everyKindHasARow() {
      let names = CallPopupPreviewCatalog.all.map { Self.caseName($0.content) }
      #expect(Set(names).count == names.count)
      #expect(
        Set(names) == [
          "ask", "switchMeeting", "countdown", "stopped", "stoppedByUser", "endConfirmation",
          "switchNotConfirmed", "needsAttention", "couldNotStart", "firstTip", "lastTip",
        ])
      let ids = CallPopupPreviewCatalog.all.map(\.id)
      #expect(Set(ids).count == ids.count)
    }

    @Test("Play shows the selected card in the preview panel")
    func playShowsTheCard() {
      let rig = Rig()
      rig.play("ask")
      #expect(rig.panel.content == .ask(appName: "Microsoft Teams"))
      #expect(rig.controller.outcome == .shown("Offer to record (Microsoft Teams)"))
    }

    @Test("Play refuses while a real call pop-up is on screen")
    func playRefusesOverARealPopup() {
      let rig = Rig()
      rig.realShowing = true
      rig.play("ask")
      #expect(rig.panel.shown.isEmpty)
      #expect(rig.controller.outcome == .notShown("a real call pop-up is on screen"))
    }

    @Test("a real call pop-up appearing closes the preview")
    func realPopupClosesThePreview() {
      let rig = Rig()
      rig.play("endConfirmation")
      rig.realShowing = true
      rig.advance(0.5)
      #expect(!rig.panel.isShowing)
      #expect(rig.controller.outcome == .notShown("a real call pop-up appeared"))
    }

    @Test("the countdown ticks down, hands over to Recording stopped, which then closes")
    func countdownRunsLikeARealCallEnd() {
      let rig = Rig()
      rig.play("countdown")
      #expect(rig.panel.content == .countdown(secondsLeft: 10))
      rig.advance(1.2)
      #expect(rig.panel.content == .countdown(secondsLeft: 9))
      rig.advance(8.0)
      #expect(rig.panel.content == .countdown(secondsLeft: 1))
      rig.advance(1.0)
      #expect(rig.panel.content == .stopped)
      rig.advance(CallDetectionPolicy.stoppedOffer - 0.5)
      #expect(rig.panel.content == .stopped)
      rig.advance(0.5)
      #expect(!rig.panel.isShowing)
      #expect(rig.controller.outcome == .ended("Countdown, then Recording stopped"))
    }

    @Test(
      "each card closes after its real lifetime; Did your call end? waits for an answer",
      arguments: [
        ("ask", CallDetectionPolicy.promptTimeout),
        ("switchMeeting", CallDetectionPolicy.promptTimeout),
        ("stopped", CallDetectionPolicy.stoppedOffer),
        ("stoppedByUser", CallDetectionPolicy.stoppedOffer),
        ("switchNotConfirmed", CallDetectionPolicy.stoppedOffer),
        ("firstTip", CallDetectionPolicy.noteTimeout),
        ("lastTip", CallDetectionPolicy.noteTimeout),
        ("needsAttention", CallDetectionPolicy.noteTimeout),
        ("couldNotStart", CallDetectionPolicy.noteTimeout),
      ])
    func cardsCloseAfterTheirLifetime(id: String, lifetime: TimeInterval) {
      let rig = Rig()
      rig.play(id)
      rig.advance(lifetime - 0.5)
      #expect(rig.panel.isShowing, "\(id) closed early")
      rig.advance(0.5)
      #expect(!rig.panel.isShowing, "\(id) outlived its real lifetime")
    }

    @Test("Did your call end? stays until a button is pressed")
    func endConfirmationWaits() {
      let rig = Rig()
      rig.play("endConfirmation")
      rig.advance(3_600)
      #expect(rig.panel.content == .endConfirmation)
    }

    @Test("a button only closes the preview and says which button it was")
    func buttonClosesAndReports() {
      let rig = Rig()
      rig.play("stopped")
      rig.panel.actions.dismiss()
      #expect(!rig.panel.isShowing)
      #expect(rig.controller.outcome == .ended("Recording stopped (call ended)"))
      #expect(
        rig.controller.lastEvent == "Pressed Close. A preview only closes; nothing else happens.")
    }

    @Test("a button on an older card cannot close a newer one")
    func staleButtonIsIgnored() {
      let rig = Rig()
      rig.play("ask")
      let oldNo = rig.panel.actions.no
      rig.play("firstTip")
      oldNo()
      #expect(rig.panel.content == .firstTip)
      #expect(rig.controller.lastEvent == nil)
    }

    @Test("each card's buttons close it and report the label that card shows",
      arguments: [
        ("ask", "yes", "Start recording"), ("switchMeeting", "yes", "Start a new recording"),
        ("switchMeeting", "no", "Not now"), ("endConfirmation", "keepRecording", "Keep recording"),
        ("endConfirmation", "stopRecording", "Stop recording"), ("countdown", "keepRecording", "Keep recording"),
        ("stoppedByUser", "startNewRecording", "Start a new recording"), ("needsAttention", "openSettings", "Open settings"),
      ])
    func buttonsReportTheirCardLabel(id: String, button: String, label: String) throws {
      let rig = Rig()
      rig.play(id)
      let content = try #require(rig.panel.content)
      let action = try #require(rig.panel.actions.action(named: button, for: content), "\(id) shows no \(button)")
      action()
      #expect(!rig.panel.isShowing)
      #expect(rig.controller.lastEvent == "Pressed \(label). A preview only closes; nothing else happens.")
      // A countdown closed by Keep recording never hands over to Recording stopped.
      rig.advance(CallDetectionPolicy.countdownLength + 1)
      #expect(!rig.panel.isShowing)
    }

    @Test("Dismiss closes the preview")
    func dismissCloses() {
      let rig = Rig()
      rig.play("lastTip")
      rig.controller.dismiss()
      #expect(!rig.panel.isShowing)
      #expect(rig.controller.outcome == .idle)
    }
  }
#endif
