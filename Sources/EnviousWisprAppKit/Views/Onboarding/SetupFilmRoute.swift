import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// The film step (#4528 E integration): the closing film over the flow's actual picks. Launch
/// EnviousWispr on the last scene sends `filmFinished`, earlier it sends `skipFilm`; both
/// complete Setup through the flow. How the film ended goes to the visit's telemetry first, so
/// the completion summary carries it.
struct SetupFilmRoute: View {
  let model: SetupScreenModel
  let epoch: Int

  var body: some View {
    SetupFilmScreen(
      summary: Self.summary(model.state.choices, sources: model.sources),
      onFinished: { send(.filmFinished) },
      onSkip: { send(.skipFilm) },
      onReport: { result, scene in
        guard model.state.step == .film, model.routeEpoch == epoch, model.isWindowVisible else { return }
        model.onFilmEnded?(result, scene)
      },
      playback: model.sources.filmPlayback,
      canSavePlayback: {
        model.state.step == .film && model.routeEpoch == epoch
      },
      isVisible: model.isWindowVisible
    )
    .onAppear { model.screenMounted(.film, epoch: epoch) }
  }

  private func send(_ event: OnboardingEvent) {
    guard model.state.step == .film, model.routeEpoch == epoch, model.isWindowVisible else { return }
    model.send(event)
  }

  /// The film's words from the committed picks and the saved shortcut.
  static func summary(_ choices: OnboardingChoices, sources: SetupScreenSources) -> FilmSummary {
    let parakeet = sources.parakeetModelName?() ?? EngineChoicePresentation.fast.model
    let speech = choices.speech.map { SetupSpeech.name($0, parakeetModel: parakeet) } ?? ""
    let polish: String? =
      switch choices.polish {
      case nil, OnboardingChoices.polishOff?: nil
      case OnboardingChoices.polishCloud?: choices.cloudProvider?.displayName
      case let id?: SetupPolish.name(id)
      }
    let binding = sources.shortcut?.binding() ?? ShortcutBindings.shipped.record
    return FilmSummary(
      speechModel: speech, polish: polish, keyLabel: SetupShortcutScreen.display(binding),
      keyCap: SetupShortcutScreen.cap(binding))
  }
}
