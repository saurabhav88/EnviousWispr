import SwiftUI

/// Compact amber banner shown when Accessibility permission is missing.
///
/// Displayed above the history split view. Provides a "Fix Now" shortcut to the
/// Permissions settings tab and a "Dismiss" button to hide it for the session.
struct AccessibilityWarningBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)

            Text("Paste unavailable — Accessibility permission required")
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer()

            Button("Fix Now") {
                appState.pendingNavigationSection = .permissions
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)

            Button("Dismiss") {
                appState.permissions.dismissAccessibilityWarning()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
