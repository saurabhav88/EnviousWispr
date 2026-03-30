import Foundation

/// Deterministic debug breadcrumb sink for cross-process tracing.
/// Writes timestamped lines to /tmp/com.enviouswispr.ctc.log.
/// Safe to call from main app and XPC services.
/// **DEBUG ONLY:** Completely no-ops in release builds.
public enum DebugTrace {
    #if DEBUG
    private static let logURL = URL(fileURLWithPath: "/tmp/com.enviouswispr.ctc.log")
    private static let lock = NSLock()
    private static let processTag: String = {
        let name = ProcessInfo.processInfo.processName
        if name.contains("ASRService") { return "asr-xpc" }
        if name.contains("AudioService") { return "audio-xpc" }
        return "main"
    }()
    #endif

    /// Append a timestamped breadcrumb line. No-ops in release.
    /// @autoclosure avoids string construction overhead in release builds.
    public static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(processTag)] \(text)\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: logURL, atomically: false, encoding: .utf8)
        }
        #endif
    }

    /// Clear the log file. No-ops in release.
    public static func clear() {
        #if DEBUG
        try? "".write(
            to: URL(fileURLWithPath: "/tmp/com.enviouswispr.ctc.log"),
            atomically: true,
            encoding: .utf8
        )
        #endif
    }
}
