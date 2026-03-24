import Foundation

/// Cross-process progress communication via a shared temp file.
///
/// XPC connections serialize replies, making it impossible to poll for progress
/// while a long-running call (loadModel) is pending. This file-based approach
/// completely bypasses XPC for progress updates.
///
/// The XPC service writes progress snapshots. The host app reads them on a timer.
/// Both use the same well-known file path derived from the process's temp directory parent.
///
/// Thread-safe: writes are atomic (write-to-temp + rename). Reads tolerate partial writes.
public final class ProgressFile: Sendable {
    public static let shared = ProgressFile()

    /// Well-known path both processes can find.
    /// Uses /tmp/ which is accessible to both the app and its XPC services.
    private let filePath: String = "/tmp/com.enviouswispr.download-progress"

    private init() {}

    /// Write a progress snapshot. Called from the download delegate thread — must be fast.
    /// Uses atomic write (write to temp + rename) to prevent partial reads.
    public func write(fraction: Double, phase: String, detail: String) {
        // Simple format: "fraction|phase|detail" — no JSON overhead
        let content = "\(fraction)|\(phase)|\(detail)"
        guard let data = content.data(using: .utf8) else { return }

        let tmpPath = filePath + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
            // rename is atomic on APFS/HFS+
            _ = rename(tmpPath, filePath)
        } catch {
            // Progress write failure is non-fatal — UI just won't update this tick
        }
    }

    /// Read the latest progress snapshot. Returns nil if file doesn't exist or is malformed.
    /// Called by the host app on a timer.
    public func read() -> (fraction: Double, phase: String, detail: String)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let parts = content.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 1, let fraction = Double(parts[0]) else { return nil }

        let phase = parts.count > 1 ? String(parts[1]) : ""
        let detail = parts.count > 2 ? String(parts[2]) : ""
        return (fraction, phase, detail)
    }

    /// Clear the progress file. Called before starting a new download.
    public func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
