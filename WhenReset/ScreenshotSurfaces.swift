#if DEBUG && os(iOS)
import SwiftUI

struct ScreenshotUsageList: View {
    var snapshots: [UsageSnapshot]
    var showsSecondLimit: Bool
    var now: Date = .now

    var body: some View {
        StyledMultiAccountList(snapshots: snapshots, showsSecondLimit: showsSecondLimit, now: now)
            .padding(.horizontal, 12)
            .padding(.vertical, showsSecondLimit ? 8 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(InterfaceWidgetBackground())
    }
}

struct ScreenshotSmallSquare: View {
    var snapshots: [UsageSnapshot]
    var now: Date

    var body: some View {
        if snapshots.count <= 1, let only = snapshots.first {
            ScreenshotSmallUsage(snapshot: only, now: now)
        } else {
            SmallSquareAccountStack(snapshots: snapshots, now: now)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(InterfaceWidgetBackground())
        }
    }
}

struct ScreenshotSmallUsage: View {
    var snapshot: UsageSnapshot
    var now: Date = .now

    var body: some View {
        let quota = WidgetSurface.metrics(for: snapshot, after: now).first { $0.kind == .quota }
        let hasCards = ResetCardSurface.fact(snapshot: snapshot, now: now) != nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                ProviderIcon(
                    providerID: snapshot.accountProviderID ?? .chatGPT,
                    symbolName: snapshot.accountSymbolName
                )
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.resolvedAccountName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(quota?.title ?? snapshot.providerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                if let expiresAt = quota?.expiresAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(CountdownDisplay.compactString(until: expiresAt, from: now))
                            .font(.caption.bold().monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(String.localized("RESET"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 5)
            if hasCards {
                ResetCardCompactLine(snapshot: snapshot, now: now)
                    .padding(.bottom, 2)
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Spacer(minLength: 0)
                Text(UsageText.widgetFigure(quota?.remainingPercent ?? 0))
                    .font(.system(size: hasCards ? 34 : 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(InterfaceWidgetBackground())
    }
}

struct ScreenshotLiveLock: View {
    var rows: [UsageActivityAccountRow]
    var now: Date = .now
    var onDarkSurface = false
    var denseFrom = 3

    var body: some View {
        StyledLiveAccountList(rows: rows, onDarkSurface: onDarkSurface, denseFrom: denseFrom, now: now)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if onDarkSurface {
                    Color.black
                } else {
                    InterfaceWidgetBackground()
                }
            }
            .foregroundStyle(onDarkSurface ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}

struct ScreenshotLiveCompact: View {
    var rows: [UsageActivityAccountRow]

    var body: some View {
        let visible = LiveActivityAccounts.visible(rows)
        let sides = LiveActivityAccounts.compactSides(of: visible)
        let summary = ResetCardSurface.aggregate(visible.map { ($0.resetCardCount, $0.resetCardExpiresAt) })
        // The camera cutout is the system's. This gap is only that cutout.
        // Nothing is drawn in it: a dash there reads as an empty slot.
        HStack(spacing: 2) {
            LiveCompactCluster(accounts: sides.leading)
            Color.clear
                .frame(width: 8, height: 1)
                .accessibilityHidden(true)
            LiveCompactCluster(accounts: sides.trailing)
            if let summary {
                if LiveActivityAccounts.usesShortResetMark(visible) {
                    Text(ResetCardSurface.compactBadge(count: summary.count))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel(ResetCardSurface.name(count: summary.count))
                } else {
                    ResetCardCompactMark(count: summary.count)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black))
        .foregroundStyle(.white)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
