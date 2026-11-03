import SwiftUI

/// Collapsed forecast title, shared with the usage footer so one chevron
/// covers the forecast and any banked reset.
enum ForecastCardSnapshot {
    static func collapsedTitle(
        snapshot: UsageSnapshot,
        settings: ForecastSettings,
        status: CodexResetStatus?,
        now: Date
    ) -> String? {
        let rows = ForecastCardModel.rows(
            windows: snapshot.usageWindows.map(ForecastWindow.init),
            settings: settings,
            accountID: snapshot.accountID,
            now: now
        )
        let urgent = rows.filter { $0.line.tone != .lasts }
        let calm = rows.filter { $0.line.tone == .lasts }
        let showPredicted = settings.showsPredictedReset && snapshot.accountProviderID == .chatGPT
        if urgent.isEmpty && calm.isEmpty && !showPredicted { return nil }
        if let line = urgent.first?.line {
            let brief = line.brief.isEmpty ? line.text : line.brief
            if !brief.isEmpty { return brief }
        }
        if showPredicted, let status {
            let lines = CodexResetCardLines.make(status, now: now)
            if !lines.prediction.isPlaceholder {
                return String.localized("Predicted reset")
            }
        }
        if let line = calm.first?.line {
            let brief = line.brief.isEmpty ? line.text : line.brief
            if !brief.isEmpty { return brief }
        }
        return String.localized("Forecasts")
    }
}

/// Expanded exhaustion lines and the public Codex reset. The collapsed line
/// and its chevron live on the usage footer.
struct ForecastCardExtras: View {
    let snapshot: UsageSnapshot

    @Environment(ForecastSettingsStore.self) private var settingsStore
    @Environment(CodexResetStore.self) private var codex

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            details(at: context.date)
        }
    }

    @ViewBuilder
    private func details(at date: Date) -> some View {
        let settings = settingsStore.settings
        let rows = ForecastCardModel.rows(
            windows: snapshot.usageWindows.map(ForecastWindow.init),
            settings: settings,
            accountID: snapshot.accountID,
            now: date
        )
        let urgent = rows.filter { $0.line.tone != .lasts }
        let calm = rows.filter { $0.line.tone == .lasts }
        let showPredicted = settings.showsPredictedReset && snapshot.accountProviderID == .chatGPT
        let lines = showPredicted ? CodexResetCardLines.make(codex.display(at: date), now: date) : nil

        if urgent.isEmpty && calm.isEmpty && !showPredicted {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(urgent) { row in
                    ForecastLineText(line: row.line)
                }
                if let lines, !lines.prediction.isPlaceholder {
                    PredictedResetHeadline(lines: lines)
                }
                ForEach(calm) { row in
                    ForecastLineText(line: row.line)
                }
                if showPredicted, let lines {
                    PredictedResetDetails(lines: lines)
                }
            }
            .accessibilityIdentifier("forecasts-extras")
        }
    }
}

private struct ForecastLineText: View {
    let line: BurnRate.CardLine

    var body: some View {
        let ink = ForecastLineInk.style(for: line.tone)
        VStack(alignment: .leading, spacing: 2) {
            Text(line.text)
                .font(ink.weight == .medium ? .caption.weight(.medium) : .caption)
                .foregroundStyle(color(for: ink))
            if let note = line.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.spoken)
    }

    private func color(for ink: ForecastLineInk) -> Color {
        switch ink.hue {
        case .green: Color.green.opacity(ForecastLineInk.opacity)
        case .amber: Color.orange.opacity(ForecastLineInk.opacity)
        }
    }
}

private struct PredictedResetHeadline: View {
    let lines: CodexResetCardLines

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localized: "Predicted reset")
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                if let countdown = lines.prediction.countdown {
                    Text(countdown)
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(ForecastLineInk.opacity))
                        .multilineTextAlignment(.trailing)
                } else if let trailing = lines.prediction.trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let tag = lines.prediction.typeTag, !tag.isEmpty {
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PredictedResetDetails: View {
    let lines: CodexResetCardLines

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.prediction.isPlaceholder, let trailing = lines.prediction.trailing {
                Text(localized: "Predicted reset")
                    .font(.caption.weight(.medium))
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let bound = lines.prediction.bound {
                Text(bound)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = lines.prediction.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let help = lines.prediction.typeHelp, !help.isEmpty {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let latest = lines.latest {
                Text(localized: "Last reset")
                    .font(.caption.weight(.medium))
                    .padding(.top, 2)
                Text(latest.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(latest.relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let help = latest.help, !help.isEmpty {
                    Text(help)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
