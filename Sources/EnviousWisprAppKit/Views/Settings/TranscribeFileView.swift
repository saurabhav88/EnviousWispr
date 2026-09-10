import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import SwiftUI
import UniformTypeIdentifiers

/// #2648 — Transcribe a File, built to the clickable prototype the founder
/// approved on 2026-09-04 (`experiments/2648-file-import/import-prototype.html`).
///
/// **Six steps, always visible.** Upload, Transcription, Polish, Review,
/// Working, Done. The user picks BOTH engines for this import before anything
/// runs, each on its own screen with the specs needed to choose — which is why
/// this is a wizard rather than one card with a Start button. The first build of
/// this page was the latter, taken from the plan's prose instead of the
/// prototype, and the founder rejected it on sight.
///
/// **The text is the interface.** On Working the transcript itself fills the
/// page; on Done the document does. The splitting is never named: progress says
/// "62%", never "part 3 of 14".
///
/// **The footer changes with the step**, because what is true changes: before a
/// run it is where the audio stays, during a run it is that leaving is safe,
/// after a run it is about the words that were kept.
struct TranscribeFileView: View {
  @Environment(FileImportCoordinator.self) private var coordinator
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    VStack(spacing: 0) {
      stepBar
      ScrollView {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
          switch coordinator.step {
          case .upload: uploadStep
          case .transcription: transcriptionStep
          case .polish: polishStep
          case .review: reviewStep
          case .working: workingStep
          case .done: doneStep
          }
        }
        .padding(.top, SettingsLayout.contentTop)
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.bottom, SettingsLayout.contentBottom)
      }
      privacyFooter
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.stPageBg)
    .tint(.stAccent)
    .font(.stBody)
    // **Asked where the answer is needed, once per arrival.** The Ollama catalog
    // is populated by the AI Polish page, so a user who opens this wizard
    // directly after a relaunch has never asked the daemon anything and every
    // model reads as unknown. Keyed on the step so it is one local request when
    // the user reaches a screen whose words depend on it, not one per redraw.
    .task(id: coordinator.step) {
      guard coordinator.step == .polish || coordinator.step == .review else { return }
      await coordinator.refreshOllamaFacts()
    }
  }

  // MARK: - The step bar

  /// Completed steps carry a check and stay clickable; the current one is
  /// underlined; the rest are numbered and dim. Going back is offered only while
  /// nothing has run — after that the choices are frozen for the run, and a
  /// live-looking control would be a lie.
  private var stepBar: some View {
    HStack(spacing: 2) {
      ForEach(FileImportCoordinator.Step.allCases, id: \.self) { step in
        let done = step.rawValue < coordinator.step.rawValue
        let current = step == coordinator.step
        Button {
          coordinator.jump(to: step)
        } label: {
          // The design's tab: a numbered ring that FILLS once the step is
          // behind you, and a 2pt underline on the one you are standing in.
          let tint: Color = current ? .stAccent : (done ? .stTextSecondary : .stTextTertiary)
          HStack(spacing: 8) {
            Group {
              if done {
                Image(systemName: "checkmark")
                  .font(.system(size: 10, weight: .bold))
                  .foregroundStyle(.white)
                  .frame(width: 19, height: 19)
                  .background(Circle().fill(Color.stAccentSolid))
              } else {
                Text("\(step.rawValue)")
                  .font(.system(size: 11, weight: .bold))
                  .foregroundStyle(tint)
                  .frame(width: 19, height: 19)
                  .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
              }
            }
            Text(step.title)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(tint)
          }
          .padding(.top, 10)
          .padding(.bottom, 9)
          .padding(.horizontal, 4)
          .frame(maxWidth: .infinity)
          .overlay(alignment: .bottom) {
            Rectangle().fill(current ? Color.stAccent : Color.clear).frame(height: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.canGo(to: step))
      }
    }
    .padding(.horizontal, 8)
    .background(Color.stPageBg)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// The prototype's `.tile`: a 36pt rounded square in accent-light with an
  /// accent border. Used wherever the design puts an icon beside a heading.
  private func iconTile(_ systemName: String, size: CGFloat = 36, radius: CGFloat = 10)
    -> some View
  {
    Image(systemName: systemName)
      .font(.system(size: size * 0.45, weight: .medium))
      .foregroundStyle(Color.stAccent)
      .frame(width: size, height: size)
      .background(RoundedRectangle(cornerRadius: radius).fill(Color.stAccentLight))
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(Color.stAccent.opacity(0.32)))
  }

  private func stepHeading(_ title: String) -> some View {
    HStack {
      Text(title).font(.system(size: 20, weight: .semibold))
      Spacer()
      Text("Step \(coordinator.step.rawValue) of 6").foregroundStyle(Color.stTextSecondary)
    }
  }

  /// The row every choosing step ends with: a plain sentence about the choice on
  /// the left, and the way forward on the right.
  private func actionRow(
    note: String, showBack: Bool = true, forwardTitle: String,
    forward: @escaping () -> Void
  ) -> some View {
    BrandedSection {
      HStack(spacing: 10) {
        Text(note).foregroundStyle(Color.stTextSecondary)
        Spacer(minLength: 12)
        if showBack, coordinator.canGoBack {
          SettingsActionButton(title: "Back", isEnabled: true, action: { coordinator.goBack() })
        }
        SettingsActionButton(
          title: forwardTitle, isEnabled: true, emphasis: .filled, action: forward)
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  // MARK: - 1. Upload

  @ViewBuilder
  private var uploadStep: some View {
    heroCard
    switch coordinator.state {
    case .ready, .finished, .stopped, .transcribing, .polishing:
      chosenFileCard
    case .reading(let name):
      BrandedSection {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Reading \(name)")
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
    case .rejected(let reason):
      InsetNotice(
        text: Self.sentence(for: reason), systemImage: "exclamationmark.triangle", tint: .orange)
      dropZone
    case .idle:
      dropZone
      featureTiles
    }
  }

  private var heroCard: some View {
    BrandedSection {
      HStack(alignment: .top, spacing: 14) {
        iconTile("doc.badge.plus")
        VStack(alignment: .leading, spacing: 4) {
          Text("Transcribe a File").font(.system(size: 16, weight: .semibold))
          Text(
            """
            Upload an audio or video file, then EnviousWispr will transcribe it and polish it \
            into clean, readable text.
            """
          )
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
  }

  /// The empty state. A dashed target rather than a bare button, because the
  /// design accepts a dropped file as well as a chosen one and the shape has to
  /// say so before the sentence does.
  private var dropZone: some View {
    VStack(spacing: 7) {
      iconTile("arrow.up", size: 50, radius: 13)
      SettingsActionButton(
        title: "Choose a file", isEnabled: true, emphasis: .filled, action: { chooseFile() })
      Text("or drag and drop here").foregroundStyle(Color.stTextSecondary)
      WrappingHStack(spacing: 6) {
        Text("Supported formats").foregroundStyle(Color.stTextTertiary)
        ForEach(Self.supportedFormats, id: \.self) { format in
          Text(format)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.stTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.stAccentLight.opacity(0.5)))
            .overlay(Capsule().strokeBorder(Color.stDivider))
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 30)
    .padding(.horizontal, 20)
    .background(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius).fill(Color.stSectionBg))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(Color.stDivider, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
    )
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in coordinator.choose(url: url) }
      }
      return true
    }
  }

  static let supportedFormats = ["m4a", "mp3", "wav", "aiff", "caf", "mp4", "mov", "flac"]

  /// The four things a person wants to know before handing over a recording.
  ///
  /// ONE panel divided by hairlines, the way the design draws it, rather than
  /// four separate boxes with gaps between them.
  private var featureTiles: some View {
    BrandedSection {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          featureTile("lock", "Your voice stays here", "Audio never leaves this Mac.")
          Divider()
          featureTile("bolt", "Two transcription engines", "Fast, or All Languages.")
        }
        Divider()
        HStack(spacing: 0) {
          featureTile("sparkles", "Six ways to polish", "On device, or your own cloud key.")
          Divider()
          featureTile("shield", "Original kept", "Never overwritten.")
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func featureTile(_ icon: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      iconTile(icon, size: 28, radius: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(detail).font(.system(size: 14)).foregroundStyle(Color.stTextTertiary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var chosenFileCard: some View {
    if let file = coordinator.file {
      BrandedSection {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 14) {
            SettingsRowIcon(systemName: "waveform")
            VStack(alignment: .leading, spacing: 4) {
              Text(file.name).font(.stRowTitle)
              Text(file.detailLine).foregroundStyle(Color.stTextSecondary)
            }
            Spacer(minLength: 12)
            SettingsActionButton(
              title: "Choose a different file", isEnabled: !coordinator.isRunning,
              action: { chooseFile() })
          }
          HStack(spacing: 24) {
            check("Audio found")
            check("Ready in \(coordinator.estimateText)")
          }
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
      actionRow(
        note: "Nothing has run yet. You can still change everything.", showBack: false,
        forwardTitle: "Continue", forward: { coordinator.advance() })
    }
  }

  private func check(_ text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      Text(text)
    }
  }

  // MARK: - 2. Transcription

  @ViewBuilder
  private var transcriptionStep: some View {
    stepHeading("Select transcription engine")
    HStack(alignment: .top, spacing: 14) {
      engineCard(
        backend: .parakeet, title: "Fast", icon: "bolt.fill", recommended: true,
        blurb: "Best for everyday English and European recordings.",
        specs: [
          ("Model", "Parakeet v3"),
          ("Languages", "25 European"),
          ("An hour of audio", "About 7 seconds"),
          ("Runs on", "This Mac · Neural Engine"),
        ])
      engineCard(
        backend: .whisperKit, title: "All Languages", icon: "globe", recommended: false,
        blurb: "Best for other languages or the toughest audio.",
        specs: [
          ("Model", "Whisper Large v3 Turbo"),
          ("Languages", "99+"),
          ("An hour of audio", "About 2 minutes"),
          ("Runs on", "This Mac · Apple GPU"),
        ])
    }
    actionRow(
      note: "Both engines run entirely on this Mac.", forwardTitle: "Continue",
      forward: { coordinator.advance() })
  }

  private func engineCard(
    backend: ASRBackendType, title: String, icon: String, recommended: Bool, blurb: String,
    specs: [(String, String)]
  ) -> some View {
    // **Writes the app's own setting.** `EngineCoordinator` watches it and does
    // the switch, including loading the model, so picking here is a real pick
    // rather than a highlighted card.
    let selected = settings.selectedBackend == backend
    return Button {
      settings.selectedBackend = backend
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: icon).foregroundStyle(Color.stAccent)
          Text(title).font(.stRowTitle)
          if recommended { badge("Recommended") }
          Spacer(minLength: 8)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.stAccent : Color.stTextSecondary)
        }
        Text(blurb)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(specs, id: \.0) { spec in
          Divider()
          HStack {
            Text(spec.0).foregroundStyle(Color.stTextSecondary)
            Spacer()
            Text(spec.1).font(.stRowLabel)
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius).fill(Color.stSectionBg))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(selected ? Color.stAccent : Color.stDivider)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func badge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, 9)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.stAccentSolid))
      .foregroundStyle(.white)
  }

  // MARK: - 3. Polish

  @ViewBuilder
  private var polishStep: some View {
    stepHeading("Select polishing engine")
    // Six across, matching the design at the window's ordinary width. The
    // prototype drops to three below 1000px and two below 640; the app's own
    // minimum window is 750, so three is the narrow fallback.
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 6), spacing: 9
    ) {
      ForEach(Self.polishChoices, id: \.provider) { choice in
        polishCard(choice)
      }
    }
    polishDetailCard
    actionRow(
      note: "Numbers, dates, your saved words and filler removal run either way.",
      forwardTitle: "Continue", forward: { coordinator.advance() })
  }

  struct PolishChoice {
    let provider: LLMProvider
    let icon: String
    let availability: String
    let detail: String

    /// Read from the provider, never restated here. `LLMProviderDisplayNameFreezeTests`
    /// enforces it, and it is right to: a licence-bound spelling or a rename has
    /// to change in one place, not in every screen that happens to list them.
    var title: String { provider.displayName }
  }

  /// The six, in the order the design shows them. Each carries the one line that
  /// decides whether a person can use it at all, because "Needs a key" is the
  /// answer to the question they are actually asking.
  static let polishChoices: [PolishChoice] = [
    PolishChoice(
      provider: .egOne, icon: "star", availability: "On device",
      detail:
        """
        Our best model for cleanup and list-making. On an imported recording it removes about \
        four times more filler than Apple Intelligence.
        """),
    PolishChoice(
      provider: .appleIntelligence, icon: "apple.logo",
      availability: "On device",
      detail: "Apple's on-device model. Needs macOS 26 or later."),
    PolishChoice(
      provider: .ollama, icon: "cube", availability: "Needs the app",
      // Deliberately says nothing about where the text goes. Ollama proxies
      // some models to its own servers, so the answer depends on the MODEL, and
      // this card cannot see one. `ollamaPrivacyLine` says it right below.
      detail: "Any model you run in Ollama."),
    PolishChoice(
      provider: .openAI, icon: "circle.hexagongrid", availability: "Needs a key",
      detail: "Your own OpenAI key. Only the text is sent, never the audio."),
    PolishChoice(
      provider: .gemini, icon: "sparkle", availability: "Needs a key",
      detail: "Your own Google key. Only the text is sent, never the audio."),
    PolishChoice(
      provider: .claude, icon: "star.circle", availability: "Needs a key",
      detail: "Your own Anthropic key. Only the text is sent, never the audio."),
  ]

  /// Where an Ollama polish actually sends the text, for the model selected now.
  /// The unknown case says so rather than guessing either way.
  private var ollamaPrivacyLine: String {
    switch coordinator.polishOllamaLocalityNow() {
    case true: return "The model you picked runs on Ollama's servers, so the text is sent there."
    case false: return "That model runs on this Mac, so nothing leaves it."
    case nil:
      return "Checking whether that model runs here or on Ollama's servers. Start Ollama to find out."
    }
  }

  private func polishCard(_ choice: PolishChoice) -> some View {
    // Same door the AI Polish page uses. `SettingsManager` canonicalizes the
    // model id for the new provider and `PipelineSettingsSync` starts or stops
    // the runtime; writing a private copy did neither.
    let selected = settings.llmProvider == choice.provider
    return Button {
      settings.llmProvider = choice.provider
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: choice.icon).foregroundStyle(Color.stAccent)
          Spacer(minLength: 4)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.stAccent : Color.stTextSecondary)
        }
        Text(choice.title).font(.stRowLabel).fixedSize(horizontal: false, vertical: true)
        if choice.provider == .egOne { badge("Recommended") }
        Text(choice.availability).foregroundStyle(Color.stTextSecondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius).fill(Color.stSectionBg))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(selected ? Color.stAccent : Color.stDivider)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var polishDetailCard: some View {
    if let choice = selectedPolish {
      BrandedSection {
        HStack(alignment: .top, spacing: 14) {
          SettingsRowIcon(systemName: choice.icon)
          VStack(alignment: .leading, spacing: 4) {
            Text(choice.title).font(.stRowTitle)
            Text(choice.detail)
              .foregroundStyle(Color.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
            // **The sentence sits where the user approves the choice**, not only
            // in the footer. This card promised "Nothing leaves this Mac" for
            // every Ollama model, immediately above the button that sends the
            // transcript to one Ollama proxies to its own servers. Found by
            // Codex.
            if choice.provider == .ollama {
              Text(ollamaPrivacyLine)
                .foregroundStyle(Color.stTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
    }
  }

  /// Where a provider runs, for the ones the tile grid does not render. Derived
  /// from the provider so a new one cannot be silently blank here.
  static func availability(_ provider: LLMProvider) -> String {
    switch provider {
    case .egOne, .s1Mini, .appleIntelligence: return "On device"
    case .ollama: return "Needs the app"
    case .openAI, .gemini, .claude: return "Needs a key"
    case .none: return ""
    }
  }

  private var selectedPolish: PolishChoice? {
    Self.polishChoices.first { $0.provider == settings.llmProvider }
  }

  // MARK: - 4. Review

  @ViewBuilder
  private var reviewStep: some View {
    stepHeading("Review and start")
    if case .rejected(let reason) = coordinator.state {
      InsetNotice(
        text: Self.sentence(for: reason), systemImage: "exclamationmark.triangle", tint: .orange)
    }
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
        BrandedSection(header: "SELECTED FILE") {
          VStack(alignment: .leading, spacing: 12) {
            if let file = coordinator.file {
              HStack(alignment: .top, spacing: 14) {
                SettingsRowIcon(systemName: "waveform")
                VStack(alignment: .leading, spacing: 4) {
                  Text(file.name).font(.stRowTitle)
                  Text(file.detailLine).foregroundStyle(Color.stTextSecondary)
                }
                Spacer(minLength: 0)
              }
              check("Audio found")
              check("Ready in \(coordinator.estimateText)")
            }
          }
          .padding(.horizontal, SettingsLayout.rowPaddingH)
          .padding(.vertical, SettingsLayout.rowPaddingV)
        }
        // The founder's lock decision, said BEFORE the user commits rather than
        // discovered when their keybind stops working.
        InsetNotice(
          text:
            """
            Dictation pauses while this runs. Your keybind will not record until the transcript \
            is finished, \(coordinator.estimateText).
            """,
          systemImage: "mic.slash", tint: .orange)
        // The words change with what the action IS. After a refusal the file is
        // still read and still in memory, so this is a retry, not a fresh start.
        actionRow(
          note: coordinator.canRetry
            ? "Your file is still here. Nothing needs reading again."
            : (coordinator.rawTranscript.isEmpty
              ? "Nothing has run yet."
              : "Already transcribed. Only the cleanup runs again."),
          forwardTitle: coordinator.canRetry
            ? "Try again"
            : (coordinator.rawTranscript.isEmpty
              ? "Start transcription" : "Clean it again"),
          forward: { coordinator.canRetry ? coordinator.retry() : coordinator.advance() })
      }
      processingPath.frame(width: 300)
    }
  }

  /// The two engines this run will use, stacked in the order they run with an
  /// arrow between them. It answers "what is about to happen to my recording" in
  /// one glance.
  private var processingPath: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("YOUR PROCESSING PATH")
        .font(.stSectionHeader).tracking(0.6).foregroundStyle(Color.stAccent)
      pathCard(
        icon: settings.selectedBackend == .parakeet ? "bolt.fill" : "globe",
        title: settings.selectedBackend == .parakeet ? "Fast" : "All Languages",
        recommended: settings.selectedBackend == .parakeet,
        blurb: "Writes down what was said.",
        rows: [
          (
            "Runs on",
            settings.selectedBackend == .parakeet
              ? "This Mac · Neural Engine" : "This Mac · Apple GPU"
          )
        ])
      Image(systemName: "arrow.down")
        .foregroundStyle(Color.stTextSecondary)
        .frame(maxWidth: .infinity)
      // **Named from the PROVIDER, not from the tile list.** `polishChoices`
      // renders six tiles and S1-mini is not one of them, so a user who had
      // selected it in AI Polish was told "No polish" on the one screen that
      // exists to confirm what is about to happen — while the freeze kept
      // S1-mini and the runner ran it. A hand-written list of what to DISPLAY
      // cannot answer a question about what will RUN. Found by Codex.
      pathCard(
        icon: selectedPolish?.icon ?? "sparkles",
        title: settings.llmProvider.displayName,
        recommended: settings.llmProvider == .egOne,
        blurb: "Cleans it into readable text.",
        rows: [("Runs on", selectedPolish?.availability ?? Self.availability(settings.llmProvider))])
    }
  }

  private func pathCard(
    icon: String, title: String, recommended: Bool, blurb: String, rows: [(String, String)]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: icon).foregroundStyle(Color.stAccent)
        Text(title).font(.stRowLabel)
        if recommended { badge("Recommended") }
        Spacer(minLength: 0)
      }
      Text(blurb).foregroundStyle(Color.stTextSecondary)
      ForEach(rows, id: \.0) { row in
        Divider()
        Text(row.0).foregroundStyle(Color.stTextSecondary)
        Text(row.1).font(.stRowLabel)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius).fill(Color.stSectionBg))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius).strokeBorder(Color.stDivider))
  }

  // MARK: - 5. Working

  @ViewBuilder
  private var workingStep: some View {
    stepHeading("Working on your transcript")
    BrandedSection {
      HStack(spacing: 14) {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.stAccentLight.opacity(0.6))
            Capsule()
              .fill(
                LinearGradient(
                  colors: [Color.stAccent, Color.stAccentSolid],
                  startPoint: .leading, endPoint: .trailing)
              )
              .frame(width: max(6, geo.size.width * coordinator.progress))
          }
        }
        .frame(width: 170, height: 9)
        Text("\(Int(coordinator.progress * 100))%")
          .font(.system(size: 14, weight: .semibold, design: .monospaced))
          .monospacedDigit()
          .frame(minWidth: 38, alignment: .leading)
        HStack(spacing: 8) {
          Image(systemName: "list.bullet").foregroundStyle(Color.stTextSecondary)
          Text(coordinator.phase)
        }
        Spacer(minLength: 12)
        Text("\(coordinator.wordCount) words").foregroundStyle(Color.stTextSecondary)
        SettingsActionButton(title: "Stop", isEnabled: true, action: { coordinator.stop() })
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
    liveTranscript
  }

  /// The words themselves while the run goes: cleaned parts as they land, and
  /// the raw transcript until the first one does, so the page is never empty and
  /// never just a spinner.
  private var liveTranscript: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(coordinator.isShowingOriginal ? [] : coordinator.parts) { part in
        VStack(alignment: .leading, spacing: 4) {
          Text(part.text)
            .lineSpacing(6)
            .foregroundStyle(Color.stTextBody)
            .textSelection(.enabled)
          // Only a FAILED polish is marked. A document the user chose not to
          // have polished is not a document with fourteen problems in it.
          if part.isUnpolished {
            Text("This passage could not be cleaned up. These are the raw words.")
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
          }
        }
      }
      if coordinator.isShowingOriginal || coordinator.parts.isEmpty,
        !coordinator.rawTranscript.isEmpty
      {
        Text(coordinator.rawTranscript)
          .lineSpacing(6)
          .foregroundStyle(Color.stTextSecondary)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius).fill(Color.stSectionBg))
  }

  // MARK: - 6. Done

  @ViewBuilder
  private var doneStep: some View {
    stepHeading(coordinator.state == .stopped ? "Stopped" : "Your transcript is ready")
    // A refusal raised while a document exists lands HERE rather than on Upload,
    // because Upload's only offer is choosing another file, which clears it. The
    // sentence sits above the words it did not touch.
    if case .rejected(let reason) = coordinator.state {
      InsetNotice(
        text: Self.sentence(for: reason), systemImage: "exclamationmark.triangle", tint: .orange)
    }
    BrandedSection {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Text(coordinator.file?.name ?? "Transcript").font(.stRowTitle)
          Spacer(minLength: 12)
          chip("\(coordinator.wordCount) words")
          if let file = coordinator.file {
            chip(FileImportCoordinator.durationText(file.seconds))
          }
        }
        HStack(spacing: 8) {
          // **The provider this document was RUN with**, from the frozen
          // configuration, and named by `LLMProvider.displayName` so the six
          // names have one owner. Reading the live selection credited whatever
          // was picked after the run — pick Claude on Change, return to Done,
          // and unchanged EG-1 output was labelled Claude's. It says
          // "cleanup engine" rather than "polished by" because a passage whose
          // polish failed carries its own note and this line must not overrule
          // it. Found by Codex.
          chip(
            "Cleanup engine: \((coordinator.runConfiguration?.polishProvider ?? .none).displayName)"
          )
          Button("Change") { coordinator.choosePolisherAgain() }
            .buttonStyle(.plain)
            .foregroundStyle(Color.stAccent)
          Spacer(minLength: 12)
          // The page promises the untouched words are kept. This is where the
          // user reads them, and Copy and Save follow whichever is on screen.
          if !coordinator.parts.isEmpty {
            Button(coordinator.isShowingOriginal ? "Show cleaned words" : "Show original words") {
              coordinator.isShowingOriginal.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.stAccent)
          }
        }
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
    liveTranscript
    BrandedSection {
      HStack(spacing: 10) {
        // **Offered only when there is something to hand over.** Stopping before
        // the first words arrive lands on this step with an empty document, and
        // Copy would then CLEAR the user's clipboard while Save wrote an empty
        // file — both of which destroy something the user had, to give them
        // nothing. Found enumerating (step, state) rather than by review.
        SettingsActionButton(
          title: "Copy everything", isEnabled: coordinator.hasDocument, emphasis: .filled,
          systemImage: "doc.on.doc", action: { copyDocument() })
        SettingsActionButton(
          title: "Save as...", isEnabled: coordinator.hasDocument,
          systemImage: "square.and.arrow.down",
          action: { saveDocument() })
        Spacer(minLength: 12)
        SettingsActionButton(
          title: "New transcription", isEnabled: true, systemImage: "arrow.up",
          action: { coordinator.startOver() })
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
    // Sits directly under the buttons that produce it, and stays there, because
    // New transcription is one click away and it clears the document.
    if let message = coordinator.saveMessage {
      Text(message).foregroundStyle(Color.stTextSecondary)
    }
  }

  private func chip(_ text: String) -> some View {
    Text(text)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.stDivider.opacity(0.35)))
  }

  // MARK: - The footer, which changes with the step

  private var privacyFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: "shield").foregroundStyle(.green)
      Text(Self.footerLead(step: coordinator.step))
        .font(.stRowLabel).foregroundStyle(.green)
      Text(Self.footerDetail(step: coordinator.step, isCloudPolish: isCloudPolish))
        .foregroundStyle(Color.stTextSecondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .frame(minHeight: 52)
    .background(Color.stSidebarBg)
    .overlay(alignment: .top) { Divider() }
  }

  static func footerLead(step: FileImportCoordinator.Step) -> String {
    step == .working ? "Safe to leave this page." : "Secure. Private. Local."
  }

  /// **Computed, never fixed, and after a run it describes THAT run.**
  /// "Your audio and text both stay on this Mac" is false the moment a cloud
  /// polisher is chosen, which the founder caught in the prototype; and reading
  /// the LIVE provider after a run would retrospectively re-describe a finished
  /// document, which cloud review caught in the first build.
  static func footerDetail(step: FileImportCoordinator.Step, isCloudPolish: Bool) -> String {
    switch step {
    case .working:
      // The cloud branch belongs HERE most of all: this is the step during
      // which the text is actually being sent. A line claiming both stay on the
      // Mac would be false at the exact moment it is on screen.
      return isCloudPolish
        ? "Your audio never leaves this Mac. The text is going to the provider you chose."
        : "Your audio and text both stay on this Mac."
    case .done:
      return isCloudPolish
        ? "Your audio stayed on this Mac. Only the text went to the provider you chose."
        : "Your untouched words are kept beside this one."
    case .upload, .transcription, .polish, .review:
      return isCloudPolish
        ? "Your audio never leaves this Mac. Only the text goes to the provider you chose."
        : "Your audio and text both stay on this Mac."
    }
  }

  /// Whether the text this sentence is ABOUT leaves the Mac.
  ///
  /// **Which run it describes depends on the step.** On Working and Done it
  /// describes THIS document, so it must read the configuration frozen at Start
  /// — a later provider change must not retrospectively re-describe words
  /// already polished. On every earlier step it describes what is ABOUT to
  /// happen, so it must read live settings: after a local run, picking a cloud
  /// polisher on the Polish step left the frozen local configuration on screen
  /// saying the text stays here. Found by Codex.
  private var isCloudPolish: Bool {
    switch coordinator.step {
    case .working, .done:
      if let frozen = coordinator.runConfiguration { return frozen.polishIsCloud }
    case .upload, .transcription, .polish, .review:
      break
    }
    return Self.isCloud(
      settings.llmProvider, ollamaModelIsRemote: coordinator.polishOllamaLocalityNow())
  }

  /// Enumerated, never `default:`. A new provider must be classified here
  /// deliberately, because getting it wrong publishes a false privacy claim.
  /// Whether the chosen polisher sends the transcript off this Mac.
  ///
  /// **Ollama is the case the provider name cannot answer.** The daemon proxies
  /// some models to its own servers, which it reports as a non-empty
  /// `remote_host` and `OllamaModelFacts.isRemote` decodes; a user polishing
  /// with one of those is sending their transcript to Ollama's infrastructure
  /// while a provider-only classification tells them it stayed here. The
  /// remoteness is resolved by the same lookup `PipelineSettingsSync` uses and
  /// FROZEN with the run, so a document already polished is never re-described.
  /// Found by Codex.
  /// - Parameter ollamaModelIsRemote: `nil` when the daemon has not been asked.
  ///   **Unknown counts as leaving the Mac**, because the two mistakes are not
  ///   equal: promising local processing for a model Ollama proxies to its own
  ///   servers is a broken privacy promise, while saying the text may be sent
  ///   when it is not is merely cautious. The eviction rule uses the SAME lookup
  ///   with the opposite default on purpose — there an unknown model is evicted,
  ///   because the cost of a needless unload is one local request and the cost
  ///   of skipping a real local model is weights left in memory.
  static func isCloud(_ provider: LLMProvider, ollamaModelIsRemote: Bool?) -> Bool {
    switch provider {
    case .openAI, .gemini, .claude: return true
    case .ollama: return ollamaModelIsRemote ?? true
    case .egOne, .s1Mini, .appleIntelligence, .none: return false
    }
  }

  /// One honest sentence per refusal. No mechanism, no error codes.
  static func sentence(for reason: FileImportCoordinator.FileImportRejection) -> String {
    switch reason {
    case .cannotRead: return "That file couldn't be opened. Try a different one."
    case .noAudio: return "There's no sound in that file."
    case .noSpeechFound: return "No speech was found in that file."
    case .engineBusy(.dictation): return "A dictation is running. Try again when it finishes."
    case .engineBusy(.crashRecovery): return "Finishing an earlier take. Try again in a moment."
    case .engineNotInstalled:
      return "That transcription engine isn't downloaded yet. Get it in Transcription settings."
    case .engineNotReady: return "The transcription engine didn't start. Try again."
    case .engineBusy(.fileImport): return "Another file is being transcribed right now."
    case .failed: return "Something went wrong reading that file. Try a different one."
    }
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
    NSPasteboard.general.setString(coordinator.exportText, forType: .string)
  }

  private func saveDocument() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue =
      (coordinator.file?.name as NSString?)?.deletingPathExtension ?? "Transcript"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try coordinator.exportText.write(to: url, atomically: true, encoding: .utf8)
      coordinator.noteSaveSucceeded(fileName: url.lastPathComponent)
    } catch {
      coordinator.noteSaveFailed(error)
    }
  }
}
