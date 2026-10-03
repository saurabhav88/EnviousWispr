import SwiftUI

/// #3385: presentation of verified facts, never an engine activation or setup owner.
enum EngineSummaryPresentation {
  static func fastModelStatus(admitted: Bool?) -> ProviderStatus {
    switch admitted {
    case true?: return ProviderStatus(label: EngineSummaryCopy.modelReady, tone: .ready)
    case false?: return ProviderStatus(label: EngineSummaryCopy.modelNotSetUp, tone: .needsSetup)
    case nil: return ProviderStatus(label: EngineSummaryCopy.checking, tone: .unavailable)
    }
  }

  /// Keep the mapping's unhappy states and remedies intact. Ready describes capability,
  /// not words appearing; the full detail remains available through the row's help.
  static func previewStatus(_ summary: LivePreviewStatusMapping.Summary) -> ProviderStatus {
    switch summary.kind {
    case .active: return ProviderStatus(label: EngineSummaryCopy.ready, tone: summary.chip.tone)
    case .off: return ProviderStatus(label: EngineSummaryCopy.off, tone: summary.chip.tone)
    case .needsMacOS26, .checking, .needsLanguage, .unsupportedLanguage, .needsDownload,
      .gettingReady, .downloadFailed, .buildCannotRun, .paused:
      return summary.chip
    }
  }

  static func showsDetail(_ summary: LivePreviewStatusMapping.Summary) -> Bool {
    switch summary.kind {
    case .active, .off: return false
    case .needsMacOS26, .checking, .needsLanguage, .unsupportedLanguage, .needsDownload,
      .gettingReady, .downloadFailed, .buildCannotRun, .paused: return true
    }
  }
}

/// The shared compact icon/name/description anatomy of both PR1 engine summaries.
struct EngineSummaryContent: View {
  let icon: String
  let name: String
  var model: String? = nil
  let short: String
  var status: ProviderStatus? = nil

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(Color.stAccent)
        .frame(width: 36, height: 36)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stAccent.opacity(0.25), lineWidth: 1).allowsHitTesting(false))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).settingsRowLabel()
            if let model { Text(model).font(.stHelper).foregroundStyle(.stTextSecondary) }
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(name).settingsRowLabel()
            if let model { Text(model).font(.stHelper).foregroundStyle(.stTextSecondary) }
          }
        }
        Text(short).font(.stRowHelper).foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      // Status on the same line, beside Change (founder, 2026-10-03: "this should be
      // all 1 line"; mockup 08).
      if let status { ProviderStatusChip(status: status, isHeadline: true) }
    }
    .accessibilityElement(children: .combine)
  }
}

#if DEBUG
/// Boundary/completion hooks for hosted-page tests. No guard or setting is overridden.
struct FastAdmissionTestHooks: Sendable {
  let read: @MainActor @Sendable () async -> Bool
  let onFinished: @MainActor @Sendable (Bool?) -> Void
  var captureRecheck: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { _ in }
}
private struct FastAdmissionTestHooksKey: EnvironmentKey {
  static let defaultValue: FastAdmissionTestHooks? = nil
}
extension EnvironmentValues {
  var fastAdmissionTestHooks: FastAdmissionTestHooks? {
    get { self[FastAdmissionTestHooksKey.self] }
    set { self[FastAdmissionTestHooksKey.self] = newValue }
  }
}
#endif
