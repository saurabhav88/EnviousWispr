import Foundation

/// Persists transcripts as JSON files in Application Support.
@MainActor
final class TranscriptStore {
    private let directory: URL

    init() {
        directory = AppConstants.appSupportURL
            .appendingPathComponent(AppConstants.transcriptsDir, isDirectory: true)

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Save a transcript to disk.
    func save(_ transcript: Transcript) throws {
        let filename = "\(transcript.id.uuidString).json"
        let url = directory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(transcript)
        try data.write(to: url, options: .atomic)
    }

    /// Load all transcripts, sorted by creation date (newest first).
    /// Heavy file IO is performed on a background thread to keep UI responsive.
    func loadAll() async throws -> [Transcript] {
        let dir = directory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        // Move heavy IO to background thread
        let transcripts: [Transcript] = try await Task.detached(priority: .userInitiated) {
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            )

            let decoder = JSONDecoder()
            var result: [Transcript] = []
            for url in files where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let transcript = try decoder.decode(Transcript.self, from: data)
                    result.append(transcript)
                } catch {
                    // Log errors but don't block — corrupt files are skipped
                    await AppLogger.shared.log(
                        "Skipping corrupt transcript \(url.lastPathComponent): \(error)",
                        level: .info, category: "TranscriptStore"
                    )
                }
            }
            return result.sorted { $0.createdAt > $1.createdAt }
        }.value

        return transcripts
    }

    /// Synchronous load for cases where async isn't suitable.
    /// Prefer loadAll() async when possible to keep UI responsive.
    func loadAllSync() throws -> [Transcript] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        let decoder = JSONDecoder()
        let transcripts = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Transcript? in
                do {
                    let data = try Data(contentsOf: url)
                    return try decoder.decode(Transcript.self, from: data)
                } catch {
                    return nil
                }
            }
        return transcripts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Delete a transcript by ID.
    func delete(id: UUID) throws {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.removeItem(at: url)
    }

    /// Delete all transcripts from disk.
    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for file in files where file.pathExtension == "json" {
            try FileManager.default.removeItem(at: file)
        }
    }
}
