import XCTest
import SwiftUI
@testable import WhenReset

#if DEBUG && os(iOS)
@MainActor
final class ScreenshotRenderTests: XCTestCase {
    func testRendersWidgetAndLiveActivityPreviews() {
        let previousLanguage = AppLanguage.current
        let previousAppearance = AppAppearance.current
        let previousBars = UsageBarStyle.current
        defer {
            AppLanguage.choose(previousLanguage)
            AppAppearance.choose(previousAppearance)
            UsageBarStyle.choose(previousBars)
        }
        for language in [AppLanguage.english, AppLanguage.chineseSimplified] {
            for appearance in [AppAppearance.light, AppAppearance.dark] {
                render(language: language, appearance: appearance)
            }
        }
    }

    private func render(language: AppLanguage, appearance: AppAppearance) {
        AppLanguage.choose(language)
        AppAppearance.choose(appearance)
        UsageBarStyle.choose(.continuous)
        if language == .chineseSimplified {
            XCTAssertEqual(String.localized("5h limit"), "5 小时额度")
            XCTAssertEqual(String.localized("Progress bars"), "进度条")
            XCTAssertEqual(String.localized("Segmented"), "分段")
            let now = Date(timeIntervalSince1970: 1_000)
            XCTAssertEqual(
                CountdownDisplay.compactString(until: now.addingTimeInterval(3 * 3_600), from: now),
                "3 小时"
            )
            XCTAssertEqual(
                CountdownDisplay.compactString(until: now.addingTimeInterval(5 * 86_400), from: now),
                "5 天"
            )
        }
        let now = Date()
        let seeded = ScreenshotFixture.seed(now: now)
        let snapshots = seeded.accounts.compactMap { seeded.snapshots[$0.id] }
        let rows = ScreenshotFixture.activityRows(now: now)
        let prefix = "\(language.screenshotPrefix)-\(appearance.rawValue)"
        let scheme = appearance.colorScheme ?? .light
        let withCards = snapshots.first { ResetCardSurface.fact(snapshot: $0, now: now) != nil }
        let withoutCards = snapshots.first { ResetCardSurface.fact(snapshot: $0, now: now) == nil }
        for style in [InterfaceStyle.classic, .screenTime, .liquidGlass] {
            if let withCards {
                attach(
                    ScreenshotSmallUsage(snapshot: withCards, now: now)
                        .screenshotChrome(language: language, scheme: scheme, interfaceStyle: style),
                    name: "\(prefix)-widget-small-\(style.rawValue)",
                    scale: 2,
                    size: CGSize(width: 170, height: 170)
                )
            }
            if let withoutCards {
                attach(
                    ScreenshotSmallUsage(snapshot: withoutCards, now: now)
                        .screenshotChrome(language: language, scheme: scheme, interfaceStyle: style),
                    name: "\(prefix)-widget-small-none-\(style.rawValue)",
                    scale: 2,
                    size: CGSize(width: 170, height: 170)
                )
            }
            attach(
                ScreenshotUsageList(snapshots: Array(snapshots.prefix(4)), showsSecondLimit: false, now: now)
                    .screenshotChrome(language: language, scheme: scheme, interfaceStyle: style),
                name: "\(prefix)-widget-medium-\(style.rawValue)",
                scale: 2,
                size: CGSize(width: 364, height: 170)
            )
            attach(
                ScreenshotLiveLock(rows: rows, now: now)
                    .screenshotChrome(language: language, scheme: scheme, interfaceStyle: style),
                name: "\(prefix)-live-\(style.rawValue)",
                scale: 2,
                size: CGSize(width: 360, height: 320)
            )
            attach(
                ScreenshotLiveLock(rows: Array(rows.prefix(3)), now: now, onDarkSurface: true)
                    .screenshotChrome(language: language, scheme: .dark, interfaceStyle: style),
                name: "\(prefix)-island-\(style.rawValue)",
                scale: 2,
                size: CGSize(width: 360, height: 260)
            )
        }
        attach(
            ScreenshotUsageList(snapshots: snapshots, showsSecondLimit: true, now: now)
                .screenshotChrome(language: language, scheme: scheme, interfaceStyle: .liquidGlass),
            name: "\(prefix)-07-widget-large",
            scale: 2,
            size: CGSize(width: 364, height: 382)
        )
        attach(
            ScreenshotLiveCompact(rows: rows)
                .screenshotChrome(language: language, scheme: scheme),
            name: "\(prefix)-09-live-activity-compact",
            scale: 2,
            size: CGSize(width: 280, height: 48)
        )
    }

    private func attach<V: View>(_ view: V, name: String, scale: CGFloat, size: CGSize) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let image = renderer.uiImage, let data = image.pngData() else {
            return XCTFail("Could not render \(name)")
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension AppLanguage {
    var screenshotPrefix: String {
        switch self {
        case .system, .english: "en"
        case .chineseSimplified: "zh-Hans"
        }
    }
}

private extension View {
    func screenshotChrome(
        language: AppLanguage,
        scheme: ColorScheme,
        interfaceStyle: InterfaceStyle = .liquidGlass
    ) -> some View {
        environment(\.locale, language.locale)
            .environment(\.usageBarStyle, .continuous)
            .environment(\.interfaceStyle, interfaceStyle)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}
#endif
