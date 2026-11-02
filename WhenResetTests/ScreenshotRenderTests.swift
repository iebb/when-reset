import XCTest
import SwiftUI
@testable import WhenReset

#if DEBUG && os(iOS)
@MainActor
final class ScreenshotRenderTests: XCTestCase {
    func testRendersWidgetAndLiveActivityPreviews() {
        let previous = AppLanguage.current
        defer { AppLanguage.choose(previous) }
        render(language: .english, prefix: "en")
        render(language: .chineseSimplified, prefix: "zh-Hans")
    }

    private func render(language: AppLanguage, prefix: String) {
        AppLanguage.choose(language)
        if language == .chineseSimplified {
            XCTAssertEqual(String.localized("5h limit"), "5 小时额度")
            XCTAssertEqual(String.localized("Open %@ linking"), "打开 %@ 关联")
            let now = Date(timeIntervalSince1970: 1_000)
            XCTAssertEqual(
                CountdownDisplay.compactString(until: now.addingTimeInterval(3 * 3_600), from: now),
                "3小时"
            )
            XCTAssertEqual(
                CountdownDisplay.compactString(until: now.addingTimeInterval(5 * 86_400), from: now),
                "5天"
            )
        }
        let seeded = ScreenshotFixture.seed()
        let snapshots = seeded.accounts.compactMap { seeded.snapshots[$0.id] }
        let rows = ScreenshotFixture.activityRows()
        let locale = language.locale
        attach(
            ScreenshotUsageList(snapshots: Array(snapshots.prefix(4)), showsSecondLimit: false)
                .environment(\.locale, locale)
                .frame(width: 364, height: 170),
            name: "\(prefix)-06-widget-medium",
            scale: 2
        )
        attach(
            ScreenshotUsageList(snapshots: snapshots, showsSecondLimit: true)
                .environment(\.locale, locale)
                .frame(width: 364, height: 382),
            name: "\(prefix)-07-widget-large",
            scale: 2
        )
        attach(
            ScreenshotLiveLock(rows: rows)
                .environment(\.locale, locale)
                .frame(width: 360, height: 280),
            name: "\(prefix)-08-live-activity-lock",
            scale: 2
        )
        attach(
            ScreenshotLiveCompact(rows: rows)
                .environment(\.locale, locale)
                .frame(width: 280, height: 48),
            name: "\(prefix)-09-live-activity-compact",
            scale: 2
        )
    }

    private func attach<V: View>(_ view: V, name: String, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
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
#endif
