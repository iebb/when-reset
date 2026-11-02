import XCTest
@testable import WhenReset

final class UsageBarTests: XCTestCase {
    func testSegmentedTicksNeverLookUntouchedOrFullUntilTheyAre() {
        let width: CGFloat = 100
        let empty = UsageBar.ticks(width: width, fraction: 0)
        XCTAssertGreaterThan(empty.count, 1)
        XCTAssertEqual(empty.lit, 0)

        let touched = UsageBar.ticks(width: width, fraction: 0.001)
        XCTAssertEqual(touched.count, empty.count)
        XCTAssertEqual(touched.lit, 1)

        let almost = UsageBar.ticks(width: width, fraction: 0.999)
        XCTAssertEqual(almost.lit, almost.count - 1)

        let full = UsageBar.ticks(width: width, fraction: 1)
        XCTAssertEqual(full.lit, full.count)
    }

    func testBarStyleDefaultsToSegmented() {
        let standard = UserDefaults.standard
        let shared = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)
        let key = UsageBarStyle.storageKey
        let previousStandard = standard.string(forKey: key)
        let previousShared = shared?.string(forKey: key)
        standard.removeObject(forKey: key)
        shared?.removeObject(forKey: key)
        defer {
            if let previousStandard {
                standard.set(previousStandard, forKey: key)
            }
            if let shared {
                if let previousShared {
                    shared.set(previousShared, forKey: key)
                } else {
                    shared.removeObject(forKey: key)
                }
            }
        }
        XCTAssertEqual(UsageBarStyle.current, .segmented)
    }
}
