import Darwin
import Foundation
import XCTest
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

#if DEBUG
/// The child half of the #3972 C2a process-death proof. The parent test starts this test bundle
/// again in its own `xctest` process with the two environment keys set; this entry runs the
/// production `MeetingTrackWriter`, announces the requested phase on stdout and then blocks until
/// the parent kills it with `SIGKILL`. In an ordinary test run the keys are absent and the entry
/// returns at once.
///
/// An XCTest case only because `xctest -XCTest <Class/method>` can select it without running
/// any Swift Testing suite in the child.
@objc(MeetingWriterCrashChild)
final class MeetingWriterCrashChild: XCTestCase {
  func testChildEntry() {
    let environment = ProcessInfo.processInfo.environment
    guard let folder = environment[MeetingWriterCrash.folderKey],
      let phase = environment[MeetingWriterCrash.phaseKey]
    else { return }
    MeetingWriterCrash.runChild(folder: URL(fileURLWithPath: folder), phase: phase)
  }
}

enum MeetingWriterCrash {
  static let folderKey = "EW_MEETING_CRASH_FOLDER"
  static let phaseKey = "EW_MEETING_CRASH_PHASE"
  /// Phases the child can stop at: after its samples are written into the open segment, and
  /// the writer's two finalization phases.
  static let appended = "appended"
  static let frames = 40_000

  /// Known audio, exactly representable as 16-bit integers.
  static func sample(_ i: Int) -> Float { Float((i * 37) % 2_000 - 1_000) / 32_768 }

  private static func announce(_ phase: String) {
    print("EW_CRASH_PHASE \(phase)")
    fflush(stdout)
  }

  /// Runs in the child process; never returns.
  static func runChild(folder: URL, phase: String) -> Never {
    let anchor = mach_absolute_time()
    let writer = MeetingTrackWriter(
      configuration: .init(
        meetingID: UUID(), track: .microphone, folder: folder, anchorHostTime: anchor),
      onSegmentFinalized: { _ in announce("acknowledged") },
      onFailure: { _ in announce("failed") })
    if phase != appended {
      writer.setPhaseHookForTesting { reached in
        guard reached.rawValue == phase else { return }
        announce(phase)
        // Holds the writer's queue at this exact point until the parent's SIGKILL.
        while true { pause() }
      }
    }
    writer.append((0..<frames).map(sample), hostTime: anchor)
    if phase == appended {
      let written = DispatchSemaphore(value: 0)
      Task.detached {
        await writer.waitUntilWritten()
        written.signal()
      }
      written.wait()
      announce(appended)
      while true { pause() }
    }
    _ = writer.close(until: .distantFuture)
    announce("closed")
    exit(3)
  }

  struct ChildResult {
    /// The child announced the requested phase before it was killed.
    let reachedPhase: Bool
    let killedBySIGKILL: Bool
    let output: String
  }

  /// Starts the child for `phase` writing into `folder`, waits (at most `deadline`) for it to
  /// announce the phase, kills only that child with `SIGKILL` and reaps it on every path.
  static func runAndKill(
    phase: String, folder: URL, deadline: Duration = .seconds(60)
  ) async throws -> ChildResult {
    let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    guard executable.lastPathComponent == "xctest" else {
      throw ChildError.notRunningUnderXCTest(executable.path)
    }
    let bundle = Bundle(for: MeetingWriterCrashChild.self).bundleURL
    let products = bundle.deletingLastPathComponent().path
    // A small, explicit environment. Inheriting the parent's makes the child join the
    // parent's Xcode test session (its XCTest configuration and injected libraries) and wait
    // there forever instead of running the selected entry.
    let parent = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
      "DYLD_FRAMEWORK_PATH": products, "DYLD_LIBRARY_PATH": products,
    ]
    for key in ["PATH", "HOME", "TMPDIR", "USER"] { environment[key] = parent[key] }
    environment[folderKey] = folder.path
    environment[phaseKey] = phase

    let process = Process()
    process.executableURL = executable
    process.arguments = ["-XCTest", "MeetingWriterCrashChild/testChildEntry", bundle.path]
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    let output = OSAllocatedUnfairLock(initialState: "")
    let reached: Bool = await withCheckedContinuation { continuation in
      let once = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (Bool) -> Void = { value in
        let first = once.withLock { done -> Bool in
          defer { done = true }
          return !done
        }
        if first { continuation.resume(returning: value) }
      }
      let marker = "EW_CRASH_PHASE \(phase)"
      stdout.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        let text = output.withLock { all -> String in
          all += String(decoding: data, as: UTF8.self)
          return all
        }
        if text.contains(marker) { finish(true) }
        if text.contains("EW_CRASH_PHASE failed") || text.contains("EW_CRASH_PHASE closed") {
          finish(false)
        }
      }
      process.terminationHandler = { _ in finish(false) }
      do {
        try process.run()
      } catch {
        finish(false)
        return
      }
      Task {
        // deadline-fallback: a child that never announces must fail the test, not hang it.
        try? await Task.sleep(for: deadline)
        finish(false)
      }
    }
    // Kill and reap only the child this call started, whatever happened above.
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    stdout.fileHandleForReading.readabilityHandler = nil
    return ChildResult(
      reachedPhase: reached,
      killedBySIGKILL: process.terminationReason == .uncaughtSignal
        && process.terminationStatus == SIGKILL,
      output: output.withLock { $0 })
  }

  enum ChildError: Error {
    case notRunningUnderXCTest(String)
  }
}
#endif
