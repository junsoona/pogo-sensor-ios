import SwiftUI

/// A small status pill combining icon, text, and color so status is legible even
/// with Reduce Transparency or grayscale accessibility settings on.
struct StatusBadge: View {
    let status: SensorStatus

    var body: some View {
        Label(status.displayName, systemImage: status.symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(PogoTheme.color(for: status))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PogoTheme.color(for: status).opacity(0.15), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(SensorStatus.allCases, id: \.self) { status in
            StatusBadge(status: status)
        }
    }
    .padding()
}
