import AppKit
import SwiftUI

/// Shared family identity treatment. Keep this small native view in sync across the four repos.
struct FamilyHeader: View {
    let title: String
    let subtitle: String
    var statusSymbol: String? = nil
    var statusColor: Color = .secondary

    private static let icon = NSImage(named: NSImage.applicationIconName)

    var body: some View {
        HStack(spacing: 12) {
            if let icon = Self.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let statusSymbol {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                            .accessibilityHidden(true)
                    }
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
