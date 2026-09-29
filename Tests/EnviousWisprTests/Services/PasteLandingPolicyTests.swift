import EnviousWisprServices
import Testing

/// The one table deciding which landing results are misses (#3106). Every result against every
/// destination class: the table is small enough to state whole, and a new case must be placed.
@Suite(.tags(.productOutcome))
struct PasteLandingPolicyTests {
  typealias AppClass = TelemetryService.LearnFromEditsTelemetry.AppClass

  static let eligibleAbsent: Set<AppClass> = [.native, .browser, .manualAccessibility]
  static let eligibleNoTarget: Set<AppClass> = [.native, .browser]

  @Test("absent is a miss in a readable-before class; no_target only where focus is honest")
  func misses() {
    for appClass in AppClass.allCases {
      #expect(
        PasteLandingPolicy.isMiss(.absent, appClass: appClass) == Self.eligibleAbsent.contains(appClass),
        "absent in \(appClass.rawValue)")
      #expect(
        PasteLandingPolicy.isMiss(.noTarget, appClass: appClass)
          == Self.eligibleNoTarget.contains(appClass),
        "no_target in \(appClass.rawValue)")
    }
  }

  @Test("found, cannot_read and inconclusive are never misses")
  func neverMisses() {
    var others: [PasteArrivalLanding] = PasteArrivalLanding.Found.allCases.map { .found($0) }
    others += PasteArrivalLanding.CannotRead.allCases.map { .cannotRead($0) }
    others += PasteArrivalLanding.Inconclusive.allCases.map { .inconclusive($0) }
    #expect(others.count == 1 + 5 + 17)
    for landing in others {
      for appClass in AppClass.allCases {
        #expect(
          PasteLandingPolicy.isMiss(landing, appClass: appClass) == false,
          "\(landing.observed)/\(landing.reason) in \(appClass.rawValue)")
      }
    }
  }

  // MARK: mayRetain (#3106 PR B): permission, separate from the evidence

  /// Routes that wrote the board and posted a paste; the others never retain.
  static let keyRoutes: [PasteTier] = [.cgEvent, .appleScript, .menuPaste]
  static let otherRoutes: [PasteTier] = [.axDirect, .clipboardOnly]

  static func allLandings() -> [PasteArrivalLanding] {
    var all: [PasteArrivalLanding] = [.absent, .noTarget]
    all += PasteArrivalLanding.Found.allCases.map { .found($0) }
    all += PasteArrivalLanding.CannotRead.allCases.map { .cannotRead($0) }
    all += PasteArrivalLanding.Inconclusive.allCases.map { .inconclusive($0) }
    return all
  }

  @Test("A key route retains only evidence-backed misses; Tier 1 and clipboard-only never do")
  func retainsOnlyMissesOnKeyRoutes() {
    let landings = Self.allLandings()
    #expect(landings.count == 2 + 1 + 5 + 17)
    var retained = 0
    for landing in landings {
      for appClass in AppClass.allCases {
        let miss = landing == .absent && Self.eligibleAbsent.contains(appClass)
        for tier in Self.keyRoutes {
          let got = PasteLandingPolicy.mayRetain(
            landing, bundleID: "com.example.app", appClass: appClass, tier: tier, excluded: [])
          #expect(got == miss, "\(landing.observed) in \(appClass.rawValue) via \(tier.rawValue)")
          if got { retained += 1 }
        }
        for tier in Self.otherRoutes {
          #expect(
            PasteLandingPolicy.mayRetain(
              landing, bundleID: "com.example.app", appClass: appClass, tier: tier, excluded: [])
              == false,
            "\(landing.observed) in \(appClass.rawValue) via \(tier.rawValue)")
        }
      }
    }
    // Three absent classes on three key routes; no_target never retains.
    #expect(retained == 3 * 3)
  }

  /// #3286: a Chromium host (Chrome, Brave, Edge, the ChatGPT app) reports no focused element while
  /// its accessibility is asleep, with the box focused and the paste landing. That is not proof of a
  /// miss, so it must never keep the dictation in place of the user's clipboard.
  @Test("no_target never retains for any class, app identity or route")
  func noTargetNeverRetains() {
    let bundleIDs: [String?] = [nil, "com.example.app"]
    for appClass in AppClass.allCases {
      for bundleID in bundleIDs {
        for tier in Self.keyRoutes + Self.otherRoutes {
          #expect(
            PasteLandingPolicy.mayRetain(
              .noTarget, bundleID: bundleID, appClass: appClass, tier: tier, excluded: []) == false,
            "no_target retained in \(appClass.rawValue) \(bundleID ?? "nil") via \(tier.rawValue)")
        }
      }
    }
  }

  @Test("An excluded app, or one excluded route in it, does not retain; other routes still do")
  func exclusionsNarrowPermission() {
    let app = "com.example.terminal"
    let wholeApp: Set<PasteLandingPolicy.Exclusion> = [.init(bundleID: app)]
    for tier in Self.keyRoutes {
      #expect(
        PasteLandingPolicy.mayRetain(
          .absent, bundleID: app, appClass: .native, tier: tier, excluded: wholeApp) == false)
      #expect(
        PasteLandingPolicy.mayRetain(
          .absent, bundleID: "com.example.other", appClass: .native, tier: tier, excluded: wholeApp))
    }
    let oneRoute: Set<PasteLandingPolicy.Exclusion> = [.init(bundleID: app, tier: .menuPaste)]
    #expect(
      PasteLandingPolicy.mayRetain(
        .absent, bundleID: app, appClass: .native, tier: .menuPaste, excluded: oneRoute) == false)
    #expect(
      PasteLandingPolicy.mayRetain(
        .absent, bundleID: app, appClass: .native, tier: .cgEvent, excluded: oneRoute))
  }

  @Test("An app with no bundle identifier cannot be checked against exclusions, so it does not retain")
  func unnamedAppDoesNotRetain() {
    #expect(
      PasteLandingPolicy.mayRetain(
        .absent, bundleID: nil, appClass: .native, tier: .cgEvent, excluded: []) == false)
  }

  /// Drift Guard in a Product Outcome suite on purpose: the shipped table holds only apps that
  /// failed a PR B gate, each with its evidence line in the policy. A new entry is noticed here.
  @Test("The shipped exclusion table is exactly the apps that failed a gate")
  func shippedExclusionsAreTheFailedGates() {
    #expect(
      PasteLandingPolicy.excludedRoutes == [
        .init(bundleID: "com.microsoft.VSCode"), .init(bundleID: "com.microsoft.Excel"),
      ])
    for tier in Self.keyRoutes {
      #expect(PasteLandingPolicy.routeMayRetain(bundleID: "com.microsoft.VSCode", tier: tier) == false)
      #expect(PasteLandingPolicy.routeMayRetain(bundleID: "com.microsoft.Excel", tier: tier) == false)
      #expect(PasteLandingPolicy.routeMayRetain(bundleID: "com.google.Chrome", tier: tier))
    }
  }

  @Test("Ghostty's miss is decided at 700 ms; every other app, and an unnamed one, at 300 ms")
  func perAppDeadlines() {
    #expect(PasteLandingPolicy.landingDeadlineMs(bundleID: "com.mitchellh.ghostty") == 700)
    #expect(PasteLandingPolicy.landingDeadlineMs(bundleID: "com.google.Chrome") == 300)
    #expect(PasteLandingPolicy.landingDeadlineMs(bundleID: nil) == 300)
    for (_, ms) in PasteLandingPolicy.slowRevealDeadlinesMs {
      #expect(ms < PastedRegionTiming.arrivalShadowMs, "the late-hit shadow must outlast every deadline")
    }
  }
}
