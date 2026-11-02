import SwiftUI

/// Forecast switches. One section, so the rest of Settings stays as it is.
struct ForecastSettingsSection: View {
    let accounts: [MonitoredAccount]

    @Environment(ForecastSettingsStore.self) private var settingsStore
    @Environment(CodexResetStore.self) private var codex

    var body: some View {
        let settings = settingsStore.settings
        Section {
            Toggle("Show the estimate", isOn: binding(\.showsForecast))
                .accessibilityIdentifier("forecasts-show-estimate")
            if settings.showsForecast {
                Stepper(value: hoursBinding, in: ExhaustionStage.minimumHours...ExhaustionStage.maximumHours) {
                    LabeledContent(
                        "Countdown up to",
                        value: ExhaustionHoursControl.digits(settings.exhaustionCardHours)
                    )
                }
                .accessibilityIdentifier("forecasts-countdown-hours")
                Toggle("May run out before reset", isOn: binding(\.exhaustionSoftHint))
                    .accessibilityIdentifier("forecasts-soft-hint")
                Toggle("Say roughly when", isOn: binding(\.exhaustionBeforeReset))
                    .accessibilityIdentifier("forecasts-before-reset")
                Toggle("All accounts", isOn: allAccountsBinding)
                    .accessibilityIdentifier("forecasts-all-accounts")
                if !settings.allAccounts {
                    ForEach(accounts) { account in
                        Toggle(account.resolvedDisplayName, isOn: accountBinding(account.id))
                    }
                }
            }
            Toggle("Show predicted reset", isOn: binding(\.showsPredictedReset))
                .accessibilityIdentifier("forecasts-show-predicted")
                .onChange(of: settings.showsPredictedReset) { _, _ in
                    codex.wake()
                }
            Toggle("Remind before a predicted reset", isOn: binding(\.remindsBeforePredictedReset))
                .accessibilityIdentifier("forecasts-remind-predicted")
                .onChange(of: settings.remindsBeforePredictedReset) { _, enabled in
                    Task {
                        if enabled { await ForecastReminderScheduler.authorizeIfNeeded() }
                        await codex.remindersDidChange()
                        codex.wake()
                    }
                }
            if settings.remindsBeforePredictedReset {
                Picker("How early", selection: leadBinding) {
                    ForEach(ResetLead.allCases) { lead in
                        Text(verbatim: lead.title).tag(lead)
                    }
                }
                .accessibilityIdentifier("forecasts-predicted-lead")
                .onChange(of: settings.predictedResetLeadHours) { _, _ in
                    Task { await codex.remindersDidChange() }
                }
            }
        } header: {
            Text("Forecasts")
        } footer: {
            Text("Shows how long the weekly limit may last, or the longest other limit when there is no weekly one. A shorter limit that states its length, including five hours, appears when that pace runs out before its reset. Predicted reset is the public Codex Resets forecast on ChatGPT cards, not that account's own clock.")
        }
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { settingsStore.settings.exhaustionCardHours },
            set: { settingsStore.settings.exhaustionCardHours = ExhaustionHoursControl.applied($0) }
        )
    }

    private var allAccountsBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.allAccounts },
            set: { enabled in
                if !enabled, settingsStore.settings.accountIDs.isEmpty {
                    settingsStore.settings.accountIDs = accounts.map(\.id)
                }
                settingsStore.settings.allAccounts = enabled
            }
        )
    }

    private var leadBinding: Binding<ResetLead> {
        Binding(
            get: { ResetLead.resolved(settingsStore.settings.predictedResetLeadHours) },
            set: { settingsStore.settings.predictedResetLeadHours = $0.rawValue }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<ForecastSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }

    private func accountBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settingsStore.settings.accountIDs.contains(id) },
            set: { included in
                var ids = settingsStore.settings.accountIDs
                if included {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                settingsStore.settings.accountIDs = ids
            }
        )
    }
}
