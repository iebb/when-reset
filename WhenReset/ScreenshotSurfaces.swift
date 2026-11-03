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
                    Text(quota?.title ?? snapshot.providerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let expiresAt = quota?.expiresAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(CountdownDisplay.widgetString(until: expiresAt, from: now))
                            .font(.caption.bold().monospacedDigit())
                            .lineLimit(1)
                        Text("RESET")
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
                Text("\(Int((quota?.remainingPercent ?? 0).rounded()))%")
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
    var limit = 4

    var body: some View {
        StyledLiveAccountList(rows: rows, onDarkSurface: onDarkSurface, limit: limit, now: now)
            .padding(12)
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
        HStack(spacing: 8) {
            ForEach(rows.prefix(4)) { account in
                VStack(spacing: 1) {
                    ProviderIcon(providerID: account.providerID)
                        .frame(width: 14, height: 14)
                    Text(UsageText.remainingPercent(account.headlineRemainingPercent))
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .foregroundStyle(.primary)
    }
}
#endif
