import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import SwiftUI

// MARK: - Provider status (single at-a-glance authority)
//
// #1286 Phase 2. The rail's detail header shows exactly ONE status light per
// selected engine. To avoid a sixth ad-hoc status mapping, this file owns the
// single summary mapping (`ProviderStatusMapping.status`) that reads the SAME
// coordinator values the existing inline controls read in `AIPolishSettingsView`
// (EG-1 install/health, Apple availability, cloud key validation, Ollama setup).
// The inline controls keep their detailed, actionable UI (refresh, download,
// per-gate diagnostics); this chip is the "can I use this engine right now?"
// summary. Partial-consolidation, not a takeover (plan §3c).

/// Severity tone for the header status chip. Rendered as a colored dot + text
/// label — never color-only, for colorblind / low-vision users (plan §3d).
enum ProviderStatusTone: Equatable {
  case ready  // green — usable now
  case needsSetup  // amber — one action away (download / key / start)
  case unavailable  // neutral — not offered on this Mac / not checked
  case error  // red — broken, needs attention

  /// The brand semantic color for this tone. Semantic tokens only, never raw
  /// `.red`/`.green` (SettingsDesignTokens).
  var color: Color {
    switch self {
    case .ready: return .stSuccess
    case .needsSetup: return .stWarning
    case .unavailable: return .stTextTertiary
    case .error: return .stError
    }
  }
}

/// A resolved status summary for one engine: the short label and its tone.
struct ProviderStatus: Equatable {
  let label: String
  let tone: ProviderStatusTone
}

/// The one place engine → (label, tone) is decided. Pure function of the
/// coordinator states, so `ProviderStatusMappingTests` can exercise every
/// engine's state grid without a running app. Switches on the provider FIRST
/// and reads ONLY that provider's own coordinator state — a cloud key state
/// never reaches an Apple/EG-1/Ollama branch and vice versa (plan §3, Codex r2:
/// provider-first, no cross-provider leak).
enum ProviderStatusMapping {
  static func status(
    for provider: LLMProvider,
    egOneInstall: EGOneInstallState,
    egOneHealth: EGOneHealth,
    appleStatus: AIAvailabilityStatus?,
    cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState,
    cloudKeyPresent: Bool = false,
    ollamaSetup: OllamaSetupState
  ) -> ProviderStatus {
    switch provider {
    case .egOne:
      return egOne(install: egOneInstall, health: egOneHealth)
    case .appleIntelligence:
      return apple(appleStatus)
    case .openAI, .gemini, .claude:
      return cloud(cloudValidation, keyPresent: cloudKeyPresent)
    case .ollama:
      return ollama(ollamaSetup)
    case .none:
      return ProviderStatus(label: "Off", tone: .unavailable)
    }
  }

  // EG-1: install lifecycle first, health only once installed — mirrors the
  // inline `egOneStatusContent` switch (installState first, health inside the
  // `.installed` case). So the chip and the inline row read the same authority.
  private static func egOne(
    install: EGOneInstallState, health: EGOneHealth
  ) -> ProviderStatus {
    switch install {
    case .notInstalled:
      return ProviderStatus(label: "Not installed", tone: .needsSetup)
    case .downloading:
      return ProviderStatus(label: "Downloading", tone: .needsSetup)
    case .verifying:
      return ProviderStatus(label: "Verifying", tone: .needsSetup)
    case .failed:
      return ProviderStatus(label: "Needs attention", tone: .error)
    case .installed:
      switch health {
      case .green:
        return ProviderStatus(label: "Live", tone: .ready)
      case .yellow:
        return ProviderStatus(label: "Starting", tone: .needsSetup)
      case .red:
        return ProviderStatus(label: "Not working", tone: .error)
      }
    }
  }

  // Apple Intelligence: unavailable/degraded/unknown/not-checked all read as the
  // neutral "unavailable" tone (plan §3); available → ready.
  private static func apple(_ status: AIAvailabilityStatus?) -> ProviderStatus {
    switch status {
    case .available:
      return ProviderStatus(label: "Available", tone: .ready)
    case .degraded:
      return ProviderStatus(label: "Degraded", tone: .unavailable)
    case .unavailable:
      return ProviderStatus(label: "Unavailable", tone: .unavailable)
    case .unknown:
      return ProviderStatus(label: "Unknown", tone: .unavailable)
    case nil:
      return ProviderStatus(label: "Not checked", tone: .unavailable)
    }
  }

  // Cloud (OpenAI / Gemini): keyed off validation state. `.idle` means we have
  // not validated this session — which is the normal state when a saved key is
  // loaded from the Keychain on settings-open (onAppear does not re-validate).
  // Showing "Key needed" there would falsely alarm a user with a working saved
  // key, so idle-with-a-key reads as the neutral "Not checked"; only idle with
  // NO key reads as "Key needed" (cloud review PR #1293, #1286).
  private static func cloud(
    _ state: LLMModelDiscoveryCoordinator.KeyValidationState,
    keyPresent: Bool
  ) -> ProviderStatus {
    switch state {
    case .idle:
      return keyPresent
        ? ProviderStatus(label: "Not checked", tone: .unavailable)
        : ProviderStatus(label: "Key needed", tone: .needsSetup)
    case .validating:
      return ProviderStatus(label: "Validating", tone: .needsSetup)
    case .valid:
      return ProviderStatus(label: "Key valid", tone: .ready)
    case .invalid:
      return ProviderStatus(label: "Key needed", tone: .error)
    }
  }

  // Ollama: setup wizard state.
  private static func ollama(_ state: OllamaSetupState) -> ProviderStatus {
    switch state {
    case .detecting:
      return ProviderStatus(label: "Checking", tone: .needsSetup)
    case .notInstalled:
      return ProviderStatus(label: "Not installed", tone: .needsSetup)
    case .installedNotRunning:
      return ProviderStatus(label: "Not running", tone: .needsSetup)
    case .runningNoModels:
      return ProviderStatus(label: "No model", tone: .needsSetup)
    case .pullingModel:
      return ProviderStatus(label: "Downloading", tone: .needsSetup)
    case .ready:
      return ProviderStatus(label: "Running", tone: .ready)
    case .error:
      return ProviderStatus(label: "Error", tone: .error)
    }
  }
}

// MARK: - Rail catalog

/// One row's presentation data. Order and grouping are the approved Direction-C
/// handoff: "On this Mac" (EG-1, Apple, Ollama) then "Cloud" (OpenAI, Gemini),
/// EG-1 pinned first and Recommended.
struct PolishRailProvider: Identifiable, Equatable {
  let provider: LLMProvider
  let name: String
  let tagline: String
  let isLocal: Bool
  let recommended: Bool

  var id: LLMProvider { provider }
}

enum PolishRailCatalog {
  static let local: [PolishRailProvider] = [
    PolishRailProvider(
      provider: .egOne, name: "EG-1", tagline: "Our tuned model",
      isLocal: true, recommended: true),
    PolishRailProvider(
      provider: .appleIntelligence, name: "Apple Intelligence", tagline: "Built into macOS",
      isLocal: true, recommended: false),
    PolishRailProvider(
      provider: .ollama, name: "Local (Ollama)", tagline: "Any open model",
      isLocal: true, recommended: false),
  ]
  static let cloud: [PolishRailProvider] = [
    PolishRailProvider(
      provider: .openAI, name: "OpenAI", tagline: "Your API key",
      isLocal: false, recommended: false),
    PolishRailProvider(
      provider: .gemini, name: "Google Gemini", tagline: "Your API key",
      isLocal: false, recommended: false),
    PolishRailProvider(
      provider: .claude, name: "Claude", tagline: "Your API key",
      isLocal: false, recommended: false),
  ]
  static let all: [PolishRailProvider] = local + cloud

  static func entry(for provider: LLMProvider) -> PolishRailProvider? {
    all.first { $0.provider == provider }
  }
}

// MARK: - Layout metrics

/// Fixed measurements for the two-column master-detail. The settings window's
/// 710pt minimum guarantees both columns fit, so the layout is always
/// side-by-side and needs no adaptive width measurement.
enum PolishRailMetrics {
  /// Fixed rail column width. Sized to fit the longest engine name
  /// ("Apple Intelligence") beside a 32pt logo tile at full size, while leaving
  /// the detail column as much room as possible at narrow window widths (the
  /// rail row name also shrinks slightly before it would ever truncate).
  static let railWidth: CGFloat = 216
  /// Gap between the rail and the detail column.
  static let columnGap: CGFloat = 16
}

// MARK: - Logo tile

/// The rounded logo tile. One swap site for all six marks:
/// - EG-1: the app's own animated brand mark (`RainbowLipsIcon`) drawn STATIC
///   (audioLevel 0) so there is no fourth copy of the bar coordinates (plan §3c).
/// - Apple: the `apple.logo` SF Symbol (empirically confirmed available).
/// - OpenAI / Gemini / Ollama / Claude: their brand marks as inline SVG
///   rendered via `NSImage(data:)`, template-tinted so one foreground color
///   handles light/dark and selected/unselected (plan §3).
/// Any mark that fails to build falls back to a lettered monogram so a row is
/// never blank (the "Apple tile was empty" class from the preview, plan §7/§9).
struct ProviderLogoTile: View {
  let provider: LLMProvider
  let size: CGFloat
  let isSelected: Bool

  private var cornerRadius: CGFloat { size * 0.28 }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(tileBackground)
      mark
        .frame(width: size, height: size)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)  // decorative; the row's text label is the identifier
  }

  // EG-1 keeps its colored soundwave on a fixed dark chip so the brand mark
  // always reads; every other tile follows the selected/unselected treatment.
  private var tileBackground: Color {
    if provider == .egOne {
      return Color(red: 0.075, green: 0.063, blue: 0.098)  // brand ink, matches #131019
    }
    return isSelected ? Color.stAccent : Color.stAccentLight
  }

  private var markTint: Color {
    isSelected ? Color.white : Color.stTextSecondary
  }

  @ViewBuilder
  private var mark: some View {
    switch provider {
    case .egOne:
      // Reuse the existing brand drawing statically (no audio drive). The mark
      // fills ~78% of the tile with a little inset.
      RainbowLipsIcon(size: size * 0.82, audioLevel: 0)
    case .appleIntelligence:
      appleMark
    case .openAI:
      svgMark(ProviderLogoSVG.openAI, inset: 0.62)
    case .gemini:
      svgMark(ProviderLogoSVG.gemini, inset: 0.60)
    case .ollama:
      svgMark(ProviderLogoSVG.ollama, inset: 0.60)
    case .claude:
      svgMark(ProviderLogoSVG.claude, inset: 0.60)
    case .none:
      monogram("--")
    }
  }

  @ViewBuilder
  private var appleMark: some View {
    if NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) != nil {
      Image(systemName: "apple.logo")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size * 0.52, height: size * 0.52)
        .foregroundStyle(markTint)
    } else {
      monogram("")  // Apple glyph unavailable on the macOS-14 floor → letter fallback
    }
  }

  /// Renders an inline SVG brand mark, template-tinted. `inset` is the fraction
  /// of the tile the glyph occupies. Falls back to a monogram if the SVG fails
  /// to rasterize (macOS-14-floor guard — plan §7 fallback).
  @ViewBuilder
  private func svgMark(_ svg: String, inset: CGFloat) -> some View {
    if let image = ProviderLogoSVG.templateImage(svg) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size * inset, height: size * inset)
        .foregroundStyle(markTint)
    } else {
      monogram(ProviderLogoSVG.monogram(for: provider))
    }
  }

  private func monogram(_ letters: String) -> some View {
    Text(letters)
      .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
      .foregroundStyle(markTint)
  }
}

/// Brand-mark SVG strings + the `NSImage(data:)` render helper. The four
/// monochrome marks (OpenAI / Gemini / Ollama / Claude) are set
/// `isTemplate = true` so SwiftUI `.foregroundStyle` tints them. Marks are
/// used nominatively — solely to identify the provider being configured,
/// monochrome, no endorsement.
enum ProviderLogoSVG {
  static func templateImage(_ svg: String) -> NSImage? {
    guard let data = svg.data(using: .utf8), let image = NSImage(data: data),
      image.isValid
    else { return nil }
    image.isTemplate = true
    return image
  }

  static func monogram(for provider: LLMProvider) -> String {
    switch provider {
    case .openAI: return "OA"
    case .gemini: return "G"
    case .claude: return "CL"
    case .ollama: return "OL"
    case .egOne: return "EG"
    case .appleIntelligence: return ""
    case .none: return "--"
    }
  }

  private static func wrap(_ path: String) -> String {
    "<svg viewBox=\"0 0 24 24\" width=\"24\" height=\"24\" fill=\"currentColor\">"
      + "<path d=\"\(path)\"/></svg>"
  }

  static let openAI = wrap(
    "M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z"
  )

  static let gemini = wrap(
    "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
  )

  static let claude = wrap(
    "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
  )

  static let ollama = wrap(
    "M16.361 10.26a.894.894 0 0 0-.558.47l-.072.148.001.207c0 .193.004.217.059.353.076.193.152.312.291.448.24.238.51.3.872.205a.86.86 0 0 0 .517-.436.752.752 0 0 0 .08-.498c-.064-.453-.33-.782-.724-.897a1.06 1.06 0 0 0-.466 0zm-9.203.005c-.305.096-.533.32-.65.639a1.187 1.187 0 0 0-.06.52c.057.309.31.59.598.667.362.095.632.033.872-.205.14-.136.215-.255.291-.448.055-.136.059-.16.059-.353l.001-.207-.072-.148a.894.894 0 0 0-.565-.472 1.02 1.02 0 0 0-.474.007Zm4.184 2c-.131.071-.223.25-.195.383.031.143.157.288.353.407.105.063.112.072.117.136.004.038-.01.146-.029.243-.02.094-.036.194-.036.222.002.074.07.195.143.253.064.052.076.054.255.059.164.005.198.001.264-.03.169-.082.212-.234.15-.525-.052-.243-.042-.28.087-.355.137-.08.281-.219.324-.314a.365.365 0 0 0-.175-.48.394.394 0 0 0-.181-.033c-.126 0-.207.03-.355.124l-.085.053-.053-.032c-.219-.13-.259-.145-.391-.143a.396.396 0 0 0-.193.032zm.39-2.195c-.373.036-.475.05-.654.086-.291.06-.68.195-.951.328-.94.46-1.589 1.226-1.787 2.114-.04.176-.045.234-.045.53 0 .294.005.357.043.524.264 1.16 1.332 2.017 2.714 2.173.3.033 1.596.033 1.896 0 1.11-.125 2.064-.727 2.493-1.571.114-.226.169-.372.22-.602.039-.167.044-.23.044-.523 0-.297-.005-.355-.045-.531-.288-1.29-1.539-2.304-3.072-2.497a6.873 6.873 0 0 0-.855-.031zm.645.937a3.283 3.283 0 0 1 1.44.514c.223.148.537.458.671.662.166.251.26.508.303.82.02.143.01.251-.043.482-.08.345-.332.705-.672.957a3.115 3.115 0 0 1-.689.348c-.382.122-.632.144-1.525.138-.582-.006-.686-.01-.853-.042-.57-.107-1.022-.334-1.35-.68-.264-.28-.385-.535-.45-.946-.03-.192.025-.509.137-.776.136-.326.488-.73.836-.963.403-.269.934-.46 1.422-.512.187-.02.586-.02.773-.002zm-5.503-11a1.653 1.653 0 0 0-.683.298C5.617.74 5.173 1.666 4.985 2.819c-.07.436-.119 1.04-.119 1.503 0 .544.064 1.24.155 1.721.02.107.031.202.023.208a8.12 8.12 0 0 1-.187.152 5.324 5.324 0 0 0-.949 1.02 5.49 5.49 0 0 0-.94 2.339 6.625 6.625 0 0 0-.023 1.357c.091.78.325 1.438.727 2.04l.13.195-.037.064c-.269.452-.498 1.105-.605 1.732-.084.496-.095.629-.095 1.294 0 .67.009.803.088 1.266.095.555.288 1.143.503 1.534.071.128.243.393.264.407.007.003-.014.067-.046.141a7.405 7.405 0 0 0-.548 1.873c-.062.417-.071.552-.071.991 0 .56.031.832.148 1.279L3.42 24h1.478l-.05-.091c-.297-.552-.325-1.575-.068-2.597.117-.472.25-.819.498-1.296l.148-.29v-.177c0-.165-.003-.184-.057-.293a.915.915 0 0 0-.194-.25 1.74 1.74 0 0 1-.385-.543c-.424-.92-.506-2.286-.208-3.451.124-.486.329-.918.544-1.154a.787.787 0 0 0 .223-.531c0-.195-.07-.355-.224-.522a3.136 3.136 0 0 1-.817-1.729c-.14-.96.114-2.005.69-2.834.563-.814 1.353-1.336 2.237-1.475.199-.033.57-.028.776.01.226.04.367.028.512-.041.179-.085.268-.19.374-.431.093-.215.165-.333.36-.576.234-.29.46-.489.822-.729.413-.27.884-.467 1.352-.561.17-.035.25-.04.569-.04.319 0 .398.005.569.04a4.07 4.07 0 0 1 1.914.997c.117.109.398.457.488.602.034.057.095.177.132.267.105.241.195.346.374.43.14.068.286.082.503.045.343-.058.607-.053.943.016 1.144.23 2.14 1.173 2.581 2.437.385 1.108.276 2.267-.296 3.153-.097.15-.193.27-.333.419-.301.322-.301.722-.001 1.053.493.539.801 1.866.708 3.036-.062.772-.26 1.463-.533 1.854a2.096 2.096 0 0 1-.224.258.916.916 0 0 0-.194.25c-.054.109-.057.128-.057.293v.178l.148.29c.248.476.38.823.498 1.295.253 1.008.231 2.01-.059 2.581a.845.845 0 0 0-.044.098c0 .006.329.009.732.009h.73l.02-.074.036-.134c.019-.076.057-.3.088-.516.029-.217.029-1.016 0-1.258-.11-.875-.295-1.57-.597-2.226-.032-.074-.053-.138-.046-.141.008-.005.057-.074.108-.152.376-.569.607-1.284.724-2.228.031-.26.031-1.378 0-1.628-.083-.645-.182-1.082-.348-1.525a6.083 6.083 0 0 0-.329-.7l-.038-.064.131-.194c.402-.604.636-1.262.727-2.04a6.625 6.625 0 0 0-.024-1.358 5.512 5.512 0 0 0-.939-2.339 5.325 5.325 0 0 0-.95-1.02 8.097 8.097 0 0 1-.186-.152.692.692 0 0 1 .023-.208c.208-1.087.201-2.443-.017-3.503-.19-.924-.535-1.658-.98-2.082-.354-.338-.716-.482-1.15-.455-.996.059-1.8 1.205-2.116 3.01a6.805 6.805 0 0 0-.097.726c0 .036-.007.066-.015.066a.96.96 0 0 1-.149-.078A4.857 4.857 0 0 0 12 3.03c-.832 0-1.687.243-2.456.698a.958.958 0 0 1-.148.078c-.008 0-.015-.03-.015-.066a6.71 6.71 0 0 0-.097-.725C8.997 1.392 8.337.319 7.46.048a2.096 2.096 0 0 0-.585-.041Zm.293 1.402c.248.197.523.759.682 1.388.03.113.06.244.069.292.007.047.026.152.041.233.067.365.098.76.102 1.24l.002.475-.12.175-.118.178h-.278c-.324 0-.646.041-.954.124l-.238.06c-.033.007-.038-.003-.057-.144a8.438 8.438 0 0 1 .016-2.323c.124-.788.413-1.501.696-1.711.067-.05.079-.049.157.013zm9.825-.012c.17.126.358.46.498.888.28.854.36 2.028.212 3.145-.019.14-.024.151-.057.144l-.238-.06a3.693 3.693 0 0 0-.954-.124h-.278l-.119-.178-.119-.175.002-.474c.004-.669.066-1.19.214-1.772.157-.623.434-1.185.68-1.382.078-.062.09-.063.159-.012z"
  )
}

// MARK: - Status chip

/// 7pt dot + short text label. Color from the single mapping; text ALWAYS
/// present so status never depends on color alone (plan §3d).
struct ProviderStatusChip: View {
  let status: ProviderStatus

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(status.tone.color)
        .frame(width: 7, height: 7)
      Text(status.label)
        .font(.stHelper)
        .foregroundStyle(status.tone.color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(status.label)")
  }
}

// MARK: - Rail row

/// One selectable engine row: logo tile + name (+ EG-1 star) + tagline. A native
/// `Button` so it inherits AX button traits + Space/Enter activation; the
/// explicit label/value/hint + `.accessibilityAction` guarantee VoiceOver reads
/// "engine name, group, selected" and can activate it (plan §3d).
struct ProviderRailRow: View {
  let entry: PolishRailProvider
  let isSelected: Bool
  let namespace: Namespace.ID
  let onSelect: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        ProviderLogoTile(provider: entry.provider, size: 32, isSelected: isSelected)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(entry.name)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(isSelected ? Color.stAccent : Color.stTextPrimary)
              .lineLimit(1)
              .minimumScaleFactor(0.85)
            if entry.recommended {
              Image(systemName: "star.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.stAccent)
            }
          }
          Text(entry.tagline)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      // ONE moving highlight (matchedGeometryEffect) so selection glides between
      // rows. Only the selected row renders it; SwiftUI interpolates position on
      // the animated selection change. Solid accent fill + stroke stay the
      // primary selected signal (high-contrast / differentiate-without-colour);
      // the brand rainbow is an ADDITIVE tint on the same edge. #1298.
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.stAccentLight)
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.stAccent, lineWidth: 1.5)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.obRainbow, lineWidth: 1.5)
                .opacity(0.5)
            )
            .matchedGeometryEffect(id: "railSelection", in: namespace)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Subtle hover lift. scaleEffect is a render transform applied AFTER layout,
    // so the row's frame and hover hit-region do not move (no jitter loop); it
    // only grows (1.006), never shrinks. Gated on reduce-motion. #1298.
    .scaleEffect(hovering && !reduceMotion ? 1.006 : 1.0)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("\(entry.name), \(entry.isLocal ? "on this Mac" : "cloud")")
    .accessibilityValue(
      isSelected
        ? "Selected\(entry.recommended ? ", recommended" : "")"
        : (entry.recommended ? "Recommended" : "")
    )
    .accessibilityHint("Selects \(entry.name) for AI polish")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityAction { onSelect() }
  }
}

// MARK: - Rail

/// The grouped vertical rail: "On this Mac" then "Cloud". Writes the selection
/// through the same `settings.llmProvider` setter the old dropdown used — no new
/// state home (plan §3b).
struct ProviderRail: View {
  @Binding var selection: LLMProvider
  /// Shared namespace so the single selection highlight glides between rows
  /// (matchedGeometryEffect) instead of jumping. #1298.
  @Namespace private var selectionNS
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      groupHeader("On this Mac")
      ForEach(PolishRailCatalog.local) { row(for: $0) }
      groupHeader("Cloud")
        .padding(.top, 14)
      ForEach(PolishRailCatalog.cloud) { row(for: $0) }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.stSectionBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI polish engine")
  }

  private func row(for entry: PolishRailProvider) -> some View {
    ProviderRailRow(
      entry: entry,
      isSelected: selection == entry.provider,
      namespace: selectionNS,
      onSelect: {
        // State commits immediately; the spring only animates the highlight
        // glide. Gated on reduce-motion (instant end state).
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) {
          selection = entry.provider
        }
      })
  }

  private func groupHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.stSectionHeader)
      .tracking(0.9)
      .foregroundStyle(Color.stAccent)
      .padding(.horizontal, 12)
      .padding(.bottom, 3)
      .accessibilityHidden(true)
  }
}

// MARK: - Detail header

/// The identity header above the selected engine's existing setup content:
/// 32pt logo, name, EG-1 "Recommended" pill, privacy sub-line, and exactly ONE
/// status chip (the single `providerStatus` summary). The "Recommended" pill is
/// a visual badge only — it never changes the selection (plan §3 honesty).
struct ProviderDetailHeader: View {
  let entry: PolishRailProvider
  let status: ProviderStatus

  private var privacyLine: String {
    // "only" is dropped for cloud providers, not just Claude's: all three
    // (OpenAI/Gemini/Claude) route through the shared `.cloudFixed` prompt
    // family, which conditionally includes the active app name and custom
    // word list alongside the transcript (CloudFixedPromptBuilder) — "text
    // only" was never accurate here, this terse header line just hadn't
    // been caught by #158's earlier fix to the fuller privacy sentences in
    // AIPolishSettingsView.swift (a different string, missed by that
    // round's grep; Codex r8 found it).
    entry.isLocal
      ? "Nothing you dictate leaves this Mac"
      : "Sends transcribed text, never audio"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ProviderLogoTile(provider: entry.provider, size: 32, isSelected: true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 7) {
          Text(entry.name)
            .settingsRowTitle()
          if entry.recommended {
            Text("Recommended")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.stAccent)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(
                Capsule().fill(Color.stAccentLight))
          }
        }
        Text("\(entry.tagline) · \(privacyLine)")
          .font(.stHelper)
          .foregroundStyle(Color.stTextSecondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      ProviderStatusChip(status: status)
    }
    .padding(.vertical, 2)
  }
}
