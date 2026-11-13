import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("Setup cloud panel", .tags(.productOutcome))
struct SetupCloudPanelTests {
  private static let sample = LLMModelInfo(
    id: "gpt-fixture", displayName: "Example model", provider: .openAI,
    availability: .available, isRemote: true)

  @Test("Explicit choice stays with its provider and becomes unusable when the credential changes")
  func selection() async throws {
    let fixture = Check()
    let model = makeModel(fixture)
    #expect(model.phase == .idle)
    model.edit("fixture")
    let task = try #require(model.check())
    try await BoundedWait.until(fixture.started)
    #expect(model.phase == .checking)
    fixture.progress?(.probingModels, 1)
    #expect(model.phase == .loading)
    model.provider = .gemini
    model.edit("another fixture")
    fixture.finish(.accepted(1, [Self.sample]))
    await task.value
    #expect(model.phase == .idle)
    #expect(model.key == "another fixture")
    model.provider = .openAI
    #expect(model.key == "fixture")
    #expect(model.phase == .picker)
    #expect(model.chosen == nil)
    model.select(Self.sample.id)
    #expect(model.chosen?.id == Self.sample.id)
    fixture.revision = 2
    #expect(model.chosen == nil)
    #expect(model.phase == .idle)
  }

  @Test("Light, dark and Reduce Motion render every cloud setup state")
  func renders() async throws {
    let fixture = Check()
    let model = makeModel(fixture)
    let folder = RepoRoot.url.appending(path: "build/design-render")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try render(model, "no-key", folder)
    model.edit("fixture")
    let rejected = try #require(model.check())
    try await BoundedWait.until(fixture.started)
    try render(model, "checking", folder)
    fixture.finish(.rejected(1))
    await rejected.value
    #expect(model.phase == .rejected)
    try render(model, "rejected", folder)
    fixture.started = BoundedWait.Signal()
    let accepted = try #require(model.check())
    try await BoundedWait.until(fixture.started)
    fixture.progress?(.probingModels, 1)
    try render(model, "loading-models", folder)
    fixture.finish(.accepted(1, [Self.sample]))
    await accepted.value
    try render(model, "picker", folder)
    model.select(Self.sample.id)
    try render(model, "chosen", folder)
    // The Ollama card is always present; capture it with the uncluttered empty form.
    model.provider = .gemini
    try render(model, "ollama-later", folder)
  }

  private func makeModel(_ fixture: Check) -> SetupCloudPanelModel {
    SetupCloudPanelModel(
      inputs: .init(
        hydrate: { _ in nil },
        check: { _, _, progress in await fixture.run(progress) },
        isCurrent: { _, revision in revision == fixture.revision },
        canChoose: { _, _, revision in revision == fixture.revision },
        list: { nil }))
  }

  private func render(_ model: SetupCloudPanelModel, _ name: String, _ folder: URL) throws {
    _ = NSApplication.shared
    let variants: [(String, ColorScheme, Bool)] = [
      ("light", .light, false), ("dark", .dark, false), ("reduce-motion", .light, true),
    ]
    for (variant, scheme, reduceMotion) in variants {
      let size = CGSize(width: SetupLayout.windowWidth, height: SetupLayout.contentHeight)
      let host = NSHostingView(
        rootView:
          SetupCloudPanel(model: model, onChoose: { _, _ in }, onLater: {}, onBack: {})
          .padding(SetupLayout.contentPadding)
          .frame(width: size.width, height: size.height)
          .background(Color.obCardBg)
          .environment(\.colorScheme, scheme)
          .environment(\.overlayReduceMotionOverride, reduceMotion)
      )
      host.frame = NSRect(origin: .zero, size: size)
      host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = host.appearance
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      #expect(rep.size == size)
      let data = try #require(rep.representation(using: .png, properties: [:]))
      try data.write(to: folder.appending(path: "setup-cloud-\(name)-\(variant).png"))
    }
  }

  @MainActor
  private final class Check {
    var started = BoundedWait.Signal()
    private var result: CheckedContinuation<SetupCloudPanelModel.Answer, Never>?
    var progress: LLMModelDiscoveryCoordinator.SetupProgress?
    var revision: UInt64 = 1

    func run(_ progress: @escaping LLMModelDiscoveryCoordinator.SetupProgress) async
      -> SetupCloudPanelModel.Answer
    {
      await withCheckedContinuation {
        result = $0
        self.progress = progress
        started.fire()
      }
    }

    func finish(_ answer: SetupCloudPanelModel.Answer) {
      let waiting = result
      result = nil
      waiting?.resume(returning: answer)
    }
  }
}
