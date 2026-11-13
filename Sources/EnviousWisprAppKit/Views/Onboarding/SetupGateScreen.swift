import EnviousWisprCore
import SwiftUI

/// Setup's Downloads and Getting ready (#4528 D4a.2, plan M83; mockup `isGate`, one template for
/// both, copy verbatim where the live facts support it). It renders `SetupGate`'s cards from the
/// live `OnboardingDownloadsPresentation`, read in the body so owner progress and the runtime's
/// slow-network and countdown changes redraw it. Every action goes through the coordinator or the
/// flow's own events; nothing here schedules, polls or decides readiness.
struct SetupGateScreen: View {
  let model: SetupScreenModel
  let epoch: Int
  let screen: SetupGate.Screen

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private var step: OnboardingStep { screen == .downloads ? .downloads : .gettingReady }

  var body: some View {
    let p = model.sources.downloads?() ?? Self.empty(model.state)
    let names = self.names
    let cards = SetupGate.cards(p, screen: screen, names: names)
    let problem = SetupGate.problem(p, screen: screen)
    VStack(spacing: 0) {
      RainbowLipsView(
        animationState: problem == nil ? .pulse : .idle, size: SetupMetrics.screenLips
      )
      .accessibilityHidden(true)
      .frame(width: SetupMetrics.screenLips, height: SetupMetrics.screenLips)
      .padding(.bottom, DesignSpacing.xl)
      Text(verbatim: SetupGate.title(p, screen: screen, names: names))
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(verbatim: SetupGate.subtitle(p, screen: screen))
        .font(.firstRunBody)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      VStack(spacing: DesignSpacing.md) {
        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
          cardView(card)
            .modifier(SetupRise(delay: 0.05 + Double(index) * 0.08, reduceMotion: reduceMotion))
        }
        if screen == .gettingReady {
          ForEach(SetupGate.permissionRows(p)) { row in permissionRow(row) }
        }
        sharedControls(p)
      }
      Spacer(minLength: 0)
      footer(p)
    }
    .padding(.top, DesignSpacing.xs)
    .onAppear { model.screenMounted(step, epoch: epoch) }
  }

  // MARK: Names and sizes from the owners

  private var names: SetupGate.Names {
    let sources = model.sources
    let parakeet = sources.parakeetModelName?() ?? EngineChoicePresentation.fast.model
    return SetupGate.Names(
      speech: { SetupSpeech.name($0, parakeetModel: parakeet) },
      speechBytes: { SetupSpeech.downloadBytes($0, parakeetModel: parakeet) },
      polish: { SetupPolish.name($0) },
      polishBytes: { SetupPolish.downloadBytes($0, sources: sources) },
      cloudProvider: model.state.choices.cloudProvider?.displayName)
  }

  /// No live source (render fixtures): the flow state alone, every owner fact unknown.
  static func empty(_ state: OnboardingFlowState) -> OnboardingDownloadsPresentation {
    OnboardingDownloadsPresentation.make(
      state: state, block: nil, warmFailed: false, queuedPolish: nil, isNetworkSlow: false,
      isCountingDown: false, speechPhase: { _ in .unknown }, polishPhase: { _ in nil },
      downloadsFinished: false)
  }

  // MARK: Cards

  private func cardView(_ card: SetupGate.Card) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HStack(spacing: DesignSpacing.xl) {
        statusBadge(card.tone)
        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
          Text(verbatim: card.eyebrow.uppercased())
            .font(.firstRunEyebrow).tracking(0.8)
            .foregroundStyle(Color.firstRunTextTertiary)
          Text(verbatim: card.name).font(.firstRunTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let percent = card.percent {
          Text(verbatim: "\(percent)%").font(.firstRunLabel).foregroundStyle(Color.obAccent)
        }
      }
      if card.showsBar {
        SetupProgressBar(
          fraction: card.indeterminate ? nil : card.fraction, isError: card.tone == .error,
          label: card.name, reduceMotion: reduceMotion)
      }
      HStack(spacing: DesignSpacing.xl) {
        Text(verbatim: card.status)
          .font(.firstRunCaption)
          .foregroundStyle(statusColor(card.tone))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let action = card.action, let title = card.actionTitle {
          Button(title) { perform(action) }
            .buttonStyle(SetupSmallButtonStyle())
        }
      }
      .frame(minHeight: SetupMetrics.cardStatusRow)
    }
    .padding(DesignSpacing.xxl)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous).fill(Color.obSurface)
    )
    .accessibilityElement(children: .contain)
  }

  private func statusBadge(_ tone: SetupGate.Tone) -> some View {
    Group {
      switch tone {
      case .done: SetupCheckBadge().modifier(SetupPop(delay: 0, reduceMotion: reduceMotion))
      case .error:
        Image(systemName: "exclamationmark.circle.fill")
          .resizable()
          .symbolRenderingMode(.palette)
          .foregroundStyle(Color.firstRunErrorText, Color.obErrorSoft)
      case .working: SetupSpinner(reduceMotion: reduceMotion)
      case .pending:
        Circle().strokeBorder(Color.firstRunTextTertiary.opacity(0.6), lineWidth: 1.8)
      }
    }
    .frame(width: SetupMetrics.check, height: SetupMetrics.check)
    .accessibilityHidden(true)
  }

  private func statusColor(_ tone: SetupGate.Tone) -> Color {
    switch tone {
    case .error: .firstRunErrorText
    case .done: .firstRunSuccessText
    case .pending, .working: .obTextSecondary
    }
  }

  private func permissionRow(_ row: SetupGate.PermissionRow) -> some View {
    HStack(spacing: DesignSpacing.xl) {
      statusBadge(row.done ? .done : .pending)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(verbatim: row.title).font(.firstRunLabel)
        Text(verbatim: row.status)
          .font(.firstRunCaption)
          .foregroundStyle(row.done ? Color.firstRunSuccessText : Color.obTextSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, DesignSpacing.xl)
    .padding(.horizontal, DesignSpacing.xxl)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obSurface)
    )
    .accessibilityElement(children: .combine)
  }

  /// Both downloads at once: a shared row, labelled for both, never inside one card.
  @ViewBuilder
  private func sharedControls(_ p: OnboardingDownloadsPresentation) -> some View {
    let controls = SetupGate.sharedControls(p)
    if !controls.isEmpty {
      HStack(spacing: DesignSpacing.md) {
        Spacer(minLength: 0)
        ForEach(controls, id: \.self) { control in
          switch control {
          case .retryDownloads:
            Button(
              SetupGate.problem(p, screen: screen).map(Self.isDisk) == true
                ? "Try again" : "Resume downloads"
            ) {
              model.sources.downloadActions.retryDownloads()
            }
            .buttonStyle(SetupSmallButtonStyle())
          case .cancelDownloads:
            SetupLinkButton(title: "Cancel downloads", quiet: true) {
              model.sources.downloadActions.cancelDownloads()
            }
          }
        }
      }
    }
  }

  private static func isDisk(_ problem: SetupGate.Problem) -> Bool {
    if case .disk = problem { return true }
    return false
  }

  // MARK: Footer

  @ViewBuilder
  private func footer(_ p: OnboardingDownloadsPresentation) -> some View {
    if screen == .downloads {
      SetupFooter(title: "Continue setup", action: { send(.next) }) {
        Text(verbatim: SetupGate.note(p))
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
      }
    } else {
      let routes = SetupGate.gettingReadyRoutes(p)
      SetupFooter(
        title: "Try your first dictation", isEnabled: model.state.isReadyForPractice,
        action: { send(.next) }
      ) {
        if routes.permissions {
          SetupLinkButton(title: "Review permissions") { send(.reviewPermissions) }
        }
        if routes.withoutPolish {
          SetupLinkButton(title: "Continue without AI polish", quiet: true) {
            send(.continueWithoutPolish)
          }
        }
        if !routes.permissions, !routes.withoutPolish, let close = model.sources.closeSetup {
          SetupLinkButton(
            title: SetupGate.problem(p, screen: screen) == nil
              ? "Close setup. Downloads continue in the menu bar."
              : "Close setup. Retry any time from the menu bar.",
            quiet: true, action: close)
        }
      }
    }
  }

  // MARK: Actions

  private func perform(_ action: SetupGate.CardAction) {
    switch action {
    case .retryWarmup: model.sources.downloadActions.retryWarmup()
    case .retryPolish: model.sources.downloadActions.retryPolish()
    case .turnPolishOn: send(.turnPolishOn)
    case .changePolish: send(.back)  // Downloads' Back is the polish choice (flow table)
    }
  }

  private func send(_ event: OnboardingEvent) {
    guard model.state.step == step else { return }
    model.send(event)
  }
}

/// The card's small button (mockup `[data-ui="btn-sm"]`): 32 high, 10 corners, accent.
struct SetupSmallButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.firstRunLabel)
      .foregroundStyle(Color.firstRunOnAccent)
      .padding(.horizontal, DesignSpacing.xl)
      .frame(height: SetupMetrics.linksHeight)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
          .fill(hovering || configuration.isPressed ? Color.firstRunButtonHover : Color.obAccent)
      )
      .opacity(isEnabled ? 1 : 0.55)
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
      .onHover { hovering = $0 }
      .animation(SettingsHover.animation, value: hovering)
  }
}
