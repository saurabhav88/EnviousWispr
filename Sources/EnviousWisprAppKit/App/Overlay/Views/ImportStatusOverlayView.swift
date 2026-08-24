import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

/// Bulk-import-enrichment start/finish pill (#1701 Chunk 2). Mirrors
/// `NotificationOverlayView`'s shell with a neutral status icon — this is
/// neither an error nor a warning, so it does not borrow `NotificationStyle`.
struct ImportStatusOverlayView: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundStyle(.white)
        .font(.system(size: 16))
      Text(message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(OverlayCapsuleBackground())
  }
}
