import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Setup's Polish intro (#4528 D3a, plan M77; mockup `polishShow`, copy verbatim): six
/// capabilities rising in turn with their checks popping in, then "Choose my AI polish".
struct SetupPolishIntroScreen: View {
  let model: SetupScreenModel
  let epoch: Int

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  var body: some View {
    VStack(spacing: 0) {
      SetupPolishLips()
      Text("Cleaner writing that still sounds like you")
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      VStack(spacing: DesignSpacing.md) {
        ForEach(Array(SetupPolish.introPoints.enumerated()), id: \.offset) { index, point in
          HStack(spacing: DesignSpacing.xl) {
            SetupCheckBadge()
              .modifier(SetupPop(delay: 0.24 + Double(index) * 0.09, reduceMotion: reduceMotion))
            Text(point).font(.firstRunLabel)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, DesignSpacing.xl)
          .padding(.horizontal, DesignSpacing.xxl)
          .background(
            RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
              .fill(Color.obSurface)
          )
          .accessibilityElement(children: .combine)
          .modifier(SetupRise(delay: 0.08 + Double(index) * 0.09, reduceMotion: reduceMotion))
        }
      }
      Spacer(minLength: 0)
      SetupFooter(title: "Choose my AI polish", action: next) { EmptyView() }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear { model.screenMounted(.polishIntro, epoch: epoch) }
  }

  private func next() {
    guard model.state.step == .polishIntro else { return }
    model.send(.next)
  }
}

/// Setup's AI polish pick and its local See all (#4528 D3a, plan M77; mockup `polishPickView`
/// and `polishAll`'s On your Mac tab, copy verbatim). The cards are the flow's held
/// recommendation; a click changes only the pending pick, and "Continue with <model>" commits
/// exactly the model the screen names through `choosePolish`. See all's Cloud tab (D3b, M82)
/// mounts `SetupCloudPanel` with its own footer; Choose sends `chooseCloud`, Add my key later
/// sends `skipPolish` and Recommended options sends `back`. The tab shows only when the
/// presenter supplies the panel factory.
struct SetupPolishScreen: View {
  let model: SetupScreenModel
  let epoch: Int
  let seeAll: Bool

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private var recommended: OnboardingRecommended { model.state.recommended }
  private var language: LanguageMode? { model.state.choices.languageMode }
  private var appleIntelligence: AppleIntelligenceSetupState { recommended.appleIntelligence }
  private var shown: String {
    seeAll
      ? SetupPolish.seeAllDisplayed(
        draft: model.polishDraft, committed: model.state.choices.polish, recommended: recommended,
        language: language)
      : SetupPolish.pickDisplayed(
        draft: model.polishDraft, committed: model.state.choices.polish, recommended: recommended,
        language: language)
  }

  var body: some View {
    VStack(spacing: 0) {
      SetupPolishLips()
      if seeAll {
        seeAllHeader
        if model.seeAllTab == .cloud, let panel = model.cloudPanel {
          SetupCloudPanel(
            model: panel,
            onChoose: { provider, id in send(.chooseCloud(provider, model: id)) },
            onLater: {
              panel.later()
              skip()
            },
            onBack: { send(.back) }
          )
          .modifier(SetupRise(delay: 0, reduceMotion: reduceMotion))
        } else {
          seeAllPanel
          Spacer(minLength: 0)
          footer
        }
      } else {
        pickPanel
        Spacer(minLength: 0)
        footer
      }
      if model.state.recoveringReadiness {
        SetupLinkButton(title: "Return to getting ready", quiet: true) {
          send(.returnToGettingReady)
        }
      }
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear { model.screenMounted(seeAll ? .polishSeeAll : .polishPick, epoch: epoch) }
  }

  // MARK: Pick (two recommended cards)

  private var pickPanel: some View {
    let withApple = recommended.polishCards.contains {
      SetupPolish.model($0.model)?.provider == .appleIntelligence
    }
    return VStack(spacing: 0) {
      Text(withApple ? "Choose your AI polish" : "Meet EG-1")
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)  // a long German title wraps, never truncates
        .accessibilityAddTraits(.isHeader)
      Group {
        if withApple {
          Text(
            "Both run on your Mac. Start right away,\nor download our model for the best results.")
        } else {
          Text(
            "Our own polish model, made for dictation.\nHere are the two best sizes for this Mac.")
        }
      }
      .font(.firstRunBody)
      .foregroundStyle(Color.obTextSecondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, DesignSpacing.md)
      .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      VStack(spacing: DesignSpacing.xl) {
        ForEach(Array(recommended.polishCards.enumerated()), id: \.element.model) { index, card in
          polishCard(card)
            .modifier(SetupRise(delay: 0.08 + Double(index) * 0.08, reduceMotion: reduceMotion))
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("AI polish model"))
    }
  }

  private func polishCard(_ card: SetupRecommendation.PolishCard) -> some View {
    let selected = card.model == shown
    let tag = SetupPolish.label(card.label)
    let size = downloadText(card.model)
    let line =
      card.preselected && SetupPolish.model(card.model)?.size != nil
      ? SetupPolish.line(card.model) + " "
        + String(
          localized: "Picked for this Mac’s memory.",
          comment: "Setup AI polish card: after the recommended EG-1 size's line.")
      : SetupPolish.line(card.model)
    return Button {
      model.setPolishDraft(card.model)
    } label: {
      HStack(alignment: .top, spacing: DesignSpacing.xl) {
        SetupRadio(selected: selected).padding(.top, DesignSpacing.xxs)
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
          HStack(spacing: DesignSpacing.md) {
            SetupTag(text: tag, recommended: card.preselected)
            Spacer(minLength: 0)
            Text(verbatim: size)
              .font(.firstRunCaption.weight(.semibold))
              .foregroundStyle(Color.obTextSecondary)
          }
          Text(verbatim: SetupPolish.name(card.model)).font(.firstRunTitle)
          Text(verbatim: line)
            .font(.firstRunBody)
            .foregroundStyle(Color.obTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(DesignSpacing.xxl)
    }
    .buttonStyle(SetupChoiceStyle(selected: selected))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel(Text(verbatim: SetupPolish.name(card.model)))
    .accessibilityValue(Text(verbatim: [tag, size, line].joined(separator: ", ")))
  }

  // MARK: See all (On your Mac)

  private var footer: some View {
    SetupFooter(title: "Continue with \(SetupPolish.name(shown))", action: accept) {
      if seeAll {
        SetupLinkButton(title: "Recommended options", quiet: true) { send(.back) }
      } else {
        SetupLinkButton(title: "See all") { send(.seeAllPolish) }
      }
      SetupLinkButton(title: "Skip AI polish", quiet: true, action: skip)
    }
  }

  private var seeAllHeader: some View {
    VStack(spacing: 0) {
      Text("Choose your AI polish")
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)  // a long German title wraps, never truncates
        .accessibilityAddTraits(.isHeader)
      Text("On your Mac or with your own provider.")
        .font(.firstRunBody)
        .foregroundStyle(Color.obTextSecondary)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      if model.sources.makeCloudPanel != nil { seeAllTabs }
    }
  }

  /// Mockup `[role="tablist"]`: two equal tabs in a bordered input-colored well.
  private var seeAllTabs: some View {
    HStack(spacing: DesignSpacing.xs) {
      seeAllTab(.mac, title: "On your Mac", symbol: "laptopcomputer")
      seeAllTab(.cloud, title: "Cloud", symbol: "cloud")
    }
    .padding(DesignSpacing.xxs + 1)
    .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
    .overlay {
      RoundedRectangle(cornerRadius: DesignRadius.xl)
        .strokeBorder(Color.stInputBorder, lineWidth: 1)
        .allowsHitTesting(false)
    }
    .padding(.bottom, DesignSpacing.xxl)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Where AI polish runs"))
  }

  private func seeAllTab(
    _ tab: SetupScreenModel.SeeAllTab, title: LocalizedStringKey, symbol: String
  )
    -> some View
  {
    let selected = model.seeAllTab == tab
    return Button {
      model.showSeeAllTab(tab)
    } label: {
      HStack(spacing: DesignSpacing.md) {
        Image(systemName: symbol).accessibilityHidden(true)
        Text(title)
      }
      .font(.firstRunLabel)
      .foregroundStyle(selected ? Color.firstRunOnAccent : Color.obTextSecondary)
      .frame(maxWidth: .infinity)
      .frame(height: SetupMetrics.segmentHeight)
      .background(
        selected ? Color.obAccent : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignRadius.lg)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private var seeAllPanel: some View {
    let tiles = egOneTiles
    let measuredOn = model.sources.egOneSizeCatalog.facts.measuredOn
    return VStack(spacing: 0) {
      VStack(spacing: DesignSpacing.md) {
        HStack(alignment: .top, spacing: DesignSpacing.md) {
          ForEach(tiles) { tile in egOneTile(tile) }
        }
        .fixedSize(horizontal: false, vertical: true)  // the three tiles share one height
        .padding(.top, SetupMetrics.tagOverlap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("EG-1 size"))
        if !measuredOn.isEmpty, tiles.contains(where: { $0.polishMilliseconds != nil }) {
          Text("Polish time for a short dictation, measured on an \(measuredOn).")
            .font(.firstRunEyebrow)
            .foregroundStyle(Color.obTextSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)  // German wraps, never truncates
        }
        appleIntelligenceRow
        s1MiniRow
      }
      .modifier(SetupRise(delay: 0, reduceMotion: reduceMotion))
    }
  }

  /// The three EG-1 sizes from the presenter Settings uses (names, sizes, speeds, memory
  /// warnings); every size stays selectable on every Mac.
  private var egOneTiles: [EGOneSizeCard] {
    let catalog = model.sources.egOneSizeCatalog
    let primary = SetupPolish.model(SetupPolish.preselected(recommended))?.size
    let fallback = SetupPolish.model(recommended.polish)?.size ?? .mini
    let preferred = SetupPolish.model(shown)?.size ?? primary ?? fallback
    return EGOneSizeCardPresenter.cards(
      .init(
        preferred: preferred, surfaceUsesEGOne: false, allowsRuntimeActivation: false,
        recommendation: primary ?? fallback, installStates: [:],
        displayVersions: catalog.displayVersions, downloadBytes: catalog.downloadBytes,
        facts: catalog.facts, physicalMemoryBytes: model.sources.physicalMemoryBytes))
  }

  private func egOneTile(_ tile: EGOneSizeCard) -> some View {
    let id = SetupPolish.id(of: tile.size)
    let selected = id == shown
    let name = EGOneSizeCardCopy.title(tile.size)
    let reason = SetupPolish.tileReason(tile.size)
    let facts = [
      tile.downloadBytes.map { EGOneSizeCardCopy.byteCount($0) },
      tile.polishMilliseconds.map {
        String(
          localized: "\($0) ms", comment: "Setup AI polish See all: polish time per dictation.")
      },
    ].compactMap { $0 }.joined(separator: " · ")
    let tight =
      tile.memory?.warning != nil
      ? String(
        localized: "Tight on this Mac",
        comment: "Setup AI polish See all: this EG-1 size needs more than half of the Mac's memory."
      )
      : nil
    var spoken = [reason]
    if let bytes = tile.downloadBytes {
      spoken.append(
        String(
          localized: "\(EGOneSizeCardCopy.byteCount(bytes)) download",
          comment: "Setup AI polish: a model's download size."))
    }
    if let ms = tile.polishMilliseconds {
      spoken.append(
        String(
          localized: "\(ms) milliseconds polish",
          comment: "Setup AI polish See all, VoiceOver: polish time per dictation."))
    }
    if tile.isRecommended { spoken.insert(EGOneSizeCardCopy.bestForThisMac, at: 0) }
    if let tight { spoken.append(tight) }
    return Button {
      model.setPolishDraft(id)
    } label: {
      VStack(spacing: DesignSpacing.xxs) {
        Text(verbatim: name).font(.firstRunSay).padding(.top, DesignSpacing.xxs)
        Text(verbatim: reason)
          .font(.firstRunCaption.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        if !facts.isEmpty {
          Text(verbatim: facts).font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
        }
        if let tight {
          Text(verbatim: tight).font(.firstRunCaption).foregroundStyle(Color.obWarning)
        }
      }
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, DesignSpacing.xxl + DesignSpacing.xxs)
      .padding(.bottom, DesignSpacing.xl + DesignSpacing.xxs)
      .padding(.horizontal, DesignSpacing.sm)
    }
    .buttonStyle(SetupChoiceStyle(selected: selected))
    // Above the button's border and wider than the tile if it must (mockup: nowrap, centered).
    .overlay(alignment: .top) {
      if tile.isRecommended {
        SetupTag(text: EGOneSizeCardCopy.bestForThisMac, recommended: true)
          .fixedSize()
          .offset(y: -SetupMetrics.tagOverlap)
          .accessibilityHidden(true)
      }
    }
    .zIndex(tile.isRecommended ? 1 : 0)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(Text(verbatim: spoken.joined(separator: ", ")))
  }

  private var appleIntelligenceRow: some View {
    let id = SetupPolish.id(of: .appleIntelligence) ?? "appleIntelligence"
    let available = appleIntelligence == .available
    return VStack(spacing: DesignSpacing.xs) {
      localRow(
        id: id,
        meta: String(
          localized: "No download", comment: "Setup AI polish See all: Apple Intelligence's size."),
        line: SetupPolish.appleIntelligenceLine(appleIntelligence), enabled: available)
      switch appleIntelligence {
      case .turnedOff:
        SetupLinkButton(title: "Open Settings") {
          if let url = URL(string: AppleIntelligenceSettings.systemSettingsURL) {
            NSWorkspace.shared.open(url)
          }
        }
      case .gettingReady:
        if let recheck = model.sources.recheckAppleIntelligence {
          SetupLinkButton(title: "Check again") { recheck() }
        }
      case .available, .needsNewerMacOS, .unavailable:
        EmptyView()
      }
    }
  }

  private var s1MiniRow: some View {
    let id = SetupPolish.id(of: .s1Mini) ?? "s1mini"
    let supported = SetupPolish.s1MiniSupports(language)
    return localRow(
      id: id, meta: downloadText(id), line: SetupPolish.s1MiniLine(supported: supported),
      enabled: supported)
  }

  private func localRow(id: String, meta: String, line: String, enabled: Bool) -> some View {
    let selected = id == shown && enabled
    let name = SetupPolish.name(id)
    return Button {
      model.setPolishDraft(id)
    } label: {
      HStack(spacing: DesignSpacing.xl) {
        SetupRadio(selected: selected)
        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
          HStack(spacing: DesignSpacing.md) {
            Text(verbatim: name).font(.firstRunLabel)
            Spacer(minLength: 0)
            Text(verbatim: meta)
              .font(.firstRunCaption.weight(.semibold))
              .foregroundStyle(Color.obTextSecondary)
          }
          Text(verbatim: line)
            .font(.firstRunCaption)
            .foregroundStyle(Color.obTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, DesignSpacing.lg)
      .padding(.horizontal, DesignSpacing.xl + DesignSpacing.xxs)
    }
    .buttonStyle(SetupChoiceStyle(selected: selected))
    .disabled(!enabled)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(Text(verbatim: [meta, line].joined(separator: ", ")))
  }

  // MARK: Facts and actions

  /// "1.5 GB download", or "Nothing to download" for Apple Intelligence; sizes from the owners.
  private func downloadText(_ id: String) -> String {
    guard let polish = SetupPolish.model(id) else { return "" }
    if polish.provider == .appleIntelligence {
      return String(
        localized: "Nothing to download",
        comment: "Setup AI polish card: Apple Intelligence's size.")
    }
    guard let bytes = SetupPolish.downloadBytes(id, sources: model.sources) else { return "" }
    return String(
      localized: "\(EGOneSizeCardCopy.byteCount(bytes)) download",
      comment: "Setup AI polish: a model's download size.")
  }

  /// "Continue with <model>": commits exactly the model the screen names, once.
  private func accept() {
    guard model.state.step == (seeAll ? .polishSeeAll : .polishPick),
      SetupPolish.isSelectable(shown, appleIntelligence: appleIntelligence, language: language)
    else { return }
    model.send(.choosePolish(shown))
  }

  private func skip() {
    send(.skipPolish)
  }

  /// Every send is guarded by the screen's own step.
  private func send(_ event: OnboardingEvent) {
    guard model.state.step == (seeAll ? .polishSeeAll : .polishPick) else { return }
    model.send(event)
  }
}

/// The AI polish screens' lips: the mockup's `shimmer` mood (static under Reduce Motion, which
/// the lips read themselves).
struct SetupPolishLips: View {
  var body: some View {
    RainbowLipsView(animationState: .shimmer, size: SetupMetrics.screenLips)
      .accessibilityHidden(true)
      .frame(width: SetupMetrics.screenLips, height: SetupMetrics.screenLips)
      .padding(.bottom, DesignSpacing.xl)
  }
}

/// The green check badge (mockup `[data-ui="status"]` success circle with a white tick).
struct SetupCheckBadge: View {
  var body: some View {
    Image(systemName: "checkmark.circle.fill")
      .resizable()
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color.white, Color.obSuccess)
      .frame(width: SetupMetrics.check, height: SetupMetrics.check)
      .accessibilityHidden(true)
  }
}
