# Feature: WAV Recording History

**ID:** 020
**Category:** Developer Experience
**Priority:** Medium
**Inspired by:** Handy — SQLite + WAV files with save/delete/retention policies
**Status:** Ready for Implementation

## Problem

After transcription, the raw audio is discarded. Users cannot:

- Re-listen to what they said
- Re-transcribe with a different model or settings
- Verify transcription accuracy against the original audio
- Keep audio records for reference

## Proposed Solution

Optionally save the raw audio alongside each transcript:

1. After recording stops, write `capturedSamples` to a `.wav` file in the transcripts directory
2. Link the `.wav` file path in the `Transcript` model
3. Add a playback button in `TranscriptDetailView` (using `AVAudioPlayer`)
4. Add retention settings: Keep All / Keep Latest N / Auto-Delete After N Days / Never Save
5. Show audio duration and file size in transcript metadata

## Files to Modify

- `Sources/EnviousWispr/Models/Transcript.swift` — add `wavFilename: String?` and `audioFileSize: Int?` fields (optional, backward-compatible `Codable`)
- `Sources/EnviousWispr/Storage/TranscriptStore.swift` — add `saveWAV(samples:sampleRate:forID:)` and `deleteWAV(forID:)` methods; update `delete(id:)` to also remove the associated `.wav` file; add `applyRetentionPolicy(_:)` method
- `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` — after `transcriptStore.save(transcript)`, conditionally call `transcriptStore.saveWAV(...)` when `wavRetentionPolicy != .neverSave`; pre-generate the UUID before WAV save so the filename matches the JSON
- `Sources/EnviousWispr/App/AppState.swift` — add `wavRetentionPolicy: WAVRetentionPolicy` (persisted) and `saveWAVRecordings: Bool` convenience; add `deleteTranscript` extension to also clean up WAV; call `applyRetentionPolicy` after each save
- `Sources/EnviousWispr/Views/Settings/SettingsView.swift` — add WAV recording section in `GeneralSettingsView`
- `Sources/EnviousWispr/Views/Main/TranscriptDetailView.swift` — add playback button and audio metadata display

## New Files

- `Sources/EnviousWispr/Utilities/WAVWriter.swift` — pure-Swift RIFF/WAV writer (44-byte header + Float32 PCM samples)
- `Sources/EnviousWispr/Utilities/WAVRetentionPolicy.swift` — enum definition
- `Sources/EnviousWispr/Utilities/AVAudioPlayerWrapper.swift` — `NSObject` subclass wrapping `AVAudioPlayer` for `AVAudioPlayerDelegate` conformance in Swift 6

## Implementation Plan

### Step 1: Define WAVRetentionPolicy

```swift
// Sources/EnviousWispr/Utilities/WAVRetentionPolicy.swift
import Foundation

/// Controls whether and how long WAV recordings are kept on disk.
enum WAVRetentionPolicy: String, CaseIterable, Codable, Sendable {
    /// Never save WAV files. Raw audio is discarded after transcription (default).
    case neverSave      = "neverSave"
    /// Save all WAV files indefinitely.
    case keepAll        = "keepAll"
    /// Keep the most recent N recordings; delete older ones automatically.
    case keepLatestN    = "keepLatestN"
    /// Delete WAV files older than N days; keep the JSON transcript.
    case deleteAfterDays = "deleteAfterDays"

    var displayName: String {
        switch self {
        case .neverSave:       return "Never Save (default)"
        case .keepAll:         return "Keep All"
        case .keepLatestN:     return "Keep Latest N Recordings"
        case .deleteAfterDays: return "Delete After N Days"
        }
    }
}
```

### Step 2: Implement WAVWriter

The RIFF/WAV format is simple: a 44-byte header followed by raw PCM sample data. EnviousWispr captures audio as `[Float]` at 16kHz mono. The WAV file stores these as 32-bit IEEE float PCM (format code 3), which `AVAudioPlayer` can play back natively on macOS.

```swift
// Sources/EnviousWispr/Utilities/WAVWriter.swift
import Foundation

/// Writes a RIFF/WAV file from an array of Float32 audio samples.
///
/// Format: PCM IEEE Float (format tag 3), mono, 16000 Hz, 32-bit.
/// No external dependencies — pure Swift byte manipulation.
enum WAVWriter {

    /// Write samples to the given URL. Returns the file size in bytes, or throws on error.
    @discardableResult
    static func write(
        samples: [Float],
        sampleRate: UInt32 = 16000,
        to url: URL
    ) throws -> Int {
        let numSamples     = UInt32(samples.count)
        let numChannels    : UInt32 = 1
        let bitsPerSample  : UInt16 = 32
        let byteRate       = sampleRate * numChannels * UInt32(bitsPerSample) / 8
        let blockAlign     = UInt16(numChannels * UInt32(bitsPerSample) / 8)
        let dataChunkSize  = numSamples * UInt32(bitsPerSample / 8)
        let riffChunkSize  = 36 + dataChunkSize

        var header = Data(capacity: 44)

        // RIFF chunk descriptor
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndianBytes: riffChunkSize)
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndianBytes: UInt32(16))       // sub-chunk size
        header.append(littleEndianBytes: UInt16(3))        // IEEE Float = 3
        header.append(littleEndianBytes: UInt16(numChannels))
        header.append(littleEndianBytes: sampleRate)
        header.append(littleEndianBytes: byteRate)
        header.append(littleEndianBytes: blockAlign)
        header.append(littleEndianBytes: bitsPerSample)

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        header.append(littleEndianBytes: dataChunkSize)

        // Sample data — reinterpret [Float] bytes directly
        var sampleData = Data(count: Int(dataChunkSize))
        sampleData.withUnsafeMutableBytes { rawPtr in
            guard let floatPtr = rawPtr.bindMemory(to: Float.self).baseAddress else { return }
            for (i, sample) in samples.enumerated() {
                floatPtr[i] = sample
            }
        }

        let fileData = header + sampleData
        try fileData.write(to: url, options: .atomic)
        return fileData.count
    }
}

// MARK: - Data helpers for little-endian encoding

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndianBytes value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
```

Storage size reference: 16kHz mono Float32 = 64,000 bytes/second. A 30-second recording = ~1.9 MB (WAV), not 3.8 MB, because the samples are already 32-bit — the 3.8 MB figure includes the original unresampled buffer which is larger. Post-resampling at 16kHz: 16000 samples/s × 4 bytes = 64 KB/s.

### Step 3: Implement AVAudioPlayerWrapper

`AVAudioPlayerDelegate` requires `NSObject` conformance, which conflicts with Swift 6 actor isolation. Wrapping in an `NSObject` subclass keeps the delegate logic isolated from SwiftUI:

```swift
// Sources/EnviousWispr/Utilities/AVAudioPlayerWrapper.swift
import AVFoundation
import Foundation

/// NSObject wrapper around AVAudioPlayer so it can implement AVAudioPlayerDelegate.
/// Observable so SwiftUI views can bind to isPlaying/playbackProgress.
@MainActor
@Observable
final class AVAudioPlayerWrapper: NSObject {
    private var player: AVAudioPlayer?
    private(set) var isPlaying: Bool = false
    private(set) var duration: TimeInterval = 0
    private(set) var playbackProgress: Double = 0  // 0.0 – 1.0
    private var progressTimer: Timer?

    func load(url: URL) throws {
        stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        playbackProgress = 0
    }

    func play() {
        guard let p = player else { return }
        p.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        playbackProgress = 0
        stopProgressTimer()
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.playbackProgress = p.currentTime / p.duration
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

extension AVAudioPlayerWrapper: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            self.isPlaying = false
            self.playbackProgress = 0
            self.stopProgressTimer()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated {
            self.isPlaying = false
            self.stopProgressTimer()
        }
    }
}
```

### Step 4: Update Transcript model (backward-compatible Codable)

Adding optional fields with default values preserves Codable compatibility with existing JSON files — old JSON without these keys decodes with `nil`, which is the correct backward-compatible behaviour:

```swift
// Sources/EnviousWispr/Models/Transcript.swift — add two fields:
struct Transcript: Codable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let polishedText: String?
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let backendType: ASRBackendType
    let createdAt: Date
    var isFavorite: Bool
    // NEW — both optional for backward compatibility:
    let wavFilename: String?       // e.g. "550E8400-E29B-41D4-A716-446655440000.wav"
    let audioFileSize: Int?        // bytes, for display in UI

    init(
        id: UUID = UUID(),
        text: String,
        polishedText: String? = nil,
        language: String? = nil,
        duration: TimeInterval = 0,
        processingTime: TimeInterval = 0,
        backendType: ASRBackendType = .parakeet,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
        wavFilename: String? = nil,      // NEW
        audioFileSize: Int? = nil        // NEW
    ) {
        // ... assign all fields ...
        self.wavFilename = wavFilename
        self.audioFileSize = audioFileSize
    }
}
```

Because both fields are `Optional` with no `@available` restriction, `JSONDecoder` will set them to `nil` when decoding older JSON files that lack these keys — no `CodingKeys` enum or custom `init(from:)` is needed.

### Step 5: Update TranscriptStore

```swift
// TranscriptStore.swift — add methods:

/// Write audio samples as a WAV file alongside the transcript JSON.
/// Returns the file size in bytes.
@discardableResult
func saveWAV(samples: [Float], sampleRate: UInt32 = 16000, forID id: UUID) throws -> Int {
    let url = directory.appendingPathComponent("\(id.uuidString).wav")
    return try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: url)
}

/// URL of the WAV file for a given transcript ID (may not exist).
func wavURL(forID id: UUID) -> URL {
    directory.appendingPathComponent("\(id.uuidString).wav")
}

/// Delete the WAV file for a transcript (if it exists). Silent if not found.
func deleteWAV(forID id: UUID) {
    let url = directory.appendingPathComponent("\(id.uuidString).wav")
    try? FileManager.default.removeItem(at: url)
}

/// Update delete(id:) to also remove the WAV file:
func delete(id: UUID) throws {
    let jsonURL = directory.appendingPathComponent("\(id.uuidString).json")
    try FileManager.default.removeItem(at: jsonURL)
    deleteWAV(forID: id)   // <-- ADD THIS LINE
}

/// Apply retention policy to WAV files (not JSON — transcripts are always kept).
func applyRetentionPolicy(_ policy: WAVRetentionPolicy, keepLatestN: Int = 10, deleteAfterDays: Int = 7) throws {
    switch policy {
    case .neverSave, .keepAll:
        return  // neverSave: WAV files won't exist; keepAll: no action needed

    case .keepLatestN:
        let all = try loadAll()  // sorted newest first
        let toDelete = all.dropFirst(keepLatestN)
        for t in toDelete { deleteWAV(forID: t.id) }

    case .deleteAfterDays:
        let cutoff = Date().addingTimeInterval(-Double(deleteAfterDays) * 86400)
        let all = try loadAll()
        for t in all where t.createdAt < cutoff {
            deleteWAV(forID: t.id)
        }
    }
}
```

### Step 6: Wire into TranscriptionPipeline

The UUID is pre-generated so the WAV filename can match the JSON filename. The WAV is saved before `Transcript` creation so its size is available for the model:

```swift
// TranscriptionPipeline.swift — in stopAndTranscribe(), replace the Transcript creation block:

// Pre-generate UUID so WAV and JSON share the same identifier
let transcriptID = UUID()

// Optionally save WAV before creating the Transcript
var wavFilename: String? = nil
var audioFileSize: Int? = nil
if wavRetentionPolicy != .neverSave {
    do {
        let size = try transcriptStore.saveWAV(
            samples: rawSamples,  // save raw (pre-VAD) audio for full fidelity
            forID: transcriptID
        )
        wavFilename = "\(transcriptID.uuidString).wav"
        audioFileSize = size
    } catch {
        print("WAV save failed (non-fatal): \(error)")
        // Continue — a missing WAV is not a fatal error
    }
}

let transcript = Transcript(
    id: transcriptID,           // use pre-generated ID
    text: convertedText,
    polishedText: polishedText,
    language: result.language,
    duration: result.duration,
    processingTime: result.processingTime,
    backendType: result.backendType,
    wavFilename: wavFilename,
    audioFileSize: audioFileSize
)

try transcriptStore.save(transcript)

// Apply retention policy after each save
try? transcriptStore.applyRetentionPolicy(
    wavRetentionPolicy,
    keepLatestN: wavKeepLatestN,
    deleteAfterDays: wavDeleteAfterDays
)
```

Add three new properties to `TranscriptionPipeline`:

```swift
var wavRetentionPolicy: WAVRetentionPolicy = .neverSave
var wavKeepLatestN: Int = 10
var wavDeleteAfterDays: Int = 7
```

### Step 7: Add settings to AppState

```swift
// AppState.swift — add properties:
var wavRetentionPolicy: WAVRetentionPolicy {
    didSet {
        UserDefaults.standard.set(wavRetentionPolicy.rawValue, forKey: "wavRetentionPolicy")
        pipeline.wavRetentionPolicy = wavRetentionPolicy
    }
}
var wavKeepLatestN: Int {
    didSet {
        UserDefaults.standard.set(wavKeepLatestN, forKey: "wavKeepLatestN")
        pipeline.wavKeepLatestN = wavKeepLatestN
    }
}
var wavDeleteAfterDays: Int {
    didSet {
        UserDefaults.standard.set(wavDeleteAfterDays, forKey: "wavDeleteAfterDays")
        pipeline.wavDeleteAfterDays = wavDeleteAfterDays
    }
}

// In init():
wavRetentionPolicy = WAVRetentionPolicy(
    rawValue: defaults.string(forKey: "wavRetentionPolicy") ?? ""
) ?? .neverSave
wavKeepLatestN = defaults.integer(forKey: "wavKeepLatestN").nonZero ?? 10
wavDeleteAfterDays = defaults.integer(forKey: "wavDeleteAfterDays").nonZero ?? 7
pipeline.wavRetentionPolicy = wavRetentionPolicy
pipeline.wavKeepLatestN = wavKeepLatestN
pipeline.wavDeleteAfterDays = wavDeleteAfterDays
```

Helper extension (add to a shared utilities file or inline):

```swift
private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
```

### Step 8: Add UI in SettingsView

```swift
// In GeneralSettingsView, add a new Section:
Section("Audio Recording History") {
    Picker("Save Recordings", selection: $state.wavRetentionPolicy) {
        ForEach(WAVRetentionPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
        }
    }

    if appState.wavRetentionPolicy == .keepLatestN {
        Stepper("Keep latest \(appState.wavKeepLatestN) recordings",
                value: $state.wavKeepLatestN, in: 1...100)
    }

    if appState.wavRetentionPolicy == .deleteAfterDays {
        Stepper("Delete after \(appState.wavDeleteAfterDays) days",
                value: $state.wavDeleteAfterDays, in: 1...365)
    }

    if appState.wavRetentionPolicy != .neverSave {
        Text("16kHz mono recordings use approximately 64 KB per second of audio.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Raw audio recordings are more sensitive than text transcripts. They are stored locally and never uploaded.")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
```

### Step 9: Update TranscriptDetailView with playback controls

```swift
// TranscriptDetailView.swift — add state and integrate player:
struct TranscriptDetailView: View {
    let transcript: Transcript
    @Environment(AppState.self) private var appState
    @State private var audioPlayer = AVAudioPlayerWrapper()
    @State private var playerError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ... existing transcript text ScrollView ...

            Divider()

            HStack(spacing: 12) {
                // ... existing Copy / Paste / Enhance / Delete buttons ...

                // NEW: Playback button (shown only when WAV file exists)
                if let wavFilename = transcript.wavFilename {
                    playbackControls(wavFilename: wavFilename)
                }

                Spacer()

                // Metadata (extend existing VStack)
                VStack(alignment: .trailing) {
                    // ... existing backend / processingTime / Enhanced labels ...

                    // NEW: Audio file size
                    if let size = transcript.audioFileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func playbackControls(wavFilename: String) -> some View {
        HStack(spacing: 6) {
            Button {
                togglePlayback(wavFilename: wavFilename)
            } label: {
                Label(
                    audioPlayer.isPlaying ? "Pause" : "Play",
                    systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill"
                )
            }

            if audioPlayer.duration > 0 {
                ProgressView(value: audioPlayer.playbackProgress)
                    .frame(width: 80)
                    .tint(.accentColor)

                Text(formatDuration(audioPlayer.duration))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { audioPlayer.stop() }
    }

    private func togglePlayback(wavFilename: String) {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            return
        }
        do {
            let url = AppConstants.appSupportURL
                .appendingPathComponent(AppConstants.transcriptsDir)
                .appendingPathComponent(wavFilename)
            try audioPlayer.load(url: url)
            audioPlayer.play()
            playerError = nil
        } catch {
            playerError = "Cannot play audio: \(error.localizedDescription)"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

## Testing Strategy

1. **WAV writer correctness:** Write a known sine wave (`sin(2π × 440 × t)`) at 16kHz using `WAVWriter.write(samples:to:)`. Open the resulting file with `AVAudioPlayer` and verify it plays at 440 Hz. Also verify the file starts with the bytes "RIFF" and "WAVE" and that the header values (sample rate, bit depth) are correct.

2. **Backward-compatible Codable:** Create a JSON file that looks like an existing `Transcript` (without `wavFilename` or `audioFileSize` keys). Decode it with the new `Transcript` model. Verify `wavFilename == nil` and `audioFileSize == nil`. Verify re-encoding and decoding round-trips cleanly.

3. **UUID pre-generation:** After a recording with `wavRetentionPolicy = .keepAll`, verify that `{transcript.id.uuidString}.wav` exists alongside `{transcript.id.uuidString}.json` in the Application Support transcripts directory.

4. **Opt-in default:** Fresh install with no prior settings. Verify `wavRetentionPolicy == .neverSave`. Perform a recording. Verify no `.wav` file is created.

5. **Retention policy — keepLatestN:** Set `keepLatestN = 3`. Perform 5 recordings. Verify only the 3 most recent UUIDs have `.wav` files; the 2 oldest `.wav` files are deleted (but their `.json` files remain).

6. **Retention policy — deleteAfterDays:** Manually create a `.wav` file with `createdAt` 8 days in the past (inject a fake transcript). Call `applyRetentionPolicy(.deleteAfterDays)` with `deleteAfterDays = 7`. Verify the old `.wav` is deleted and the JSON transcript remains.

7. **Delete transcript also deletes WAV:** Call `appState.deleteTranscript(transcript)` for a transcript with a known WAV file. Verify both `.json` and `.wav` are removed from disk.

8. **Playback in UI:** Select a transcript with an associated WAV file. Click "Play" in `TranscriptDetailView`. Verify audio plays. Click "Pause". Verify playback pauses. Navigate away from the detail view — verify `audioPlayer.stop()` is called via `onDisappear`.

9. **File size display:** Verify the file size label in `TranscriptDetailView` matches the actual byte count of the `.wav` file on disk (use `FileManager.default.attributesOfItem(atPath:)`).

10. **Storage estimate accuracy:** Record exactly 10 seconds of silence. Verify the WAV file size is approximately 640,000 bytes (16000 samples/s × 4 bytes/sample × 10s = 640 KB).

## Risks & Considerations

- Storage: 16kHz mono Float32 audio is ~64 KB/sec — a 30-second recording is ~1.9 MB (WAV format, post-resampling). Storage estimate in the original feature request was for unresampled audio.
- Need a WAV file writer (write RIFF/WAV header + raw PCM data) — mitigated by pure-Swift `WAVWriter` with no dependencies
- Retention policy must clean up orphaned .wav files — mitigated by calling `applyRetentionPolicy` after every save and by updating `delete(id:)` to also remove WAV
- Privacy: raw audio recordings are more sensitive than text transcripts — mitigated by opt-in default (`neverSave`), local-only storage, and a prominent orange warning in Settings
- Should be opt-in, disabled by default — enforced by `wavRetentionPolicy` defaulting to `.neverSave`
- `AVAudioPlayer` requires the file to exist at load time — if the user manually deletes the WAV, the play button should show an error gracefully (handled by the `do/catch` in `togglePlayback`)
- The `AVAudioPlayerWrapper` uses `@MainActor @Observable` — compatible with Swift 6 strict concurrency; the `nonisolated` delegate callbacks use `MainActor.assumeIsolated` following the established pattern in `AudioCaptureManager`
