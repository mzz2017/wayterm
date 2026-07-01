import SwiftUI
import StoreKit

// MARK: - Plans

enum ProPlanKind: String, CaseIterable, Identifiable {
    case monthly
    case yearly
    case lifetime

    static let displayOrder: [ProPlanKind] = [.monthly, .yearly, .lifetime]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly:
            return String(localized: "Monthly")
        case .yearly:
            return String(localized: "Yearly")
        case .lifetime:
            return String(localized: "Lifetime")
        }
    }

    var billingCaption: String {
        switch self {
        case .monthly:
            return String(localized: "Billed monthly")
        case .yearly:
            return String(localized: "Billed yearly")
        case .lifetime:
            return String(localized: "One-time purchase")
        }
    }

    var detail: String {
        switch self {
        case .monthly:
            return String(localized: "Flexible access to every Pro feature.")
        case .yearly:
            return String(localized: "Best value for ongoing terminal work.")
        case .lifetime:
            return String(localized: "Pay once and keep Pro access forever.")
        }
    }

    var badge: String? {
        switch self {
        case .monthly:
            return nil
        case .yearly:
            return String(localized: "Best value")
        case .lifetime:
            return nil
        }
    }
}

struct PlanSelectionCard: View {
    let product: Product
    let plan: ProPlanKind
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(plan.title)
                            .font(.headline)
                            .fontWeight(.semibold)

                        if let badge = plan.badge {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }

                    Text(priceLine)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(plan.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : cardStroke, lineWidth: isSelected ? 3 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var priceLine: String {
        switch plan {
        case .monthly:
            return String(format: String(localized: "%@ per month"), product.displayPrice)
        case .yearly:
            return String(format: String(localized: "%@ per year"), product.displayPrice)
        case .lifetime:
            return String(format: String(localized: "%@ one time"), product.displayPrice)
        }
    }

    private var cardFill: Color {
        paywallCardFillColor
    }

    private var cardStroke: Color {
        paywallCardBorderColor
    }
}

// MARK: - Comparison Table

struct ComparisonFeature: Identifiable {
    let icon: String
    let title: String
    let free: ComparisonValue
    let pro: ComparisonValue

    var id: String { title }
}

enum ComparisonValue {
    case included(accessibilityLabel: String)
    case number(String)
    case notIncluded(accessibilityLabel: String)
    case text(String, emphasized: Bool)
    case unlimited(accessibilityLabel: String)
}

struct ComparisonTable: View {
    let rows: [ComparisonFeature]

    var body: some View {
        VStack(spacing: 0) {
            ComparisonTableRow(isHeader: true) {
                ComparisonHeaderCell(title: String(localized: "Feature"), alignment: .leading)
            } free: {
                ComparisonHeaderCell(title: String(localized: "Free"), alignment: .center)
            } pro: {
                ComparisonHeaderCell(title: String(localized: "Pro"), alignment: .center)
            }

            separator

            ForEach(rows) { row in
                ComparisonTableRow {
                    ComparisonFeatureCell(feature: row)
                } free: {
                    ComparisonValueCell(value: row.free)
                } pro: {
                    ComparisonValueCell(value: row.pro)
                }

                if row.id != rows.last?.id {
                    separator
                }
            }
        }
        .overlay {
            GeometryReader { proxy in
                Path { path in
                    let featureBoundary = proxy.size.width - (ComparisonTableLayout.valueColumnWidth * 2)
                    let proBoundary = proxy.size.width - ComparisonTableLayout.valueColumnWidth

                    path.move(to: CGPoint(x: featureBoundary, y: 0))
                    path.addLine(to: CGPoint(x: featureBoundary, y: proxy.size.height))
                    path.move(to: CGPoint(x: proBoundary, y: 0))
                    path.addLine(to: CGPoint(x: proBoundary, y: proxy.size.height))
                }
                .stroke(paywallTableGridColor, lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(paywallTableGridColor)
            .frame(height: 0.5)
    }
}

private struct ComparisonTableRow<Feature: View, Free: View, Pro: View>: View {
    var isHeader = false
    @ViewBuilder let feature: Feature
    @ViewBuilder let free: Free
    @ViewBuilder let pro: Pro

    var body: some View {
        HStack(spacing: 0) {
            feature
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, verticalPadding)

            free
                .frame(width: ComparisonTableLayout.valueColumnWidth, alignment: .center)
                .frame(minHeight: rowHeight, alignment: .center)
                .padding(.vertical, verticalPadding)

            pro
                .frame(width: ComparisonTableLayout.valueColumnWidth, alignment: .center)
                .frame(minHeight: rowHeight, alignment: .center)
                .padding(.vertical, verticalPadding)
        }
    }

    private var rowHeight: CGFloat {
        isHeader ? 20 : 20
    }

    private var verticalPadding: CGFloat {
        isHeader ? 6 : 4
    }
}

private enum ComparisonTableLayout {
    static let valueColumnWidth: CGFloat = 68
}

private struct ComparisonFeatureCell: View {
    let feature: ComparisonFeature

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: feature.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15)

            Text(feature.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ComparisonHeaderCell: View {
    let title: String
    let alignment: Alignment

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct ComparisonValueCell: View {
    let value: ComparisonValue

    var body: some View {
        Group {
            switch value {
            case .included(let accessibilityLabel):
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel(accessibilityLabel)

            case .number(let text):
                Text(text)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

            case .notIncluded(let accessibilityLabel):
                Text(verbatim: "-")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(accessibilityLabel)

            case .text(let text, let emphasized):
                Text(text)
                    .font(.caption2)
                    .fontWeight(emphasized ? .semibold : .regular)
                    .foregroundStyle(emphasized ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

            case .unlimited(let accessibilityLabel):
                Image(systemName: "infinity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityLabel(accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

var paywallTableGridColor: Color {
    #if os(iOS)
    Color.primary.opacity(0.10)
    #else
    Color.primary.opacity(0.13)
    #endif
}

var paywallCardFillColor: Color {
    #if os(iOS)
    Color(uiColor: .secondarySystemGroupedBackground)
    #else
    Color(nsColor: .controlBackgroundColor)
    #endif
}

var paywallCardBorderColor: Color {
    #if os(iOS)
    Color.primary.opacity(0.10)
    #else
    Color.primary.opacity(0.16)
    #endif
}

// MARK: - Native Card

struct NativeSectionCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        content
            .padding(padding)
            .background(
                shape.fill(cardFill)
            )
            .clipShape(shape)
            .overlay(
                shape.stroke(cardStroke, lineWidth: 0.5)
            )
    }

    private var cardFill: Color {
        paywallCardFillColor
    }

    private var cardStroke: Color {
        paywallCardBorderColor
    }
}
