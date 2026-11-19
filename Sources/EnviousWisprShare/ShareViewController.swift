import AppKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
  private var operation: Progress?
  private var sending: (file: URL, transfer: SharedMediaTransfer)?
  private var started = false
  private var finished = false

  override func viewDidAppear() {
    super.viewDidAppear()
    guard !started, !finished else { return }
    started = true
    beginTransfer()
  }

  // Choosing the native Share action already confirms sending the file to the app.
  override func isContentValid() -> Bool { false }

  override func didSelectCancel() {
    if let sending, !sending.transfer.discardOffer(sending.file) {
      // The receiver has taken ownership. Allow the outstanding open to conclude.
      return
    }
    finish(error: CocoaError(.userCancelled))
  }

  private func beginTransfer() {
    guard let items = extensionContext?.inputItems, items.count == 1,
      let item = items.first as? NSExtensionItem,
      let attachments = item.attachments, attachments.count == 1,
      let provider = attachments.first,
      let type = provider.registeredTypeIdentifiers
        .compactMap({ UTType($0) })
        .first(where: { Self.canShare($0) }),
      let suffix = type.preferredFilenameExtension,
      let transfer = SharedMediaTransfer.live()
    else {
      fail()
      return
    }

    let receiver = Bundle.main.bundleURL
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let suggestion = provider.suggestedName
    let continueCopy: @MainActor (String?) -> Void = { [weak self] name in
      guard let self, !self.finished else { return }
      self.copyMedia(
        from: provider, type: type, suffix: suffix, name: name ?? suggestion,
        receiver: receiver, transfer: transfer)
    }
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
      continueCopy(nil)
      return
    }
    // Finder may omit suggestedName and name its temporary audio by type.
    // Use the companion URL for the label, then prefer the typed file copy.
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
      let url = (item as? URL) ?? (item as? Data).flatMap {
        URL(dataRepresentation: $0, relativeTo: nil)
      }
      let name = url?.isFileURL == true ? url?.lastPathComponent : nil
      Task { @MainActor in continueCopy(name) }
    }
  }

  private func copyMedia(
    from provider: NSItemProvider, type: UTType, suffix: String, name: String?,
    receiver: URL, transfer: SharedMediaTransfer
  ) {
    let deliver: @MainActor (URL?) -> Void = { [weak self] file in
      guard let self, !self.finished else {
        if let file { transfer.discardOffer(file) }
        return
      }
      guard let file else {
        self.fail()
        return
      }
      self.send(file, to: receiver, using: transfer)
    }
    let copyFile: @Sendable (URL) -> URL? = { source in
      try? transfer.offer(source, suffix: suffix, suggestedName: name, receiver: receiver)
    }
    let copyAsURL: @MainActor () -> Void = { [weak self] in
      guard let self, !self.finished else { return }
      // Voice Memos advertises M4A but grants readable file access through its URL object.
      self.operation = provider.loadObject(ofClass: URL.self) { source, error in
        guard error == nil, let source, source.isFileURL,
          UTType(filenameExtension: source.pathExtension)?.conforms(to: type) == true
        else {
          Task { @MainActor in deliver(nil) }
          return
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let file = copyFile(source)
        Task { @MainActor in deliver(file) }
      }
    }
    operation = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
      guard let source, error == nil else {
        Task { @MainActor in copyAsURL() }
        return
      }
      // The provider deletes this URL on return, so the copy must finish inside its callback.
      let file = copyFile(source)
      Task { @MainActor in deliver(file) }
    }
  }

  private func send(_ file: URL, to receiver: URL, using transfer: SharedMediaTransfer) {
    sending = (file, transfer)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.allowsRunningApplicationSubstitution = false
    configuration.addsToRecentItems = false
    NSWorkspace.shared.open([file], withApplicationAt: receiver, configuration: configuration) {
      [weak self] running, error in
      let delivered = error == nil
        && running?.bundleURL?.resolvingSymlinksInPath() == receiver.resolvingSymlinksInPath()
      if !delivered { transfer.discardOffer(file) }
      Task { @MainActor in
        if delivered {
          self?.finish(error: nil)
        } else {
          self?.fail()
        }
      }
    }
  }

  private func fail() {
    let message = NSLocalizedString("ShareAudioFailed", comment: "Share action could not hand off media")
    finish(error: CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: message]))
  }

  private func finish(error: (any Error)?) {
    guard !finished else { return }
    finished = true
    sending = nil
    operation?.cancel()
    operation = nil
    if let error {
      extensionContext?.cancelRequest(withError: error)
    } else {
      extensionContext?.completeRequest(returningItems: nil)
    }
  }

  private static func canShare(_ type: UTType) -> Bool {
    guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "EWSharedMediaTypes") as? [String]
    else { return false }
    return identifiers.compactMap { UTType($0) }.contains { type.conforms(to: $0) }
  }
}
