import AppKit
import EnviousWisprAudio
import Foundation
import UniformTypeIdentifiers

/// #4799: History's Save audio, from the press to what the user sees.
///
/// One save of one item: claim it, ask where to save, have the source owner admit a snapshot,
/// stage the file next to the destination off the main actor, then on the main actor check the
/// source and the destination again and publish with no suspension in between. Success shows
/// the file in Finder; every failure after the panel was confirmed shows one alert owned here,
/// never by the view that started it (History rows are reused table cells). Only cancelling the
/// panel, and quitting before the save finished, are silent. Source owners answer only "is this
/// still the recording the user chose"; this owner decides everything else.
///
/// Built once by `WisprBootstrapper`; both automatic retention sweeps read `isExporting` so they
/// never remove audio that is being saved.
@MainActor
@Observable
final class HistoryAudioExport {
  /// The item being saved.
  enum Key: Hashable, Sendable {
    case dictation(UUID)
    case meeting(UUID)
  }

  /// What the source owner admitted: a finished file to copy, or tracks to mix.
  enum Source: Sendable {
    case file(URL)
    case meeting(files: MeetingPlaybackController.TrackFiles, durationMs: Int)
  }

  /// The source owner's answer at commit.
  enum SourceCheck: Sendable, Equatable {
    case deliverable
    /// Deleted since it was admitted (by the user, Delete All or retention).
    case deleted
    /// Still there, but no longer the audio that was admitted.
    case changed
  }

  /// One press of Save audio, as the surface that started it describes it.
  struct Request {
    let key: Key
    /// The name the save panel suggests, without an extension.
    let defaultName: String
    /// Runs after the panel closes; nil when the item has no audio to save any more.
    let admit: @MainActor () async -> Source?
    /// Runs at commit with no suspension before the publish.
    let check: @MainActor () -> SourceCheck
    /// The window the save was started from, read when an alert is shown; nil when it closed
    /// (the alert then uses the main window).
    var window: @MainActor () -> NSWindow? = { nil }
  }

  /// What the user is told after the panel was confirmed.
  enum Notice: Equatable {
    case unavailable
    case deleted
    case changed
    case targetChanged
    case partlySilent
    case failed(detail: String?)
  }

  /// How one save ended, for tests and the caller's own bookkeeping.
  enum Outcome: Equatable {
    case alreadySaving
    case cancelled
    case saved(URL)
    case notSaved(Notice)
    /// Stopped (a quit) before anything was published.
    case abandoned
  }

  /// The side effects a save has outside the app, replaced in tests (no panel, no Finder, no
  /// alert window on the desktop).
  struct Effects {
    var chooseURL: @MainActor (_ defaultName: String) -> URL?
    var reveal: @MainActor (_ url: URL) -> Void
    var notify: @MainActor (_ notice: Notice, _ window: NSWindow?) -> Void
    /// A new, empty staging folder on the destination's volume; called off the main actor.
    var makeStagingDirectory: @Sendable (_ destination: URL) throws -> URL = Effects.stagingDirectory
    /// Replaces the approved file with the staged one; returns the file's URL afterwards.
    var replace: @MainActor (_ destination: URL, _ staged: URL) throws -> URL = Effects.replaceFile

    static let live = Effects(
      chooseURL: { HistoryDelivery.chooseSaveURL(defaultName: $0, types: [HistoryAudioExport.m4aType]) },
      reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
      notify: { HistoryAudioExport.presentAlert($0, on: $1) })

    /// The system's replacement folder for `destination`'s volume.
    @Sendable static func stagingDirectory(_ destination: URL) throws -> URL {
      try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
        create: true)
    }

    /// Foundation's safe replacement: the new file takes its own metadata (0644), not the old
    /// file's.
    static func replaceFile(_ destination: URL, _ staged: URL) throws -> URL {
      try FileManager.default.replaceItemAt(
        destination, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
        ?? destination
    }
  }

  /// The save panel's one type. `UTType.mpeg4Audio` (public.mpeg-4-audio) prefers ".mp4", so
  /// the panel would suggest "Dictation.mp4" (Live UAT, #4799); the M4A type prefers ".m4a".
  static let m4aType = UTType(filenameExtension: "m4a") ?? .mpeg4Audio

  private(set) var inFlight: Set<Key> = []
  @ObservationIgnored private var tasks: [Key: Task<Outcome, Never>] = [:]
  /// Set at quit: no new save starts.
  @ObservationIgnored private var closed = false
  @ObservationIgnored private let effects: Effects

  init(effects: Effects = .live) {
    self.effects = effects
  }

  /// Whether `key` is being saved now: menus show it as busy and retention skips it.
  func isExporting(_ key: Key) -> Bool { inFlight.contains(key) }

  /// Starts one save; nil when this item is already being saved (a press from a menu opened
  /// before the claim). The claim is taken before the panel opens and released on every exit.
  @discardableResult
  func save(_ request: Request) -> Task<Outcome, Never>? {
    guard !closed, !inFlight.contains(request.key) else { return nil }
    inFlight.insert(request.key)
    let task = Task { [self] in
      defer {
        inFlight.remove(request.key)
        tasks[request.key] = nil
      }
      return await run(request)
    }
    tasks[request.key] = task
    return task
  }

  /// At quit: no new save starts, and every save in flight stops without publishing or
  /// telling anyone. Not awaited (the quit does not wait for audio work); a stopped save never
  /// touches the destination, since publishing is its last step.
  func cancelAll() {
    closed = true
    for task in tasks.values { task.cancel() }
  }

  private func run(_ request: Request) async -> Outcome {
    let feedback = await prepareAndPublish(request)
    // Staging is gone before the user hears anything (`prepareAndPublish` removes it).
    switch feedback {
    case .saved(let url, let partlySilent):
      effects.reveal(url)
      if partlySilent { effects.notify(.partlySilent, request.window()) }
      return .saved(url)
    case .notSaved(let notice):
      effects.notify(notice, request.window())
      return .notSaved(notice)
    case .originalLeftAside(let notice, let original):
      // The user's own file could not go back to its place: show them where it is.
      effects.notify(notice, request.window())
      effects.reveal(original)
      return .notSaved(notice)
    case .silent(let outcome):
      return outcome
    }
  }

  /// How a save ended, before the user is told.
  private enum Feedback {
    case saved(URL, partlySilent: Bool)
    case notSaved(Notice)
    /// A failed Replace left the user's original at this place.
    case originalLeftAside(Notice, URL)
    case silent(Outcome)
  }

  private func prepareAndPublish(_ request: Request) async -> Feedback {
    // A quit can land at any await: checked before the panel, after it and after admission,
    // so a stopped save never opens a panel or speaks.
    if Task.isCancelled { return .silent(.abandoned) }
    guard let destination = effects.chooseURL(request.defaultName) else {
      return .silent(Task.isCancelled ? .abandoned : .cancelled)
    }
    if Task.isCancelled { return .silent(.abandoned) }
    // The URL the user confirmed is kept exactly; the panel allows only M4A.
    guard destination.pathExtension.lowercased() == "m4a" else {
      return .notSaved(.failed(detail: nil))
    }
    // The file the user agreed to replace, if any: only that file may be replaced.
    let approved = DictationRecordings.FileStamp.read(destination)
    let admitted = await request.admit()
    if Task.isCancelled { return .silent(.abandoned) }
    guard let source = admitted else { return .notSaved(.unavailable) }

    let staged: Staged
    let makeDirectory = effects.makeStagingDirectory
    // Detached, not `Task {}`: this type is @MainActor and a plain Task inherits it; staging
    // copies or encodes the whole recording. Awaited at once; a quit's cancel is forwarded so
    // the encoder stops between windows and removes its output.
    let worker = Task.detached(priority: .userInitiated) {
      try Self.stage(source, near: destination, makeDirectory: makeDirectory)
    }
    do {
      staged = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
    } catch is CancellationError {
      return .silent(.abandoned)
    } catch {
      if Task.isCancelled { return .silent(.abandoned) }
      // A read that failed because the recording was deleted or rebuilt meanwhile says so.
      switch request.check() {
      case .deleted: return .notSaved(.deleted)
      case .changed: return .notSaved(.changed)
      case .deliverable: return .notSaved(.failed(detail: Self.detail(error)))
      }
    }

    // From here to the publish there is no suspension: a deletion cannot land in between.
    var keepStaging = false
    defer { if !keepStaging { try? FileManager.default.removeItem(at: staged.directory) } }
    if Task.isCancelled { return .silent(.abandoned) }
    switch request.check() {
    case .deliverable: break
    case .deleted: return .notSaved(.deleted)
    case .changed: return .notSaved(.changed)
    }
    if let approved {
      guard DictationRecordings.FileStamp.read(destination) == approved else {
        return .notSaved(.targetChanged)
      }
      do {
        return .saved(try effects.replace(destination, staged.file), partlySilent: staged.partlySilent)
      } catch {
        // A failed replacement can leave the user's file moved aside; if it cannot be put
        // back, the staging folder (where it may sit) is kept rather than deleted.
        let notice = Notice.failed(detail: Self.detail(error))
        guard let original = Self.restoreDisplacedOriginal(after: error, at: destination) else {
          return .notSaved(notice)
        }
        // Kept only while the original is still inside the staging folder.
        keepStaging = original.standardizedFileURL.path.hasPrefix(
          staged.directory.standardizedFileURL.path)
        return .originalLeftAside(notice, original)
      }
    }
    do {
      // Never overwrites: a file that appeared meanwhile makes this fail.
      try FileManager.default.moveItem(at: staged.file, to: destination)
      return .saved(destination, partlySilent: staged.partlySilent)
    } catch {
      return .notSaved(.failed(detail: Self.detail(error)))
    }
  }

  // MARK: - Staging (off the main actor)

  /// The finished file in its own staging folder on the destination's volume.
  struct Staged: Sendable {
    let directory: URL
    let file: URL
    /// A listed meeting file could not be read; its stretch is silent, as in playback.
    let partlySilent: Bool
  }

  enum StagingError: Error, Equatable {
    /// The staged file did not take normal user file permissions.
    case permissions
  }

  /// Copies or mixes the source into a new file beside the destination. Removes its staging
  /// folder on every failure; on success the caller owns it.
  nonisolated static func stage(
    _ source: Source, near destination: URL,
    makeDirectory: @Sendable (URL) throws -> URL
  ) throws -> Staged {
    let fm = FileManager.default
    let directory = try makeDirectory(destination)
    do {
      let file = directory.appendingPathComponent(destination.lastPathComponent)
      var partlySilent = false
      switch source {
      case .file(let url):
        try fm.copyItem(at: url, to: file)
      case .meeting(let files, let durationMs):
        let tracks = try MeetingPlaybackController.load(files)
        partlySilent = tracks.contains { track in
          track.problems.contains {
            switch $0 {
            case .unreadable, .incompatibleFormat, .empty: return true
            case .overlap: return false
            }
          }
        }
        let frames = Int64(durationMs) * Int64(MeetingPlaybackController.samplesPerMs)
        _ = try SpeechAudioEncoder.encode(frames: frames, purpose: .meeting, to: file) {
          offset, count in
          try MeetingPlaybackController.mixSamples(tracks, start: Int(offset), count: count)
        }
      }
      try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      let mode = (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
        .intValue
      guard mode == 0o644 else { throw StagingError.permissions }
      return Staged(directory: directory, file: file, partlySilent: partlySilent)
    } catch {
      try? fm.removeItem(at: directory)
      throw error
    }
  }

  /// A failed `replaceItemAt` can leave the user's original moved aside, at the location its
  /// error names (`MeetingStore.originalItemLocationKey`): put it back, so a failed save never
  /// loses the file the user had. Never overwrites a file that took the destination meanwhile:
  /// then the original goes beside it, as "<name> (original).m4a" (numbered only when that
  /// name is taken), where the user can find it. Nil when nothing is left aside; otherwise the
  /// place the original is now (beside the destination, or where Foundation left it when that
  /// folder takes no new file), which the caller must not delete and shows the user.
  @discardableResult
  nonisolated static func restoreDisplacedOriginal(after error: any Error, at destination: URL)
    -> URL?
  {
    let fm = FileManager.default
    let info = (error as NSError).userInfo
    guard let moved = info["NSFileOriginalItemLocationKey"] as? URL,
      fm.fileExists(atPath: moved.path)
    else { return nil }
    if (try? fm.moveItem(at: moved, to: destination)) != nil { return nil }
    let folder = destination.deletingLastPathComponent()
    let stem = destination.deletingPathExtension().lastPathComponent
    for attempt in 1...20 {
      let suffix = attempt == 1 ? " (original)" : " (original \(attempt))"
      let beside = folder.appendingPathComponent(stem + suffix)
        .appendingPathExtension(destination.pathExtension)
      if fm.fileExists(atPath: beside.path) { continue }
      if (try? fm.moveItem(at: moved, to: beside)) != nil { return beside }
      // The folder takes no new file: leave the original where it is.
      break
    }
    return moved
  }

  /// Foundation's own sentence for a file-system failure (#3908); nothing for the rest.
  nonisolated private static func detail(_ error: any Error) -> String? {
    (error as NSError).domain == NSCocoaErrorDomain ? error.localizedDescription : nil
  }

  // MARK: - Alerts

  /// The alert text for `notice`.
  static func message(_ notice: Notice) -> (title: String, detail: String?) {
    switch notice {
    case .unavailable:
      return (
        String(
          localized: "This recording is no longer available.",
          comment: "History Save audio alert: the recording was removed before saving started."),
        nil
      )
    case .deleted:
      return (
        String(
          localized: "The recording was deleted before it finished saving.",
          comment: "History Save audio alert: the recording was deleted while it was being saved."),
        nil
      )
    case .changed:
      return (
        String(
          localized: "The recording changed while saving. Try again.",
          comment: "History Save audio alert: the recording was rebuilt while it was being saved."),
        nil
      )
    case .targetChanged:
      return (
        String(
          localized: "The file you chose to replace changed. Save again.",
          comment:
            "History Save audio alert: the existing file the user chose to replace was changed by something else."
        ),
        nil
      )
    case .partlySilent:
      return (
        String(
          localized: "Part of this recording couldn't be read, so it is silent in the saved file.",
          comment: "History Save audio alert after saving: some recorded audio could not be read."),
        nil
      )
    case .failed(let detail):
      return (
        String(
          localized: "EnviousWispr couldn't save the audio.",
          comment: "History Save audio alert: saving the audio failed."),
        detail
      )
    }
  }

  /// The alert on the window the save started from, else the main window, else on its own:
  /// it never depends on the row that started the save still being there.
  static func presentAlert(_ notice: Notice, on window: NSWindow?) {
    let text = message(notice)
    let alert = NSAlert()
    alert.alertStyle = notice == .partlySilent ? .informational : .warning
    alert.messageText = text.title
    if let detail = text.detail { alert.informativeText = detail }
    if let host = [window, NSApp.mainWindow].compactMap({ $0 }).first(where: \.isVisible) {
      alert.beginSheetModal(for: host)
    } else {
      alert.runModal()
    }
  }
}

// MARK: - History surfaces

extension HistoryAudioExport {
  /// The Save audio row every History More menu uses (#4799): nil when the item has no audio
  /// to save, a disabled "Saving audio…" while this item is being saved, else "Save audio…".
  /// Read when the menu opens, as every More menu is built.
  func menuItem(_ key: Key, offered: Bool, start: @escaping () -> Void) -> HistoryMenuItem? {
    guard offered else { return nil }
    if isExporting(key) {
      return HistoryMenuItem(
        id: "save-audio", title: Self.savingTitle, systemImage: "waveform", isEnabled: false,
        kind: .action {})
    }
    return HistoryMenuItem(
      id: "save-audio", title: Self.saveTitle, systemImage: "waveform", kind: .action(start))
  }

  /// A dictation card's row: offered only while its recording is available.
  func dictationMenuItem(
    rowID: UUID, status: DictationRecordingStatus?, start: @escaping () -> Void
  ) -> HistoryMenuItem? {
    let available: Bool
    if case .available = status { available = true } else { available = false }
    return menuItem(.dictation(rowID), offered: available, start: start)
  }

  /// A meeting's row, one rule for the card and the page: offered only while the meeting owner
  /// would admit a Save audio now, and (on the page) no other meeting action is starting.
  func meetingMenuItem(
    meetingID: UUID, meetings: MeetingCoordinator, actionInFlight: Bool = false,
    start: @escaping () -> Void
  ) -> HistoryMenuItem? {
    menuItem(
      .meeting(meetingID),
      offered: !actionInFlight && meetings.audioExportSnapshot(meetingID: meetingID) != nil,
      start: start)
  }

  static var saveTitle: String {
    String(
      localized: "Save audio…",
      comment: "History More menu: saves this item's recording as an audio file.")
  }

  static var savingTitle: String {
    String(
      localized: "Saving audio…",
      comment: "History More menu, disabled: this item's recording is being saved as a file.")
  }

  /// One dictation's Save audio: the recording owner admits it after the panel and answers the
  /// commit check against the same snapshot.
  static func dictation(
    rowID: UUID, defaultName: String, recordings: DictationRecordings,
    window: @escaping @MainActor () -> NSWindow?
  ) -> Request {
    let held = Held<DictationRecordings.ExportSnapshot>()
    return Request(
      key: .dictation(rowID), defaultName: defaultName,
      admit: {
        held.value = await recordings.exportSnapshot(rowID: rowID)
        return held.value.map { .file($0.url) }
      },
      check: {
        guard let snapshot = held.value else { return .deleted }
        return sourceCheck(recordings.isStillDeliverable(snapshot))
      },
      window: window)
  }

  /// One meeting's Save audio: the same snapshot rule the card's and the page's menus offer
  /// it by, taken again after the panel and compared at commit.
  static func meeting(
    meetingID: UUID, defaultName: String, meetings: MeetingCoordinator,
    window: @escaping @MainActor () -> NSWindow?
  ) -> Request {
    let held = Held<MeetingAudioExportSnapshot>()
    return Request(
      key: .meeting(meetingID), defaultName: defaultName,
      admit: {
        held.value = meetings.audioExportSnapshot(meetingID: meetingID)
        return held.value.map { .meeting(files: $0.trackFiles, durationMs: $0.durationMs) }
      },
      check: {
        guard let snapshot = held.value else { return .deleted }
        if meetings.audioExportSnapshot(meetingID: meetingID) == snapshot { return .deliverable }
        // A removal under way or done (the owner's live intent, before the saved record
        // changes): deleted. Otherwise its audio changed (recovery rebuilt the inventory).
        return meetings.isAudioRemovalUnderway(meetingID: meetingID) ? .deleted : .changed
      },
      window: window)
  }

  static func sourceCheck(_ check: DictationRecordings.ExportCheck) -> SourceCheck {
    switch check {
    case .deliverable: return .deliverable
    case .deleted: return .deleted
    case .changed: return .changed
    }
  }

  /// The snapshot one request admitted, read again by its commit check.
  @MainActor final class Held<Value> {
    var value: Value?
  }
}
