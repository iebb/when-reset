import SwiftUI

struct AddAccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var completionTask: Task<Void, Never>?
    @State private var selectedProvider: ProviderID?
    @State private var claudeCode = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let link = store.link {
                    linkView(link)
                } else if let claudeLink = store.claudeLink {
                    claudeCodeView(claudeLink)
                } else {
                    providerView
                }
            }
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } } }
            .onDisappear { completionTask?.cancel() }
            .alert("Couldn’t link account", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var providerView: some View {
        List {
            Section {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    Button { withAnimation { selectedProvider = provider } } label: {
                        ProviderCard(provider: provider, selected: selectedProvider == provider)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Choose a provider")
            }
            if let selectedProvider {
                Section(selectedProvider.displayName) {
                    if selectedProvider == .chatGPT { chatGPTLinker } else { claudeLinker }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var chatGPTLinker: some View {
        Group {
            Text("Uses the same secure device-link flow as Codex. Your token is stored only in this device’s Keychain.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Continue with ChatGPT") {
                completionTask = Task {
                    await store.beginLink()
                    if let link = store.link {
                        openURL(link.verificationURL)
                        if await store.completeLink() { dismiss() }
                    }
                }
            }.buttonStyle(.borderedProminent).disabled(store.isLinking)
            if store.isLinking { ProgressView("Starting secure link…") }
        }
    }

    private var claudeLinker: some View {
        Group {
            Text("Sign in with Claude using the same PKCE OAuth flow as Claude Code. Access and refresh tokens are stored only in this device’s Keychain.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Continue with Claude") {
                store.beginClaudeLink()
                if let url = store.claudeLink?.authorizationURL { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isLinking)
        }
    }

    private func claudeCodeView(_ link: ClaudeOAuthLink) -> some View {
        Form {
            Section("Finish Claude sign-in") {
                Text("After approving access in Safari, copy the authorization code from Claude and paste it here.")
                    .foregroundStyle(.secondary)
                TextField("Authorization code", text: $claudeCode, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...5)
                Button("Finish linking") {
                    completionTask = Task {
                        if await store.completeClaudeLink(code: claudeCode) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(claudeCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLinking)
                Button("Open Claude again") { openURL(link.authorizationURL) }
            }
            Section {
                Text("The code may include a #state suffix. Paste the complete value so When Reset can verify the sign-in attempt.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func linkView(_ link: DeviceLink) -> some View {
        VStack(spacing: 18) {
            Text("Enter this code").font(.headline)
            Text(link.userCode).font(.system(.largeTitle, design: .monospaced, weight: .bold)).textSelection(.enabled)
            Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = link.userCode }
            Button("Open ChatGPT linking") { openURL(link.verificationURL) }.buttonStyle(.borderedProminent)
            ProgressView("Waiting for ChatGPT…")
            Text("The code expires in 15 minutes.").font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 32).padding(.horizontal)
    }

    private func cancel() { completionTask?.cancel(); store.cancelLink(); dismiss() }
}

private struct ProviderCard: View {
    let provider: ProviderID
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if provider == .chatGPT {
                    RoundedRectangle(cornerRadius: 12).fill(.white)
                }
                Image(provider == .chatGPT ? "ChatGPTLogo" : "ClaudeLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(provider == .chatGPT ? 7 : 0)
            }
            .frame(width: 46, height: 46)
            .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.headline).foregroundStyle(.primary)
                Text(provider == .chatGPT ? "Usage limits and banked resets" : "Session and weekly reset times")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
