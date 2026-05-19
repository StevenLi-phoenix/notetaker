import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    var isActive: Bool = false
    var onTimestampTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            timestampLabel
                .frame(width: DS.Layout.timestampWidth, alignment: .leading)

            Text(segment.text)
                .font(DS.Typography.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.leading, DS.Spacing.xxs)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Timestamp

    @ViewBuilder
    private var timestampLabel: some View {
        if let onTimestampTap {
            Button(action: onTimestampTap) {
                Text(segment.startTime.mmss)
                    .font(DS.Typography.timestamp)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Jump to \(segment.startTime.mmss)")
            .accessibilityLabel("Seek to \(segment.startTime.mmss)")
        } else {
            Text(segment.startTime.mmss)
                .font(DS.Typography.timestamp)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
}
