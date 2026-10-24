import EnviousWisprCore
import Foundation

/// The one table of apps and meeting websites EnviousMeet can notice (#4012 D4, §3.2, c1 C1).
///
/// A process that starts using the microphone is looked up here by bundle identifier. A row
/// says which call app it is and what else must be true before it counts as a call:
/// - `.callApp`: the app itself is a calling app; its microphone use is a call.
/// - `.callWindow`: the app also uses the microphone outside calls (Zoom's main window, Slack
///   messages); only its meeting window or huddle counts.
/// - `.browser`: a web browser; only a meeting page in its front window counts
///   (`CallMeetingURL`).
/// Membership follows two shipped competitors' tables (Wispr Flow 1.6.1147, FluidVoice) and the
/// founder's list; Firefox, Discord and WhatsApp stay out until a live check proves their
/// evidence (#4012 D4 rule, Gate 1 addendum).
public enum CallAppCatalog {
  /// A browser whose front window can show a meeting page.
  public enum Browser: String, Sendable, CaseIterable, Equatable {
    case chrome, safari, arc, dia, edge, brave, opera, vivaldi, zen, comet, atlas

    /// The browser app whose window holds the page (helpers report the parent's sound).
    public var appBundleIDs: [String] {
      switch self {
      case .chrome:
        [
          "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary",
          "com.google.chrome.dev",
        ]
      case .safari: ["com.apple.safari"]
      case .arc: ["company.thebrowser.browser"]
      case .dia: ["company.thebrowser.dia"]
      case .edge: ["com.microsoft.edgemac"]
      case .brave: ["com.brave.browser"]
      case .opera: ["com.operasoftware.opera"]
      case .vivaldi: ["com.vivaldi.vivaldi"]
      case .zen: ["app.zen-browser.zen"]
      case .comet: ["ai.perplexity.comet"]
      case .atlas: ["com.openai.atlas"]
      }
    }
  }

  public enum Rule: Sendable, Equatable {
    case callApp(CallAppFamily)
    case callWindow(CallAppFamily)
    case browser(Browser)
  }

  /// The per-app switch a rule belongs to (`SettingsManager.meetingCallAppsOff`): each native
  /// app has its own, every browser shares "browser".
  public static func switchID(for rule: Rule) -> String {
    switch rule {
    case .callApp(let family), .callWindow(let family): family.rawValue
    case .browser: browserSwitchID
    }
  }

  public static let browserSwitchID = "browser"

  /// The native call apps, in settings order, with the bundle identifiers of the app itself
  /// (not its helpers): the settings page lists a switch for each one installed (D5).
  public static let nativeApps: [(family: CallAppFamily, appBundleIDs: [String])] = [
    (.zoom, ["us.zoom.xos"]),
    (.teams, ["com.microsoft.teams2", "com.microsoft.teams"]),
    (.facetime, ["com.apple.FaceTime"]),
    (.webex, ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"]),
    (.slack, ["com.tinyspeck.slackmacgap"]),
    (.dialpadMeetings, ["com.electron.uberconference"]),
    (.gather, ["com.gather.Gather"]),
    (.lark, ["com.larksuite.larkApp"]),
    (.voov, ["com.tencent.tencentmeeting"]),
  ]

  /// The switched-off ids stored in `SettingsManager.meetingCallAppsOff` ("zoom,browser").
  public static func appsOff(from stored: String) -> Set<String> {
    Set(stored.split(separator: ",").map(String.init).filter { !$0.isEmpty })
  }

  public static func encodeAppsOff(_ ids: Set<String>) -> String {
    ids.sorted().joined(separator: ",")
  }

  /// The native call apps on this Mac, `isInstalled` being asked per bundle identifier.
  public static func installedNativeApps(isInstalled: (String) -> Bool) -> [CallAppFamily] {
    nativeApps.filter { $0.appBundleIDs.contains(where: isInstalled) }.map(\.family)
  }

  /// Bundle identifiers, lowercased, of the processes that hold the microphone for each app.
  /// Helper processes map to their app.
  private static let rules: [String: Rule] = {
    var table: [String: Rule] = [:]
    func add(_ rule: Rule, _ ids: [String]) { for id in ids { table[id] = rule } }
    add(.callWindow(.zoom), ["us.zoom.xos"])
    add(
      .callApp(.teams),
      ["com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.teams2.modulehost"])
    add(.callApp(.facetime), ["com.apple.facetime", "com.apple.avconferenced"])
    add(.callApp(.webex), ["com.cisco.webexmeetingsapp", "cisco-systems.spark"])
    add(
      .callApp(.dialpadMeetings),
      ["com.electron.uberconference", "com.electron.uberconference.helper"])
    add(.callApp(.gather), ["com.gather.gather", "com.gather.gather.helper"])
    add(.callApp(.lark), ["com.larksuite.larkapp", "com.larksuite.larkapp.helper"])
    add(.callApp(.voov), ["com.tencent.tencentmeeting"])
    add(.callWindow(.slack), ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap.helper"])
    for browser in Browser.allCases {
      add(.browser(browser), browser.appBundleIDs)
      add(.browser(browser), browser.appBundleIDs.map { $0 + ".helper" })
    }
    // Safari's audio runs in the shared WebKit GPU process; it counts only with a meeting page
    // in Safari's own window.
    add(.browser(.safari), ["com.apple.webkit.gpu"])
    add(
      .browser(.chrome), ["com.google.chrome.helper.renderer", "com.google.chrome.helper.plugin"])
    add(.browser(.atlas), ["com.openai.atlas.web.helper"])
    return table
  }()

  /// The rule for a microphone-holding process, or nil when it is not a call app.
  public static func rule(forBundleID bundleID: String) -> Rule? {
    rules[bundleID.lowercased()]
  }

  /// Every bundle identifier in the table, for the watcher's candidate filter.
  public static var bundleIDs: Set<String> { Set(rules.keys) }

  /// Whether a process whose executable could not be read may still be a call app: it reports
  /// no bundle identifier, or one inside a call app's (a helper not in the table). Such a
  /// process, holding the microphone, keeps every call from being confirmed over.
  public static func mayBeCallApp(bundleID: String?) -> Bool {
    guard let id = bundleID?.lowercased(), !id.isEmpty else { return true }
    return rules.keys.contains { id == $0 || id.hasPrefix($0 + ".") }
  }

  /// The app bundle a helper's executable lives in, when a process reports no bundle id
  /// of its own: `/Applications/Zoom.app/Contents/Frameworks/.../zoom Helper` → the path of
  /// `Zoom.app`. Nil when the path is not inside an app bundle.
  public static func owningAppPath(ofExecutable path: String) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
    return parts[...index].joined(separator: "/")
  }
}

/// A meeting page address, classified (#4012 §3.2). Parses with `URLComponents`; https only.
/// A URL is START evidence only: it never keeps a call alive (R4).
public enum CallMeetingURL {
  public struct Match: Sendable, Equatable {
    public let family: CallAppFamily
    /// Room code, meeting number or path: tells one meeting from the next. Never logged or
    /// sent; the policy keeps only a hash of it.
    public let room: String
  }

  public static func classify(_ text: String) -> Match? {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
      components.scheme?.lowercased() == "https", let host = components.host?.lowercased()
    else { return nil }
    let path = components.path
    let segments = path.split(separator: "/").map(String.init)

    func hostIs(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    if host == "meet.google.com", let code = segments.first,
      code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
    {
      return Match(family: .googleMeet, room: code)
    }
    if hostIs("zoom.us") || hostIs("zoomgov.com") {
      // /j/123, /s/123, /wc/join/123, /wc/123/join, /wc/123/start
      if segments.count >= 2, ["j", "s"].contains(segments[0]), Int(segments[1]) != nil {
        return Match(family: .zoom, room: segments[1])
      }
      if segments.count >= 3, segments[0] == "wc" {
        if segments[1] == "join", Int(segments[2]) != nil {
          return Match(family: .zoom, room: segments[2])
        }
        if Int(segments[1]) != nil, ["join", "start"].contains(segments[2]) {
          return Match(family: .zoom, room: segments[1])
        }
      }
      return nil
    }
    if host == "teams.microsoft.com" || host == "teams.live.com" {
      // Only a meeting link counts (r3 F2): a join link (/l/meetup-join/…) or a personal room
      // (/meet/<id>). The web app's chat and calendar pages share the host and are not calls;
      // a meeting the web app opens without one of these paths is missed, never guessed.
      let lower = path.lowercased()
      if lower.hasPrefix("/l/meetup-join/") || (lower.hasPrefix("/meet/") && segments.count >= 2) {
        return Match(family: .teams, room: host + path)
      }
      return nil
    }
    if hostIs("webex.com") {
      // Only a meeting link counts (r3 F2): a personal room (/meet/<name>), a join page
      // (j.php, /wbxmjs/joinservice/) or the web app's meeting page; webex.com's own pages
      // (pricing, downloads) are not calls.
      let lower = path.lowercased()
      let meeting =
        (lower.hasPrefix("/meet/") && segments.count >= 2) || lower.hasSuffix("/j.php")
        || lower.contains("/wbxmjs/joinservice/") || lower.contains("/webappng/sites/")
      // The meeting number rides in the query of a join page (j.php?MTID=…): part of the room,
      // so two meetings on one page address are two calls (review r4 F7).
      // Only the meeting number counts, so the same meeting with its parameters in another
      // order is the same call (review r15 F3).
      let number = components.queryItems?.first { $0.name.lowercased() == "mtid" }?.value
      let room = host + path + (number.map { "?MTID=" + $0 } ?? "")
      return meeting ? Match(family: .webex, room: room) : nil
    }
    if host == "whereby.com", let room = segments.first,
      !["user", "information", "login", "org"].contains(room.lowercased())
    {
      return Match(family: .whereby, room: room)
    }
    if host == "meet.jit.si", let room = segments.first {
      return Match(family: .jitsi, room: room)
    }
    if hostIs("slack.com"), path.contains("/huddle/") {
      return Match(family: .slack, room: path)
    }
    return nil
  }
}
