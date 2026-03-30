import Foundation

/// Deterministic debug breadcrumb sink for cross-process tracing.
/// Writes timestamped lines to /tmp/com.enviouswispr.ctc.log.
/// Safe to call from main app and XPC services.
public enum DebugTrace {
    private static let logURL = URL(fileURLWithPath: "/tmp/com.enviouswispr.ctc.log")
    private static let lock = NSLock()
    private static let processTag: String = {
        let name = ProcessInfo.processInfo.processName
        if name.contains("ASRService") { return "asr-xpc" }
        if name.contains("AudioService") { return "audio-xpc" }
        return "main"
    }()

    /// Append a timestamped breadcrumb line.
    public static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(processTag)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: logURL, atomically: false, encoding: .utf8)
        }
    }

    /// Clear the log file.
    public static func clear() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}
