import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4578: leaving a speech engine tab with the picked engine not downloaded. When this fails,
/// the person leaves Dictation > Engine or EnviousMeet > Models with dictation or meetings silently
/// broken, is asked when nothing is wrong, or "Go back to" picks an engine that is not there.
@MainActor
@Suite(.tags(.productOutcome))
struct SpeechSetupLeaveTests {
  final class Facts {
    var dictation: ASRBackendType = .parakeet
    var meeting: ASRBackendType = .parakeet
    var installed: [ASRBackendType: Bool?] = [.parakeet: false, .whisper: true]
    var downloading: Set<ASRBackendType> = []
    var value: SpeechSetupFacts {
      SpeechSetupFacts(
        picked: { $0 == .dictation ? self.dictation : self.meeting },
        installed: { self.installed[$0] ?? nil },
        downloading: { self.downloading.contains($0) })
    }
  }

  private var onEngine: SettingsNavigationState {
    var state = SettingsNavigationState()
    state.perform(.destination(.dictation(.engine)))
    return state
  }

  @Test("leaving Engine with the picked engine missing asks, with Set up model, Go back and Leave anyway")
  func asksWhenMissing() throws {
    let facts = Facts()
    let request = try #require(
      SpeechSetupLeaveGuard.request(
        for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value,
        previous: .whisper))
    #expect(request.engine == .parakeet && request.goBack == .whisper && !request.downloading)
    let content = SpeechSetupLeaveGuard.content(for: request)
    #expect(content.title == "Finish speech engine setup")
    #expect(content.message == "Parakeet is not downloaded yet. Until then, dictation won't work.")
    #expect(content.buttons.map(\.title) == ["Set up model", "Go back to Whisper", "Leave anyway"])
    #expect(content.buttons.first?.role == .cancel, "Set up model is the safe answer")
  }

  @Test("no question: installed, unknown, staying on the tab, or another tab's place")
  func silentWhenFine() {
    let facts = Facts()
    facts.installed[.parakeet] = true
    #expect(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value, previous: nil) == nil)
    facts.installed[.parakeet] = .some(nil)
    #expect(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value, previous: nil) == nil, "unknown never asks")
    facts.installed[.parakeet] = false
    #expect(SpeechSetupLeaveGuard.request(for: .destination(.dictation(.engine)), from: onEngine, scope: .dictation, facts: facts.value, previous: nil) == nil)
    #expect(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .meetings, facts: facts.value, previous: nil) == nil)
  }

  @Test("Go back is offered only for a different, downloaded engine; a download in progress is a notice")
  func goBackAndDownloading() throws {
    let facts = Facts()
    facts.installed[.whisper] = false
    let noOther = try #require(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value, previous: .whisper))
    #expect(noOther.goBack == nil)
    facts.downloading = [.parakeet]
    let downloading = try #require(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value, previous: nil))
    let notice = SpeechSetupLeaveGuard.content(for: downloading)
    #expect(notice.buttons.map(\.action) == [.ok])
    #expect(notice.message == "Parakeet is still downloading. Until then, dictation won't work.")
  }

  @Test("EnviousMeet > Models asks about the meeting engine with the meeting words")
  func meetingsScope() throws {
    let facts = Facts()
    facts.dictation = .whisper
    facts.meeting = .parakeet
    var state = SettingsNavigationState()
    state.perform(.destination(.meetings(.models)))
    let request = try #require(SpeechSetupLeaveGuard.request(for: .destination(.meetings(.general)), from: state, scope: .meetings, facts: facts.value, previous: nil))
    #expect(SpeechSetupLeaveGuard.content(for: request).message == "Parakeet is not downloaded yet. Until then, meetings won't get a transcript.")
  }

  @Test("answers are judged now: Set up model stays, Go back restores only while offered, a repair lets the person go")
  func answers() throws {
    let facts = Facts()
    let request = try #require(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value, previous: .whisper))
    #expect(SpeechSetupLeaveGuard.resolve(.finishSetup, request: request, facts: facts.value, previous: .whisper) == .setUp(.parakeet))
    #expect(SpeechSetupLeaveGuard.resolve(.goBackToEngine(.whisper), request: request, facts: facts.value, previous: .whisper) == .restore(.whisper, then: .sidebar(.history)))
    #expect(SpeechSetupLeaveGuard.resolve(.leaveAnyway, request: request, facts: facts.value, previous: .whisper) == .navigate(.sidebar(.history)))
    facts.installed[.whisper] = false
    #expect(SpeechSetupLeaveGuard.resolve(.goBackToEngine(.whisper), request: request, facts: facts.value, previous: .whisper) == .stay, "no longer offered")
    facts.installed[.parakeet] = true
    #expect(SpeechSetupLeaveGuard.resolve(.finishSetup, request: request, facts: facts.value, previous: .whisper) == .stay)
    #expect(SpeechSetupLeaveGuard.resolve(.leaveAnyway, request: request, facts: facts.value, previous: .whisper) == .navigate(.sidebar(.history)))
  }

  @Test("Escape only closes the question: it never starts the Set up model download")
  func escapeNeverDownloads() throws {
    let facts = Facts()
    let request = try #require(SpeechSetupLeaveGuard.request(for: .sidebar(.history), from: onEngine, scope: .dictation, facts: facts.value, previous: .whisper))
    let layout = try #require(PolishSetupLeaveCardLayout(SpeechSetupLeaveGuard.content(for: request)))
    let escape = try #require(layout.escape)
    #expect(escape.action == .finishSetup, "Escape lands on the safe button, Set up model")
    #expect(SpeechSetupLeaveGuard.answer(escape, press: .escape) == nil)
    #expect(SpeechSetupLeaveGuard.answer(escape, press: .button) == .finishSetup)
  }
}
