import Darwin
import Foundation
import XCTest
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

#if DEBUG
  /// The child half of the #3972 C3b process-death proof, the same pattern as the C2a writer
  /// proof (`MeetingWriterCrashSupport.swift`): the parent re-runs this bundle in its own `xctest`
  /// process; this entry runs the production job with the production checkpoint store on the
  /// parent's audio, announces each committed save on stdout and blocks after the requested
  /// number until the parent's `SIGKILL`. In an ordinary run the keys are absent and it returns.
  @objc(MeetingProcessingCrashChild)
  final class MeetingProcessingCrashChild: XCTestCase {
    @MainActor
    func testChildEntry() async throws {
      let environment = ProcessInfo.processInfo.environment
      guard let folder = environment[MeetingProcessingCrash.folderKey],
        let stopAfter = environment[MeetingProcessingCrash.stopAfterKey].flatMap(Int.init)
      else { return }
      try await MeetingProcessingCrash.runChild(
        folder: URL(fileURLWithPath: folder), stopAfter: stopAfter)
    }
  }

  enum MeetingProcessingCrash {
    static let folderKey = "EW_MEETING_JOB_FOLDER"
    static let stopAfterKey = "EW_MEETING_JOB_STOP_AFTER"
    static let meetingID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    static func transcribe(_ samples: [Float]) -> ASRResult { FakeSpeech.transcribe(samples) }

    @MainActor
    static func job(onTranscribe: @escaping @MainActor () -> Void = {}) -> MeetingTranscriptionJob {
      var config = MeetingTranscriptionJob.Configuration()
      config.pieceTargetSeconds = 20
      config.pieceSearchSeconds = 5
      return MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
          loadEngine: {},
          transcribe: { samples, _ in
            onTranscribe()
            return transcribe(samples)
          },
          unloadEngine: {},
          analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
          engineIdentity: { "fake" }),
        configuration: config)
    }

    static func audio(in folder: URL) throws -> MeetingTrackAudio {
      let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      let files = names.compactMap { name -> (url: URL, startMs: Int)? in
        guard let parsed = MeetingSegmentNaming.parse(name), !parsed.partial else { return nil }
        return (folder.appendingPathComponent(name), parsed.startMs)
      }
      return MeetingTrackAudio(files: files)
    }

    static func access(folder: URL, onSaved: @escaping @MainActor (Int) -> Void = { _ in })
      -> MeetingTranscriptionJob.CheckpointAccess
    {
      let store = MeetingProcessingCheckpointStore(meetingFolder: folder)
      let saves = OSAllocatedUnfairLock(initialState: 0)
      return .init(
        meetingID: meetingID,
        load: {
          if case .checkpoint(let c) = store.load() { return c }
          return nil
        },
        save: { checkpoint in
          try store.save(checkpoint)
          let count = saves.withLock { value -> Int in
            value += 1
            return value
          }
          await MainActor.run { onSaved(count) }
        })
    }

    /// Runs in the child process; never returns when the stop point is reached.
    @MainActor
    static func runChild(folder: URL, stopAfter: Int) async throws {
      _ = try await job().runTestAttempt(
        tracks: [.microphone: try audio(in: folder)], language: nil,
        checkpoint: access(folder: folder) { count in
          print("EW_JOB_SAVED \(count)")
          fflush(stdout)
          guard count >= stopAfter else { return }
          // The checkpoint for this many pieces is durable; hold here until SIGKILL.
          while true { pause() }
        }
      ) { _ in }
      print("EW_JOB_FINISHED")
      fflush(stdout)
      exit(3)
    }

    struct ChildResult {
      let reachedStop: Bool
      let killedBySIGKILL: Bool
      let output: String
    }

    /// Starts the child on `folder`, waits (bounded) for it to report `stopAfter` saves, kills
    /// only that child with SIGKILL and reaps it on every path.
    static func runAndKill(folder: URL, stopAfter: Int, deadline: Duration = .seconds(60))
      async throws
      -> ChildResult
    {
      let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
      guard executable.lastPathComponent == "xctest" else {
        throw NSError(domain: "MeetingProcessingCrash", code: 1)
      }
      let bundle = Bundle(for: MeetingProcessingCrashChild.self).bundleURL
      let products = bundle.deletingLastPathComponent().path
      let parent = ProcessInfo.processInfo.environment
      // A small explicit environment: inheriting the parent's joins its Xcode test session.
      var environment: [String: String] = [
        "DYLD_FRAMEWORK_PATH": products, "DYLD_LIBRARY_PATH": products,
        folderKey: folder.path, stopAfterKey: String(stopAfter),
      ]
      for key in ["PATH", "HOME", "TMPDIR", "USER"] { environment[key] = parent[key] }
      let process = Process()
      process.executableURL = executable
      process.arguments = ["-XCTest", "MeetingProcessingCrashChild/testChildEntry", bundle.path]
      process.environment = environment
      let stdout = Pipe()
      process.standardOutput = stdout
      process.standardError = FileHandle.nullDevice
      let output = OSAllocatedUnfairLock(initialState: "")
      let marker = "EW_JOB_SAVED \(stopAfter)"
      let reached: Bool = await withCheckedContinuation { continuation in
        let once = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (Bool) -> Void = { value in
          let first = once.withLock { done -> Bool in
            defer { done = true }
            return !done
          }
          if first { continuation.resume(returning: value) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          guard !data.isEmpty else { return }
          let text = output.withLock { all -> String in
            all += String(decoding: data, as: UTF8.self)
            return all
          }
          if text.contains(marker) { finish(true) }
          if text.contains("EW_JOB_FINISHED") { finish(false) }
        }
        process.terminationHandler = { _ in finish(false) }
        do {
          try process.run()
        } catch {
          finish(false)
          return
        }
        Task {
          // deadline-fallback: a child that never reports fails the test instead of hanging.
          try? await Task.sleep(for: deadline)
          finish(false)
        }
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      stdout.fileHandleForReading.readabilityHandler = nil
      return ChildResult(
        reachedStop: reached,
        killedBySIGKILL: process.terminationReason == .uncaughtSignal
          && process.terminationStatus == SIGKILL,
        output: output.withLock { $0 })
    }
  }
#endif
