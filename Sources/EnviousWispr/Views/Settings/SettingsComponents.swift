import SwiftUI
import EnviousWisprCore

// MARK: - Settings Content Container

/// Replaces `Form { }.formStyle(.grouped)` with a branded ScrollView layout.
struct SettingsContentView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                content
            }
            .padding(.top, SettingsLayout.contentTop)
            .padding(.horizontal, SettingsLayout.contentH)
            .padding(.bottom, SettingsLayout.contentBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stPageBg)
        .tint(.stAccent)
    }
}

// MARK: - Branded Section

/// White card with rounded corners and optional header/footer.
struct BrandedSection<Content: View, Footer: View>: View {
    let header: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        header: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header.uppercased())
                    .font(.stSectionHeader)
                    .foregroundStyle(.stTextTertiary)
                    .padding(.leading, 4)
                    .padding(.bottom, 6)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.stSectionBg)
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
                    .strokeBorder(Color.stDivider, lineWidth: 1)
            )

            footer
                .padding(.leading, 4)
                .padding(.top, 6)
        }
    }
}

extension BrandedSection where Footer == EmptyView {
    init(
        header: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.content = content()
        self.footer = EmptyView()
    }
}

// MARK: - Branded Row

/// Provides consistent row padding and an optional purple-tinted divider.
struct BrandedRow<Content: View>: View {
    let showDivider: Bool
    @ViewBuilder let content: Content

    init(showDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showDivider = showDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsLayout.rowPaddingH)
                .padding(.vertical, SettingsLayout.rowPaddingV)

            if showDivider {
                Divider()
                    .overlay(Color.stDivider)
                    .padding(.horizontal, SettingsLayout.rowPaddingH)
            }
        }
    }
}

// MARK: - Branded Toggle Style

/// Green ON / lavender OFF toggle matching the brand mockups, 38x22 px.
struct BrandedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                toggleTrack(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleTrack(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.stToggleOn : Color.stToggleOff)
                .frame(width: 38, height: 22)

            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                .frame(width: 18, height: 18)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

// MARK: - Branded Slider

/// Label + purple value badge + Low/High range labels + native Slider.
struct BrandedSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let label: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let lowLabel: String
    let highLabel: String
    let format: String

    init(
        _ label: String,
        value: Binding<V>,
        in range: ClosedRange<V>,
        step: V.Stride = 0.1,
        low: String = "Low",
        high: String = "High",
        format: String = "%.1f"
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.lowLabel = low
        self.highLabel = high
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, Double(value)))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.stAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.stAccent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            HStack(spacing: 8) {
                Text(lowLabel).font(.caption2).foregroundStyle(.stTextTertiary)
                Slider(value: $value, in: range, step: step)
                    .tint(.stAccent)
                Text(highLabel).font(.caption2).foregroundStyle(.stTextTertiary)
            }
        }
    }
}

// MARK: - Branded Segmented Picker

/// Custom drawn segmented control matching the brand palette.
struct BrandedSegmentedPicker<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = selection == option.value

                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.stAccent : .stTextSecondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background(isSelected ? Color.stAccentLight : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isSelected ? "selected" : "")

                if index < options.count - 1 {
                    Divider()
                        .frame(height: 16)
                        .overlay(Color.stDivider)
                }
            }
        }
        .background(Color.stPageBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.stDivider, lineWidth: 1)
        )
    }
}

// MARK: - Branded Status Row

/// Green checkmark / red X status indicator for permission-style rows.
struct BrandedStatusRow: View {
    let isGranted: Bool
    let grantedText: String
    let deniedText: String
    var helperText: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? Color.stToggleOn : .stError)

            VStack(alignment: .leading, spacing: 2) {
                Text(isGranted ? grantedText : deniedText)
                if let helperText, !isGranted {
                    Text(helperText)
                        .font(.stHelper)
                        .foregroundStyle(.stTextTertiary)
                }
            }

            Spacer()

            if !isGranted, let actionLabel, let action {
                Button(actionLabel, action: action)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Branded Word Chip

/// Purple pill chip with an X remove button for word lists.
struct BrandedWordChip: View {
    let word: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.stAccent)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.stTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.stAccentLight)
        .clipShape(Capsule())
    }
}

// MARK: - Wrapping HStack (flow layout for chips)

/// Layout that wraps items to the next line when they exceed the available width.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: nil),
            subviews: subviews
        )
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        return (CGSize(width: totalWidth, height: y + rowHeight), positions)
    }
}
