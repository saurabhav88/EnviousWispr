import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Testing

@testable import EnviousWisprAppKit

/// #2772 finding 7a — the Polish step let a user press Continue with a cloud engine
/// selected and no key saved. The wizard moved on, the run started, and polish was skipped
/// in silence. Founder: "right now, I don't have an OpenAI key selected but it's acting
/// like it's working."
///
/// **Product coverage, not a drift guard.** What fails here is a person pressing a button
/// that promises cleanup and receiving none.
@Suite("Transcribe a File polish gate (#2772)", .tags(.productOutcome))
struct FileImportPolishGateTests {

  /// Everything the gate reads, with the values that mean "healthy" so each test can name
  /// only the one fact it is about.
  private static func readiness(
    provider: LLMProvider,
    savedKey: FileImportSavedKeyState = .present,
    hasUnsavedKeyDraft: Bool = false,
    keyValidation: LLMModelDiscoveryCoordinator.KeyValidationState = .idle,
    egOneInstall: EGOneInstallState = .installed(version: "1.1"),
    egOneHealth: EGOneHealth = .green,
    s1MiniInstall: EGOneInstallState = .installed(version: "1.0"),
    s1MiniHealth: EGOneHealth = .green,
    appleStatus: AIAvailabilityStatus? = .available,
    ollamaSetup: OllamaSetupState = .ready,
    ollamaModelIsArmed: Bool = true
  ) -> FileImportPolishReadiness {
    FileImportPolishGate.readiness(
      provider: provider, savedKey: savedKey, hasUnsavedKeyDraft: hasUnsavedKeyDraft,
      keyValidation: keyValidation,
      egOneInstall: egOneInstall, egOneHealth: egOneHealth,
      s1MiniInstall: s1MiniInstall, s1MiniHealth: s1MiniHealth,
      appleStatus: appleStatus, ollamaSetup: ollamaSetup,
      ollamaModelIsArmed: ollamaModelIsArmed)
  }

  /// The finding itself, on all three cloud engines rather than the one the founder had
  /// selected.
  @Test("a cloud engine with no saved key blocks Continue")
  func cloudWithNoKeyBlocks() {
    for provider in [LLMProvider.openAI, .gemini, .claude] {
      let verdict = Self.readiness(provider: provider, savedKey: .absent)
      #expect(
        verdict == .blocked(.needsSetup),
        "\(provider) with no key returned \(verdict)")
      #expect(verdict.footer == "Finish setting this one up, or pick another.")
    }
  }

  /// The other direction, so a gate that blocked everything would fail too.
  @Test("a cloud engine with a saved key is allowed through unvalidated")
  func cloudWithASavedKeyProceeds() {
    for provider in [LLMProvider.openAI, .gemini, .claude] {
      #expect(Self.readiness(provider: provider, savedKey: .present).isReady)
    }
  }

  /// Plan §7: a Keychain we could not read must never be reported as "you have no key".
  /// The distinction is the whole reason the saved-key state has three values.
  @Test("an unreadable Keychain says so, and does not accuse the user of having no key")
  func unreadableKeychainIsItsOwnAnswer() {
    let verdict = Self.readiness(provider: .openAI, savedKey: .unknown)
    #expect(verdict == .blocked(.couldNotCheckKey))
    #expect(verdict.footer == "We could not check your saved key. Try again, or pick another.")
  }

  /// Plan §7 asks readiness to tell five states apart, and this is the one that reads as
  /// "you did nothing" while the user did almost everything. Polish reads the Keychain and
  /// not the field, so an unsaved draft runs as no key at all.
  @Test("a typed but unsaved key says so, rather than 'finish setting this up'")
  func anUnsavedDraftIsItsOwnAnswer() {
    let verdict = Self.readiness(
      provider: .claude, savedKey: .absent, hasUnsavedKeyDraft: true)
    #expect(verdict == .blocked(.unsavedKey))
    #expect(verdict.footer == "Press Save key to finish, or pick another.")
    #expect(
      FileImportPolishSubtitle.text(provider: .claude, readiness: verdict) == "Key not saved")
    // And the other side of the same fork, so one arm cannot swallow the other.
    #expect(
      Self.readiness(provider: .claude, savedKey: .absent, hasUnsavedKeyDraft: false)
        == .blocked(.needsSetup))
  }

  /// The replacement-key case, which is the same fact as the row above wearing a saved key.
  /// It reads worse than a missing key: the run does not stop, it proceeds under the OLD
  /// value while the user believes they changed it. Found by the cloud review of PR #2786.
  @Test("a replacement key typed over a saved one blocks until it is saved")
  func aReplacementKeyBlocksUntilSaved() {
    let verdict = Self.readiness(
      provider: .openAI, savedKey: .present, hasUnsavedKeyDraft: true)
    #expect(verdict == .blocked(.unsavedKey))
    #expect(
      FileImportPolishSubtitle.text(provider: .openAI, readiness: verdict) == "Key not saved")
    // Both other sides, so no arm can swallow another: a saved key nobody has retyped is
    // ready, and the block outranks a stale invalid verdict about the key being replaced.
    #expect(
      Self.readiness(provider: .openAI, savedKey: .present, hasUnsavedKeyDraft: false)
        == .ready)
    #expect(
      Self.readiness(
        provider: .openAI, savedKey: .present, hasUnsavedKeyDraft: true,
        keyValidation: .invalid("nope")) == .blocked(.unsavedKey))
  }

  /// Named for what the state IS, not for one cause of it. `KeyValidationState.invalid`
  /// also carries general discovery and network failures, so "the provider refused the key"
  /// would be a claim this row cannot make. Narrowed by Codex.
  @Test("a failed key check blocks, even though a key is stored")
  func aFailedKeyCheckBlocks() {
    #expect(
      Self.readiness(
        provider: .openAI, savedKey: .present, keyValidation: .invalid("Invalid API key"))
        == .blocked(.needsSetup))
  }

  @Test("a validation in flight asks the user to wait, not to act")
  func validationInFlightIsChecking() {
    #expect(
      Self.readiness(provider: .openAI, savedKey: .absent, keyValidation: .validating)
        == .blocked(.checking))
  }

  /// Finding 7f/7h. Ollama is a separate app, and every one of these is a trip into it.
  @Test("Ollama blocks until it is installed, running, and has a model armed")
  func ollamaBlocksUntilItCanRun() {
    let blocking: [OllamaSetupState] = [
      .notInstalled, .installedNotRunning, .runningNoModels, .error("boom"),
    ]
    for state in blocking {
      #expect(
        Self.readiness(provider: .ollama, ollamaSetup: state) == .blocked(.needsSetup),
        "Ollama in \(state) did not block")
    }
    #expect(
      Self.readiness(provider: .ollama, ollamaSetup: .ready, ollamaModelIsArmed: false)
        == .blocked(.needsSetup),
      "Ollama running with nothing armed did not block")
    #expect(Self.readiness(provider: .ollama, ollamaSetup: .ready).isReady)
  }

  /// A bundled engine that is downloading clears itself, so the user is asked to wait. One
  /// that is not installed at all, or is refusing to start, is their move.
  @Test("a bundled engine tells the user to wait or to act, and never confuses the two")
  func bundledEngineSeparatesWaitingFromActing() {
    for provider in [LLMProvider.egOne, .s1Mini] {
      let installing = Self.readiness(
        provider: provider,
        egOneInstall: .downloading(fractionCompleted: 0.4, upgrade: nil),
        s1MiniInstall: .downloading(fractionCompleted: 0.4, upgrade: nil))
      #expect(installing == .blocked(.checking), "\(provider) mid-download said \(installing)")

      let missing = Self.readiness(
        provider: provider, egOneInstall: .notInstalled, s1MiniInstall: .notInstalled)
      #expect(missing == .blocked(.needsSetup), "\(provider) not installed said \(missing)")

      // **An INSTALLED bundled engine is admitted whatever its server is doing**, and Live
      // UAT on 2026-09-10 is why. There is one local inference slot; selecting EG-1 for an
      // import starts its server and dictation's reconciler takes the slot back, because
      // outside a run nothing pins the import's choice. Requiring green health blocked
      // Continue forever for anyone whose two polishers differ. The RUN starts and awaits
      // the server (chunk 2) and defers that reconciliation while it holds the claim.
      for health in [EGOneHealth.green, .yellow(reason: "starting"), .red(reason: "dead")] {
        let verdict = Self.readiness(
          provider: provider, egOneHealth: health, s1MiniHealth: health)
        #expect(
          verdict.isReady,
          "\(provider) installed but blocked on health \(health): \(verdict)")
      }

      #expect(Self.readiness(provider: provider).isReady)
    }
  }

  /// Apple Intelligence blocks WITHOUT diagnosing. An overall availability status does not
  /// establish that the Mac cannot run it, and the editor below the cards already shows the
  /// report's own per-gate explanation and a re-check. A first version said "cannot run on
  /// this Mac" for a degraded or unknown reading, which is a claim the input cannot support.
  /// Found by Codex.
  @Test("an unconfirmed Apple Intelligence status blocks without diagnosing the Mac")
  func appleIntelligenceBlocksWithoutDiagnosing() {
    for status in [AIAvailabilityStatus.unavailable, .degraded, .unknown] {
      let verdict = Self.readiness(provider: .appleIntelligence, appleStatus: status)
      #expect(verdict == .blocked(.availabilityUnconfirmed), "\(status) said \(verdict)")
      #expect(verdict.footer == "That engine is not ready. Check its status below, or pick another.")
      #expect(!verdict.footer!.contains("cannot run on this Mac"))
    }
    #expect(
      Self.readiness(provider: .appleIntelligence, appleStatus: nil) == .blocked(.checking),
      "an availability check that has not answered yet is not a verdict")
    #expect(Self.readiness(provider: .appleIntelligence).isReady)
  }

  /// Polish deliberately off for imports. Numbers, dates, saved words and filler removal
  /// still run, so there is nothing to set up and nothing to block.
  @Test("no cleanup chosen is not a blocked state")
  func noCleanupIsReady() {
    #expect(Self.readiness(provider: .none).isReady)
    #expect(Self.readiness(provider: .none).footer == nil)
  }

  /// Finding 7g: the subtitle is computed FROM the verdict, so the two cannot disagree.
  /// This is the property the founder named as "the free tell for 7a".
  @Test("no card says a cloud engine is ready while the gate is blocking it")
  func theSubtitleAgreesWithTheGate() {
    for provider in LLMProvider.allCases {
      for savedKey in [FileImportSavedKeyState.present, .absent, .unknown] {
        for ollama in [OllamaSetupState.ready, .notInstalled] {
          let verdict = Self.readiness(
            provider: provider, savedKey: savedKey, ollamaSetup: ollama)
          let subtitle = FileImportPolishSubtitle.text(provider: provider, readiness: verdict)
          #expect(!subtitle.isEmpty, "\(provider) has no subtitle")
          if !verdict.isReady {
            #expect(
              subtitle != "Cloud based" && subtitle != "On device" && subtitle != "Ready",
              "\(provider) reads \"\(subtitle)\" while the gate blocks with \(verdict)")
          }
        }
      }
    }
  }

  /// **A readiness word must never become a LOCATION claim.** A first version returned
  /// "On this Mac" for a ready Ollama, on a screen where the user approves sending their
  /// transcript — and the daemon proxies some models to Ollama's own servers, so that
  /// sentence is false for exactly the models it matters for. Readiness does not know which
  /// model is selected; `TranscribeFileView.polisherLocation` does. Found by Codex.
  @Test("no Ollama subtitle claims the text stays on this Mac")
  func theOllamaSubtitleMakesNoLocalityClaim() {
    for readiness in [
      FileImportPolishReadiness.ready, .blocked(.needsSetup), .blocked(.checking),
      .blocked(.availabilityUnconfirmed), .blocked(.couldNotCheckKey), .blocked(.unsavedKey),
    ] {
      let subtitle = FileImportPolishSubtitle.text(provider: .ollama, readiness: readiness)
      #expect(
        !subtitle.lowercased().contains("this mac"),
        "the Ollama card says \"\(subtitle)\" from readiness alone")
    }
  }

  /// House rule: no em or en dash in any user-facing string.
  @Test("no footer or subtitle carries an em or en dash")
  func noDashes() {
    var strings: [String] = []
    for block in [
      FileImportPolishBlock.needsSetup, .checking, .availabilityUnconfirmed,
      .couldNotCheckKey, .unsavedKey,
    ] {
      strings.append(block.footer)
      for provider in LLMProvider.allCases {
        strings.append(
          FileImportPolishSubtitle.text(provider: provider, readiness: .blocked(block)))
      }
    }
    for provider in LLMProvider.allCases {
      strings.append(FileImportPolishSubtitle.text(provider: provider, readiness: .ready))
    }
    for line in strings {
      #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in \"\(line)\"")
    }
  }

  /// The other shared resource on the page (#2772). Leaving Ollama on one surface used to
  /// cancel the download, the resolving name and the warm-up for both, so choosing a
  /// different file polisher threw away gigabytes dictation was still waiting on. Found by
  /// the cloud review of PR #2786.
  ///
  /// All four cells, because the fix is a two-way condition and either half alone would pass
  /// a version that never cancels.
  @Test("leaving Ollama on one surface keeps the shared download while the other still uses it")
  func sharedOllamaWorkOutlivesAnImportOnlySwitch() {
    // Import leaves; dictation stays on Ollama: keep.
    #expect(
      !SharedOllamaCleanup.mayCancel(
        leaving: .fileImport, dictation: .ollama, importEffective: .appleIntelligence))
    // Import leaves; dictation never used Ollama: cancel.
    #expect(
      SharedOllamaCleanup.mayCancel(
        leaving: .fileImport, dictation: .claude, importEffective: .appleIntelligence))
    // Dictation leaves; import overrides to Ollama on its own: keep.
    #expect(
      !SharedOllamaCleanup.mayCancel(
        leaving: .dictation, dictation: .claude, importEffective: .ollama))
    // Dictation leaves and import follows it, so its effective provider left too: cancel.
    #expect(
      SharedOllamaCleanup.mayCancel(
        leaving: .dictation, dictation: .claude, importEffective: .claude))
  }
}
