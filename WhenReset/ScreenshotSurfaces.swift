#if DEBUG && os(iOS)
import SwiftUI

struct ScreenshotUsageList: View {
    var snapshots: [UsageSnapshot]
    var showsSecondLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsSecondLimit ? 6 : 5) {
            Text("Usage")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(snapshots, id: \.accountID) { snapshot in
                row(snapshot)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, showsSecondLimit ? 10 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func row(_ snapshot: UsageSnapshot) -> some View {
        let headline = snapshot.headlineWindow(pinnedMetricID: nil)
        let secondary = headline.flatMap { snapshot.secondaryLimit(after: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ProviderIcon(providerID: snapshot.accountProviderID ?? .chatGPT)
                    .frame(width: 16, height: 16)
                Text(snapshot.resolvedAccountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let headline {
                    if headline.showsCountdown {
                        Text(CountdownDisplay.compactString(until: headline.resetsAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(UsageText.remainingPercent(headline.remainingPercent))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                }
            }
            if let headline {
                ScreenshotMeter(remaining: headline.remainingPercent)
                if showsSecondLimit, let secondary {
                    HStack {
                        Text(secondary.displayTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(UsageText.remainingPercent(secondary.remainingPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct ScreenshotLiveLock: View {
    var rows: [UsageActivityAccountRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.prefix(4)) { account in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ProviderIcon(providerID: account.providerID)
                            .frame(width: 14, height: 14)
                        Text(account.accountName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if account.isSoonestReset {
                            Text(UsageText.soonestBadge())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 4)
                                .background(.orange.opacity(0.85), in: .capsule)
                        }
                        Spacer(minLength: 4)
                        if let reset = account.headlineResetsAt {
                            Text(CountdownDisplay.compactString(until: reset))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        Text(UsageText.remainingPercent(account.headlineRemainingPercent))
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                    }
                    ScreenshotMeter(remaining: account.headlineRemainingPercent)
                    if let secondary = account.secondaryTitle,
                       let percent = account.secondaryRemainingPercent {
                        Text("\(secondary) \(UsageText.remainingPercent(percent))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}

private struct ScreenshotMeter: View {
    var remaining: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.blue)
                    .frame(width: max(0, geo.size.width * min(1, max(0, remaining / 100))))
            }
        }
        .frame(height: 6)
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
        .background(Color.black)
        .foregroundStyle(.white)
    }
}
#endif
