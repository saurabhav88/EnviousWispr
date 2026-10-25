import EnviousWisprASR
import Foundation

/// The one composition of the Universal model's removal hooks (#3973 plan §3.2): dictation's
/// Live Preview and EnviousMeet's live words each hold the model, so removal must let both go
/// before it deletes the files.
///
/// Order, inside `ModelDeliveryHome.drainPreviewHoldersBeforeRemoval`:
/// 1. every holder's suppression begins, synchronously, before any await, so nothing reloads the
///    model while its admission marker is still on disk;
/// 2. every holder's drain starts at once, each in its own task, so one held preparation, feed,
///    end or unload never stops another holder's teardown from starting;
/// 3. once every drain has returned (each physically released its own holders), the one
///    process-wide residency wait;
/// then the home deletes the files and `previewRemovalDidFinish` ends every suppression (it
/// means "no longer removing", never "deleted").
@MainActor
enum PreviewModelRemoval {
  struct Holder {
    var begin: @MainActor () -> Void
    var drain: @MainActor () async -> Void
    var end: @MainActor () -> Void
  }

  static func install(
    on home: ModelDeliveryHome, holders: [Holder],
    waitUntilNoneLoaded: @escaping @MainActor () async -> Void
  ) {
    home.drainPreviewHoldersBeforeRemoval = {
      for holder in holders { holder.begin() }
      let drains = holders.map { holder in Task { @MainActor in await holder.drain() } }
      for drain in drains { await drain.value }
      await waitUntilNoneLoaded()
    }
    home.previewRemovalDidFinish = {
      for holder in holders { holder.end() }
    }
  }

  /// Dictation's Live Preview. Weak: a removal hook must never keep the limb alive.
  static func dictation(_ coordinator: LivePreviewCoordinator) -> Holder {
    Holder(
      begin: { [weak coordinator] in coordinator?.beginRemovalSuppression() },
      drain: { [weak coordinator] in await coordinator?.releaseAndDrainForRemoval() },
      end: { [weak coordinator] in coordinator?.endRemovalSuppression() })
  }

  /// EnviousMeet's live words.
  static func meeting(_ liveWords: MeetingLiveWords) -> Holder {
    Holder(
      begin: { [weak liveWords] in liveWords?.beginModelRemoval() },
      drain: { [weak liveWords] in await liveWords?.drainForModelRemoval() },
      end: { [weak liveWords] in liveWords?.endModelRemoval() })
  }

  /// The production wiring: both holders, and the executor's residency (the executor, not ARC,
  /// frees a transcribe.cpp model, and its free drains running native work first).
  static func install(
    on home: ModelDeliveryHome, dictation: LivePreviewCoordinator, meeting: MeetingLiveWords
  ) {
    install(
      on: home, holders: [Self.dictation(dictation), Self.meeting(meeting)],
      waitUntilNoneLoaded: { await TranscribeCppPreviewResidency.shared.waitUntilNoneLoaded() })
  }
}
