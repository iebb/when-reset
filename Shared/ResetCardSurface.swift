import SwiftUI

/// Reset-card facts for widgets and Live Activity.
///
/// The count and the soonest expiry come from the same snapshot fields as the
/// usage card (`availableResetCount`, `availableResetCredits`). Wording is the
/// card's too: "重置卡" / "Reset cards", never a stored-reset label. A count of
/// zero is absence — callers omit the row entirely.
enum ResetCardSurface {
    struct Fact: Equatable, Sendable {
        var count: Int
        var expiresAt: Date?
    }

    /// `included` is the account's show-reset-cards switch. Widgets pass snapshots
    /// that were already filtered; Live Activity passes the switch explicitly.
    static func fact(snapshot: UsageSnapshot, now: Date, included: Bool = true) -> Fact? {
        guard included else { return nil }
        let count = max(0, max(snapshot.availableResetCount, snapshot.availableResetCredits.count))
        guard count > 0 else { return nil }
        return Fact(count: count, expiresAt: snapshot.nextBankedResetCredit(after: now)?.expiresAt)
    }

    /// Facts in the order the snapshots were given. Widgets keep the stored
    /// account order; this does not sort by remaining quota or expiry.
    static func facts(in snapshots: [UsageSnapshot], now: Date) -> [Fact?] {
        snapshots.map { fact(snapshot: $0, now: now) }
    }

    /// Medium widgets drop the redundant "Usage" title when a reset-card line
    /// needs the row. Large widgets keep the title; they have the height.
    static func showsUsageTitle(showsSecondLimit: Bool, snapshots: [UsageSnapshot], now: Date) -> Bool {
        if showsSecondLimit { return true }
        return !snapshots.contains { fact(snapshot: $0, now: now) != nil }
    }

    /// Next timeline reload. The regular 15-minute refresh stays, and a card
    /// that expires sooner wakes the widget so the line can move to the next card.
    static func reloadDate(
        targetExpiresAt: Date?,
        snapshots: [UsageSnapshot],
        now: Date,
        fallback: TimeInterval = 15 * 60
    ) -> Date {
        var candidates = [now.addingTimeInterval(fallback)]
        if let targetExpiresAt, targetExpiresAt > now {
            candidates.append(targetExpiresAt.addingTimeInterval(1))
        }
        for snapshot in snapshots {
            if let expiry = fact(snapshot: snapshot, now: now)?.expiresAt, expiry > now {
                candidates.append(expiry.addingTimeInterval(1))
            }
        }
        return candidates.min() ?? now.addingTimeInterval(fallback)
    }

    /// "重置卡 1 张" / "1 reset card". Same key the collapsed card line uses.
    static func name(count: Int) -> String {
        let locale = AppLanguage.current.locale
        if count == 1 { return String.localized("1 banked reset") }
        return String(
            format: String.localized("%lld banked resets"),
            locale: locale,
            Int64(max(count, 0))
        )
    }

    static var sectionLabel: String { String.localized("Reset cards") }

    /// Small badge on a crowded row. "卡×1" / "×1".
    static func compactBadge(count: Int) -> String {
        String(
            format: String.localized("×%lld"),
            locale: AppLanguage.current.locale,
            Int64(max(count, 0))
        )
    }

    /// "可用 1 张" / "1 available". The card's expanded value.
    static func countValue(count: Int) -> String {
        ResetCardCopy.availableText(count: max(count, 0))
    }

    static func expiryPhrase(count: Int, expiresAt: Date?, now: Date) -> String? {
        guard let expiresAt, expiresAt > now else { return nil }
        return BankedResetCopy.expiresPhrase(until: expiresAt, from: now, soonestOfMany: count > 1)
    }

    /// Trailing value: count, then the soonest expiry when there is one.
    static func rowValue(count: Int, expiresAt: Date?, now: Date) -> String {
        let countText = countValue(count: count)
        guard let expiry = expiryPhrase(count: count, expiresAt: expiresAt, now: now) else {
            return countText
        }
        return ForecastCopy.format("%@ · %@", countText, expiry)
    }
}

/// Small-widget line. The count phrase stays leading; the soonest expiry trails.
struct ResetCardCompactLine: View {
    var snapshot: UsageSnapshot
    /// Nil follows the clock. Screenshots pass the fixture instant.
    var now: Date? = nil

    var body: some View {
        if let now {
            line(at: now)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                line(at: context.date)
            }
        }
    }

    @ViewBuilder
    private func line(at date: Date) -> some View {
        if let fact = ResetCardSurface.fact(snapshot: snapshot, now: date) {
            let expiry = ResetCardSurface.expiryPhrase(count: fact.count, expiresAt: fact.expiresAt, now: date)
            ResetCardLabelValue(
                label: ResetCardSurface.name(count: fact.count),
                value: expiry,
                emphasizesLabel: true
            )
        }
    }
}

/// Per-account row for the multi-account widget and the expanded Live Activity.
/// Hidden when the count is zero, so accounts without cards do not keep a gap.
struct ResetCardAccountRow: View {
    var count: Int
    var expiresAt: Date?
    var now: Date? = nil
    var onDarkSurface = false

    var body: some View {
        if count <= 0 {
            EmptyView()
        } else if let now {
            labeled(at: now)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                labeled(at: context.date)
            }
        }
    }

    private func labeled(at date: Date) -> some View {
        ResetCardLabelValue(
            label: ResetCardSurface.sectionLabel,
            value: ResetCardSurface.rowValue(count: count, expiresAt: expiresAt, now: date),
            emphasizesLabel: false,
            onDarkSurface: onDarkSurface
        )
    }
}

/// Compact Dynamic Island trailing mark.
/// One phrase, "重置卡 1 张" / "1 reset card", so the number is not a bare digit
/// beside the quota percents.
struct ResetCardCompactMark: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(ResetCardSurface.name(count: count))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityLabel(ResetCardSurface.name(count: count))
        }
    }
}

/// One horizontal pair. The label takes the leading side; the value trails.
private struct ResetCardLabelValue: View {
    var label: String
    var value: String?
    var emphasizesLabel: Bool
    var onDarkSurface = false

    @Environment(\.interfaceStyle) private var interfaceStyle

    var body: some View {
        // Equal columns so a long expiry cannot ellipsize the count.
        // Each side scales down instead of turning into "重置卡 1…".
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(labelFont)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value, !value.isEmpty {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }

    private var labelFont: Font {
        if emphasizesLabel {
            return .caption2.weight(interfaceStyle == .screenTime ? .bold : .semibold)
        }
        return .caption2.weight(interfaceStyle == .screenTime ? .semibold : .regular)
    }

    private var valueFont: Font {
        .caption2.weight(interfaceStyle == .screenTime ? .bold : .semibold)
    }

    private var labelColor: Color {
        if onDarkSurface { return Color.white.opacity(0.72) }
        return emphasizesLabel ? Color.primary : Color.secondary
    }

    private var valueColor: Color {
        if onDarkSurface { return Color.white.opacity(emphasizesLabel ? 0.72 : 0.92) }
        // The small-widget expiry is support text. The account-row value is the fact.
        return emphasizesLabel ? Color.secondary : Color.primary
    }
}
