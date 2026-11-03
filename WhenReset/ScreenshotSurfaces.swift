#if DEBUG && os(iOS)
import SwiftUI

struct ScreenshotUsageList: View {
    var snapshots: [UsageSnapshot]
    var showsSecondLimit: Bool

    var body: some View {
        StyledMultiAccountList(snapshots: snapshots, showsSecondLimit: showsSecondLimit)
            .padding(.horizontal, 12)
            .padding(.vertical, showsSecondLimit ? 8 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(InterfaceWidgetBackground())
    }
}

struct ScreenshotLiveLock: View {
    var rows: [UsageActivityAccountRow]

    var body: some View {
        StyledLiveAccountList(rows: rows)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(InterfaceWidgetBackground())
            .foregroundStyle(.primary)
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
