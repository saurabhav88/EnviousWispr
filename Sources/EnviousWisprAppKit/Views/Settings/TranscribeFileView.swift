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
    .onAppear { seedChoicesFromSettings() }
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
        .disabled(!done || coordinator.isRunning)
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
        if showBack {
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
    let selected = coordinator.chosenBackend == backend
    return Button {
      coordinator.chosenBackend = backend
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
      detail: "Any model you run locally in Ollama. Nothing leaves this Mac."),
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

  private func polishCard(_ choice: PolishChoice) -> some View {
    let selected = coordinator.chosenPolish == choice.provider
    return Button {
      coordinator.chosenPolish = choice.provider
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
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
    }
  }

  private var selectedPolish: PolishChoice? {
    Self.polishChoices.first { $0.provider == coordinator.chosenPolish }
  }

  // MARK: - 4. Review

  @ViewBuilder
  private var reviewStep: some View {
    stepHeading("Review and start")
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
        actionRow(
          note: "Nothing has run yet.", forwardTitle: "Start transcription",
          forward: { coordinator.advance() })
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
        icon: coordinator.chosenBackend == .parakeet ? "bolt.fill" : "globe",
        title: coordinator.chosenBackend == .parakeet ? "Fast" : "All Languages",
        recommended: coordinator.chosenBackend == .parakeet,
        blurb: "Writes down what was said.",
        rows: [
          (
            "Runs on",
            coordinator.chosenBackend == .parakeet
              ? "This Mac · Neural Engine" : "This Mac · Apple GPU"
          )
        ])
      Image(systemName: "arrow.down")
        .foregroundStyle(Color.stTextSecondary)
        .frame(maxWidth: .infinity)
      pathCard(
        icon: selectedPolish?.icon ?? "sparkles",
        title: selectedPolish?.title ?? "No polish",
        recommended: coordinator.chosenPolish == .egOne,
        blurb: "Cleans it into readable text.",
        rows: [("Runs on", selectedPolish?.availability ?? "")])
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
      ForEach(coordinator.parts) { part in
        VStack(alignment: .leading, spacing: 4) {
          Text(part.text)
            .lineSpacing(6)
            .foregroundStyle(Color.stTextBody)
            .textSelection(.enabled)
          if part.isUnpolished {
            Text("This passage could not be cleaned up. These are the raw words.")
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
          }
        }
      }
      if coordinator.parts.isEmpty, !coordinator.rawTranscript.isEmpty {
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
          chip("Polished by \(selectedPolish?.title ?? "nothing")")
          Button("Change") { coordinator.rePolish() }
            .buttonStyle(.plain)
            .foregroundStyle(Color.stAccent)
        }
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
    liveTranscript
    BrandedSection {
      HStack(spacing: 10) {
        SettingsActionButton(
          title: "Copy everything", isEnabled: true, emphasis: .filled,
          systemImage: "doc.on.doc", action: { copyDocument() })
        SettingsActionButton(
          title: "Save as...", isEnabled: true, systemImage: "square.and.arrow.down",
          action: { saveDocument() })
        Spacer(minLength: 12)
        SettingsActionButton(
          title: "New transcription", isEnabled: true, systemImage: "arrow.up",
          action: { coordinator.startOver() })
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
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

  private var isCloudPolish: Bool {
    if let frozen = coordinator.runConfiguration { return frozen.polishIsCloud }
    return Self.isCloud(coordinator.chosenPolish)
  }

  /// Enumerated, never `default:`. A new provider must be classified here
  /// deliberately, because getting it wrong publishes a false privacy claim.
  static func isCloud(_ provider: LLMProvider) -> Bool {
    switch provider {
    case .openAI, .gemini, .claude: return true
    case .egOne, .s1Mini, .appleIntelligence, .ollama, .none: return false
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
    case .engineBusy(.fileImport): return "Another file is being transcribed right now."
    case .failed: return "Something went wrong reading that file. Try a different one."
    }
  }

  // MARK: - Actions

  /// The import's engines start from what the user already uses, so the common
  /// path is two Continues. Changing them here does NOT write back to settings:
  /// a choice made for one file is not a change to how dictation works.
  private func seedChoicesFromSettings() {
    guard coordinator.state == .idle else { return }
    coordinator.chosenBackend = settings.selectedBackend
    coordinator.chosenPolish = settings.llmProvider
  }

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

  private func saveDocument() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue =
      (coordinator.file?.name as NSString?)?.deletingPathExtension ?? "Transcript"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? coordinator.documentText.write(to: url, atomically: true, encoding: .utf8)
  }
}
