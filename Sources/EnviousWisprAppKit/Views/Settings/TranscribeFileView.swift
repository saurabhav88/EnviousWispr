import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// #2648 — Transcribe a File.
///
/// **The text is the interface.** The founder's binding calls on 2026-09-04:
/// while a run is going the document fills in with the words themselves, not a
/// row of numbered chips; the splitting is never user-facing; Done stays put
/// until a new run is started; and every primary action sits with the content it
/// acts on rather than pinned to a far bottom bar.
///
/// One page, six states, driven entirely by `FileImportCoordinator` — the job
/// outlives this view, so leaving the page and coming back lands on whatever the
/// run has reached.
struct TranscribeFileView: View {
  @Environment(FileImportCoordinator.self) private var coordinator
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    SettingsContentView {
      switch coordinator.state {
      case .idle:
        chooseCard
      case .reading(let fileName):
        readingCard(fileName: fileName)
      case .ready(let fileName, let seconds):
        readyCard(fileName: fileName, seconds: seconds)
      case .transcribing(let fileName):
        workingCard(title: "Transcribing \(fileName)", detail: nil)
      case .polishing(let done, let total):
        workingCard(title: "Cleaning up your text", detail: progressLine(done: done, total: total))
        documentCard
      case .finished:
        doneHeader
        documentCard
      case .stopped:
        stoppedHeader
        documentCard
      case .rejected(let reason):
        rejectedCard(reason: reason)
      }
      privacyCard
    }
  }

  // MARK: - Choosing

  private var chooseCard: some View {
    BrandedSection(header: "YOUR FILE") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Pick an audio or video file and get clean text back.")
        Text("Voice memos, lectures, meetings. Any length.")
          .foregroundStyle(.secondary)
        SettingsActionButton(
          title: "Choose a file", isEnabled: true, emphasis: .filled, action: { chooseFile() })
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  private func readingCard(fileName: String) -> some View {
    BrandedSection(header: "YOUR FILE") {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Reading \(fileName)")
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  private func readyCard(fileName: String, seconds: Double) -> some View {
    BrandedSection(header: "YOUR FILE") {
      VStack(alignment: .leading, spacing: 12) {
        Text(fileName).font(.stRowTitle)
        Text(Self.lengthLine(seconds: seconds)).foregroundStyle(.secondary)
        HStack(spacing: 10) {
          SettingsActionButton(
          title: "Start", isEnabled: true, emphasis: .filled, action: { coordinator.start() })
          SettingsActionButton(
          title: "Choose a different file", isEnabled: true, action: { chooseFile() })
        }
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  // MARK: - Working

  private func workingCard(title: String, detail: String?) -> some View {
    BrandedSection(header: "WORKING") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(title)
        }
        if let detail {
          Text(detail).foregroundStyle(.secondary)
        }
        // The stop control sits WITH the work it stops, not in a bar at the
        // bottom of the page.
        SettingsActionButton(
          title: "Stop", isEnabled: true, action: { coordinator.stop() })
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  /// Progress in the user's terms. **Never "part 3 of 14"**: the splitting is a
  /// property of the polisher, not something the user asked for, and naming it
  /// would invite questions about a mechanism they cannot change.
  private func progressLine(done: Int, total: Int) -> String {
    guard total > 1 else { return "Almost there." }
    let percent = Int((Double(done) / Double(total)) * 100)
    return "\(percent)% of the way through."
  }

  private var doneHeader: some View {
    BrandedSection(header: "DONE") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Your text is ready.").font(.stRowTitle)
        HStack(spacing: 10) {
          SettingsActionButton(
          title: "Copy", isEnabled: true, emphasis: .filled, action: { copyDocument() })
          SettingsActionButton(
          title: "Change the polisher", isEnabled: true, action: { coordinator.rePolish() })
          SettingsActionButton(
          title: "Transcribe another file", isEnabled: true, action: { chooseFile() })
        }
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  private var stoppedHeader: some View {
    BrandedSection(header: "STOPPED") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Stopped. What finished is below.").font(.stRowTitle)
        HStack(spacing: 10) {
          SettingsActionButton(
          title: "Copy", isEnabled: true, emphasis: .filled, action: { copyDocument() })
          SettingsActionButton(
          title: "Transcribe another file", isEnabled: true, action: { chooseFile() })
        }
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  // MARK: - The document

  /// **The words themselves, rewritten in place as each part lands.** Not a
  /// progress list, and not a set of numbered blocks the user has to assemble in
  /// their head.
  @ViewBuilder
  private var documentCard: some View {
    if !coordinator.parts.isEmpty {
      BrandedSection(header: "YOUR TEXT") {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(coordinator.parts) { part in
            VStack(alignment: .leading, spacing: 4) {
              Text(part.text).textSelection(.enabled)
              if part.isUnpolished {
                // Marked, never hidden. A passage that could not be cleaned is
                // still the user's words, and pretending otherwise is the
                // failure this feature must not have.
                Text("This passage could not be cleaned up. These are the raw words.")
                  .font(.stHelper)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
      }
    }
  }

  // MARK: - Refusals

  private func rejectedCard(reason: FileImportCoordinator.FileImportRejection) -> some View {
    BrandedSection(header: "YOUR FILE") {
      VStack(alignment: .leading, spacing: 12) {
        Text(Self.sentence(for: reason))
        SettingsActionButton(
          title: "Choose a file", isEnabled: true, emphasis: .filled, action: { chooseFile() })
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  /// One honest sentence per refusal. No mechanism, no error codes, and nothing
  /// that invites the user to retry something that cannot work.
  static func sentence(for reason: FileImportCoordinator.FileImportRejection) -> String {
    switch reason {
    case .cannotRead:
      return "That file couldn't be opened. Try a different one."
    case .noAudio:
      return "There's no sound in that file."
    case .noSpeechFound:
      return "No speech was found in that file."
    case .engineBusy(.dictation):
      return "A dictation is running. Try again when it finishes."
    case .engineBusy(.crashRecovery):
      return "Finishing an earlier take. Try again in a moment."
    case .engineBusy(.fileImport):
      return "Another file is being transcribed right now."
    case .failed:
      return "Something went wrong reading that file. Try a different one."
    }
  }

  static func lengthLine(seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "Under a minute of audio." }
    if minutes == 1 { return "About a minute of audio." }
    return "About \(minutes) minutes of audio."
  }

  // MARK: - Privacy, computed from what is actually selected

  /// **The line is computed, never fixed.** "All processing happens on this Mac"
  /// is false the moment a cloud polisher is selected, and the founder caught
  /// exactly that in the prototype. The audio never leaves either way, so that
  /// half is always true; the text half depends on the choice.
  private var privacyCard: some View {
    InsetNotice(text: Self.privacyLine(isCloudPolish: isCloudPolish))
  }

  private var isCloudPolish: Bool {
    switch settings.llmProvider {
    case .openAI, .gemini, .claude: return true
    case .egOne, .s1Mini, .appleIntelligence, .ollama, .none: return false
    }
  }

  static func privacyLine(isCloudPolish: Bool) -> String {
    if isCloudPolish {
      return """
        Your audio never leaves this Mac. With a cloud polisher selected, only the text goes to the \
        provider you chose, under your own key.
        """
    }
    return "Everything here happens on this Mac. Nothing is uploaded."
  }

  // MARK: - Actions

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    coordinator.choose(url: url)
  }

  private func copyDocument() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(coordinator.documentText, forType: .string)
  }
}
