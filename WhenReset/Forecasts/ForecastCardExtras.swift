import SwiftUI

/// Exhaustion lines and the public Codex reset, under the usage bars.
///
/// A pace that may not last is written in place. "Expected to last", the
/// early-pace note's quieter siblings, and the Codex announcement sit behind
/// a disclosure so the bars stay the primary reading.
struct ForecastCardExtras: View {
    let snapshot: UsageSnapshot

    @Environment(ForecastSettingsStore.self) private var settingsStore
    @Environment(CodexResetStore.self) private var codex
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(at: context.date)
        }
        .onChange(of: usageSignature, initial: true) { _, _ in
            guard snapshot.accountProviderID == .chatGPT else { return }
            codex.noteUsage(snapshot.usageWindows.map(ForecastWindow.init), accountID: snapshot.accountID)
        }
        .task(id: pollKey) {
            guard snapshot.accountProviderID == .chatGPT else { return }
            let settings = settingsStore.settings
            guard settings.showsPredictedReset || settings.remindsBeforePredictedReset else { return }
            codex.wake()
            await codex.refreshIfDue()
        }
    }

    private var pollKey: String {
        let settings = settingsStore.settings
        return "\(settings.showsPredictedReset)-\(settings.remindsBeforePredictedReset)-\(snapshot.accountID)"
    }

    private var usageSignature: String {
        snapshot.usageWindows.map {
            "\($0.metricID)|\($0.usedPercent)|\($0.resetsAt.timeIntervalSince1970)|\($0.reportsReset)"
        }.joined(separator: ";")
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(urgent) { row in
                    ForecastLineText(line: row.line)
                }
                if let lines, !lines.prediction.isPlaceholder {
                    PredictedResetHeadline(lines: lines)
                }
                if !calm.isEmpty || showPredicted {
                    Button {
                        expanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Forecasts")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("forecasts-disclosure")
                    if expanded {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(calm) { row in
                                ForecastLineText(line: row.line)
                            }
                            if showPredicted, let lines {
                                PredictedResetDetails(lines: lines)
                            }
                        }
                    }
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
                .font(.caption.weight(ink.weight == .medium ? .medium : .regular))
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
                Text("Predicted reset")
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
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let bound = lines.prediction.bound {
                Text(bound)
                    .font(.caption2)
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
                Text("Last reset")
                    .font(.caption.weight(.medium))
                    .padding(.top, 2)
                Text(latest.detail)
                    .font(.caption2)
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
            Link(destination: CodexResetEndpoint.site) {
                Label("Codex Resets", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
