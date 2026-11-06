import SwiftUI

/// How many accounts the square widget keeps from the stored custom order.
/// Automatic passes this cap. Five is the most that still fits: four named
/// rows fill the square, and a fifth stays a single line so 智谱 is not dropped
/// off the end of a four-account list.
enum SmallSquareAccounts {
    static let maximum = 5

    static func visible(_ ordered: [UsageSnapshot], limit: Int) -> [UsageSnapshot] {
        let cap = min(maximum, max(1, limit))
        return Array(ordered.prefix(min(cap, ordered.count)))
    }
}

/// Square widget for two to five accounts.
/// One account stays on the rich card. Order is the array order.
struct SmallSquareAccountStack: View {
    var snapshots: [UsageSnapshot]
    var now: Date? = nil

    var body: some View {
        let rows = Array(snapshots.prefix(SmallSquareAccounts.maximum))
        let spacing: CGFloat = rows.count >= 5 ? 2 : 4
        VStack(spacing: spacing) {
            ForEach(rows, id: \.accountID) { snapshot in
                squareRow(snapshot, count: rows.count)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func squareRow(_ snapshot: UsageSnapshot, count: Int) -> some View {
        if count <= 2 {
            TwoAccountRow(snapshot: snapshot, now: now)
        } else {
            DenseAccountRow(snapshot: snapshot, now: now, showsName: count < 5)
        }
    }
}

/// Name and percent on one line, a thin bar, then the reset time and card badge.
private struct TwoAccountRow: View {
    var snapshot: UsageSnapshot
    var now: Date?

    var body: some View {
        let headline = snapshot.headlineWindow(pinnedMetricID: nil)
        let cards = ResetCardSurface.fact(snapshot: snapshot, now: now ?? .now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProviderIcon(providerID: snapshot.accountProviderID ?? .chatGPT, symbolName: snapshot.accountSymbolName)
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { dimensions in dimensions.height * 0.8 }
                Text(snapshot.resolvedAccountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let headline {
                    Text(UsageText.widgetFigure(headline.remainingPercent))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            if let headline {
                ThinQuotaBar(remainingFraction: headline.remainingPercent / 100)
            }
            if headline?.showsCountdown == true || cards != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if cards != nil, let headline, headline.showsCountdown {
                        resetClock(headline)
                        Spacer(minLength: 4)
                        ResetCardCountBadge(count: cards?.count ?? 0)
                    } else {
                        Spacer(minLength: 4)
                        if let headline, headline.showsCountdown {
                            resetClock(headline)
                        }
                        if let cards {
                            ResetCardCountBadge(count: cards.count)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func resetClock(_ headline: UsageWindow) -> some View {
        Text(CountdownDisplay.compactString(until: headline.resetsAt, from: now ?? .now))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Icon, quota, and a card badge. Three and four accounts also keep the name
/// so the square is not a stack of anonymous bars. Five accounts drop the name
/// so the last row is not clipped.
private struct DenseAccountRow: View {
    var snapshot: UsageSnapshot
    var now: Date?
    var showsName: Bool

    var body: some View {
        let headline = snapshot.headlineWindow(pinnedMetricID: nil)
        let cards = ResetCardSurface.fact(snapshot: snapshot, now: now ?? .now)
        HStack(alignment: .center, spacing: 6) {
            ProviderIcon(providerID: snapshot.accountProviderID ?? .chatGPT, symbolName: snapshot.accountSymbolName)
                .frame(width: showsName ? 22 : 16, height: showsName ? 22 : 16)
            VStack(alignment: .leading, spacing: showsName ? 4 : 3) {
                HStack(alignment: showsName ? .firstTextBaseline : .center, spacing: 4) {
                    if showsName {
                        Text(snapshot.resolvedAccountName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    if !showsName, let headline {
                        ThinQuotaBar(remainingFraction: headline.remainingPercent / 100)
                    } else {
                        Spacer(minLength: 4)
                    }
                    if let headline {
                        Text(UsageText.widgetFigure(headline.remainingPercent))
                            .font((showsName ? Font.caption : Font.caption2).weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    if let cards {
                        ResetCardCountBadge(count: cards.count)
                            .layoutPriority(1)
                    }
                }
                if showsName, let headline {
                    ThinQuotaBar(remainingFraction: headline.remainingPercent / 100, height: 5)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ResetCardCountBadge: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(ResetCardSurface.compactBadge(count: count))
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.10), in: Capsule())
                .accessibilityLabel(ResetCardSurface.name(count: count))
        }
    }
}

private struct ThinQuotaBar: View {
    var remainingFraction: Double
    var height: CGFloat = 3
    @Environment(\.quotaPercentBasis) private var basis
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let remaining = min(1, max(0, remainingFraction))
        let fill = basis.fillFraction(remainingFraction: remaining)
        let tint = UsageMeterTint.color(remainingFraction: remaining, colorScheme: colorScheme)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: max(fill > 0 ? 2 : 0, geo.size.width * fill))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
