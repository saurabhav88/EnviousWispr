import AppKit
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// When these fail, the saved switch can claim a transcription mode the selected language cannot use.
@MainActor
@Suite("Faster Transcription settings (#3809)", .tags(.productOutcome))
struct FasterTranscriptionSettingsTests {
  init() { _ = NSApplication.shared }

  private func freshStore(sourceLocation: SourceLocation = #_sourceLocation) throws -> UserDefaults {
    try #require(
      TestDefaults.suite("ew.fasterTranscriptionTests." + UUID().uuidString),
      sourceLocation: sourceLocation)
  }

  private func freshWriteStore(sourceLocation: SourceLocation = #_sourceLocation) throws -> StreamingWriteStore {
    let name = "ew.fasterTranscriptionWrites." + UUID().uuidString
    // TestDefaults registers cleanup before the counting view opens the SAME owned suite.
    _ = try #require(TestDefaults.suite(name), sourceLocation: sourceLocation)
    try #require(TestDefaults.registeredSuiteNames.contains(name), sourceLocation: sourceLocation)
    let store = try #require(StreamingWriteStore(suiteName: name), sourceLocation: sourceLocation)
    store.set(false, forKey: "useStreamingASR")
    try #require(
      store.takeStreamingWrites() == [false], "The witness must intercept a real write",
      sourceLocation: sourceLocation)
    return store
  }

  @Test("Whisper with Auto refuses an ON preference")
  func autoRefusesOn() throws {
    let store = try freshStore()
    let settings = SettingsManager(defaults: store)
    settings.selectedBackend = .whisper
    settings.languageMode = .auto

    settings.useStreamingASR = true

    #expect(settings.useStreamingASR == false)
    #expect(store.object(forKey: "useStreamingASR") as? Bool == false)
  }

  @Test("Returning Whisper to Auto saves the switch as OFF")
  func returningToAutoTurnsOff() throws {
    let store = try freshStore()
    let settings = SettingsManager(defaults: store)
    settings.selectedBackend = .whisper
    settings.languageMode = .locked("en")
    settings.useStreamingASR = true
    try #require(settings.useStreamingASR == true)

    settings.languageMode = .auto

    #expect(settings.useStreamingASR == false)
    #expect(store.object(forKey: "useStreamingASR") as? Bool == false)
  }

  @Test("An old Whisper Auto ON preference is repaired on load")
  func incompatibleSavedOnIsRepaired() throws {
    let store = try freshStore()
    store.set("whisper", forKey: "selectedBackend")
    store.set(try JSONEncoder().encode(LanguageMode.auto), forKey: "languageMode")
    store.set(true, forKey: "useStreamingASR")

    let settings = SettingsManager(defaults: store)

    #expect(settings.selectedBackend == .whisper)
    #expect(settings.languageMode == .auto)
    #expect(settings.useStreamingASR == false)
    #expect(store.object(forKey: "useStreamingASR") as? Bool == false)
  }

  @Test("Compatible saved ON choices survive loading")
  func compatibleSavedOnSurvives() throws {
    let cases: [(ASRBackendType, LanguageMode)] = [
      (.parakeet, .auto), (.parakeet, .locked("de")), (.whisper, .locked("en")),
    ]
    for (backend, language) in cases {
      let store = try freshStore()
      store.set(backend.rawValue, forKey: "selectedBackend")
      store.set(try JSONEncoder().encode(language), forKey: "languageMode")
      store.set(true, forKey: "useStreamingASR")

      let settings = SettingsManager(defaults: store)

      #expect(settings.useStreamingASR == true, "Compatible choice for \(backend) was cleared")
      #expect(store.object(forKey: "useStreamingASR") as? Bool == true)
    }
  }

  @Test("Selecting a language or returning to Parakeet does not restore ON")
  func eligibleAgainStaysOff() throws {
    let store = try freshStore()
    let settings = SettingsManager(defaults: store)
    settings.selectedBackend = .parakeet
    settings.languageMode = .auto
    settings.useStreamingASR = true

    settings.selectedBackend = .whisper
    #expect(settings.useStreamingASR == false)
    settings.selectedBackend = .parakeet
    #expect(settings.useStreamingASR == false)
    settings.selectedBackend = .whisper
    settings.languageMode = .locked("de")
    #expect(settings.useStreamingASR == false)

    settings.useStreamingASR = true
    #expect(settings.useStreamingASR == true)
    #expect(SettingsManager(defaults: store).useStreamingASR == true)
  }

  @Test("Compatible engine changes preserve the shared ON choice")
  func compatibleSwitchKeepsOn() throws {
    let settings = SettingsManager(defaults: try freshStore())
    settings.selectedBackend = .whisper
    settings.languageMode = .locked("de")
    settings.useStreamingASR = true

    settings.selectedBackend = .parakeet
    #expect(settings.useStreamingASR == true)
    settings.selectedBackend = .whisper
    #expect(settings.useStreamingASR == true)
  }

  @Test("A stale saved language becomes Auto and clears incompatible ON")
  func invalidSavedLanguageUsesAuto() throws {
    let store = try freshStore()
    store.set("whisper", forKey: "selectedBackend")
    store.set(try JSONEncoder().encode(LanguageMode.locked("retired-language")), forKey: "languageMode")
    store.set(true, forKey: "useStreamingASR")

    let settings = SettingsManager(defaults: store)

    #expect(settings.languageMode == .auto)
    #expect(settings.useStreamingASR == false)
    #expect(store.object(forKey: "useStreamingASR") as? Bool == false)
    #expect(SettingsManager(defaults: store).useStreamingASR == false)
  }

  @Test("Default OFF stays unseeded when prerequisites change")
  func missingOffKeyIsNotSeeded() throws {
    let store = try freshStore()
    let settings = SettingsManager(defaults: store)
    #expect(settings.useStreamingASR == false)
    #expect(store.object(forKey: "useStreamingASR") == nil)

    settings.selectedBackend = .whisper
    settings.languageMode = .auto
    #expect(store.object(forKey: "useStreamingASR") == nil)
    settings.languageMode = .locked("en")
    #expect(settings.useStreamingASR == false)
    #expect(store.object(forKey: "useStreamingASR") == nil)
  }

  @Test("An invalid direct ON assignment persists and notifies exactly once")
  func directCorrectionHasOneWriteAndNotification() throws {
    let store = try freshWriteStore()
    let settings = SettingsManager(defaults: store)
    settings.selectedBackend = .whisper
    settings.languageMode = .auto
    try #require(store.takeStreamingWrites().isEmpty)

    var notifications: [SettingsManager.SettingKey] = []
    var observedValues: [Bool] = []
    settings.onChange = { [weak settings] key in
      notifications.append(key)
      observedValues.append(settings?.useStreamingASR ?? true)
    }
    defer { settings.onChange = nil }

    for _ in 0..<2 {
      notifications.removeAll()
      observedValues.removeAll()
      settings.useStreamingASR = true

      #expect(store.takeStreamingWrites() == [false], "Duplicate persistence violates E1")
      #expect(notifications.count == 1, "A repeated notification violates E1")
      #expect(notifications.first == .useStreamingASR)
      #expect(observedValues == [false])
      #expect(store.object(forKey: "useStreamingASR") as? Bool == false)
    }

    settings.languageMode = .locked("en")
    for nextValue in [true, false] {
      _ = store.takeStreamingWrites()
      notifications.removeAll()
      observedValues.removeAll()
      settings.useStreamingASR = nextValue

      #expect(store.takeStreamingWrites() == [nextValue])
      #expect(notifications.count == 1)
      #expect(notifications.first == .useStreamingASR)
      #expect(observedValues == [nextValue])
    }
  }

  @Test("Prerequisite callbacks observe the already-normalized tuple")
  func originCallbacksSeeOff() throws {
    for changedLanguage in [true, false] {
      let store = try freshWriteStore()
      let settings = SettingsManager(defaults: store)
      settings.selectedBackend = changedLanguage ? .whisper : .parakeet
      settings.languageMode = changedLanguage ? .locked("en") : .auto
      settings.useStreamingASR = true
      try #require(settings.useStreamingASR == true)
      _ = store.takeStreamingWrites()
      var notifications: [SettingsManager.SettingKey] = []
      var observedValues: [Bool] = []
      var persistedValues: [Bool?] = []
      settings.onChange = { [weak settings] key in
        notifications.append(key)
        observedValues.append(settings?.useStreamingASR ?? true)
        persistedValues.append(store.object(forKey: "useStreamingASR") as? Bool)
      }

      if changedLanguage { settings.languageMode = .auto }
      else { settings.selectedBackend = .whisper }
      settings.onChange = nil

      #expect(store.takeStreamingWrites() == [false])
      #expect(notifications.count == 2)
      #expect(notifications.first == .useStreamingASR)
      #expect(notifications.last == (changedLanguage ? .languageMode : .selectedBackend))
      #expect(observedValues == [false, false])
      #expect(persistedValues == [false, false])
      #expect(SettingsManager(defaults: store).useStreamingASR == false)
    }
  }
}

/// Observes real typed Bool persistence calls, not defaults-change notifications or a fake setter.
private final class StreamingWriteStore: UserDefaults, @unchecked Sendable {
  private let writesLock = NSLock()
  private var streamingWrites: [Bool] = []

  override func set(_ value: Bool, forKey defaultName: String) {
    if defaultName == "useStreamingASR" {
      writesLock.lock()
      streamingWrites.append(value)
      writesLock.unlock()
    }
    super.set(value, forKey: defaultName)
  }

  func takeStreamingWrites() -> [Bool] {
    writesLock.lock()
    defer { writesLock.unlock() }
    let result = streamingWrites
    streamingWrites.removeAll()
    return result
  }
}
