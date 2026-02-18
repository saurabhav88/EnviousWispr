import Foundation

/// Persists transcripts as JSON files in Application Support.
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
    func loadAll() throws -> [Transcript] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        let transcripts = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Transcript? in
                do {
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode(Transcript.self, from: data)
                } catch {
                    print("Skipping corrupt transcript \(url.lastPathComponent): \(error)")
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
}
