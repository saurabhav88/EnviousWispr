import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// Issue #1286 Phase 2 — locks the single at-a-glance status authority
/// `ProviderStatusMapping.status`. Two contracts:
///   1. Each engine maps its OWN coordinator states to the right (label, tone).
///   2. Provider-first, no cross-provider leak: a coordinator state that is
///      "blocking" for one engine must not change another engine's result
///      (a cloud key state never reaches the EG-1/Apple/Ollama branch, etc.).
@Suite("ProviderStatusMapping — one status authority, no cross-provider leak")
struct ProviderStatusMappingTests {

  // Neutral "everything nominal" inputs for the engines NOT under test, so a
  // per-engine assertion isolates the one coordinator that should matter.
  private func status(
    for provider: LLMProvider,
    egOneInstall: EGOneModelStore.InstallState = .installed(version: "1"),
    egOneHealth: EGOneHealth = .green,
    appleStatus: AIAvailabilityStatus? = .available,
    cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState = .valid,
    ollamaSetup: OllamaSetupState = .ready
  ) -> ProviderStatus {
    ProviderStatusMapping.status(
      for: provider,
      egOneInstall: egOneInstall,
      egOneHealth: egOneHealth,
      appleStatus: appleStatus,
      cloudValidation: cloudValidation,
      ollamaSetup: ollamaSetup)
  }

  // MARK: - EG-1 (install lifecycle first, health once installed)

  @Test("EG-1 not installed → Not installed / needs-setup")
  func egOneNotInstalled() {
    let s = status(for: .egOne, egOneInstall: .notInstalled)
    #expect(s.label == "Not installed")
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 downloading → Downloading / needs-setup")
  func egOneDownloading() {
    let s = status(for: .egOne, egOneInstall: .downloading(fractionCompleted: 0.4))
    #expect(s.label == "Downloading")
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 verifying → Verifying / needs-setup")
  func egOneVerifying() {
    let s = status(for: .egOne, egOneInstall: .verifying)
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 download failed → error")
  func egOneFailed() {
    let s = status(for: .egOne, egOneInstall: .failed(.network))
    #expect(s.tone == .error)
  }

  @Test("EG-1 installed + green → Live / ready")
  func egOneLive() {
    let s = status(for: .egOne, egOneInstall: .installed(version: "1"), egOneHealth: .green)
    #expect(s.label == "Live")
    #expect(s.tone == .ready)
  }

  @Test("EG-1 installed + yellow → Starting / needs-setup")
  func egOneStarting() {
    let s = status(
      for: .egOne, egOneInstall: .installed(version: "1"),
      egOneHealth: .yellow(reason: "starting"))
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 installed + red → Not working / error")
  func egOneNotWorking() {
    let s = status(
      for: .egOne, egOneInstall: .installed(version: "1"),
      egOneHealth: .red(reason: "crashed_twice"))
    #expect(s.label == "Not working")
    #expect(s.tone == .error)
  }

  // MARK: - Apple Intelligence

  @Test("Apple available → ready")
  func appleAvailable() {
    #expect(status(for: .appleIntelligence, appleStatus: .available).tone == .ready)
  }

  @Test("Apple degraded/unavailable/unknown/nil → unavailable tone")
  func appleNonReady() {
    #expect(status(for: .appleIntelligence, appleStatus: .degraded).tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: .unavailable).tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: .unknown).tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: nil).tone == .unavailable)
  }

  // MARK: - Cloud (OpenAI / Gemini share the mapping)

  @Test("Cloud valid → Key valid / ready")
  func cloudValid() {
    for p in [LLMProvider.openAI, .gemini] {
      let s = status(for: p, cloudValidation: .valid)
      #expect(s.label == "Key valid")
      #expect(s.tone == .ready)
    }
  }

  @Test("Cloud validating → needs-setup")
  func cloudValidating() {
    #expect(status(for: .openAI, cloudValidation: .validating).tone == .needsSetup)
  }

  @Test("Cloud idle → Key needed / needs-setup")
  func cloudIdle() {
    let s = status(for: .gemini, cloudValidation: .idle)
    #expect(s.label == "Key needed")
    #expect(s.tone == .needsSetup)
  }

  @Test("Cloud invalid → Key needed / error")
  func cloudInvalid() {
    let s = status(for: .openAI, cloudValidation: .invalid("bad key"))
    #expect(s.label == "Key needed")
    #expect(s.tone == .error)
  }

  // MARK: - Ollama

  @Test("Ollama ready → Running / ready")
  func ollamaRunning() {
    let s = status(for: .ollama, ollamaSetup: .ready)
    #expect(s.label == "Running")
    #expect(s.tone == .ready)
  }

  @Test("Ollama not-installed/not-running/no-model/pulling/detecting → needs-setup")
  func ollamaNeedsSetup() {
    #expect(status(for: .ollama, ollamaSetup: .detecting).tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .notInstalled).tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .installedNotRunning).tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .runningNoModels).tone == .needsSetup)
    #expect(
      status(for: .ollama, ollamaSetup: .pullingModel(progress: 0.2, status: "x")).tone
        == .needsSetup)
  }

  @Test("Ollama error → error")
  func ollamaError() {
    #expect(status(for: .ollama, ollamaSetup: .error("boom")).tone == .error)
  }

  // MARK: - No cross-provider leak

  @Test("A blocking cloud key state does NOT change EG-1/Apple/Ollama results")
  func cloudStateDoesNotLeak() {
    // Cloud is .invalid (an error state) but the OTHER engines are nominal.
    #expect(
      status(for: .egOne, cloudValidation: .invalid("x")).tone == .ready,
      "EG-1 stays Live regardless of a broken cloud key")
    #expect(
      status(for: .appleIntelligence, cloudValidation: .invalid("x")).tone == .ready,
      "Apple stays Available regardless of a broken cloud key")
    #expect(
      status(for: .ollama, cloudValidation: .invalid("x")).tone == .ready,
      "Ollama stays Running regardless of a broken cloud key")
  }

  @Test("A blocking EG-1 state does NOT change cloud/Apple/Ollama results")
  func egOneStateDoesNotLeak() {
    #expect(
      status(for: .openAI, egOneInstall: .notInstalled).tone == .ready,
      "OpenAI stays Key valid regardless of EG-1 not being installed")
    #expect(
      status(for: .appleIntelligence, egOneHealth: .red(reason: "x")).tone == .ready,
      "Apple stays Available regardless of EG-1 health")
    #expect(
      status(for: .ollama, egOneInstall: .notInstalled).tone == .ready,
      "Ollama stays Running regardless of EG-1 not being installed")
  }

  @Test("Off provider → neutral, never a real engine status")
  func offProvider() {
    #expect(status(for: .none).tone == .unavailable)
  }
}
