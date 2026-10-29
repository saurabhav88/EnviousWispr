import AppKit
import EnviousWisprServices
import Foundation

/// One Settings help button's ephemeral observations (#3862). It never drives the UI.
/// Native tooltip visibility and the cause of a system dismissal are unobservable here.
@MainActor
final class SettingsHelpTrace {
  private struct Interaction {
    let id = UUID()
    let started: TimeInterval
    let eligible: Bool
    var sequence = 0
    var elapsedMilliseconds = 0.0
    var escapeObserved = false
  }

  private let now: () -> TimeInterval
  private let captureAvailable: () -> Bool
  private let windowState: () -> (appActive: Bool, hasKeyWindow: Bool)
  private let emit: (SettingsHelpObservation) -> Void
  private var pointerInside = false
  private var popover: Interaction?

  init(
    now: @escaping () -> TimeInterval,
    captureAvailable: @escaping () -> Bool,
    windowState: @escaping () -> (appActive: Bool, hasKeyWindow: Bool),
    emit: @escaping (SettingsHelpObservation) -> Void
  ) {
    self.now = now
    self.captureAvailable = captureAvailable
    self.windowState = windowState
    self.emit = emit
  }

  /// Pointer context only: moving over or away from help never emits telemetry.
  func pointerChanged(_ inside: Bool) { pointerInside = inside }

  func requested(alreadyPresented: Bool) {
    guard !alreadyPresented else { return }
    finishPopover(.supersededByRequest)
    var interaction = begin()
    publish(.requested, kind: .popover, interaction: &interaction)
    popover = interaction
  }

  func escapeObserved() { popover?.escapeObserved = true }

  func bindingFalseObserved() { finishPopover(.bindingFalseObserved) }

  func anchorDisappeared() {
    finishPopover(.anchorDisappeared)
    pointerInside = false
  }

  private func begin() -> Interaction {
    Interaction(started: now(), eligible: captureAvailable())
  }

  private func finishPopover(_ phase: SettingsHelpObservation.Phase) {
    guard var interaction = popover else { return }
    popover = nil
    publish(phase, kind: .popover, interaction: &interaction)
  }

  private func publish(
    _ phase: SettingsHelpObservation.Phase,
    kind: SettingsHelpObservation.Interaction,
    interaction: inout Interaction
  ) {
    interaction.sequence += 1
    interaction.elapsedMilliseconds = max(
      interaction.elapsedMilliseconds, max(0, now() - interaction.started) * 1_000)
    guard interaction.eligible, captureAvailable() else { return }
    let state = windowState()
    emit(SettingsHelpObservation(
      interactionID: interaction.id, interaction: kind, phase: phase,
      sequence: interaction.sequence, elapsedMilliseconds: interaction.elapsedMilliseconds,
      pointerInside: pointerInside, appActive: state.appActive, hasKeyWindow: state.hasKeyWindow,
      escapeObserved: interaction.escapeObserved))
  }
}

@MainActor
extension SettingsHelpTrace {
  static func live() -> SettingsHelpTrace {
    SettingsHelpTrace(
      now: { ProcessInfo.processInfo.systemUptime },
      captureAvailable: { ObservabilityBootstrap.isUsageCaptureRunning },
      windowState: { (NSApp.isActive, NSApp.keyWindow != nil) },
      emit: { TelemetryService.shared.settingsHelpObserved($0) })
  }
}
