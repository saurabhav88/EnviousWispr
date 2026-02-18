import AppKit

/// Plays audio cues for recording state changes using macOS system sounds.
@MainActor
final class SoundManager {
    /// Whether audio cues are enabled. Controlled by user preference.
    var isEnabled: Bool = true

    /// Play the recording-started cue.
    func playStartSound() {
        guard isEnabled else { return }
        NSSound(named: "Tink")?.play()
    }

    /// Play the recording-stopped cue.
    func playStopSound() {
        guard isEnabled else { return }
        NSSound(named: "Pop")?.play()
    }

    /// Play an error indication.
    func playErrorSound() {
        guard isEnabled else { return }
        NSSound(named: "Basso")?.play()
    }

    /// Play transcription-complete cue.
    func playCompleteSound() {
        guard isEnabled else { return }
        NSSound(named: "Glass")?.play()
    }
}
