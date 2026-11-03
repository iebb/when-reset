#if os(iOS)
import SwiftUI
import UIKit

/// Disclosure under the quota bars, then label-left detail rows.
/// No progress bar, no section headers, no estimated value, no token usage.
struct UsageFooter: View {
    let snapshot: UsageSnapshot

    @Environment(ForecastSettingsStore.self) private var settingsStore
    @Environment(CodexResetStore.self) private var codex
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.openURL) private var openURL
    @State private var expanded = false
    @State private var note: UsageNote?

    private var showsBanked: Bool {
        snapshot.availableResetCount > 0 || !snapshot.availableResetCredits.isEmpty
    }

    private var usageSignature: String {
        snapshot.usageWindows.map {
            "\($0.metricID)|\($0.usedPercent)|\($0.resetsAt.timeIntervalSince1970)|\($0.reportsReset)"
        }.joined(separator: ";")
    }

    private var pollKey: String {
        let settings = settingsStore.settings
        return "\(settings.showsPredictedReset)-\(settings.remindsBeforePredictedReset)-\(snapshot.accountID)"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            footer(at: context.date)
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
        .sheet(item: $note) { note in
            NavigationStack {
                ScrollView {
                    Text(note.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .navigationTitle(note.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { self.note = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func footer(at date: Date) -> some View {
        let settings = settingsStore.settings
        let exhaustions = ExhaustionCardCopy.facts(snapshot: snapshot, settings: settings, now: date)
        let resetLine = showsBanked
            ? BankedResetCopy.collapsedLine(
                count: max(snapshot.availableResetCount, snapshot.availableResetCredits.count),
                expiresAt: snapshot.nextBankedResetCredit(after: date)?.expiresAt,
                now: date
            )
            : nil
        let resetDetail = ResetCardCopy.detail(snapshot: snapshot, now: date)
        let summary = CollapsedUsageSummary.make(
            exhaustions: exhaustions,
            resetLine: resetLine,
            resetExpiresIn: ResetCardCopy.soonestExpiry(snapshot: snapshot, now: date)
        )
        let codexStatus = settings.showsPredictedReset && snapshot.accountProviderID == .chatGPT
            ? codex.display(at: date) : nil
        let codexLines = codexCardLines(status: codexStatus, at: date, settings: settings)
        let prediction = codexLines.flatMap { Self.predictionValue($0, status: codexStatus, now: date) }
        let latest = codexLines?.latest
        let balance = snapshot.usageWindows.isEmpty ? nil : snapshot.apiBalance
        let showsCodexButton = settings.showsPredictedReset && snapshot.accountProviderID == .chatGPT
        let hasBody = !exhaustions.isEmpty || resetDetail != nil || prediction != nil || latest != nil || balance != nil || showsCodexButton
        let updated = UpdatedCaption.phrase(since: snapshot.fetchedAt, now: date)
        let showSeparator = !exhaustions.isEmpty && (resetDetail != nil || prediction != nil || latest != nil || balance != nil)

        return VStack(alignment: .leading, spacing: 0) {
            disclosure(
                summary: summary,
                updated: updated,
                canExpand: hasBody
            )
            if expanded, hasBody {
                hairline
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(exhaustions.enumerated()), id: \.element.id) { index, fact in
                        DetailRow(
                            label: String.localized("Exhaustion forecast"),
                            value: fact.value,
                            secondary: fact.secondary.map { [$0] } ?? [],
                            valueColor: factColor(fact),
                            showsWarningMark: fact.warning || fact.critical,
                            identifier: index == 0 ? "usage-footer-forecast" : nil
                        )
                    }
                    if showSeparator {
                        lightSeparator
                    }
                    if let resetDetail {
                        DetailRow(
                            label: String.localized("Reset cards"),
                            value: resetDetail.countText,
                            secondary: resetDetail.lines,
                            valueColor: .primary,
                            showsWarningMark: false,
                            identifier: "usage-footer-reset-cards"
                        )
                    }
                    if let lines = codexLines, let prediction {
                        predictionRow(lines: lines, value: prediction)
                    }
                    if let latest {
                        DetailRow(
                            label: String.localized("Last reset"),
                            value: latest.relative,
                            secondary: [latest.detail],
                            valueColor: .primary,
                            showsWarningMark: false,
                            identifier: "usage-footer-last-reset"
                        )
                    }
                    if let balance {
                        DetailRow(
                            label: balance.title,
                            value: balanceValue(balance),
                            secondary: balanceNotes(balance),
                            valueColor: .primary,
                            showsWarningMark: false,
                            identifier: "usage-footer-balance"
                        )
                    }
                }
                .padding(.top, 10)
                if showsCodexButton {
                    codexButton
                        .padding(.top, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosure(summary: CollapsedUsageSummary, updated: String, canExpand: Bool) -> some View {
        Button {
            guard canExpand else { return }
            withAnimation(.snappy(duration: 0.2)) {
                expanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        if let primary = summary.primary {
                            Text(marked(primary, tone: summary.tone))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(summaryColor(summary.tone))
                                .lineLimit(1)
                        }
                        if let secondary = summary.secondary {
                            Text(secondary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Text(updated)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .accessibilityIdentifier("usage-updated")
                    if canExpand {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forecasts-disclosure")
        .accessibilityValue(Text(expanded ? String.localized("Expanded") : String.localized("Collapsed")))
    }

    private func predictionRow(lines: CodexResetCardLines, value: String) -> some View {
        let secondary = Self.predictionSecondary(lines)
        let noteText = [lines.prediction.note, lines.prediction.typeHelp]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let row = DetailRow(
            label: String.localized("Predicted reset"),
            value: value,
            secondary: secondary.map { [$0] } ?? [],
            valueColor: .primary,
            showsWarningMark: false,
            identifier: "usage-footer-prediction"
        )
        if noteText.isEmpty {
            return AnyView(row)
        }
        return AnyView(Button {
            note = UsageNote(title: String.localized("Predicted reset"), text: noteText)
        } label: {
            row
        }
        .buttonStyle(.plain))
    }

    private var codexButton: some View {
        Button {
            openURL(CodexResetEndpoint.site)
        } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(String.localized("Codex Resets"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(buttonFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("usage-footer-codex")
    }

    private var hairline: some View {
        Rectangle()
            .fill(interfaceStyle == .liquidGlass ? Color.primary.opacity(0.08) : Color(uiColor: .separator))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private var lightSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(height: 1)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    private var buttonFill: Color {
        switch interfaceStyle {
        case .liquidGlass:
            Color.primary.opacity(0.10)
        case .screenTime:
            Color.primary.opacity(0.08)
        case .classic:
            Color(uiColor: .secondarySystemFill)
        }
    }

    private func factColor(_ fact: ExhaustionFact) -> Color {
        if fact.critical { return UsageStatusInk.critical(colorScheme) }
        if fact.warning { return UsageStatusInk.warning(colorScheme) }
        return .secondary
    }

    private func summaryColor(_ tone: CollapsedUsageSummary.Tone) -> Color {
        switch tone {
        case .critical: UsageStatusInk.critical(colorScheme)
        case .warning: UsageStatusInk.warning(colorScheme)
        case .neutral: .secondary
        }
    }

    private func marked(_ text: String, tone: CollapsedUsageSummary.Tone) -> String {
        switch tone {
        case .warning, .critical: "⚠ \(text)"
        case .neutral: text
        }
    }

    private func codexCardLines(status: CodexResetStatus?, at date: Date, settings: ForecastSettings) -> CodexResetCardLines? {
        guard settings.showsPredictedReset, snapshot.accountProviderID == .chatGPT else { return nil }
        let lines = CodexResetCardLines.make(status, now: date)
        let hasPrediction = Self.predictionValue(lines, status: status, now: date) != nil
        guard hasPrediction || lines.latest != nil else { return nil }
        return lines
    }

    /// A short clock on the right. "约 21 小时后" / "in ~21 hours", not the full sentence.
    private static func predictionValue(_ lines: CodexResetCardLines, status: CodexResetStatus?, now: Date) -> String? {
        guard !lines.prediction.isPlaceholder else { return nil }
        if let short = PredictedResetCopy.shortCountdown(status: status, now: now) {
            return short
        }
        return lines.prediction.trailing
    }

    private static func predictionSecondary(_ lines: CodexResetCardLines) -> String? {
        var parts: [String] = []
        if let tag = lines.prediction.typeTag, !tag.isEmpty { parts.append(tag) }
        if lines.prediction.countdown != nil, let trailing = lines.prediction.trailing, !trailing.isEmpty {
            parts.append(trailing)
        }
        if let bound = lines.prediction.bound, !bound.isEmpty { parts.append(bound) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func balanceValue(_ balance: APIBalance) -> String {
        if balance.isUnlimited { return String.localized("Unlimited") }
        return APIBalanceRow.formattedValue(balance.remaining ?? balance.spent, balance: balance)
    }

    private func balanceNotes(_ balance: APIBalance) -> [String] {
        var notes: [String] = []
        if balance.kind != .wallet, balance.remaining != nil {
            notes.append(String(format: String.localized("Spent %@"), locale: AppLanguage.current.locale, APIBalanceRow.formattedValue(balance.spent, balance: balance)))
        }
        return notes
    }
}

private struct UsageNote: Identifiable {
    var title: String
    var text: String
    var id: String { title + text }
}

enum UsageStatusInk {
    static func warning(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1, green: 179 / 255, blue: 64 / 255)
            : Color(red: 194 / 255, green: 65 / 255, blue: 12 / 255)
    }

    static func critical(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1, green: 105 / 255, blue: 97 / 255)
            : Color(red: 198 / 255, green: 40 / 255, blue: 40 / 255)
    }
}

private struct DetailLabelIdentifier: ViewModifier {
    var identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct DetailRow: View {
    var label: String
    var value: String
    var secondary: [String]
    var valueColor: Color
    var showsWarningMark: Bool
    var identifier: String?

    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // ViewThatFits uses each child's ideal width. A long detail line
        // is wider than the card, so it picked the stacked layout and put
        // the label and the time on the left. Accessibility sizes still stack.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                sideBySide
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sideBySide: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            labelText
                .fixedSize(horizontal: true, vertical: false)
            valueStack(alignment: .trailing)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            labelText
            valueStack(alignment: .leading)
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .layoutPriority(1)
            .modifier(DetailLabelIdentifier(identifier: identifier))
    }

    private func valueStack(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(showsWarningMark ? "⚠ \(value)" : value)
                .font(valueFont)
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(secondary, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var valueFont: Font {
        if interfaceStyle == .screenTime {
            return .system(.callout, design: .rounded).weight(.semibold)
        }
        return .subheadline.weight(.semibold)
    }
}
#endif
