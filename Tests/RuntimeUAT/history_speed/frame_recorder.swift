// History speed frame recorder (#4586 PR 0). Records every frame ScreenCaptureKit delivers for
// one window, with the WindowServer display time (`SCStreamFrameInfo.displayTime`, host time in
// mach_absolute_time ticks), the frame status, and a 32x32 grayscale signature of a crop region.
// The callback only copies a downsampled signature into a preallocated buffer; JSON is written
// after capture stops, off the capture path.
//
// Capture stops when the caller sends SIGINT or SIGTERM (the normal end: the driver knows when its
// measurement is over); `--seconds` is only a deadline fallback.
//
// Build (into the producing checkout's build/ folder):
//   swiftc -O -o build/history_speed/frame_recorder Tests/RuntimeUAT/history_speed/frame_recorder.swift
// Usage:
//   frame_recorder --pid <pid> --seconds <max s> --out <file.jsonl> [--crop x,y,w,h] [--title <substring>]
//   frame_recorder --display-rect x,y,w,h --seconds <max s> --out <file.jsonl>   (no window needed)
// The crop is in window points from the top-left; default is the whole window.

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct Options {
  var pid: pid_t = 0
  var seconds: Double = 60
  var out = ""
  var crop: CGRect?
  var title: String?
  /// Display mode (#4586 WP-A open driver): capture a rectangle of the main display in screen
  /// points from the top-left, with no window needed, so capture can be armed BEFORE the app starts.
  var displayRect: CGRect?
}

func parse() -> Options {
  var o = Options()
  var args = Array(CommandLine.arguments.dropFirst())
  while !args.isEmpty {
    let key = args.removeFirst()
    guard !args.isEmpty else { break }
    let value = args.removeFirst()
    switch key {
    case "--pid": o.pid = pid_t(value) ?? 0
    case "--seconds": o.seconds = Double(value) ?? 60
    case "--out": o.out = value
    case "--title": o.title = value
    case "--display-rect":
      let p = value.split(separator: ",").compactMap { Double($0) }
      if p.count == 4 { o.displayRect = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
    case "--crop":
      let p = value.split(separator: ",").compactMap { Double($0) }
      if p.count == 4 { o.crop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
    default: break
    }
  }
  guard o.pid > 0 || o.displayRect != nil, !o.out.isEmpty else {
    FileHandle.standardError.write(
      Data(
        "usage: frame_recorder --pid <pid> --seconds <max s> --out <file> [--crop x,y,w,h] [--title t]\n"
          .utf8))
    exit(2)
  }
  return o
}

let side = 32
struct Frame {
  var arrival: UInt64
  var display: UInt64
  var status: Int
  var signature: [UInt8]
  var hash: UInt64
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
  let cropPixels: CGRect?
  let lock = NSLock()
  var frames: [Frame] = []
  var stopError: Error?

  init(cropPixels: CGRect?) {
    self.cropPixels = cropPixels
    frames.reserveCapacity(20_000)
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    let arrival = mach_absolute_time()
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]], let info = attachments.first
    else { return }
    let status = (info[.status] as? Int) ?? -1
    let display = (info[.displayTime] as? UInt64) ?? 0
    var signature: [UInt8] = []
    var hash: UInt64 = 0
    if status == SCFrameStatus.complete.rawValue, let buffer = sample.imageBuffer {
      signature = Recorder.signature(buffer, crop: cropPixels)
      hash = Recorder.exactHash(buffer)
    }
    lock.lock()
    frames.append(Frame(arrival: arrival, display: display, status: status, signature: signature, hash: hash))
    lock.unlock()
  }

  func snapshot() -> [Frame] { lock.withLock { frames } }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    stopError = error
  }

  /// FNV-1a over every pixel byte of the delivered frame (row padding excluded): two frames hash
  /// equal only when their pixels are identical, so equality is an auditable "same picture".
  static func exactHash(_ buffer: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for y in 0..<height {
      let row = base + y * stride
      for i in 0..<(width * 4) {
        h ^= UInt64(row[i])
        h = h &* 0x0000_0100_0000_01B3
      }
    }
    return h
  }

  static func signature(_ buffer: CVPixelBuffer, crop: CGRect?) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
      return []
    }
    let region = (crop ?? CGRect(x: 0, y: 0, width: width, height: height))
      .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard region.width >= CGFloat(side), region.height >= CGFloat(side) else { return [] }
    var out = [UInt8](repeating: 0, count: side * side)
    for row in 0..<side {
      let y = Int(region.minY) + Int(Double(row) * Double(region.height) / Double(side))
      for col in 0..<side {
        let x = Int(region.minX) + Int(Double(col) * Double(region.width) / Double(side))
        let p = base + y * stride + x * 4  // BGRA
        out[row * side + col] = UInt8((Int(p[2]) * 299 + Int(p[1]) * 587 + Int(p[0]) * 114) / 1000)
      }
    }
    return out
  }
}

/// Resumes once: on SIGINT/SIGTERM from the caller, or at the deadline fallback.
final class StopSignal: @unchecked Sendable {  // single resume guarded by `lock`
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Never>?
  private var sources: [DispatchSourceSignal] = []

  func wait(deadline seconds: Double) async -> String {
    await withCheckedContinuation { continuation in
      lock.lock()
      self.continuation = continuation
      lock.unlock()
      for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { [weak self] in self?.resume("signal") }
        source.resume()
        sources.append(source)
      }
      // deadline-fallback: the caller normally stops capture with a signal; this bounds a lost caller
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
        self?.resume("deadline")
      }
    }
  }

  private func resume(_ reason: String) {
    lock.lock()
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(returning: reason)
  }
}

/// Display mode: the same recording loop over a rectangle of the main display.
func recordDisplay(_ rect: CGRect) async throws {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
    FileHandle.standardError.write(Data("frame_recorder: no main display\n".utf8))
    exitCode = 3
    return
  }
  let filter = SCContentFilter(display: display, excludingWindows: [])
  let config = SCStreamConfiguration()
  config.sourceRect = rect
  config.width = max(Int(rect.width), side)
  config.height = max(Int(rect.height), side)
  config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
  config.queueDepth = 8
  config.showsCursor = false
  config.pixelFormat = kCVPixelFormatType_32BGRA
  let recorder = Recorder(cropPixels: nil)
  let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
  try stream.addStreamOutput(
    recorder, type: .screen,
    sampleHandlerQueue: DispatchQueue(label: "frames", qos: .userInteractive))
  let stopper = StopSignal()
  let requested = mach_absolute_time()
  try await stream.startCapture()
  let ready = mach_absolute_time()
  print("{\"ready\": \(ready)}")
  fflush(stdout)
  let reason = await stopper.wait(deadline: options.seconds)
  try await stream.stopCapture()
  let frames = recorder.snapshot()
  var lines: [String] = []
  let header: [String: Any] = [
    "kind": "header", "pid": options.pid, "display_rect": [rect.minX, rect.minY, rect.width, rect.height],
    "timebase_numer": timebase.numer, "timebase_denom": timebase.denom,
    "capture_requested": requested, "capture_ready": ready, "frames": frames.count,
    "stopped_by": reason, "stop_error": recorder.stopError.map { "\($0)" } ?? NSNull(),
  ]
  lines.append(String(data: try JSONSerialization.data(withJSONObject: header), encoding: .utf8)!)
  for f in frames {
    let row: [String: Any] = [
      "arrival": f.arrival, "display": f.display, "status": f.status,
      "sig": Data(f.signature).base64EncodedString(), "hash": String(f.hash, radix: 16),
    ]
    lines.append(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
  }
  try (lines.joined(separator: "\n") + "\n").write(toFile: options.out, atomically: true, encoding: .utf8)
  print("{\"frames\": \(frames.count), \"stopped_by\": \"\(reason)\", \"out\": \"\(options.out)\"}")
}

let options = parse()
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
  do {
    // The target's window can reach the window server a moment after its process starts: keep
    // looking until it is listed (the signal), bounded by a 5 s deadline fallback.
    var candidates: [SCWindow] = []
    let lookupDeadline = Date().addingTimeInterval(options.displayRect == nil ? 5 : 0)
    if let rect = options.displayRect {
      try await recordDisplay(rect)
      semaphore.signal()
      return
    }
    repeat {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      candidates = content.windows.filter {
        $0.owningApplication?.processID == options.pid && $0.frame.width > 100
          && $0.frame.height > 100
          && (options.title == nil || ($0.title ?? "").contains(options.title!))
      }
      if candidates.isEmpty { try await Task.sleep(for: .milliseconds(50)) }  // deadline-fallback: poll interval while the window appears
    } while candidates.isEmpty && Date() < lookupDeadline
    guard
      let window = candidates.max(by: {
        $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
      })
    else {
      FileHandle.standardError.write(
        Data("frame_recorder: no on-screen window for pid \(options.pid)\n".utf8))
      exitCode = 3
      semaphore.signal()
      return
    }
    let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    // Capture only the crop region (`sourceRect`, window points) at 1 point per pixel: the
    // signature is 32x32, so full-resolution frames only add copy load that costs delivered frames.
    let region = options.crop ?? CGRect(origin: .zero, size: window.frame.size)
    config.sourceRect = region
    config.width = max(Int(region.width), side)
    config.height = max(Int(region.height), side)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 120)  // CMTime.zero measured worse: more misses plus duplicates
    config.queueDepth = 8
    config.showsCursor = false
    config.pixelFormat = kCVPixelFormatType_32BGRA
    let cropPixels: CGRect? = nil  // the delivered frame IS the crop
    let recorder = Recorder(cropPixels: cropPixels)
    let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
    try stream.addStreamOutput(
      recorder, type: .screen,
      sampleHandlerQueue: DispatchQueue(label: "frames", qos: .userInteractive))
    let stopper = StopSignal()
    let requested = mach_absolute_time()
    try await stream.startCapture()
    let ready = mach_absolute_time()
    print("{\"ready\": \(ready)}")
    fflush(stdout)
    let reason = await stopper.wait(deadline: options.seconds)
    try await stream.stopCapture()
    let frames = recorder.snapshot()
    var lines: [String] = []
    let header: [String: Any] = [
      "kind": "header", "pid": options.pid, "window_id": window.windowID,
      "title": window.title ?? "",
      "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
      "scale": scale, "timebase_numer": timebase.numer, "timebase_denom": timebase.denom,
      "capture_requested": requested, "capture_ready": ready, "frames": frames.count,
      "stopped_by": reason, "stop_error": recorder.stopError.map { "\($0)" } ?? NSNull(),
    ]
    lines.append(String(data: try JSONSerialization.data(withJSONObject: header), encoding: .utf8)!)
    for f in frames {
      let row: [String: Any] = [
        "arrival": f.arrival, "display": f.display, "status": f.status,
        "sig": Data(f.signature).base64EncodedString(), "hash": String(f.hash, radix: 16),
      ]
      lines.append(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
    }
    try (lines.joined(separator: "\n") + "\n").write(
      toFile: options.out, atomically: true, encoding: .utf8)
    print(
      "{\"frames\": \(frames.count), \"stopped_by\": \"\(reason)\", \"out\": \"\(options.out)\"}")
  } catch {
    FileHandle.standardError.write(Data("frame_recorder: \(error)\n".utf8))
    exitCode = 4
  }
  semaphore.signal()
}
semaphore.wait()
exit(exitCode)
