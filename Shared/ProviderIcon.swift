import SwiftUI
import UIKit

struct ProviderIcon: View {
    let providerID: ProviderID
    var symbolName: String? = nil

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: max(2, side * 0.26))
                    .fill(iconBackgroundColor)
                if let customSymbolName {
                    Image(systemName: customSymbolName)
                        .resizable()
                        .scaledToFit()
                        .padding(side * 0.2)
                        .foregroundStyle(Color.primary)
                } else if let assetName = providerID.logoAssetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(providerID == .githubCopilot ? .template : .original)
                        .scaledToFit()
                        .padding(side * imageInsetFraction)
                        .foregroundStyle(providerID == .githubCopilot ? Color.primary : foregroundColor)
                } else {
                    Image(systemName: providerID.systemImageName)
                        .resizable()
                        .scaledToFit()
                        .padding(side * 0.2)
                        .foregroundStyle(foregroundColor)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var customSymbolName: String? {
        guard let symbolName, UIImage(systemName: symbolName) != nil else { return nil }
        return symbolName
    }

    private var iconBackgroundColor: Color {
        customSymbolName == nil ? backgroundColor : .secondary.opacity(0.14)
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

    private var imageInsetFraction: CGFloat {
        switch providerID {
        case .chatGPT: 0.16
        case .githubCopilot: 0.18
        case .claude, .kimi, .zai: 0
        case .miniMax: 0.13
        }
    }
}
