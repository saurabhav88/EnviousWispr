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
/// **The text is the interface.** On Working the cleaned paragraphs fill the page as they
/// land, above the QUEUE of raw pieces still waiting, and on Done the document does.
///
/// This used to say the splitting is never named. That rule shipped, and the founder
/// rejected it against the prototype: "the clean up was supposed to show # of chunks and it
/// processing each chunk, not pasting the finished polished work in real-time." The label
/// now reads "Cleaning part 9 of 14 with EG-1" (#2772 finding 14).
///
/// **The footer changes with the step**, because what is true changes: before a
/// run it is where the audio stays, during a run it is that leaving is safe,
/// after a run it is about the words that were kept.
struct TranscribeFileView: View {
  @Environment(FileImportCoordinator.self) private var coordinator
  @Environment(SettingsManager.self) private var settings

  // #2772 chunk 3: the same coordinators the AI Polish page reads. The Polish step now
  // hosts the shared setup editor, and the Continue gate below asks these directly rather
  // than trusting the editor to report readiness back up.
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(EGOneRuntime.self) private var egOne
  @Environment(LocalPolishRuntimeSet.self) private var localPolishRuntimes

  /// The shared setup editor's own state (key drafts, saved-key reads, a pending download).
  /// Owned here so both `Part`s and the lifecycle modifier read one copy, exactly as
  /// `AIPolishSettingsView` owns its own.
  @State private var setupModel = ProviderSetupModel()

  var body: some View {
    VStack(spacing: 0) {
      stepBar
      ScrollView {
        // #2772 finding 3: the green bar sits DIRECTLY under the content, on every step.
        // It used to be pinned to the window's bottom edge, which on a short step left a
        // void the height of half the window between the last card and the sentence about
        // where the audio goes. Founder: "the footer touches the tiles ... Applies to ALL
        // SIX steps."
        //
        // TWO rules, because the two kinds of step behave differently, and Codex's read is
        // that this justifies them rather than excusing them. On the four SETUP steps the
        // content is short and a pinned bar leaves the void the founder reported, so the bar
        // follows the content. On Working and Done the content is a transcript of any
        // length, and there the bar carries "Safe to leave this page" — the one reassurance
        // that step exists to give — so it stays pinned and visible, which is also what the
        // prototype does.
        VStack(spacing: 0) {
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
          .frame(maxWidth: .infinity)
          .background(Color.stPageBg)
          if !pinsPrivacyFooter {
            privacyFooter
          }
        }
      }
      // Whatever is left below the bar carries the bar's OWN tone, so a short step reads as
      // a page that has ended rather than as a bar floating in the middle of one. Without
      // it, moving the bar up to touch the content just moved the void from above it to
      // below it, which looks less deliberate, not more.
      .background(Color.stSidebarBg)
      if pinsPrivacyFooter {
        privacyFooter
      }
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
    // #2772 chunk 3: arms the coordinators for the IMPORT's chosen engine — reads the saved
    // keys, validates a cloud key, detects Ollama, probes a bundled engine. Keyed to
    // `.fileImport`, so choosing OpenAI here validates OpenAI even when dictation is on
    // EG-1. Attached to the whole page rather than the Polish step, because the editor's
    // state must survive stepping forward to Review and back.
    .modifier(ProviderSetupLifecycle(model: setupModel, surface: .fileImport))
  }

  /// Whether the privacy bar is pinned to the window's bottom edge rather than following
  /// the content. Exhaustive over the step, so a seventh has to be decided rather than
  /// inheriting whichever branch it falls into.
  private var pinsPrivacyFooter: Bool {
    switch coordinator.step {
    case .working, .done: return true
    case .upload, .transcription, .polish, .review: return false
    }
  }

  // MARK: - The step bar

  /// Completed steps carry a check and stay clickable; the current one is
  /// underlined; the rest are numbered and dim. Going back is offered only while
  /// nothing has run — after that the choices are frozen for the run, and a
  /// live-looking control would be a lie.
  ///
  /// Two renderings, and `ViewThatFits` picks the widest that fits. At the 750-point minimum
  /// window six titled chips do not fit and SwiftUI broke the words mid-letter ("Uploa d",
  /// "Worki ng"; photographed in `docs/feature-requests/2772-uat-evidence/`). The compact
  /// row keeps every ring and only the CURRENT step's title; the rest keep their titles for
  /// accessibility. Titles are `fixedSize` so the first candidate reports its true width
  /// rather than "fitting" by wrapping, which is how the break got there.
  private var stepBar: some View {
    ViewThatFits(in: .horizontal) {
      stepBarRow(compact: false)
      stepBarRow(compact: true)
    }
  }

  private func stepBarRow(compact: Bool) -> some View {
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
            if !compact || current {
              Text(step.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
            }
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
        .accessibilityLabel(step.title)
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
  /// The prototype's button pair, in one place so "buttons need to look like this
  /// everywhere" is a property of the type rather than a habit at eight call sites.
  ///
  /// Secondary is `quiet`: a hairline divider-tone border, no fill, ordinary label. The
  /// shipped pair used `outlined`, which is the purple-bordered pill the founder rejected
  /// by name. Primary is filled and carries the prototype's trailing arrow. Both are 9pt
  /// rounded rectangles at the same height, never capsules (#2772 findings 5, 9, 14).
  private func wizardSecondary(
    _ title: String, isEnabled: Bool = true, systemImage: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    SettingsActionButton(
      title: title, isEnabled: isEnabled, emphasis: .quiet, shape: .roundedRect,
      size: .medium, systemImage: systemImage, action: action)
  }

  /// `showsArrow` is opt-OUT, because the prototype's primaries carry the arrow wherever
  /// they move the user forward: "Continue ->", "Start transcription ->". The one that does
  /// not is "Choose a file", which opens a chooser rather than advancing a step, and it
  /// carries none in the prototype either.
  /// `action` is OPTIONAL: `nil` draws the treatment without being a control, which the drop
  /// zone needs because the whole box is already the button (#2772 finding 1).
  private func wizardPrimary(
    _ title: String, isEnabled: Bool = true, size: SettingsActionButton.Size = .medium,
    systemImage: String? = nil, showsArrow: Bool = true, action: (() -> Void)? = nil
  ) -> some View {
    SettingsActionButton(
      title: title, isEnabled: isEnabled, emphasis: .filled, shape: .roundedRect,
      size: size, trailingSystemImage: showsArrow ? "arrow.right" : nil,
      systemImage: systemImage, action: action)
  }

  /// `forwardEnabled` exists for #2772 finding 7a: with a cloud engine selected and no key
  /// saved, this row used to offer an enabled Continue, and the run then skipped polish in
  /// silence. Back stays enabled whatever the gate says, so a blocked user is never trapped
  /// on the step.
  private func actionRow(
    note: String, showBack: Bool = true, forwardTitle: String, forwardEnabled: Bool = true,
    forward: @escaping () -> Void
  ) -> some View {
    BrandedSection {
      HStack(spacing: 10) {
        Text(note).foregroundStyle(Color.stTextSecondary)
        Spacer(minLength: 12)
        if showBack, coordinator.canGoBack {
          wizardSecondary("Back") { coordinator.goBack() }
        }
        wizardPrimary(forwardTitle, isEnabled: forwardEnabled, action: forward)
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
  ///
  /// **The WHOLE box is the control** (#2772 finding 1). The prototype's drop zone is a
  /// `<button>`, and the founder's note is that only our inner button answered a click:
  /// aiming at a 400pt dashed rectangle and hitting nothing teaches people the target is
  /// decoration. The inner "Choose a file" stays because it is what the design draws and
  /// what says the box is pressable at all; it is `allowsHitTesting(false)` so the two
  /// cannot both fire, and the outer button carries the label VoiceOver reads.
  private var dropZone: some View {
    Button(action: { chooseFile() }) {
      dropZoneContent
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Choose a file")
    .accessibilityHint("Opens the file chooser. You can also drag a file here.")
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in coordinator.choose(url: url) }
      }
      return true
    }
  }

  private var dropZoneContent: some View {
    VStack(spacing: 7) {
      iconTile("arrow.up", size: 50, radius: 13)
      // `.large` is the prototype's `.btn.big`. Founder finding 2: the shipped one was
      // "noticeably" smaller than the mock's.
      //
      // NO ACTION, deliberately. This draws the button; the box around it IS the button.
      // A real `Button` here was a second actionable control in one target: hit-testing is
      // off for the pointer and says nothing about keyboard focus or VoiceOver activation,
      // so anyone not using a mouse met both. Found by Codex.
      wizardPrimary("Choose a file", size: .large, showsArrow: false)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    // Without this the click-through region is only the drawn glyphs and text, so the gaps
    // between them would still swallow a press on a box that now claims to be a button.
    .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
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

  /// The chosen file: ONE card, THREE rows, a full-width hairline between each pair.
  ///
  /// **This is the headline visual defect the founder named**, in his words: "you see how
  /// there are lines dividing everything vs you just smushed it all into 1 box". The shipped
  /// version smushed the file row and the checks together with no divider, and then exiled
  /// the action row into a SECOND detached card floating below. The prototype's `.selected`
  /// card is `.selhead` / `.selchecks` / `.selact`, each separated by a 1pt divider, all
  /// inside one border (#2772 findings 5, 5a, 5b).
  @ViewBuilder
  private var chosenFileCard: some View {
    if let file = coordinator.file {
      BrandedSection {
        VStack(alignment: .leading, spacing: 0) {
          fileHeadRow(file)
          Divider()
          fileChecksRow
          Divider()
          fileActionRow
        }
      }
    }
  }

  private func fileHeadRow(_ file: FileImportCoordinator.ChosenFile) -> some View {
    HStack(spacing: 12) {
      // The prototype's `.artwork`: a tinted rounded tile, not a bare glyph. The same tile
      // the hero card and the drop zone already draw, so there is one of them.
      iconTile("waveform", size: 40, radius: 10)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.name).font(.system(size: 16, weight: .semibold))
          .lineLimit(1).truncationMode(.middle)
        Text(file.detailLine).foregroundStyle(Color.stTextTertiary)
      }
      Spacer(minLength: 12)
      wizardSecondary("Choose a different file", isEnabled: !coordinator.isRunning) {
        chooseFile()
      }
      // #2772 finding 4: the prototype's `.ellip`, a bordered square to the RIGHT of
      // "Choose a different file". The shipped card had no way to put the page back to an
      // empty drop zone at all — the only exit was choosing a different file, which is a
      // different intention.
      clearFileButton
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  /// The X. `startOver()` rather than a bare clear, because the document and the decoded
  /// audio have to go with the file; that is the method the coordinator already exposes for
  /// exactly this, and it is what returns the page to an empty Upload step.
  private var clearFileButton: some View {
    Button(action: { coordinator.startOver() }) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.stTextSecondary)
        .frame(width: 30, height: 30)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.stDivider))
    .disabled(coordinator.isRunning)
    .help("Remove this file")
    .accessibilityLabel("Remove this file")
  }

  /// The two checks, SPREAD across the row rather than crammed together on the left, which
  /// is the prototype's `.selchecks` grid (#2772 finding 5). Equal-width columns, so the
  /// second one starts at the halfway mark whatever the first one says.
  private var fileChecksRow: some View {
    HStack(spacing: 20) {
      check("Audio found").frame(maxWidth: .infinity, alignment: .leading)
      check("Ready in \(coordinator.estimateText)").frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var fileActionRow: some View {
    HStack(spacing: 10) {
      Text("Nothing has run yet. You can still change everything.")
        .foregroundStyle(Color.stTextTertiary)
      Spacer(minLength: 12)
      wizardPrimary("Continue") { coordinator.advance() }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
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
    // #2772 §3.2. There is ONE transcription engine slot and `EngineCoordinator` owns
    // exactly one live target, so this choice is shared with dictation rather than
    // per-import — unlike the polisher on the next step, which is not. Shipped #2648
    // changed the dictation engine from here with no indication at all; saying so is the
    // fix, not hiding it. Always visible, above the cards, because it has to be readable
    // BEFORE the click it describes.
    Text("This choice also changes the transcription engine used for dictation.")
      .font(.stHelper)
      .foregroundStyle(Color.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
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
        // The design's header is one row: icon, title, badge, check. At two columns in the
        // minimum window that row is wider than the card, and with the badge held whole the
        // title was the flexible thing left, so "Fast" rendered as four stacked letters
        // (photographed in `docs/feature-requests/2772-uat-evidence/`). `ViewThatFits`
        // keeps the design's row wherever it fits and drops the badge under the title
        // where it does not, which is where the polish card already puts it.
        let check = Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.stAccent : Color.stTextSecondary)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.stAccent)
            Text(title).font(.stRowTitle).lineLimit(1).fixedSize()
            if recommended { Self.wizardBadge("Recommended") }
            Spacer(minLength: 8)
            check
          }
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: icon).foregroundStyle(Color.stAccent)
              Text(title).font(.stRowTitle).lineLimit(1).fixedSize()
              Spacer(minLength: 8)
              check
            }
            if recommended { Self.wizardBadge("Recommended") }
          }
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

  /// Static and internal so `TranscribeFilePolishGridTests` can measure the one badge that
  /// sets the polish card's minimum width.
  ///
  /// Named so that no unqualified call can resolve to SwiftUI's own `View.badge(_:)`. When
  /// this helper was `badge(_:)` and became static, one call site inside an instance method
  /// stayed unqualified, and the compiler quietly chose `self.badge("Recommended")`: the
  /// whole wizard, placed inside its own processing-path card, inside the wizard, without
  /// end. On macOS 27.0 that was a main-thread stack overflow the moment Review opened
  /// (#2798; 42,933 frames of SwiftUI stack sizing). `wizardBadge` has no SwiftUI twin, so
  /// an unqualified call is a compile error rather than a recursion.
  static func wizardBadge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 13, weight: .semibold))
      // Never "Recomme…": a badge that cannot say its word is not a badge. At the minimum
      // window the transcription card's header squeezed it before anything else gave.
      .fixedSize()
      .padding(.horizontal, 9)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.stAccentSolid))
      .foregroundStyle(.white)
  }

  // MARK: - 3. Polish

  /// The grid's measured width. Zero before the first layout, which `polishColumns` reads
  /// as the design width so the first frame is six across rather than a flash of two.
  @State private var polishGridWidth: CGFloat = 0

  static let polishGridSpacing: CGFloat = 9

  /// The narrowest a polish card may be. Its title and subtitle wrap, so the one thing that
  /// cannot is the Recommended badge, inside the card's 12-point padding on each side.
  /// `TranscribeFilePolishGridTests` measures the real badge against this.
  static let polishCardMinimumWidth: CGFloat = 140

  /// How many cards fit across `width`. The design's steps are six, three, two; nothing in
  /// between, because a row of four beside a row of two is a layout the design never shows.
  static func polishColumns(fitting width: CGFloat) -> Int {
    guard width > 0 else { return 6 }
    for count in [6, 3] {
      let cardWidth = (width - polishGridSpacing * CGFloat(count - 1)) / CGFloat(count)
      if cardWidth >= polishCardMinimumWidth { return count }
    }
    return 2
  }

  @ViewBuilder
  private var polishStep: some View {
    stepHeading("Select polishing engine")
    // Six across at the design's width, three when six would squeeze a card under
    // `polishCardMinimumWidth`, two below that. The prototype steps 6 → 3 → 2 at its own
    // window breakpoints; the app's pane is narrower than its window by the sidebar, so the
    // step is taken on the CARD's width, which is what those breakpoints were protecting.
    // The count was a constant 6 while the comment above it promised the fallback; at the
    // 750-point minimum window that clipped every title. Found by the cloud review of
    // PR #2786. Width is read from a background `GeometryReader` because the grid must
    // keep its own height; `onGeometryChange` would be neater and is macOS 15.
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: Self.polishGridSpacing),
        count: Self.polishColumns(fitting: polishGridWidth)),
      spacing: Self.polishGridSpacing
    ) {
      ForEach(Self.polishChoices, id: \.provider) { choice in
        polishCard(choice)
      }
    }
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { polishGridWidth = geo.size.width }
          .onChange(of: geo.size.width) { _, width in polishGridWidth = width }
      })
    polishLeadIn
    // #2772 chunk 3, findings 7b / 7c / 7f / 7h: the SAME setup editor the AI Polish page
    // renders, keyed to the import's choice. A key typed here is saved to the one Keychain
    // entry both screens read, and the model list is the one catalog both screens use;
    // what is separate is only WHICH engine each screen selected. The founder's ruling was
    // "Keep it on the page", because sending someone to another screen to switch a feature
    // on and then back again is the experience this replaces.
    ProviderSetupSection(model: setupModel, part: .detail, surface: .fileImport)
    // Ollama's catalog is a long list, so it sits full width below the editor rather than
    // inside it, exactly as it does on the AI Polish page. The editor's own copy says "the
    // list below", so leaving it out would point at nothing.
    if settings.effectiveFileImportLLMProvider == .ollama,
      ProviderSetupVisibility.showsManageModels(setup)
    {
      ProviderSetupSection(model: setupModel, part: .manageModels, surface: .fileImport)
    }
    // #2772: the ONLY way out of an override. Without it, one curious tap on a second
    // engine is permanent, and a user who wants their imports to simply track their
    // dictation engine again has nothing to press. Shown only when there is something to
    // undo, so a follower never sees a control that would do nothing.
    if settings.fileImportLLMProvider != nil {
      Button("Use dictation's polish settings") {
        settings.followDictationForFileImportPolish()
      }
      .buttonStyle(.link)
      .font(.stHelper)
    }
    actionRow(
      note: polishReadiness.footer
        ?? "Numbers, dates, your saved words and filler removal run either way.",
      forwardTitle: "Continue", forwardEnabled: polishReadiness.isReady,
      forward: {
        guard polishReadiness.isReady else { return }
        coordinator.advance()
      })
  }

  // MARK: - May this import start? (#2772 finding 7a)

  /// The Ollama model an import would run, whichever engine happens to be selected. A
  /// follower has no field of its own, so its answer is dictation's, exactly as everywhere
  /// else the follow rule applies.
  private var importOllamaModel: String {
    settings.fileImportLLMProvider == nil
      ? settings.ollamaModel : settings.fileImportOllamaModel
  }

  /// The gate on Continue, for the engine this import will actually use.
  private var polishReadiness: FileImportPolishReadiness {
    readiness(for: settings.effectiveFileImportLLMProvider)
  }

  /// Readiness for ANY engine, not only the selected one.
  ///
  /// **Every card reads its own state, which is what the approved prototype draws:** one
  /// screenshot shows OpenAI "Cloud based" and Gemini "Needs a key" side by side, neither
  /// selected. A first version answered only for the selected engine and fell back to a
  /// fixed word elsewhere, which is the same defect the founder reported one card over.
  ///
  /// Answerable for all six because every input is per-engine: the two bundled runtimes,
  /// the availability report, the Ollama daemon, and each provider's own saved-key fact. The
  /// one shared input is the discovery verdict, and it is taken only when it is ABOUT this
  /// engine.
  ///
  /// Reads the coordinators directly rather than asking the embedded editor, because the
  /// editor renders a state and this decides an outcome; a view that reported its own
  /// readiness would be a second authority on the same question.
  private func readiness(for provider: LLMProvider) -> FileImportPolishReadiness {
    let savedKey: FileImportSavedKeyState
    // Whether the field was TYPED IN since it was last loaded or saved, which is not the
    // same fact as the SAVED one: polish reads the Keychain, so a key nobody pressed Save
    // on does not run.
    //
    // **Not "the field is non-empty".** The field is FILLED FROM the Keychain on appear, so
    // non-empty is true for every user who has a key and would block all of them. A
    // REPLACEMENT key typed over a saved one is the case this exists for: the old key is
    // still what runs. Found by the cloud review of PR #2786.
    let edited: Bool
    switch provider {
    case .openAI:
      savedKey = .from(setupModel.openAIKeySaved)
      edited = setupModel.openAIKeyEdited
    case .gemini:
      savedKey = .from(setupModel.geminiKeySaved)
      edited = setupModel.geminiKeyEdited
    case .claude:
      savedKey = .from(setupModel.claudeKeySaved)
      edited = setupModel.claudeKeyEdited
    // Enumerated, never `default:`. These carry no API key, so "absent" is the true
    // answer and the gate ignores it for them. A NEW key-carrying provider on a default
    // arm would have read as permanently key-less and blocked forever.
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      savedKey = .absent
      edited = false
    }
    return FileImportPolishGate.readiness(
      provider: provider,
      savedKey: savedKey,
      hasUnsavedKeyDraft: edited,
      // Only when the discovery coordinator's verdict is about THIS provider. It is shared
      // with the AI Polish page, which may have validated a different one.
      keyValidation: llmDiscovery.stateProvider == provider
        ? llmDiscovery.keyValidationState : .idle,
      egOneInstall: egOne.installState,
      egOneHealth: egOne.health,
      s1MiniInstall: localPolishRuntimes.s1Mini.installState,
      s1MiniHealth: localPolishRuntimes.s1Mini.health,
      appleStatus: aiAvailability.latestReport?.overallStatus,
      ollamaSetup: setup.ollamaSetup.setupState,
      // The import's own OLLAMA field, never the effective model.
      //
      // `effectiveFileImportLLMModel` answers "what will the SELECTED engine ask for", and
      // this function now runs for every card. With OpenAI selected it returns a cloud id,
      // which made the unselected Ollama card read "Ready" while its remembered Ollama
      // selection was empty. A per-card question needs a per-card field. Found by Codex.
      // And present in the daemon's own list, not merely remembered. See the gate's
      // `ollamaModelIsArmed(_:downloaded:)`.
      ollamaModelIsArmed: FileImportPolishGate.ollamaModelIsArmed(
        importOllamaModel, downloaded: setup.ollamaSetup.downloadedModels.map(\.exactName)))
  }

  struct PolishChoice {
    let provider: LLMProvider
    let detail: String

    /// Read from the provider, never restated here. `LLMProviderDisplayNameFreezeTests`
    /// enforces it, and it is right to: a licence-bound spelling or a rename has
    /// to change in one place, not in every screen that happens to list them.
    var title: String { provider.displayName }
  }

  /// The six, in the order the design shows them.
  ///
  /// **No `icon` and no `availability` any more (#2772 chunk 3).** The mark now comes from
  /// `ProviderLogoTile`, the one place all six brand mocks are drawn, and the line under
  /// the name comes from `FileImportPolishSubtitle`, which reads the engine's live state.
  /// Both were fixed strings in this table, which is how a card could say "Needs a key"
  /// beside an enabled Continue button, and how it kept saying it after a key was saved.
  static let polishChoices: [PolishChoice] = [
    PolishChoice(
      provider: .egOne,
      detail:
        """
        Our best model for cleanup and list-making. On an imported recording it removes about \
        four times more filler than Apple Intelligence.
        """),
    PolishChoice(
      provider: .appleIntelligence,
      detail: "Apple's on-device model. Needs macOS 26 or later."),
    PolishChoice(
      provider: .ollama,
      // Deliberately says nothing about where the text goes. Ollama proxies
      // some models to its own servers, so the answer depends on the MODEL, and
      // this line cannot see one. `ollamaPrivacyLine` says it right below.
      detail: "Any model you run in Ollama."),
    PolishChoice(
      provider: .openAI,
      detail: "Your own OpenAI key. Only the text is sent, never the audio."),
    PolishChoice(
      provider: .gemini,
      detail: "Your own Google key. Only the text is sent, never the audio."),
    PolishChoice(
      provider: .claude,
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
    // #2772: the IMPORT's polisher, which is a SEPARATE choice from dictation's.
    //
    // The first version of this wrote `settings.llmProvider` — the same door the AI Polish
    // page uses — on the reasoning that writing a private copy would neither canonicalize
    // the model nor start the runtime. That reasoning was right about the mechanism and
    // wrong about the target: it meant picking an engine for ONE import silently changed
    // what every later DICTATION used. The founder found it in UAT.
    //
    // Reading `effectiveFileImportLLMProvider` rather than the stored override is what
    // makes a user who has never chosen show dictation's engine as selected, which is what
    // their next import will actually use.
    let selected = settings.effectiveFileImportLLMProvider == choice.provider
    return Button {
      // An explicit pick is an override even when it EQUALS dictation's engine: choosing
      // the same thing on purpose is still choosing, and must not silently resume
      // following dictation on its next change.
      settings.seedFileImportPolishModelsIfNeeded()
      settings.fileImportLLMProvider = .some(choice.provider)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          // #2772 finding 6: the real brand mark, from the one tile the AI Polish rail
          // already draws. The founder's words were "we already have them in the software".
          ProviderLogoTile(provider: choice.provider, size: 26, isSelected: selected)
          Spacer(minLength: 4)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.stAccent : Color.stTextSecondary)
        }
        Text(choice.title).font(.stRowLabel).fixedSize(horizontal: false, vertical: true)
        if choice.provider == .egOne { Self.wizardBadge("Recommended") }
        // Wraps, like the title. A single-line subtitle truncated at three columns, and the
        // words it lost were the ones saying whether the engine is ready.
        Text(cardSubtitle(for: choice.provider))
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
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

  /// The line under a card's name, for that card's OWN engine. Founder finding 7g.
  private func cardSubtitle(for provider: LLMProvider) -> String {
    FileImportPolishSubtitle.text(provider: provider, readiness: readiness(for: provider))
  }

  /// The short description of the selected engine, plus the one sentence about where an
  /// Ollama model actually runs, above the shared setup editor.
  @ViewBuilder
  private var polishLeadIn: some View {
    if let choice = selectedPolish {
      VStack(alignment: .leading, spacing: 4) {
        Text(choice.detail)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        // **The sentence sits where the user approves the choice**, not only
        // in the footer. This card promised "Nothing leaves this Mac" for
        // every Ollama model, immediately above the button that sends the
        // transcript to one Ollama proxies to its own servers. Found by
        // Codex. Chunk 3 moved it out of the old detail card, which the shared
        // setup editor replaced; the editor's own Ollama explainer describes local and
        // hosted models in general and cannot name the one that is selected.
        if choice.provider == .ollama {
          Text(ollamaPrivacyLine)
            .foregroundStyle(Color.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// WHERE a polisher runs. Exhaustive over the provider, so a seventh cannot be silently
  /// blank on the screen that confirms what is about to happen to a recording.
  ///
  /// **This replaced `availability(_:)`, a FIXED SETUP mapping the Review row was using to
  /// answer a LOCATION question.** It read "Needs a key" on the confirmation screen of a
  /// user who had saved one, and "Needs the app" for a working Ollama. Setup state now
  /// comes from `FileImportPolishGate`, which reads the live coordinators; location comes
  /// from here, and for Ollama only the remoteness lookup can answer it, because the daemon
  /// proxies some models to its own servers. Found by Codex.
  ///
  /// Static and taking remoteness as an argument so the answer is testable without a
  /// running app: this sentence is a privacy claim.
  static func polisherLocation(_ provider: LLMProvider, ollamaModelIsRemote: Bool?) -> String {
    switch provider {
    case .egOne, .s1Mini, .appleIntelligence: return "This Mac"
    case .openAI, .gemini, .claude: return provider.displayName
    case .ollama:
      switch ollamaModelIsRemote {
      case .some(true): return "Ollama's servers"
      case .some(false): return "This Mac"
      case nil: return "Location not checked"
      }
    case .none: return "No cleanup"
    }
  }

  private var selectedPolish: PolishChoice? {
    Self.polishChoices.first { $0.provider == settings.effectiveFileImportLLMProvider }
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
        //
        // #2772 finding 7a, SECOND door. Review re-checks the selected polisher for BOTH a
        // first run and a re-polish, because setup can change after Continue was pressed:
        // `FileImportCoordinator.canGo` lets any step be reached from the bar once a
        // document exists, and a user can also sit on this step, clear the key on the AI
        // Polish page, and come back to a Start button that is still enabled. Explicitly
        // choosing no cleanup passes the same gate.
        //
        // A first version scoped this to the re-polish case, reasoning that the only way to
        // reach Review without a document is the gated Continue. That is true at the moment
        // of ARRIVAL and says nothing about the moment of PRESSING. Found by Codex, which
        // also named `retry()` as reaching `start()` with no second check.
        //
        // The guard is in the closure as well as on the button, because a disabled button is
        // a presentation and this is an admission.
        actionRow(
          note: polishReadiness.footer
            ?? (coordinator.canRetry
              ? "Your file is still here. Nothing needs reading again."
              : (coordinator.rawTranscript.isEmpty
                ? "Nothing has run yet."
                : "Already transcribed. Only the cleanup runs again.")),
          forwardTitle: coordinator.canRetry
            ? "Try again"
            : (coordinator.rawTranscript.isEmpty
              ? "Start transcription" : "Clean it again"),
          forwardEnabled: polishReadiness.isReady,
          forward: {
            guard polishReadiness.isReady else { return }
            if coordinator.canRetry { coordinator.retry() } else { coordinator.advance() }
          })
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
        mark: {
          Image(systemName: settings.selectedBackend == .parakeet ? "bolt.fill" : "globe")
            .foregroundStyle(Color.stAccent)
        },
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
        // #2772 finding 6: the real brand mark here too. `ProviderLogoTile` covers every
        // provider including the ones the six-tile grid does not render, which is the same
        // reason the title and the "Runs on" row are derived from the provider.
        mark: {
          ProviderLogoTile(
            provider: settings.effectiveFileImportLLMProvider, size: 22, isSelected: false)
        },
        title: settings.effectiveFileImportLLMProvider.displayName,
        recommended: settings.effectiveFileImportLLMProvider == .egOne,
        blurb: "Cleans it into readable text.",
        rows: [("Runs on", selectedPolisherLocation)])
    }
  }

  /// `mark` rather than an SF Symbol name, because the two cards no longer draw the same
  /// KIND of thing: the transcription engine has no brand mark of its own and the polisher
  /// does (#2772 chunk 3).
  /// WHERE the chosen polisher runs, for the row that asks exactly that.
  ///
  /// This row used `availability(_:)`, a fixed setup mapping, so it read "Needs a key" on
  /// the confirmation screen of a user who had saved one, and "Needs the app" for a working
  /// Ollama. Setup state and location are different questions, and the one owner that can
  /// answer location for Ollama is the remoteness lookup, because the daemon proxies some
  /// models to its own servers. Found by Codex.
  private var selectedPolisherLocation: String {
    Self.polisherLocation(
      settings.effectiveFileImportLLMProvider,
      ollamaModelIsRemote: coordinator.polishOllamaLocalityNow())
  }

  private func pathCard(
    @ViewBuilder mark: () -> some View,
    title: String, recommended: Bool, blurb: String, rows: [(String, String)]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        mark()
        Text(title).font(.stRowLabel)
        if recommended { Self.wizardBadge("Recommended") }
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
          // The part, the total and the engine, from the coordinator, which reads the
          // FROZEN configuration. Before a split has happened there is no part to name and
          // this falls back to the phase ("Reading the file", "Dividing it up to clean").
          Text(coordinator.cleaningLabel.isEmpty ? coordinator.phase : coordinator.cleaningLabel)
        }
        Spacer(minLength: 12)
        Text("\(coordinator.wordCount) words").foregroundStyle(Color.stTextSecondary)
        wizardSecondary("Stop") { coordinator.stop() }
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
    }
    // Finished parts, then what is still waiting. NO raw-document fallback here: it renders
    // the WHOLE recording, so before the first part landed the highlighted current row
    // started below the entire transcript and the user read their meeting twice. My own fix
    // narrowed the condition; Codex's deletes the fallback from this step instead, which
    // also covers a "Show original words" selection surviving into a re-polish.
    if !coordinator.parts.isEmpty {
      liveTranscript
    }
    if case .polishing = coordinator.state {
      cleaningQueue
    }
  }

  /// The pieces still waiting, one row each, in order.
  ///
  /// **The one being worked is outlined and bright; the ones behind it are dim.** The
  /// prototype draws it this way because a progress bar alone cannot show a person how much
  /// of THEIR recording is left, and the rows are the raw words so they can see which part
  /// of the meeting is in flight. Founder finding 14.
  ///
  /// Which row is current is derived, never stored: the queue is fixed for a run and
  /// `parts.count` only grows, so their difference is the answer and the two cannot
  /// disagree.
  @ViewBuilder
  private var cleaningQueue: some View {
    let working = coordinator.parts.count
    let waiting = Array(coordinator.pendingPieces.enumerated()).filter { $0.offset >= working }
    if !waiting.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(waiting, id: \.offset) { row in
          let isWorking = row.offset == working
          Text(row.element)
            .lineSpacing(5)
            .foregroundStyle(isWorking ? Color.stTextBody : Color.stTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
                .fill(isWorking ? Color.stAccentLight.opacity(0.35) : Color.stSectionBg))
            .overlay(
              RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
                .strokeBorder(isWorking ? Color.stAccent : Color.stDivider))
            .accessibilityLabel(
              isWorking
                ? "Cleaning this part now. \(row.element)"
                : "Waiting to be cleaned. \(row.element)")
        }
      }
    }
  }

  /// The words themselves while the run goes: cleaned parts as they land, and
  /// the raw transcript until the first one does, so the page is never empty and
  /// never just a spinner.
  private var liveTranscript: some View {
    VStack(alignment: .leading, spacing: 14) {
      // The original/cleaned toggle belongs to DONE. On Working there is nothing to toggle
      // and honouring it there hid the finished parts during a re-polish.
      ForEach(
        coordinator.step == .done
          && (coordinator.screenShowsRawWords || coordinator.documentView == .markedUp)
          ? [] : coordinator.parts
      ) { part in
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
      // DONE only, the marked-up view (#2773): the original words with the cleanup on them,
      // and the counts that are the point. The marks are one attributed text so selection
      // and copy behave like the other two views.
      if coordinator.step == .done, coordinator.documentView == .markedUp,
        !coordinator.parts.isEmpty
      {
        Group {
          if let markedUp = coordinator.markedUp {
            VStack(alignment: .leading, spacing: 8) {
              Text(markedUp.legend)
                .font(.stHelper)
                .foregroundStyle(Color.stTextSecondary)
                .accessibilityLabel("Cleanup summary: \(markedUp.legend)")
              Text(Self.markedUpText(markedUp.segments))
                .lineSpacing(6)
                .textSelection(.enabled)
                // The marks are visual; this is what a screen reader gets instead.
                .accessibilityLabel(Self.markedUpAccessibilityText(markedUp.segments))
            }
          } else {
            ProgressView("Comparing words")
              .controlSize(.small)
          }
        }
        .task(id: coordinator.markedUpInput) { await coordinator.prepareMarkedUp() }
      }
      // DONE only. This is the "Original" view and the empty-document floor, and both belong
      // to the finished screen; on Working the queue shows the raw words.
      if coordinator.step == .done,
        coordinator.screenShowsRawWords,
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
    // #2772 finding 11, the failure half. The approved plan's table says a failed History
    // write must STOP before polish and show the raw words with Copy and Retry, and must
    // never claim "Saved to History". The words are on screen and only on screen, so this
    // says the actionable thing rather than the diagnostic one.
    // The coordinator owns the WORDING, because it is the only thing that knows whether the
    // original words are safe or whether nothing was saved at all. A single sentence for both
    // would alarm the first user and under-warn the second. Found by Codex.
    if let notice = coordinator.historySaveNotice {
      InsetNotice(text: notice, systemImage: "exclamationmark.triangle", tint: .orange)
    }
    // ONE row, which is finding 12. Founder, on the shipped two-row version: "You see how
    // cleaned up by EG-1 is on the wrong line and looks unpolished?" The prototype puts the
    // title on the left and a right-aligned run of chips after it, the polisher among them.
    //
    // **`ViewThatFits`, not a `Spacer` inside `WrappingHStack`.** That layout measures each
    // child against the full width and places them in sequence; it never distributes leftover
    // space, so a `Spacer` there does not right-align anything and can take a whole line to
    // itself. A real `HStack` when the row fits, a stacked layout when it does not. Found by
    // Codex.
    BrandedSection {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          doneTitle.fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 12)
          doneMetadata.fixedSize(horizontal: true, vertical: false)
        }
        VStack(alignment: .leading, spacing: 10) {
          doneTitle
          doneMetadata.frame(maxWidth: .infinity, alignment: .trailing)
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
        // No trailing arrow on any of these: the arrow means "this moves you forward a
        // step", and copying, saving and starting over do not.
        wizardPrimary(
          "Copy everything", isEnabled: coordinator.hasDocument, systemImage: "doc.on.doc",
          showsArrow: false, action: { copyDocument() })
        wizardSecondary(
          "Save as...", isEnabled: coordinator.hasDocument,
          systemImage: "square.and.arrow.down", action: { saveDocument() })
        // #2772 finding 10a: the prototype has FOUR buttons and this one was missing
        // entirely. Anchored to its own frame so the macOS picker points at the button the
        // user pressed rather than at the window corner.
        shareButton
        Spacer(minLength: 12)
        wizardSecondary("New transcription", systemImage: "arrow.up") {
          coordinator.startOver()
        }
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

  /// #2772 finding 11: the badge the approved plan named, and it says only what happened.
  ///
  /// **Three states, not two.** Saved is a green outline. NOT saved says so, in the warning
  /// tone, because a user who is about to close the window needs to know the words are only
  /// on this screen. And a run with no words at all shows nothing rather than reassuring
  /// somebody about a document that does not exist.
  @ViewBuilder
  private var savedToHistoryChip: some View {
    if coordinator.hasDocument {
      if coordinator.isSavedToHistory {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle")
          Text("Saved to History")
        }
        .font(.stHelper)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(Color.stSuccess)
        .overlay(Capsule().strokeBorder(Color.stSuccess.opacity(0.5)))
      } else {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle")
          Text("This version is not saved")
        }
        .font(.stHelper)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(Color.stWarning)
        .overlay(Capsule().strokeBorder(Color.stWarning.opacity(0.5)))
        .help("These words are only on this screen. Copy or save them before you leave.")
      }
    }
  }

  private var doneTitle: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(documentTitle).font(.system(size: 16, weight: .semibold))
        .lineLimit(1).truncationMode(.middle)
      if let subtitle = documentSubtitle {
        Text(subtitle).font(.stHelper).foregroundStyle(Color.stTextTertiary)
      }
    }
  }

  /// The chips, which wrap among themselves when the row is narrow.
  private var doneMetadata: some View {
    WrappingHStack(spacing: 10) {
      chip("\(coordinator.wordCount) words")
      if let file = coordinator.file {
        chip(FileImportCoordinator.durationText(file.seconds))
      }
      savedToHistoryChip
      polishedByChip
      // The page promises the untouched words are kept. This is where the user reads them,
      // and Copy, Save and Share follow Cleaned and Original; Marked up exports Cleaned.
      // Three states want one picker rather than two links (#2773).
      if !coordinator.parts.isEmpty {
        Picker(
          "View",
          selection: Binding(
            get: { coordinator.documentView }, set: { coordinator.documentView = $0 })
        ) {
          Text("Cleaned").tag(FileImportCoordinator.DocumentView.cleaned)
          Text("Marked up").tag(FileImportCoordinator.DocumentView.markedUp)
          Text("Original").tag(FileImportCoordinator.DocumentView.original)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Which words to show")
      }
    }
  }

  /// The polisher, as a CHIP in the same right-hand run rather than on a second line.
  ///
  /// **The provider this document was RUN with**, from the frozen configuration, and named by
  /// `LLMProvider.displayName` so the six names have one owner. Reading the live selection
  /// credited whatever was picked after the run: pick Claude on Change, return to Done, and
  /// unchanged EG-1 output was labelled Claude's. Found by Codex.
  ///
  /// **"Polished by", not "Cleanup engine".** The old wording was chosen so it could not
  /// overrule a passage whose polish failed; that passage carries its own note directly
  /// beneath it, which is closer to the words and says the specific thing. The founder asked
  /// for the prototype's phrasing.
  private var polishedByChip: some View {
    HStack(spacing: 6) {
      Text(polishCredit)
      Button("Change") { coordinator.choosePolisherAgain() }
        .buttonStyle(.plain)
        .foregroundStyle(Color.stAccent)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.stDivider.opacity(0.35)))
  }

  /// What the chip SAYS, which is what happened rather than what was configured.
  ///
  /// **"Polished by EG-1" is a claim about completed work.** The configured provider is not
  /// evidence of any: a refused History write stops the run before a single part is cleaned,
  /// a Stop can land after one of fourteen, and explicit no-polish would still have credited
  /// an engine. None of those carry a passage-level failure note to qualify the claim,
  /// because no passage failed — none ran. Found by Codex.
  ///
  /// Change stays offered in every case: a document that was not polished is exactly the one
  /// a user wants to re-run.
  private var polishCredit: String {
    guard let provider = coordinator.runConfiguration?.polishProvider, provider != LLMProvider.none
    else { return "No AI polish" }
    guard coordinator.parts.contains(where: \.wasPolished) else { return "No AI polish applied" }
    let complete: Bool
    if case .finished = coordinator.state {
      complete = coordinator.parts.allSatisfy(\.wasPolished)
    } else {
      complete = false
    }
    return complete
      ? "Polished by \(provider.displayName)" : "Partly polished by \(provider.displayName)"
  }

  /// A readable name for the finished document, and the date under it.
  ///
  /// #2772 finding 12: the founder asked for "Marketing sync . 4 September 2026" rather than
  /// "import-demo.m4a". A file name is what the FILESYSTEM calls the recording; this screen
  /// is about the meeting. Derived rather than asked for, because asking would be a form on
  /// the screen that exists to hand the words over.
  private var documentTitle: String {
    guard let name = coordinator.file?.name else { return "Transcript" }
    return Self.readableTitle(fromFileName: name)
  }

  /// The date this DOCUMENT was made, taken from the History row the run created. `Date()`
  /// described today, so a transcript left open overnight relabelled itself. Found by Codex.
  private var documentSubtitle: String? {
    guard let date = coordinator.documentCreatedAt else { return nil }
    return Self.documentDateFormatter.string(from: date)
  }

  /// "1-emma-chamberlain-like-literally.mp4" becomes "Emma chamberlain like literally".
  ///
  /// Drops the extension, separator punctuation INCLUDING em and en dashes, and a leading
  /// ordering number. It does not title-case every word, which turns a name into Title Case
  /// Nonsense, and it falls back to the raw name when the result would be empty: an unnamed
  /// document is worse than an ugly one.
  ///
  /// **Only a SHORT leading number, and only before a non-number.** The first version dropped
  /// every consecutive leading numeric token, so "2026-09-10-board-meeting" lost its date and
  /// "1984-book-club" lost the book. Three digits or fewer, followed by a word, is an ordering
  /// prefix; anything else is part of the name. Found by Codex.
  ///
  /// This remains a FILENAME HEURISTIC. It cannot infer what a meeting was called, and it is
  /// not trying to.
  static func readableTitle(fromFileName name: String) -> String {
    var stem = name
    if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
      stem = String(stem[..<dot])
    }
    var words = stem.split { $0.isWhitespace || "-_.\u{2014}\u{2013}".contains($0) }
      .map(String.init)
    if words.count > 1, words[0].count <= 3, words[0].allSatisfy(\.isNumber),
      !words[1].allSatisfy(\.isNumber)
    {
      words.removeFirst()
    }
    let joined = words.joined(separator: " ")
    guard !joined.isEmpty else { return name }
    return joined.prefix(1).uppercased() + joined.dropFirst()
  }

  static let documentDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMMM yyyy"
    return formatter
  }()

  /// The founder's two treatments, and a third for what the cleanup added (#2773). A removed
  /// word is struck through, which reads without colour; an altered or added word is
  /// highlighted AND heavier, so colour is never the only carrier. Both tints are the
  /// existing semantic tokens, so light and dark are handled by what handles every other
  /// surface. Static so `TranscribeFileMarkedUpTests` can read the attributes it sets.
  static func markedUpText(_ segments: [WordDiff.Segment]) -> AttributedString {
    var out = AttributedString()
    for segment in segments {
      var run = AttributedString(segment.text)
      switch segment.kind {
      case .same:
        run.foregroundColor = Color.stTextBody
      case .removed:
        run.foregroundColor = Color.stTextSecondary
        run.strikethroughStyle = .single
      case .changed, .added:
        run.foregroundColor = Color.stTextBody
        run.backgroundColor = Color.stAccentLight
        run.font = .body.weight(.semibold)
      }
      out.append(run)
      // The original's own whitespace, never an invented one: `WordDiff` already put a
      // separator before an addition that needs it.
      out.append(AttributedString(segment.trailing))
    }
    return out
  }

  /// The marks in words, for a screen reader: strikethrough and highlight say nothing aloud.
  static func markedUpAccessibilityText(_ segments: [WordDiff.Segment]) -> String {
    segments.map { segment in
      switch segment.kind {
      case .same: return segment.text + segment.trailing
      case .removed: return "Removed: \(segment.text). "
      case .changed: return "Changed: \(segment.text). "
      case .added: return "Added: \(segment.text). "
      }
    }.joined()
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
      Text(
        Self.footerDetail(
          step: coordinator.step, isCloudPolish: isCloudPolish,
          provider: footerProvider))
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
  /// #2772 finding 7e: the sentence NAMES the provider. "The provider you chose" is true
  /// and asks the reader to remember which one that was, on the screen whose whole job is
  /// telling them where their words go. The provider is passed in rather than read here so
  /// the Working and Done steps can name the one FROZEN with the run, which is a different
  /// answer from the one selected now.
  ///
  /// **"under your own key" is NOT part of the cloud branch, and that is the point.** The
  /// first version appended it to every cloud sentence, and Ollama reaches the cloud branch
  /// whenever the daemon proxies the selected model to Ollama's own servers — where no key
  /// exists. Found in Live UAT: the footer read "Only the text goes to Ollama, under your
  /// own key" with no key involved anywhere. The clause belongs to the three BYOK providers
  /// and only to them.
  static func footerDetail(
    step: FileImportCoordinator.Step, isCloudPolish: Bool, provider: LLMProvider
  ) -> String {
    let providerName = provider.displayName
    let underOwnKey = Self.usesTheUsersOwnKey(provider) ? ", under your own key" : ""
    switch step {
    case .working:
      // The cloud branch belongs HERE most of all: this is the step during
      // which the text is actually being sent. A line claiming both stay on the
      // Mac would be false at the exact moment it is on screen.
      return isCloudPolish
        ? "Your audio never leaves this Mac. The text is going to \(providerName)\(underOwnKey)."
        : "Your audio and text both stay on this Mac."
    case .done:
      return isCloudPolish
        ? "Your audio stayed on this Mac. Only the text went to \(providerName)\(underOwnKey)."
        : "Your untouched words are kept beside this one."
    case .upload, .transcription, .polish, .review:
      return isCloudPolish
        ? "Your audio never leaves this Mac. Only the text goes to \(providerName)\(underOwnKey)."
        : "Your audio and text both stay on this Mac."
    }
  }

  /// Whether the user supplies their own credential to this provider.
  ///
  /// Exhaustive, never `default:`, because the sentence it decides is a claim about the
  /// user's own account. Ollama is the case that matters: a hosted Ollama model sends the
  /// text off this Mac with no key of the user's involved.
  static func usesTheUsersOwnKey(_ provider: LLMProvider) -> Bool {
    switch provider {
    case .openAI, .gemini, .claude: return true
    case .ollama, .egOne, .s1Mini, .appleIntelligence, .none: return false
    }
  }

  /// Which provider the footer names, on the same split as `isCloudPolish`: the FROZEN one
  /// once a run exists, the live one before that. Reading the live selection after a run
  /// would name an engine that never touched those words.
  private var footerProvider: LLMProvider {
    switch coordinator.step {
    case .working, .done:
      if let frozen = coordinator.runConfiguration { return frozen.polishProvider }
    case .upload, .transcription, .polish, .review:
      break
    }
    return settings.effectiveFileImportLLMProvider
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
      settings.effectiveFileImportLLMProvider,
      ollamaModelIsRemote: coordinator.polishOllamaLocalityNow())
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
    case .polisherNotReady:
      return "The cleanup engine didn't start. Your words are here. Clean it again to retry."
    case .engineBusy(.fileImport): return "Another file is being transcribed right now."
    // #2787: a dictation ended but its transcription never returned; the engine
    // is not free until the app restarts.
    case .engineBusy(.abandonedDecode):
      return "The last dictation is still transcribing. Restart the app, then try again."
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

  /// Hands the document to whatever the user has: Messages, Mail, AirDrop, Notes.
  ///
  /// **`ShareLink` with a custom label**, which is the platform control and takes this row's
  /// own button as its label. I first wrapped `NSSharingServicePicker` in a 1x1 anchor view
  /// on the stated reason that `ShareLink` renders its own treatment and could not match the
  /// other three buttons. That was false: Apple provides a label initialiser, and chunk 4
  /// already made `SettingsActionButton` usable without an action. Found by Codex; the anchor
  /// machinery is deleted rather than kept beside a correction.
  ///
  /// Shares the TEXT, and the text it shares is whatever is on screen: with "Show original
  /// words" on, the original travels, which is the rule Copy and Save follow. Sharing the
  /// FILE would hand over the recording rather than the transcript, and the recording is the
  /// thing this feature exists to keep on the Mac.
  private var shareButton: some View {
    ShareLink(item: coordinator.exportText) {
      SettingsActionButton(
        title: "Share...", isEnabled: coordinator.hasDocument, emphasis: .quiet,
        shape: .roundedRect, size: .medium, systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.plain)
    // Same rule as Copy and Save: nothing to hand over means no offer, rather than a sheet
    // that shares an empty string.
    .disabled(!coordinator.hasDocument || coordinator.exportText.isEmpty)
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
