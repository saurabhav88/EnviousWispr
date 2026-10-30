import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Which call a call card names and pictures (#4232): a desktop call app, a call in a browser
/// page, or the microphone when a hand-started recording matched no call.
enum CallAppIdentity: Equatable {
  /// A desktop call app. `bundleID` is the running app's, when known.
  case app(CallAppFamily, bundleID: String?)
  /// A meeting service in a browser page. `browserBundleID` is the browser's, when known.
  case web(CallAppFamily, browserBundleID: String?)
  /// No call: the recording takes the microphone, and the Mac's sound when `withCallSound`.
  case microphone(withCallSound: Bool)

  var family: CallAppFamily? {
    switch self {
    case .app(let family, _), .web(let family, _): family
    case .microphone: nil
    }
  }

  /// The name the cards' questions use: the short name people say ("Teams", "Meet").
  var shortName: String {
    switch family {
    case .teams?: "Teams"
    case .googleMeet?: "Meet"
    case let family?: family.displayName
    case nil: ""
    }
  }

  /// The full product name, for dev control and accessibility.
  var displayName: String { family?.displayName ?? "" }

  /// A card's identity for a call the policy tracks, from its rule and owning app run.
  init(_ call: CallDetectionPolicy.CallIdentity) {
    switch call.rule {
    case .browser(let browser):
      self = .web(
        call.family, browserBundleID: call.owner?.bundleIdentifier ?? browser.appBundleIDs.first)
    case .callApp, .callWindow:
      self = .app(call.family, bundleID: call.owner?.bundleIdentifier)
    }
  }
}

/// Looks up call apps' own icons from macOS (#4232). Each bundle is resolved once per launch.
@MainActor
enum CallAppIcon {
  private static var cache: [String: NSImage?] = [:]

  /// The installed app's icon, or nil when macOS knows no app with that bundle ID.
  static func icon(bundleID: String) -> NSImage? {
    let key = bundleID.lowercased()
    if let cached = cache[key] { return cached }
    let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
      .map { NSWorkspace.shared.icon(forFile: $0.path) }
    cache[key] = image
    return image
  }

  /// The first installed desktop app of `family` in the call catalog, in a stable order.
  static func installedApp(for family: CallAppFamily) -> String? {
    CallAppCatalog.bundleIDs.sorted().first { bundleID in
      switch CallAppCatalog.rule(forBundleID: bundleID) {
      case .callApp(family)?, .callWindow(family)?: icon(bundleID: bundleID) != nil
      default: false
      }
    }
  }
}

/// A call card's picture (#4232): the desktop app's own icon; for a browser call the service's
/// mark with the browser's icon as a small badge; a microphone tile when there is no call.
/// Anything missing falls back to a letter tile, so a card is never blank.
struct CallAppIdentityTile: View {
  let identity: CallAppIdentity
  let size: CGFloat

  var body: some View {
    tile
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  @ViewBuilder private var tile: some View {
    switch identity {
    case .microphone:
      Image(systemName: "mic")
        .font(.system(size: size * 0.42, weight: .medium))
        .foregroundStyle(Color.stAccent)
        .frame(width: size, height: size)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: size * 0.25))
    case .app(let family, let bundleID):
      if let image = (bundleID ?? CallAppIcon.installedApp(for: family)).flatMap(CallAppIcon.icon) {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
      } else {
        CallServiceMark(family: family, size: size)
      }
    case .web(let family, let browserBundleID):
      ZStack(alignment: .bottomTrailing) {
        CallServiceMark(family: family, size: size)
        if let badge = browserBundleID.flatMap(CallAppIcon.icon) {
          Image(nsImage: badge).resizable().aspectRatio(contentMode: .fit)
            .frame(width: size * 0.45, height: size * 0.45)
            .offset(x: size * 0.1, y: size * 0.1)
        }
      }
    }
  }
}

/// A meeting service's own mark, full colour (#4232), on a light tile; a letter tile when the
/// mark is missing or does not render.
struct CallServiceMark: View {
  let family: CallAppFamily
  let size: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        .fill(Color.white)
      if CallLogoSVG.prefersAppIcon(family),
        let app = CallAppIcon.installedApp(for: family).flatMap(CallAppIcon.icon)
      {
        Image(nsImage: app).resizable().aspectRatio(contentMode: .fit)
      } else if let image = CallLogoSVG.image(for: family) {
        Image(nsImage: image)
          .renderingMode(.original)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: size * 0.66, height: size * 0.66)
      } else if let app = CallAppIcon.installedApp(for: family).flatMap(CallAppIcon.icon) {
        // No mark here (Whereby and the rest): the service's own desktop app, when installed.
        Image(nsImage: app).resizable().aspectRatio(contentMode: .fit)
      } else {
        Text(verbatim: String(family.displayName.prefix(1)))
          .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.stAccentSolid)
      }
    }
    .frame(width: size, height: size)
  }
}

/// Official service marks for browser calls (#4232), parsed once per launch and never tinted.
/// Each is the vendor's own logo, from Wikimedia Commons or from Simple Icons, which records the
/// vendor source (both beside each mark); used only to name the service, as the AI Polish
/// provider marks do. Families without a mark here use the
/// service's installed desktop app icon, then the letter tile.
@MainActor
enum CallLogoSVG {
  private static var cache: [CallAppFamily: NSImage?] = [:]

  static func image(for family: CallAppFamily) -> NSImage? {
    if let cached = cache[family] { return cached }
    var image: NSImage?
    if let svg = svg(for: family), let data = svg.data(using: .utf8),
      let parsed = NSImage(data: data), parsed.isValid
    {
      parsed.isTemplate = false
      image = parsed
    }
    cache[family] = image
    return image
  }

  static func svg(for family: CallAppFamily) -> String? {
    switch family {
    // Source: https://commons.wikimedia.org/wiki/File:Google_Meet_icon_(2020).svg
    case .googleMeet:
      #"""
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 87.5 72"><path fill="#00832d" d="M49.5 36l8.53 9.75 11.47 7.33 2-17.02-2-16.64-11.69 6.44z"/><path fill="#0066da" d="M0 51.5V66c0 3.315 2.685 6 6 6h14.5l3-10.96-3-9.54-9.95-3z"/><path fill="#e94235" d="M20.5 0L0 20.5l10.55 3 9.95-3 2.95-9.41z"/><path fill="#2684fc" d="M20.5 20.5H0v31h20.5z"/><path fill="#00ac47" d="M82.6 8.68L69.5 19.42v33.66l13.16 10.79c1.97 1.54 4.85.135 4.85-2.37V11c0-2.535-2.945-3.925-4.91-2.32zM49.5 36v15.5h-29V72h43c3.315 0 6-2.685 6-6V53.08z"/><path fill="#ffba00" d="M63.5 0h-43v20.5h29V36l20-16.57V6c0-3.315-2.685-6-6-6z"/></svg>
      """#
    // Source: https://commons.wikimedia.org/wiki/File:Microsoft_Office_Teams_(2018–present).svg
    case .teams:
      #"""
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2228.833 2073.333"><path fill="#5059C9" d="M1554.637,777.5h575.713c54.391,0,98.483,44.092,98.483,98.483c0,0,0,0,0,0v524.398 c0,199.901-162.051,361.952-361.952,361.952h0h-1.711c-199.901,0.028-361.975-162-362.004-361.901c0-0.017,0-0.034,0-0.052V828.971 C1503.167,800.544,1526.211,777.5,1554.637,777.5L1554.637,777.5z"/><circle fill="#5059C9" cx="1943.75" cy="440.583" r="233.25"/><circle fill="#7B83EB" cx="1218.083" cy="336.917" r="336.917"/><path fill="#7B83EB" d="M1667.323,777.5H717.01c-53.743,1.33-96.257,45.931-95.01,99.676v598.105 c-7.505,322.519,247.657,590.16,570.167,598.053c322.51-7.893,577.671-275.534,570.167-598.053V877.176 C1763.579,823.431,1721.066,778.83,1667.323,777.5z"/><path opacity=".1" d="M1244,777.5v838.145c-0.258,38.435-23.549,72.964-59.09,87.598 c-11.316,4.787-23.478,7.254-35.765,7.257H667.613c-6.738-17.105-12.958-34.21-18.142-51.833 c-18.144-59.477-27.402-121.307-27.472-183.49V877.02c-1.246-53.659,41.198-98.19,94.855-99.52H1244z"/><path opacity=".2" d="M1192.167,777.5v889.978c-0.002,12.287-2.47,24.449-7.257,35.765 c-14.634,35.541-49.163,58.833-87.598,59.09H691.975c-8.812-17.105-17.105-34.21-24.362-51.833 c-7.257-17.623-12.958-34.21-18.142-51.833c-18.144-59.476-27.402-121.307-27.472-183.49V877.02 c-1.246-53.659,41.198-98.19,94.855-99.52H1192.167z"/><path opacity=".2" d="M1192.167,777.5v786.312c-0.395,52.223-42.632,94.46-94.855,94.855h-447.84 c-18.144-59.476-27.402-121.307-27.472-183.49V877.02c-1.246-53.659,41.198-98.19,94.855-99.52H1192.167z"/><path opacity=".2" d="M1140.333,777.5v786.312c-0.395,52.223-42.632,94.46-94.855,94.855H649.472 c-18.144-59.476-27.402-121.307-27.472-183.49V877.02c-1.246-53.659,41.198-98.19,94.855-99.52H1140.333z"/><path opacity=".1" d="M1244,509.522v163.275c-8.812,0.518-17.105,1.037-25.917,1.037 c-8.812,0-17.105-0.518-25.917-1.037c-17.496-1.161-34.848-3.937-51.833-8.293c-104.963-24.857-191.679-98.469-233.25-198.003 c-7.153-16.715-12.706-34.071-16.587-51.833h258.648C1201.449,414.866,1243.801,457.217,1244,509.522z"/><path opacity=".2" d="M1192.167,561.355v111.442c-17.496-1.161-34.848-3.937-51.833-8.293 c-104.963-24.857-191.679-98.469-233.25-198.003h190.228C1149.616,466.699,1191.968,509.051,1192.167,561.355z"/><path opacity=".2" d="M1192.167,561.355v111.442c-17.496-1.161-34.848-3.937-51.833-8.293 c-104.963-24.857-191.679-98.469-233.25-198.003h190.228C1149.616,466.699,1191.968,509.051,1192.167,561.355z"/><path opacity=".2" d="M1140.333,561.355v103.148c-104.963-24.857-191.679-98.469-233.25-198.003 h138.395C1097.783,466.699,1140.134,509.051,1140.333,561.355z"/><linearGradient id="a" gradientUnits="userSpaceOnUse" x1="198.099" y1="1683.0726" x2="942.2344" y2="394.2607" gradientTransform="matrix(1 0 0 -1 0 2075.3333)"><stop offset="0" stop-color="#5a62c3"/><stop offset=".5" stop-color="#4d55bd"/><stop offset="1" stop-color="#3940ab"/></linearGradient><path fill="url(#a)" d="M95.01,466.5h950.312c52.473,0,95.01,42.538,95.01,95.01v950.312c0,52.473-42.538,95.01-95.01,95.01 H95.01c-52.473,0-95.01-42.538-95.01-95.01V561.51C0,509.038,42.538,466.5,95.01,466.5z"/><path fill="#FFF" d="M820.211,828.193H630.241v517.297H509.211V828.193H320.123V727.844h500.088V828.193z"/></svg>
      """#
    // Source: https://commons.wikimedia.org/wiki/File:Slack_icon_2019.svg
    case .slack:
      #"""
      <svg width="127" height="127" xmlns="http://www.w3.org/2000/svg"><path d="M27.2 80c0 7.3-5.9 13.2-13.2 13.2C6.7 93.2.8 87.3.8 80c0-7.3 5.9-13.2 13.2-13.2h13.2V80zm6.6 0c0-7.3 5.9-13.2 13.2-13.2 7.3 0 13.2 5.9 13.2 13.2v33c0 7.3-5.9 13.2-13.2 13.2-7.3 0-13.2-5.9-13.2-13.2V80z" fill="#E01E5A"/><path d="M47 27c-7.3 0-13.2-5.9-13.2-13.2C33.8 6.5 39.7.6 47 .6c7.3 0 13.2 5.9 13.2 13.2V27H47zm0 6.7c7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2H13.9C6.6 60.1.7 54.2.7 46.9c0-7.3 5.9-13.2 13.2-13.2H47z" fill="#36C5F0"/><path d="M99.9 46.9c0-7.3 5.9-13.2 13.2-13.2 7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2H99.9V46.9zm-6.6 0c0 7.3-5.9 13.2-13.2 13.2-7.3 0-13.2-5.9-13.2-13.2V13.8C66.9 6.5 72.8.6 80.1.6c7.3 0 13.2 5.9 13.2 13.2v33.1z" fill="#2EB67D"/><path d="M80.1 99.8c7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2-7.3 0-13.2-5.9-13.2-13.2V99.8h13.2zm0-6.6c-7.3 0-13.2-5.9-13.2-13.2 0-7.3 5.9-13.2 13.2-13.2h33.1c7.3 0 13.2 5.9 13.2 13.2 0 7.3-5.9 13.2-13.2 13.2H80.1z" fill="#ECB22E"/></svg>
      """#
    // Source: https://brand.zoom.us/media-library/ (via Simple Icons 13.21.0, zoom.svg)
    case .zoom:
      #"""
      <svg fill="#0B5CFF" role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M5.033 14.649H.743a.74.74 0 0 1-.686-.458.74.74 0 0 1 .16-.808L3.19 10.41H1.06A1.06 1.06 0 0 1 0 9.35h3.957c.301 0 .57.18.686.458a.74.74 0 0 1-.161.808L1.51 13.59h2.464c.585 0 1.06.475 1.06 1.06zM24 11.338c0-1.14-.927-2.066-2.066-2.066-.61 0-1.158.265-1.537.686a2.061 2.061 0 0 0-1.536-.686c-1.14 0-2.066.926-2.066 2.066v3.311a1.06 1.06 0 0 0 1.06-1.06v-2.251a1.004 1.004 0 0 1 2.013 0v2.251c0 .586.474 1.06 1.06 1.06v-3.311a1.004 1.004 0 0 1 2.012 0v2.251c0 .586.475 1.06 1.06 1.06zM16.265 12a2.728 2.728 0 1 1-5.457 0 2.728 2.728 0 0 1 5.457 0zm-1.06 0a1.669 1.669 0 1 0-3.338 0 1.669 1.669 0 0 0 3.338 0zm-4.82 0a2.728 2.728 0 1 1-5.458 0 2.728 2.728 0 0 1 5.457 0zm-1.06 0a1.669 1.669 0 1 0-3.338 0 1.669 1.669 0 0 0 3.338 0z"/></svg>
      """#
    // Source: https://github.com/momentum-design/momentum-ui/blob/970c5bec962a3f72e17e0b7ed69f2c38d298c405/icons-rebrand/svg/webex-helix-filled.svg (via Simple Icons 13.21.0)
    case .webex:
      #"""
      <svg fill="#000000" role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M21.78 7.376c.512 1.181.032 2.644-1.11 3.106-2.157.888-3-1.295-3-1.295-.236-.55-.727-1.496-1.335-1.496-.204 0-.503 0-.94.844-.229.443-.434 1.185-.616 1.84l-.09.32c-.373-1.587-.821-3.454-1.536-4.816-.195-.38-.42-.74-.673-1.08a5.135 5.135 0 0 1 1.743-1.337 4.891 4.891 0 0 1 2.112-.463c1.045 0 2.765.338 4.227 2.227.167.206.317.424.448.654.278.441.52.904.726 1.383l.043.113zM.02 8.4C-.15 7.105.8 5.845 1.953 5.755c1.794-.157 2.36 1.385 2.455 1.89l.022.137c.07.44.29 1.838.48 2.744.078.4.244 1.013.353 1.416l.006.022.026.092c.11.4.232.799.362 1.193.185.548.399 1.085.641 1.61.47.955.93 1.45 1.367 1.45.203 0 .512 0 .96-.878.283-.59.512-1.208.684-1.845.373 1.598.811 3.128 1.495 4.456.205.406.444.794.715 1.16a5.124 5.124 0 0 1-1.742 1.338 4.88 4.88 0 0 1-2.112.461c-1.548 0-3.727-.698-5.339-4.005a22.407 22.407 0 0 1-1.078-2.824 26.848 26.848 0 0 1-.693-2.656 48.56 48.56 0 0 1-.215-1.114C.191 9.603.074 8.872.02 8.4zm22.047-2.645-.202-.022h-.052c.222.392.421.797.597 1.215l.053.113c.322.76.346 1.614.068 2.391a3.079 3.079 0 0 1-1.552 1.749 2.93 2.93 0 0 1-1.228.28 3.115 3.115 0 0 1-.854-.135c-.299 1.182-.768 2.634-1.195 3.511-.427.877-.93 1.451-1.378 1.451-.192 0-.501 0-.95-.877a10.746 10.746 0 0 1-.683-1.845 38.722 38.722 0 0 1-.396-1.575 12.67 12.67 0 0 1-.136-.598l-.002-.01c-.406-1.778-.865-3.645-1.655-5.142A8.263 8.263 0 0 0 11.52 4.8a5.136 5.136 0 0 0-1.748-1.34A4.892 4.892 0 0 0 7.654 3c-1.036 0-2.754.338-4.217 2.228.466.223.867.562 1.164.984.305.433.499.933.565 1.458.076.563.256 1.654.47 2.688l.001.007c.021.11.042.221.073.342.126-.34.25-.642.38-.955l.112-.271.128-.293c.235-.55.726-1.496 1.324-1.496.213 0 .513 0 .95.844.296.606.532 1.239.706 1.89.138.507.276 1.047.394 1.587.04.148.07.296.101.444l.006.028c.427 1.879.875 3.69 1.644 5.187.159.317.34.622.545.911.15.215.31.422.48.62 1.27 1.45 2.733 1.8 3.843 1.8 1.548 0 3.738-.698 5.35-4.006.822-1.7 1.515-4.208 1.772-5.48.256-1.27.449-2.419.534-3.115.04-.307.023-.618-.051-.918-.075-.299-.205-.579-.382-.825a2.247 2.247 0 0 0-.653-.607 2.143 2.143 0 0 0-.826-.296z"/></svg>
      """#
    // Source: https://github.com/jitsi/jitsi-meet/blob/767101497c9a52abf8cef7893e8d6e7e4283bbfc/images/watermark.svg (via Simple Icons 13.21.0)
    case .jitsi:
      #"""
      <svg fill="#97979A" role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M19.6711 8.6222a2.31 2.31 0 0 0-.8952-.9978c-.4642-.2943-1.044-.3567-1.4482-.3567q-.2042 0-.4075.0211h-.01a3 3 0 0 1 .0335-.1862c.0202-.1028.0432-.2194.0562-.3408.0538-.5208-.1315-1.2216-.4728-1.7847-.0542-.0897-.0523-.1205-.0523-.1205a.4.4 0 0 1 .0595-.0696l.0312-.0326c.8069-.864 1.0507-1.814.7238-2.8291C16.6697 0 16.5036 0 16.3821 0a.192.192 0 0 0-.144.0629.224.224 0 0 0-.0484.1771c.0628.6384-.0812 1.5523-.1772 1.9003-.1176.4378-.528 1.0906-1.824 1.7112a3 3 0 0 1-.2784.1023c-.4228.1416-1.1294.3782-1.522.9187-.2962.347-.3678.6945-.496 1.322-.1141.5577-.2063 1.2369-.0258 2.0475a6 6 0 0 0 .0514.2074c.011.0428.0206.0797.0278.1118l.0154-.0033-.016.0043c.012.048.0045.0596-.0128.0716a1.3 1.3 0 0 1-.192.059c-.192.0307-.384.0648-.5674.1008-.5837.1003-2.3482.4046-3.1608 1.6982-.5016.7978-.5726 1.8398-.2122 3.1008.374 1.248 1.116 2.1058 1.6239 2.2805l.0081.0028q.0547.0246.1056.0418c0 .035-.0033.0778-.0076.1258a2 2 0 0 0-.0101.069c-.0557.4071-.2477.8459-.4435.8574-.1032-.0202-.5122-.252-.8016-.4421a31 31 0 0 1-.264-.1738c-.8079-.5347-1.2533-.8289-1.934-.9048a.7.7 0 0 0-.07-.0038c-.72 0-2.016 1.2125-2.0434 3.6288-.014 1.2106.1128 2.317.3778 3.289.189.697.3907 1.094.4492 1.2L5.0234 24l.1066-.48c.5616-2.544 1.2547-3.157 2.4081-3.8904.8453.792 1.9556 1.2096 3.2199 1.2096 1.0656 0 2.1806-.3096 3.1387-.8722.9413-.552 1.668-1.296 2.112-2.1556.0739.048.1632.1104.2222.1516.2112.1478.2559.179.3312.179h.0068c.0825-.0033.8611-.2644 1.6584-1.2384.4632-.5658.8453-1.2657 1.1352-2.0812.359-1.008.576-2.1984.65-3.5372.0815-1.124-.0327-2.0193-.3395-2.6606zm-2.9866-6.4708c.067.27.0756.551.0255.8246-.0749.5318-.3005 1.008-.6855 1.4424a8.21 8.21 0 0 0 .66-2.267m-.5568 3.301c.1173.1773.2068.3715.2655.576.065.268.0534.549-.0336.8106-.1378.3279-.3226.4935-.5496.4935h-.0303a.6.6 0 0 1-.2256-.0826c-.2918-.1709-.4497-.624-.336-.9561a.5.5 0 0 0 .0135-.0303c.0187-.048.072-.1401.2198-.2827.2112-.1867.5199-.4224.6754-.528zm-3.3792-.0903.003-.0053V5.352c.0623-.1536.492-.4022.777-.5669a6 6 0 0 1 .1067-.0619 4.1 4.1 0 0 1 .384-.1771c.469-.1997 1.2-.5107 1.8018-1.09-.1746.6124-.5952 1.644-1.2864 2.2684-.1536.1387-.4636.2616-.8232.4037-.3873.1526-.8529.336-1.3046.613.035-.3534.144-.9697.3394-1.3791zm-.3 1.9958c.2324-.192.6576-.4521 2.051-.912a6 6 0 0 1 .0313.1541c.0086.0418.0177.0893.0283.1411.0912.4503.192.9561 1.1294 1.237-.0873.192-.2668.5165-.3292.5783l-.0207.0178-.0144.0236c-.1824.2928-1.1683.9316-1.6099.9316a.33.33 0 0 1-.0566-.0042c-.266-.0514-.8765-.5938-1.056-.9946-.3471-.7868-.276-1.0704-.1556-1.1707zM8.9767 14.579c-.5107-.7598-.8976-2.0875-.6442-3.155v-.0048c.1224-.5808.528-.9226.6956-1.0426l.024-.0178c.2486-.2169.7574-.4458 1.4332-.646.096-.025.1488-.036.1512-.036.1243-.026.2602-.0572.3922-.0874a6.8 6.8 0 0 1 .7584-.1482 2.2 2.2 0 0 0 .189-.0308 1.45 1.45 0 0 1 .2526-.0326.324.324 0 0 1 .192.0508c.2506.2976.864.8852 1.2662.9198h.0255c.4579-.0246 1.1755-.4714 2.1336-1.3292.1627-.144.3139-.2698.4622-.3796l.0183-.014a3.52 3.52 0 0 1 .8553-.4776c-.1003.3284-.18.8894.144 1.68.1685.409.492 1.3306.7603 2.233.4618 1.5542.3975 1.8278.3884 1.8532a.53.53 0 0 1-.062.1498.37.37 0 0 1-.1032-.0364c-.2328-.1076-.494-.2996-.7992-.5252-.5664-.4152-1.2705-.9316-2.3011-1.3344-.757-.2952-1.5096-.4454-2.2358-.4454a4.67 4.67 0 0 0-.8967.0854c-1.6233.3202-2.4792 1.0358-2.9385 1.4208l-.0034.0029a.188.188 0 0 0-.059.2088.185.185 0 0 0 .1766.1215c.0418 0 .0826-.0116.2174-.0504a9.04 9.04 0 0 1 1.488-.3101q.271-.0316.5439-.0322c.7858 0 1.5086.24 2.2738.7599.1752.1464.2822.2433.347.3072l-.0662.0172-.4642.131c-1.1491.325-2.8863.816-3.7085.816a1.4 1.4 0 0 1-.1886-.011c-.2132-.0312-.4733-.254-.7148-.61zm-3.3893 5.8296a4.09 4.09 0 0 0-.7013 1.415c-.1545-.7406-.336-1.9588-.2328-2.9072.215-1.9652 1.1885-2.6232 1.333-2.6578h.0091c.0082 0 .0178 0 .037.0206.0777.0844.2457.4411.1233 1.9162-.0288.3038.0442.561.218.7646.1177.1346.2658.2392.432.3052a4.96 4.96 0 0 0-1.2202 1.144zM7.242 18.48a.43.43 0 0 1-.1608.0374.129.129 0 0 1-.1056-.0403c-.0312-.0327-.1018-.144-.0792-.4728.0158-.1618.0384-.3231.0595-.48a7 7 0 0 0 .0845-.8933c.5673.3715 1.1961.7651 1.6032.9466-.266.2356-.8194.6595-1.4016.9033zm7.404-.0528a5.35 5.35 0 0 1-3.47 1.632 6.3 6.3 0 0 1-.4627.0173c-1.7361 0-2.6184-.7368-3.024-1.1472 1.9618-.8463 2.3597-2.0563 2.5335-2.5849a2 2 0 0 1 .048-.1344c.0749-.0374.313-.144 1.0473-.419.576-.2074 1.2668-.4396 1.8759-.645.5073-.171.9456-.3193 1.1851-.4072l.0197-.0062a1 1 0 0 1 .096-.023l.0134.0173c.2232.2909.5914.468.5947.4704.2768.1236.5728.1983.875.2208-.0071 1.0488-.4862 2.1365-1.329 3.0087zm1.5216-3.5908c-.7263 0-.9811-.2338-1.2187-.5166-1.1794-1.4059-2.4831-1.6363-2.9895-1.6704a7.3 7.3 0 0 0-.4733-.0158c-.1277 0-.2525.0034-.3744.011a5.7 5.7 0 0 1 1.824-.3034c1.3008 0 2.5532.4608 3.721 1.369.4762.3701.8266.6326 1.1294.8434a28 28 0 0 1-.5976.168l-.096.0264a5.76 5.76 0 0 1-.9235.0883zm.4526 2.6586c-.0763-.0672-.192-.1742-.3115-.2832a4.7 4.7 0 0 0 .2477-.864c.0566-.3115.0921-.72.1085-.9364a8.6 8.6 0 0 0 1.0224-.2175c.4046-.1161.717-.2481.9398-.3984-.6946 1.7343-1.7006 2.496-2.007 2.6985zm2.4034-3.9662c-.1032-.8548-.4493-1.9118-.5847-2.3227-.0144-.048-.0264-.0825-.0345-.108-.0101-.0327-.0413-.1195-.1056-.2971-.1666-.4652-.5141-1.4318-.576-1.718-.0888-.4204.1118-.9988.24-1.0492a.35.35 0 0 1 .1238-.0226c.2362 0 .528.2232.7589.5832.2794.432.445 1.0046.4666 1.6076.048 1.3156-.074 2.4148-.288 3.3268"/></svg>
      """#
    default: nil
    }
  }

  /// Zoom's published mark is its wordmark; its installed app icon reads better on a 40 pt tile,
  /// so the app icon comes first when Zoom is installed.
  static func prefersAppIcon(_ family: CallAppFamily) -> Bool { family == .zoom }
}
