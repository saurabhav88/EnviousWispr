import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4578 §3.3: the one rule for which speech engine a job may use. When this fails, a job
/// starts on a missing engine (and downloads it), dictation silently switches engines, or a
/// meeting loses its transcript although another engine is downloaded.
@Suite(.tags(.productOutcome))
struct SpeechJobAdmissionTests {
  typealias Job = SpeechJobAdmission.Job

  /// Every job with the requested engine installed: it is used, alone or beside the other.
  @Test(
    "the requested engine, when downloaded, is always the one used",
    arguments: [
      Job.dictation, .fileImport, .recoveryReplay, .benchmark, .meetingStart, .meetingTranscript,
      .meetingRetranscribe, .importedFileRetranscribe,
    ])
  func requestedInstalled(job: Job) {
    #expect(
      SpeechJobAdmission.decide(job, requested: .parakeet, installed: [.parakeet])
        == .use(.parakeet))
    #expect(
      SpeechJobAdmission.decide(job, requested: .whisper, installed: [.parakeet, .whisper])
        == .use(.whisper))
  }

  @Test(
    "a person-present job never switches engines: the missing one is named",
    arguments: [Job.dictation, .fileImport, .recoveryReplay, .benchmark])
  func personPresentJobsStop(job: Job) {
    #expect(
      SpeechJobAdmission.decide(job, requested: .parakeet, installed: [.whisper])
        == .stop(.engineNotDownloaded(.parakeet)))
    #expect(
      SpeechJobAdmission.decide(job, requested: .whisper, installed: [])
        == .stop(.engineNotDownloaded(.whisper)))
  }

  @Test("Transcribe again with a named model never substitutes; with nothing downloaded it says so")
  func importedRetranscribe() {
    #expect(
      SpeechJobAdmission.decide(.importedFileRetranscribe, requested: .parakeet, installed: [.whisper])
        == .stop(.engineNotDownloaded(.parakeet)))
    #expect(
      SpeechJobAdmission.decide(.importedFileRetranscribe, requested: .whisper, installed: [])
        == .stop(.noEngineDownloaded))
  }

  @Test("a meeting records when any engine is downloaded, and not at all when none is")
  func meetingStart() {
    #expect(
      SpeechJobAdmission.decide(.meetingStart, requested: .parakeet, installed: [.whisper])
        == .use(.parakeet))
    #expect(
      SpeechJobAdmission.decide(.meetingStart, requested: .whisper, installed: [])
        == .stop(.noEngineDownloaded))
  }

  @Test(
    "a meeting transcript uses the other downloaded engine, in both directions",
    arguments: [Job.meetingTranscript, .meetingRetranscribe])
  func meetingFallsBack(job: Job) {
    #expect(
      SpeechJobAdmission.decide(job, requested: .parakeet, installed: [.whisper])
        == .useOther(.whisper, insteadOf: .parakeet))
    #expect(
      SpeechJobAdmission.decide(job, requested: .whisper, installed: [.parakeet])
        == .useOther(.parakeet, insteadOf: .whisper))
    #expect(
      SpeechJobAdmission.decide(job, requested: .parakeet, installed: [])
        == .stop(.noEngineDownloaded))
  }
}
