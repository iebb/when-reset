import SwiftUI

struct ProviderIcon: View {
    let providerID: ProviderID

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
            if let assetName = providerID.logoAssetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(providerID == .githubCopilot ? .template : .original)
                    .scaledToFit()
                    .padding(imagePadding)
                    .foregroundStyle(providerID == .githubCopilot ? Color.primary : foregroundColor)
            } else {
                Image(systemName: providerID.systemImageName)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .foregroundStyle(foregroundColor)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private var backgroundColor: Color {
        switch providerID {
        case .chatGPT: .white
        case .claude: .clear
        case .kimi, .zai, .miniMax: .clear
        case .githubCopilot: .secondary.opacity(0.12)
        }
    }

    private var foregroundColor: Color {
        switch providerID {
        case .chatGPT, .claude: .primary
        case .kimi: .indigo
        case .githubCopilot: .purple
        case .zai: .primary
        case .miniMax: Color(red: 0.91, green: 0.21, blue: 0.38)
        }
    }

    private var imagePadding: CGFloat {
        switch providerID {
        case .chatGPT: 7
        case .githubCopilot: 9
        case .claude, .kimi, .zai: 0
        case .miniMax: 6
        }
    }
}
