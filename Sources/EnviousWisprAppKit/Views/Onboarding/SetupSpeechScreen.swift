import EnviousWisprCore
import SwiftUI

/// Setup's Speech pick and Compare (#4528 D2, plan M76; mockup `recMain` / `recCompare`, copy
/// verbatim). Both panels show one engine: the pending pick, a compatible committed pick or the
/// flow's recommendation. "Use <model>" commits exactly that engine through `chooseSpeech`.
struct SetupSpeechScreen: View {
  let model: SetupScreenModel
  let epoch: Int
  let comparing: Bool

  @State private var tour = SetupGreetingTour()

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private var language: LanguageMode? { model.state.choices.languageMode }
  private var parakeetModel: String {
    model.parakeetModelName?() ?? EngineChoicePresentation.fast.model
  }
  private var shown: ASRBackendType {
    SetupSpeech.displayed(
      draft: model.speechDraft, committed: model.state.choices.speech,
      recommended: model.state.recommended.speech, language: language)
  }
  private var shownName: String { SetupSpeech.name(shown, parakeetModel: parakeetModel) }

  var body: some View {
    VStack(spacing: 0) {
      lips
      if comparing { comparePanel } else { mainPanel }
      Spacer(minLength: 0)
      SetupFooter(title: "Use \(shownName)", action: accept) {
        if comparing {
          SetupLinkButton(title: "Recommended options", quiet: true) { model.send(.back) }
        } else {
          SetupLinkButton(title: "Compare speech models") { model.send(.compareSpeech) }
        }
      }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear { model.screenMounted(comparing ? .speechCompare : .speechPick, epoch: epoch) }
    // Keyed on the motion setting too: turning Reduce Motion on stops the tour, off restarts it.
    .task(id: GreetingKey(engine: shown, reduceMotion: reduceMotion)) { await cycleGreetings() }
  }

  // MARK: Lips and Whisper's world greetings

  private struct GreetingKey: Equatable {
    let engine: ASRBackendType
    let reduceMotion: Bool
  }

  private var lips: some View {
    let greetings = SetupSpeech.worldGreetings(for: language)
    let greeting =
      shown == .whisper && !greetings.isEmpty
      ? greetings[tour.index % greetings.count] : nil
    return ZStack(alignment: .topLeading) {
      RainbowLipsView(
        animationState: shown == .parakeet ? .modelFast : .modelVoice,
        size: SetupMetrics.screenLips
      )
      .accessibilityHidden(true)
      if let greeting {
        Text(verbatim: greeting.text)
          .font(.firstRunLabel)
          .foregroundStyle(Color.obAccent)
          .fixedSize()
          .padding(.vertical, DesignSpacing.sm)
          .padding(.horizontal, DesignSpacing.xl)
          .background(
            UnevenRoundedRectangle(
              topLeadingRadius: DesignRadius.xl, bottomLeadingRadius: DesignRadius.xs,
              bottomTrailingRadius: DesignRadius.xl, topTrailingRadius: DesignRadius.xl,
              style: .continuous
            ).fill(Color.firstRunAccentSoft)
          )
          .offset(x: SetupMetrics.screenLips + DesignSpacing.xxs, y: SetupMetrics.bubbleTop)
          .id(tour.index)
          .transition(reduceMotion ? .identity : .opacity)
          .accessibilityHidden(true)
      }
    }
    .frame(width: SetupMetrics.screenLips, height: SetupMetrics.screenLips)
    .padding(.bottom, DesignSpacing.xl)
  }

  /// Whisper's greeting tour, one every 1.4 s (mockup); cancelled when the engine changes or
  /// the screen leaves. Static (first greeting only) under Reduce Motion.
  private func cycleGreetings() async {
    await tour.run(engine: shown, reduceMotion: reduceMotion)
  }

  // MARK: Main panel (one engine)

  private var mainPanel: some View {
    let presentation = SetupSpeech.presentation(shown, parakeetModel: parakeetModel)
    let times = presentation.times
    return VStack(spacing: 0) {
      Text("Meet \(shownName)")
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      pitch
        .font(.firstRunBody)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      VStack(spacing: DesignSpacing.md) {
        SetupCard {
          VStack(spacing: DesignSpacing.md) {
            Text("Your words, transcribed in about")
              .font(.firstRunEyebrow).textCase(.uppercase).tracking(0.8)
              .foregroundStyle(Color.firstRunTextTertiary)
            Text(verbatim: EngineChoicePresentation.seconds(times.medium))
              .font(.firstRunHero)
              .foregroundStyle(Color.obAccent)
            Text("after you stop talking").font(.firstRunLabel)
            Text("For 30 seconds of speech.")
              .font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
            HStack(spacing: DesignSpacing.md) {
              fact(
                value: EngineChoicePresentation.seconds(times.long),
                caption: "even after 5 minutes of talking")
              fact(
                value: String(
                  localized: "About 2x", comment: "Setup speech card: about twice as fast."),
                caption: "faster than typing first drafts")
            }
            .padding(.top, DesignSpacing.xs)
          }
        }
        .modifier(SetupRise(delay: 0.1, reduceMotion: reduceMotion))
        SetupRow(
          symbol: "arrow.down.to.line",
          title:
            "\(String(localized: EngineChoicePresentation.downloadSize(bytes: SetupSpeech.downloadBytes(shown, parakeetModel: parakeetModel)))) download",
          detail: shown == .parakeet
            ? "Runs on the Neural Engine. Works offline." : "Runs on the Apple GPU. Works offline."
        )
        .modifier(SetupRise(delay: 0.2, reduceMotion: reduceMotion))
      }
    }
  }

  @ViewBuilder private var pitch: some View {
    switch (shown, SetupSpeech.languageName(language)) {
    case (.parakeet, let name?): Text("The fastest way to dictate in \(name).")
    case (.parakeet, nil): Text("The fastest way to dictate.")
    case (.whisper, let name?): Text("Fluent in \(name) and 98+ more languages.")
    case (.whisper, nil): Text("Fluent in 99+ languages.")
    }
  }

  private func fact(value: String, caption: LocalizedStringKey) -> some View {
    VStack(spacing: DesignSpacing.xxs) {
      Text(verbatim: value).font(.firstRunTitle)
      Text(caption)
        .font(.firstRunCaption)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, DesignSpacing.xl)
    .padding(.horizontal, DesignSpacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obCardBg)
    )
    .accessibilityElement(children: .combine)
  }

  // MARK: Compare panel (two tiles)

  private var comparePanel: some View {
    VStack(spacing: 0) {
      Text("Choose your speech model")
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text("Both run entirely on your Mac.")
        .font(.firstRunBody)
        .foregroundStyle(Color.obTextSecondary)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      HStack(spacing: DesignSpacing.xl) {
        ForEach(SetupSpeech.engines, id: \.self) { engine in tile(engine) }
      }
      .padding(.top, SetupMetrics.tagOverlap)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("Speech model"))
      compareLine
        .font(.firstRunBody)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, DesignSpacing.xl)
      Text(SetupSpeech.presentation(shown, parakeetModel: parakeetModel).times.source)
        .font(.firstRunEyebrow)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, DesignSpacing.xs)
    }
  }

  /// The shown engine's "pick this for" line, or, when the language rules Parakeet out, why.
  private var compareLine: Text {
    if !SetupSpeech.supports(.parakeet, language), let name = SetupSpeech.languageName(language) {
      return Text(
        "\(parakeetModel) is made for European languages. Whisper is the one for \(name).")
    }
    return Text(SetupSpeech.presentation(shown, parakeetModel: parakeetModel).tagline)
  }

  private func tile(_ engine: ASRBackendType) -> some View {
    let supported = SetupSpeech.supports(engine, language)
    let selected = engine == shown
    let recommended = engine == model.state.recommended.speech
    let presentation = SetupSpeech.presentation(engine, parakeetModel: parakeetModel)
    let name = SetupSpeech.name(engine, parakeetModel: parakeetModel)
    let size = String(
      localized: EngineChoicePresentation.downloadSize(
        bytes: SetupSpeech.downloadBytes(engine, parakeetModel: parakeetModel)))
    return Button {
      model.setSpeechDraft(engine)
    } label: {
      VStack(spacing: DesignSpacing.xs) {
        Image(systemName: presentation.icon)
          .font(.firstRunTitle)
          .foregroundStyle(Color.obAccent)
          .frame(width: SetupMetrics.iconWell, height: SetupMetrics.iconWell)
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
              .fill(Color.firstRunAccentSoft)
          )
          .padding(.bottom, DesignSpacing.sm)
        Text(verbatim: name).font(.firstRunSay)
        Text("\(EngineChoicePresentation.seconds(presentation.times.medium)) for 30 s of speech")
          .font(.firstRunCaption.weight(.semibold))
        Text(EngineChoicePresentation.coverage(for: engine))
          .font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
        Text("\(size) download")
          .font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
      }
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.top, DesignSpacing.xxl + DesignSpacing.xs)
      .padding(.bottom, DesignSpacing.xl + DesignSpacing.xxs)
      .padding(.horizontal, DesignSpacing.lg)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous)
          .fill(selected ? Color.firstRunAccentSoft : Color.obCardBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous)
          .strokeBorder(selected ? Color.obAccent : Color.firstRunRule, lineWidth: 2)
      )
      .overlay(alignment: .top) {
        SetupTag(text: tagText(engine, recommended: recommended), recommended: recommended)
          .offset(y: -SetupMetrics.tagOverlap)
      }
      .opacity(supported ? 1 : 0.55)
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!supported)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(
      Text(
        verbatim: tileValue(
          engine, recommended: recommended, supported: supported,
          facts: [
            String(
              localized:
                "\(EngineChoicePresentation.seconds(presentation.times.medium)) for 30 s of speech"),
            String(localized: EngineChoicePresentation.coverage(for: engine)),
            String(localized: "\(size) download"),
          ])))
  }

  private func tagText(_ engine: ASRBackendType, recommended: Bool) -> String {
    if recommended {
      if let name = SetupSpeech.languageName(language) {
        return String(
          localized: "Best for \(name)",
          comment: "Setup speech compare: the recommended engine's tag.")
      }
      return String(
        localized: "Recommended", comment: "Setup speech compare: the recommended engine's tag.")
    }
    return engine == .parakeet
      ? String(localized: "Fastest", comment: "Setup speech compare: Parakeet's tag.")
      : String(localized: "All languages", comment: "Setup speech compare: Whisper's tag.")
  }

  /// What VoiceOver reads after the name: the tag, the tile's facts, and why it is unavailable.
  private func tileValue(
    _ engine: ASRBackendType, recommended: Bool, supported: Bool, facts: [String]
  ) -> String {
    var parts = [tagText(engine, recommended: recommended)] + facts
    if !supported, let name = SetupSpeech.languageName(language) {
      parts.append(
        String(
          localized: "Made for European languages. Whisper is the one for \(name).",
          comment: "Setup speech compare: why Parakeet is not offered for this language."))
    }
    return parts.joined(separator: ", ")
  }

  /// "Use <model>": commits exactly the engine the screen names, once.
  private func accept() {
    guard model.state.step == (comparing ? .speechCompare : .speechPick) else { return }
    model.send(.chooseSpeech(shown))
  }
}
