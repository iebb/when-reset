import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
        guard let symbolName, Self.hasSystemSymbol(named: symbolName) else { return nil }
        return symbolName
    }

    private static func hasSystemSymbol(named name: String) -> Bool {
#if canImport(UIKit)
        UIImage(systemName: name) != nil
#elseif canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
#else
        false
#endif
    }

    private var iconBackgroundColor: Color {
        customSymbolName == nil ? backgroundColor : .secondary.opacity(0.14)
    }

    private var backgroundColor: Color {
        switch providerID {
        case .chatGPT, .openAIAPI: .white
        case .claude: .clear
        case .grok: .black
        case .kimi, .zai, .miniMax, .synthetic, .ollamaCloud, .warp, .antigravity,
             .compatibleAPI, .anthropicAPI, .newAPI: .clear
        case .githubCopilot: .secondary.opacity(0.12)
        }
    }

    private var foregroundColor: Color {
        switch providerID {
        case .chatGPT, .claude, .openAIAPI, .anthropicAPI: .primary
        case .grok: .white
        case .kimi: .indigo
        case .githubCopilot: .purple
        case .zai: .primary
        case .miniMax: Color(red: 0.91, green: 0.21, blue: 0.38)
        case .synthetic: .cyan
        case .ollamaCloud: .primary
        case .warp: .purple
        case .antigravity: .blue
        case .compatibleAPI: .secondary
        case .newAPI: .green
        }
    }

    private var imageInsetFraction: CGFloat {
        switch providerID {
        case .chatGPT, .openAIAPI: 0.16
        case .githubCopilot: 0.18
        case .claude, .anthropicAPI, .kimi, .zai, .grok: 0
        case .miniMax: 0.13
        case .synthetic, .ollamaCloud, .warp, .antigravity, .compatibleAPI, .newAPI: 0.2
        }
    }
}
