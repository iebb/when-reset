import XCTest
@testable import WhenReset

final class ForecastLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        AppLanguage.choose(.system)
        super.tearDown()
    }

    // MARK: - Exhaustion windows

    func testWeeklyBeatsFiveHour() {
        let five = window("5h", kind: .fiveHour, seconds: 18_000)
        let week = window("week", kind: .weekly, seconds: 604_800)
        XCTAssertEqual(ExhaustionEstimate.windows(in: [five, week]).map(\.id), ["week"])
        XCTAssertTrue(ExhaustionEstimate.includes(week, among: [five, week]))
        XCTAssertFalse(ExhaustionEstimate.includes(five, among: [five, week]))
    }

    func testEveryWeeklyIsKept() {
        let first = window("a", kind: .weekly, seconds: 604_800)
        let second = window("b", kind: .weekly, seconds: 604_800, reportsLength: false)
        let month = window("month", kind: .monthly, seconds: 30 * 86_400)
        XCTAssertEqual(ExhaustionEstimate.windows(in: [month, first, second]).map(\.id), ["a", "b"])
    }

    func testLongestFallbackWithoutAWeek() {
        let day = window("day", kind: .daily, seconds: 86_400)
        let month = window("month", kind: .monthly, seconds: 30 * 86_400)
        XCTAssertEqual(ExhaustionEstimate.windows(in: [day, month]).map(\.id), ["month"])
        XCTAssertEqual(ExhaustionEstimate.windows(in: [day]).map(\.id), ["day"])
    }

    func testEqualLengthsKeepTheEarlierId() {
        let later = window("b", kind: .daily, seconds: 86_400)
        let earlier = window("a", kind: .monthly, seconds: 86_400)
        XCTAssertEqual(ExhaustionEstimate.windows(in: [later, earlier]).map(\.id), ["a"])
    }

    func testFiveHourIsNeverTheFallback() {
        let five = window("5h", kind: .fiveHour, seconds: 18_000)
        XCTAssertTrue(ExhaustionEstimate.windows(in: [five]).isEmpty)
        let mislabelled = window("odd", kind: .daily, seconds: ExhaustionEstimate.fiveHourSeconds)
        let week = window("week", kind: .weekly, seconds: 604_800, reportsLength: false)
        XCTAssertTrue(ExhaustionEstimate.windows(in: [mislabelled]).isEmpty)
        XCTAssertEqual(ExhaustionEstimate.windows(in: [mislabelled, week]).map(\.id), ["week"])
    }

    func testMoneyAndPacksAreNotEstimated() {
        let balance = window("balance", kind: .balance, seconds: 365 * 86_400)
        let pack = window("pack", kind: .topUp, seconds: 365 * 86_400)
        let messages = window("messages", kind: .messages, seconds: 86_400)
        let spend = window("spend", kind: .spend, seconds: 30 * 86_400)
        let five = window("5h", kind: .fiveHour, seconds: 18_000)
        XCTAssertTrue(ExhaustionEstimate.windows(in: [balance, pack, messages, spend, five]).isEmpty)
        let day = window("day", kind: .daily, seconds: 86_400)
        XCTAssertEqual(
            ExhaustionEstimate.windows(in: [balance, pack, messages, spend, day]).map(\.id),
            ["day"]
        )
    }

    func testUnstatedLengthIsNotTheFallback() {
        let sorted = window("sorted", kind: .monthly, seconds: 30 * 86_400, reportsLength: false)
        let day = window("day", kind: .daily, seconds: 86_400)
        XCTAssertTrue(ExhaustionEstimate.windows(in: [sorted]).isEmpty)
        XCTAssertEqual(ExhaustionEstimate.windows(in: [sorted, day]).map(\.id), ["day"])
    }

    // MARK: - Burn rate

    func testReadingKeepsTheTimePastSixHours() {
        let far = BurnRate.reading(for: weekly(used: pace(remaining: 37 * 3600)), now: now)
        XCTAssertEqual(far?.exhaustsBeforeReset, true)
        XCTAssertEqual(far?.timeToExhaustion ?? 0, 37 * 3600, accuracy: 60)

        let close = BurnRate.reading(for: weekly(used: pace(remaining: 4 * 3600)), now: now)
        XCTAssertEqual(close?.exhaustsBeforeReset, true)
        XCTAssertEqual(close?.timeToExhaustion ?? 0, 4 * 3600, accuracy: 60)
    }

    func testReadingRefusesWhatItCannotDivide() {
        useEnglish()
        let lasts = BurnRate.reading(for: weekly(used: 0.2), now: now)
        XCTAssertEqual(lasts?.exhaustsBeforeReset, false)
        XCTAssertNil(lasts?.timeToExhaustion)
        XCTAssertEqual(lasts?.earlyPace, false)

        let barely = window("window", used: 0.01, resetsAt: now.addingTimeInterval(598_752))
        let quiet = BurnRate.reading(for: barely, now: now)
        XCTAssertEqual(quiet?.exhaustsBeforeReset, false)
        XCTAssertNil(quiet?.timeToExhaustion)
        XCTAssertEqual(quiet?.earlyPace, false)
        let quietLine = BurnRate.cardLine(
            for: barely, reading: quiet!, horizon: 6 * 3600, softHint: true, beforeReset: true
        )
        XCTAssertEqual(quietLine?.tone, .lasts)
        XCTAssertNil(quietLine?.note)

        let unstated = window("window", used: 0.8, resetsAt: now.addingTimeInterval(302_400), reportsLength: false)
        XCTAssertNil(BurnRate.reading(for: unstated, now: now))
        XCTAssertNil(BurnRate.reading(for: window("window", used: 0.8, omitReset: true), now: now))
    }

    func testCardLineFollowsTheSwitches() {
        useEnglish()
        let week = weekly(used: pace(remaining: 37 * 3600))
        let reading = BurnRate.reading(for: week, now: now)!
        let horizon = 6.0 * 3600

        let countdown = BurnRate.cardLine(
            for: week, reading: reading, horizon: 48 * 3600, softHint: true, beforeReset: true
        )
        XCTAssertEqual(countdown?.tone, .countdown)
        XCTAssertEqual(countdown?.text, "Weekly · may run out in 1d 13h")
        XCTAssertNil(countdown?.note)

        let tied = BurnRate.cardLine(
            for: week, reading: reading, horizon: horizon, softHint: true, beforeReset: true
        )
        XCTAssertEqual(tied?.tone, .beforeReset)
        XCTAssertEqual(tied?.text, "At the current pace, about 1d 13h before the next reset.")

        let hint = BurnRate.cardLine(
            for: week, reading: reading, horizon: horizon, softHint: true, beforeReset: false
        )
        XCTAssertEqual(hint?.tone, .hint)
        XCTAssertEqual(hint?.text, "Weekly · may run out before the reset")
        XCTAssertNil(BurnRate.cardLine(
            for: week, reading: reading, horizon: horizon, softHint: false, beforeReset: false
        ))

        let close = weekly(used: pace(remaining: 4 * 3600))
        let soon = BurnRate.cardLine(
            for: close, reading: BurnRate.reading(for: close, now: now)!,
            horizon: horizon, softHint: false, beforeReset: false
        )
        XCTAssertEqual(soon?.tone, .countdown)
        XCTAssertEqual(soon?.text, "Weekly · may run out in about 4 hours")

        let steady = weekly(used: 0.2)
        XCTAssertEqual(
            BurnRate.cardLine(
                for: steady, reading: BurnRate.reading(for: steady, now: now)!,
                horizon: horizon, softHint: true, beforeReset: true
            )?.tone,
            .lasts
        )

        let fiveHour = window(
            "window", kind: .fiveHour, scope: "GPT", used: 0.7, seconds: 18_000,
            resetsAt: now.addingTimeInterval(4 * 3600)
        )
        let named = BurnRate.cardLine(
            for: fiveHour, reading: BurnRate.reading(for: fiveHour, now: now)!,
            horizon: horizon, softHint: true, beforeReset: true
        )
        XCTAssertTrue(named?.text.hasPrefix("5-hour · GPT · ") == true)

        useChinese()
        XCTAssertEqual(BurnRate.approximate(37 * 3600), "约 1天13小时")
        XCTAssertEqual(BurnRate.span(37 * 3600), "1天13小时")
        let chinese = BurnRate.cardLine(
            for: week, reading: reading, horizon: 48 * 3600, softHint: true, beforeReset: true
        )
        XCTAssertEqual(chinese?.text, "每周 · 约 1天13小时后用尽")
        XCTAssertNil(chinese?.note)
    }

    func testEarlyElevatedPaceStillForecasts() {
        useEnglish()
        let opened = now.addingTimeInterval(598_752)
        let light = window("window", used: 0.04, resetsAt: opened)
        let quiet = BurnRate.reading(for: light, now: now)
        XCTAssertEqual(quiet?.earlyPace, false)
        XCTAssertNil(BurnRate.cardLine(
            for: light, reading: quiet!, horizon: 6 * 3600, softHint: true, beforeReset: true
        )?.note)

        let burst = window("window", used: BurnRate.earlyQuietUsed, resetsAt: opened)
        let burstReading = BurnRate.reading(for: burst, now: now)
        XCTAssertEqual(burstReading?.earlyPace, true)
        XCTAssertEqual(burstReading?.exhaustsBeforeReset, true)
        XCTAssertEqual(burstReading?.timeToExhaustion ?? 0, 31.92 * 3600, accuracy: 60)
        let burstLine = BurnRate.cardLine(
            for: burst, reading: burstReading!, horizon: 6 * 3600, softHint: true, beforeReset: true
        )
        XCTAssertEqual(burstLine?.tone, .beforeReset)
        XCTAssertEqual(burstLine?.text, "At the current pace, about 1d 8h before the next reset.")
        XCTAssertEqual(burstLine?.note, "A fast start. The estimate is only a guide.")
        XCTAssertTrue(burstLine?.spoken.hasSuffix("A fast start. The estimate is only a guide.") == true)

        let hintOnly = BurnRate.cardLine(
            for: burst, reading: burstReading!, horizon: 6 * 3600, softHint: true, beforeReset: false
        )
        XCTAssertEqual(hintOnly?.tone, .hint)
        XCTAssertEqual(hintOnly?.note, burstLine?.note)
        XCTAssertNil(BurnRate.cardLine(
            for: burst, reading: burstReading!, horizon: 6 * 3600, softHint: false, beforeReset: false
        ))

        let heavy = window("window", used: 0.4, resetsAt: opened)
        let heavyReading = BurnRate.reading(for: heavy, now: now)
        XCTAssertEqual(heavyReading?.earlyPace, true)
        XCTAssertEqual(heavyReading?.timeToExhaustion ?? 0, 2.52 * 3600, accuracy: 60)
        let countdown = BurnRate.cardLine(
            for: heavy, reading: heavyReading!, horizon: 6 * 3600, softHint: false, beforeReset: false
        )
        XCTAssertEqual(countdown?.tone, .countdown)
        XCTAssertEqual(countdown?.text, "Weekly · may run out in about 2.5 hours")
        XCTAssertEqual(countdown?.note, "A fast start. The estimate is only a guide.")

        let almostGone = window("window", used: 0.9, resetsAt: opened)
        let almost = BurnRate.reading(for: almostGone, now: now)
        XCTAssertEqual(almost?.earlyPace, true)
        XCTAssertLessThan(almost?.timeToExhaustion ?? .infinity, 15 * 60)
        XCTAssertEqual(
            BurnRate.cardLine(
                for: almostGone, reading: almost!, horizon: 6 * 3600, softHint: true, beforeReset: true
            )?.text,
            "Weekly · may run out in under 15 minutes"
        )

        let later = window("window", used: 0.4, resetsAt: now.addingTimeInterval(604_800 * 0.90))
        let laterReading = BurnRate.reading(for: later, now: now)
        XCTAssertNotNil(laterReading)
        XCTAssertEqual(laterReading?.earlyPace, false)
        XCTAssertNil(BurnRate.cardLine(
            for: later, reading: laterReading!, horizon: 48 * 3600, softHint: true, beforeReset: true
        )?.note)

        XCTAssertNil(BurnRate.reading(
            for: window("window", used: 0.4, resetsAt: now.addingTimeInterval(604_800)), now: now
        ))

        let week = named("week", kind: .weekly, used: 0.4, seconds: 604_800, resetsAt: opened, reportsLength: true)
        let five = named(
            "five", kind: .fiveHour, used: 0.4, seconds: 18_000,
            resetsAt: now.addingTimeInterval(10_000), reportsLength: true
        )
        let shown = BurnRate.forecastLine(
            for: week, among: [five, week], showsForecast: true,
            horizon: 6 * 3600, softHint: false, beforeReset: false, now: now
        )
        XCTAssertEqual(shown?.tone, .countdown)
        XCTAssertEqual(shown?.note, "A fast start. The estimate is only a guide.")
        XCTAssertNil(BurnRate.forecastLine(
            for: five, among: [five, week], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))
        XCTAssertNil(BurnRate.forecastLine(
            for: week, among: [five, week], showsForecast: false,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))

        useChinese()
        let chinese = BurnRate.cardLine(
            for: burst, reading: burstReading!, horizon: 6 * 3600, softHint: true, beforeReset: true
        )
        XCTAssertEqual(chinese?.text, "按当前速度，重置前约 1天8小时 会用尽。")
        XCTAssertEqual(chinese?.note, "开头偏快，预估仅供参考。")
        XCTAssertEqual(
            BurnRate.cardLine(
                for: heavy, reading: heavyReading!, horizon: 6 * 3600, softHint: false, beforeReset: false
            )?.text,
            "每周 · 约 2.5 小时后用尽"
        )
    }

    func testIdleWeeklyLastsWithoutAStatedLength() {
        useEnglish()
        let week = named(
            "week", kind: .weekly, used: 0, seconds: 604_800,
            resetsAt: now.addingTimeInterval(500_000), reportsLength: false
        )
        let five = named(
            "five", kind: .fiveHour, used: 0, seconds: 18_000,
            resetsAt: now.addingTimeInterval(10_000), reportsLength: true
        )
        let line = BurnRate.forecastLine(
            for: week, among: [five, week], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )
        XCTAssertEqual(line?.tone, .lasts)
        XCTAssertEqual(line?.text, "Expected to last the window")
        XCTAssertNil(BurnRate.forecastLine(
            for: five, among: [five, week], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))
        XCTAssertNil(BurnRate.forecastLine(
            for: week, among: [five, week], showsForecast: false,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))

        let edge = named(
            "week", kind: .weekly, used: BurnRate.earlyQuietUsed, seconds: 604_800,
            resetsAt: now.addingTimeInterval(500_000), reportsLength: false
        )
        XCTAssertEqual(BurnRate.reading(for: edge, now: now)?.exhaustsBeforeReset, false)
        XCTAssertEqual(BurnRate.forecastLine(
            for: edge, among: [edge], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )?.tone, .lasts)
        XCTAssertNil(BurnRate.reading(
            for: named("week", kind: .weekly, used: 0.4, seconds: 604_800,
                       resetsAt: now.addingTimeInterval(500_000), reportsLength: false),
            now: now
        ))
        XCTAssertNil(BurnRate.reading(
            for: named("week", kind: .weekly, used: 0, seconds: 604_800,
                       resetsAt: now.addingTimeInterval(-60), reportsLength: false),
            now: now
        ))
        XCTAssertNil(BurnRate.reading(
            for: window("window", used: 0.06, reportsLength: false, omitReset: true), now: now
        ))
        XCTAssertEqual(
            BurnRate.reading(for: window("window", used: 0.04, reportsLength: false, omitReset: true), now: now)?
                .exhaustsBeforeReset,
            false
        )

        useChinese()
        XCTAssertEqual(ForecastCopy.text("Expected to last the window"), "预计可维持到本轮重置")
    }

    func testFastStatedWindowShowsExhaustionBesideAQuietWeek() {
        useEnglish()
        let fiveReset = now.addingTimeInterval(4 * 3_600)
        let weekReset = now.addingTimeInterval(2 * 86_400 + 6 * 3_600)
        let weekly = named(
            "week", kind: .weekly, used: 0.30, seconds: 604_800, resetsAt: weekReset, reportsLength: false
        )
        let five = named(
            "five", kind: .fiveHour, used: 0.82, seconds: 18_000, resetsAt: fiveReset, reportsLength: true
        )
        let windows = [five, weekly]
        XCTAssertEqual(ExhaustionEstimate.windows(in: windows).map(\.id), ["week"])
        XCTAssertFalse(ExhaustionEstimate.includes(five, among: windows))
        XCTAssertNil(BurnRate.reading(for: weekly, now: now))

        let pace = BurnRate.reading(for: five, now: now)
        XCTAssertEqual(pace?.exhaustsBeforeReset, true)
        XCTAssertEqual(pace?.earlyPace, false)
        let untilEmpty = pace?.timeToExhaustion ?? .infinity
        XCTAssertLessThan(untilEmpty, fiveReset.timeIntervalSince(now))
        XCTAssertLessThan(untilEmpty, 15 * 60)

        let line = BurnRate.forecastLine(
            for: five, among: windows, showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )
        XCTAssertEqual(line?.tone, .countdown)
        XCTAssertEqual(line?.text, "5-hour · may run out in under 15 minutes")
        XCTAssertNil(line?.note)
        XCTAssertNil(BurnRate.forecastLine(
            for: weekly, among: windows, showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))

        let pastHorizon = BurnRate.forecastLine(
            for: five, among: windows, showsForecast: true,
            horizon: 60, softHint: false, beforeReset: true, now: now
        )
        XCTAssertEqual(pastHorizon?.tone, .beforeReset)
        XCTAssertNil(BurnRate.forecastLine(
            for: five, among: windows, showsForecast: true,
            horizon: 60, softHint: false, beforeReset: false, now: now
        ))

        let lightWeek = named(
            "week", kind: .weekly, used: 0.06, seconds: 604_800, resetsAt: weekReset, reportsLength: false
        )
        XCTAssertEqual(BurnRate.forecastLine(
            for: lightWeek, among: [five, lightWeek], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )?.text, "Expected to last the window")
        XCTAssertEqual(BurnRate.forecastLine(
            for: five, among: [five, lightWeek], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )?.tone, .countdown)

        let calmFive = named(
            "five", kind: .fiveHour, used: 0.11, seconds: 18_000,
            resetsAt: now.addingTimeInterval(96 * 60), reportsLength: true
        )
        XCTAssertEqual(BurnRate.reading(for: calmFive, now: now)?.exhaustsBeforeReset, false)
        XCTAssertNil(BurnRate.forecastLine(
            for: calmFive, among: [calmFive, weekly], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))

        let earlyFive = named(
            "five", kind: .fiveHour, used: 0.20, seconds: 18_000,
            resetsAt: now.addingTimeInterval(17_640), reportsLength: true
        )
        let earlyLine = BurnRate.forecastLine(
            for: earlyFive, among: [earlyFive, lightWeek], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )
        XCTAssertEqual(earlyLine?.tone, .countdown)
        XCTAssertEqual(earlyLine?.text, "5-hour · may run out in about 30 minutes")
        XCTAssertEqual(earlyLine?.note, "A fast start. The estimate is only a guide.")

        let day = named(
            "day", kind: .daily, used: 0.8, seconds: 86_400,
            resetsAt: now.addingTimeInterval(6 * 3_600), reportsLength: true
        )
        XCTAssertEqual(BurnRate.forecastLine(
            for: day, among: [day, weekly], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )?.text, "Daily · may run out in about 4.5 hours")
        XCTAssertNil(BurnRate.forecastLine(
            for: named("spend", kind: .spend, used: 0.9, seconds: 86_400,
                       resetsAt: now.addingTimeInterval(3_600), reportsLength: true),
            among: [named("spend", kind: .spend, used: 0.9, seconds: 86_400,
                          resetsAt: now.addingTimeInterval(3_600), reportsLength: true)],
            showsForecast: true, horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))

        useChinese()
        XCTAssertEqual(BurnRate.forecastLine(
            for: five, among: windows, showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )?.text, "5 小时 · 不到 15 分钟后用尽")
        XCTAssertEqual(BurnRate.forecastLine(
            for: earlyFive, among: [earlyFive], showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )?.note, "开头偏快，预估仅供参考。")
    }

    func testForecastInkFollowsTheTone() {
        let lasts = ForecastLineInk.style(for: .lasts)
        XCTAssertEqual(lasts.hue, .green)
        XCTAssertEqual(lasts.weight, .regular)
        for tone: BurnRate.CardLine.Tone in [.countdown, .beforeReset, .hint] {
            let ink = ForecastLineInk.style(for: tone)
            XCTAssertEqual(ink.hue, .amber)
            XCTAssertEqual(ink.weight, .medium)
        }
        XCTAssertGreaterThan(ForecastLineInk.opacity, 0)
        XCTAssertLessThan(ForecastLineInk.opacity, 1)
    }

    func testHoursControlClampsTheStepper() {
        XCTAssertEqual(ExhaustionHoursControl.applied(0), 1)
        XCTAssertEqual(ExhaustionHoursControl.applied(6), 6)
        XCTAssertEqual(ExhaustionHoursControl.applied(10_000), ExhaustionStage.maximumHours)
        XCTAssertEqual(ExhaustionHoursControl.digits(6), "6")
    }

    // MARK: - iOS window adapter

    func testAdapterReadsPercentAndStatedLength() {
        let reset = now.addingTimeInterval(4 * 3600)
        let five = ForecastWindow(UsageWindow(
            title: "5 hour", usedPercent: 82, resetsAt: reset, windowMinutes: 300, kind: .fiveHour
        ))
        XCTAssertEqual(five.kind, .fiveHour)
        XCTAssertEqual(five.usedFraction, 0.82, accuracy: 0.000_001)
        XCTAssertEqual(five.windowSeconds, 18_000)
        XCTAssertTrue(five.reportsLength)
        XCTAssertEqual(five.resetsAt, reset)

        let week = ForecastWindow(UsageWindow(
            title: "Weekly", usedPercent: 6, resetsAt: now.addingTimeInterval(200_000),
            windowMinutes: nil, kind: .weekly
        ))
        XCTAssertEqual(week.kind, .weekly)
        XCTAssertFalse(week.reportsLength)
        XCTAssertEqual(week.windowSeconds, 604_800)
        XCTAssertEqual(week.usedFraction, 0.06, accuracy: 0.000_001)

        let noClock = ForecastWindow(UsageWindow(
            title: "Weekly", usedPercent: 10, resetsAt: reset, windowMinutes: 10_080,
            kind: .weekly, reportsReset: false
        ))
        XCTAssertNil(noClock.resetsAt)
        XCTAssertTrue(noClock.reportsLength)
    }

    func testAdapterFeedsTheSameForecastAsAMacWindow() {
        useEnglish()
        let reset = now.addingTimeInterval(4 * 3600)
        let snapshotWindows = [
            UsageWindow(title: "5 hour", usedPercent: 82, resetsAt: reset, windowMinutes: 300, kind: .fiveHour),
            UsageWindow(
                title: "Weekly", usedPercent: 30, resetsAt: now.addingTimeInterval(2 * 86_400),
                windowMinutes: nil, kind: .weekly
            )
        ].map(ForecastWindow.init)
        let line = BurnRate.forecastLine(
            for: snapshotWindows[0], among: snapshotWindows, showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        )
        XCTAssertEqual(line?.text, "5-hour · may run out in under 15 minutes")
        XCTAssertNil(BurnRate.forecastLine(
            for: snapshotWindows[1], among: snapshotWindows, showsForecast: true,
            horizon: 6 * 3600, softHint: true, beforeReset: true, now: now
        ))
    }

    // MARK: - Settings

    func testForecastSettingsDefaultsAndRoundTrip() throws {
        let defaults = isolatedDefaults()
        let loaded = ForecastSettingsDisk.load(from: defaults)
        XCTAssertTrue(loaded.showsForecast)
        XCTAssertEqual(loaded.exhaustionCardHours, 6)
        XCTAssertTrue(loaded.exhaustionSoftHint)
        XCTAssertTrue(loaded.exhaustionBeforeReset)
        XCTAssertTrue(loaded.allAccounts)
        XCTAssertTrue(loaded.showsPredictedReset)
        XCTAssertFalse(loaded.remindsBeforePredictedReset)
        XCTAssertEqual(loaded.predictedLead, 24 * 3600)
        XCTAssertEqual(loaded.horizon, 6 * 3600)

        let decoded = try JSONDecoder().decode(ForecastSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ForecastSettings())

        let id = UUID()
        var chosen = ForecastSettings()
        chosen.allAccounts = false
        chosen.accountIDs = [id]
        chosen.exhaustionCardHours = 0
        chosen.predictedResetLeadHours = 3
        ForecastSettingsDisk.save(chosen, to: defaults)
        let stored = ForecastSettingsDisk.load(from: defaults)
        XCTAssertEqual(stored.exhaustionCardHours, 1)
        XCTAssertEqual(stored.predictedResetLeadHours, 24)
        XCTAssertFalse(stored.allAccounts)
        XCTAssertEqual(stored.accountIDs, [id])
        XCTAssertFalse(stored.includes(UUID()))
        XCTAssertTrue(ForecastSettings().includes(id))
    }

    func testCardRowsRespectTheAccountList() {
        useEnglish()
        let id = UUID()
        let windows = [weekly(used: 0.2)]
        var settings = ForecastSettings()
        let rows = ForecastCardModel.rows(windows: windows, settings: settings, accountID: id, now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.line.tone, .lasts)

        settings.showsForecast = false
        XCTAssertTrue(ForecastCardModel.rows(windows: windows, settings: settings, accountID: id, now: now).isEmpty)

        settings.showsForecast = true
        settings.allAccounts = false
        settings.accountIDs = []
        XCTAssertTrue(ForecastCardModel.rows(windows: windows, settings: settings, accountID: id, now: now).isEmpty)
        settings.accountIDs = [id]
        XCTAssertEqual(
            ForecastCardModel.rows(windows: windows, settings: settings, accountID: id, now: now).count,
            1
        )
    }

    // MARK: - Codex reset document

    func testScheduledWinsOverAWatch() throws {
        let status = try XCTUnwrap(CodexResetStatus.parse(json("""
        {"data":{"scheduled_reset":{"id":"post-1","reset_type":" regular ","scheduled_for":"2026-09-24T18:30:00Z"},
        "active_watch":{"level":"strong","reset_chance_percent":80,"forecast_window":"within 24h","expires_at":"2026-09-23T12:00:00Z","text":"watch"},
        "latest_reset":null}}
        """)))
        let when = try XCTUnwrap(CodexResetDates.parse("2026-09-24T18:30:00Z"))
        XCTAssertEqual(status.card, .scheduled(when))
        XCTAssertEqual(status.scheduled?.resetType, "regular")
        XCTAssertEqual(status.explicitReset, when)
        XCTAssertNotEqual(status.explicitReset, CodexResetDates.parse("2026-09-23T12:00:00Z"))
    }

    func testWatchIsNotAResetTime() throws {
        let status = try XCTUnwrap(CodexResetStatus.parse(json("""
        {"data":{"scheduled_reset":{"id":"post-2","scheduled_for":null},"active_watch":{"level":"elevated","reset_chance_percent":42,"forecast_window":"later today","expires_at":"2026-09-23T12:00:00Z","text":"watch"},"latest_reset":null}}
        """)))
        XCTAssertNil(status.explicitReset)
        guard case .watch(let watch) = status.card else { return XCTFail("expected a watch") }
        XCTAssertEqual(watch.level, "elevated")
        XCTAssertEqual(watch.chancePercent, 42)
        XCTAssertEqual(watch.forecastWindow, "later today")
        XCTAssertEqual(watch.windowEnds, CodexResetDates.parse("2026-09-23T12:00:00Z"))
        XCTAssertNotEqual(status.explicitReset, watch.windowEnds)
    }

    func testWindowEndWithoutProseIsStillAWatch() throws {
        let status = try XCTUnwrap(CodexResetStatus.parse(json("""
        {"data":{"scheduled_reset":null,"active_watch":{"level":"strong","reset_chance_percent":null,"forecast_window":"  ","expires_at":"2026-09-30T06:59:59.999Z","text":"  "}}}
        """)))
        guard case .watch(let watch) = status.card else { return XCTFail("expected a watch") }
        XCTAssertEqual(watch.windowEnds, CodexResetDates.parse("2026-09-30T06:59:59.999Z"))
        XCTAssertTrue(watch.forecastWindow.isEmpty)
        XCTAssertNil(watch.text)
        XCTAssertNil(status.explicitReset)
        XCTAssertNil(CodexResetPresentation.context(forecastWindow: watch.forecastWindow, text: watch.text))
    }

    func testEmptyDocumentIsNotAParseFailure() throws {
        let status = try XCTUnwrap(CodexResetStatus.parse(json(
            #"{"data":{"scheduled_reset":null,"active_watch":null,"latest_reset":null}}"#
        )))
        XCTAssertEqual(status.card, .empty)
        XCTAssertNil(status.explicitReset)
        XCTAssertNil(CodexResetStatus.parse(Data("nope".utf8)))
    }

    func testBankedLatestIsHistoryNotAPrediction() throws {
        let status = try XCTUnwrap(CodexResetStatus.parse(json("""
        {"data":{"latest_reset":{"id":"2102","reset_type":"banked","announced_at":"2026-09-22T18:23:37.000Z","scheduled_for":"2026-09-25T00:00:00Z","text":"We are loading a banked reset."},"scheduled_reset":null,"active_watch":null}}
        """)))
        XCTAssertEqual(status.card, .empty)
        XCTAssertNil(status.explicitReset)
        XCTAssertEqual(status.latest?.resetType, "banked")
        XCTAssertNotEqual(status.latest?.announcedAt, CodexResetDates.parse("2026-09-25T00:00:00Z"))
        useEnglish()
        let lines = CodexResetCardLines.make(status, now: now)
        XCTAssertEqual(lines.prediction.trailing, "No prediction yet")
        XCTAssertNil(lines.prediction.countdown)
        XCTAssertEqual(lines.latest?.typeLabel, "Reset card")
        XCTAssertFalse(lines.latest?.help?.isEmpty ?? true)
        XCTAssertFalse(CodexResetCardLines.identity(status).isEmpty)
        XCTAssertTrue(CodexResetCardLines.identity(nil).isEmpty)
    }

    func testCardLinesCountDownOnlyWhileTheInstantIsAhead() {
        useEnglish()
        let ahead = now.addingTimeInterval(21 * 3600)
        let scheduled = CodexResetStatus(
            scheduled: .init(id: "post", scheduledFor: ahead, resetType: "regular"),
            watch: nil
        )
        let lines = CodexResetCardLines.make(scheduled, now: now)
        XCTAssertTrue(lines.prediction.countdown?.hasPrefix("Resets ") == true)
        XCTAssertFalse(lines.prediction.bound?.isEmpty ?? true)
        XCTAssertEqual(lines.prediction.typeTag, "Global reset")
        XCTAssertNil(lines.prediction.typeHelp)
        XCTAssertFalse(lines.prediction.isPlaceholder)

        let past = CodexResetStatus(scheduled: .init(id: "post", scheduledFor: now.addingTimeInterval(-60)), watch: nil)
        let gone = CodexResetCardLines.make(past, now: now)
        XCTAssertEqual(gone.prediction.trailing, "No prediction yet")
        XCTAssertNil(gone.prediction.countdown)
        XCTAssertTrue(gone.prediction.isPlaceholder)

        let watch = CodexResetStatus(
            scheduled: nil,
            watch: .init(
                level: "elevated", chancePercent: 42, forecastWindow: "later today",
                windowEnds: ahead, text: "watch note"
            )
        )
        let forecast = CodexResetCardLines.make(watch, now: now)
        XCTAssertTrue(forecast.prediction.countdown?.hasPrefix("May reset ") == true)
        XCTAssertTrue(forecast.prediction.bound?.hasPrefix("Expected before ") == true)
        XCTAssertEqual(forecast.prediction.trailing, "Elevated · 42% chance")
        XCTAssertEqual(forecast.prediction.note, "watch note")

        useChinese()
        let chinese = CodexResetCardLines.make(watch, now: now)
        XCTAssertTrue(chinese.prediction.countdown?.hasSuffix("可能重置") == true)
        XCTAssertEqual(chinese.prediction.trailing, "偏高 · 42% 的可能")
        let announced = CodexResetCardLines.make(scheduled, now: now)
        XCTAssertTrue(announced.prediction.countdown?.hasSuffix("重置") == true)
        XCTAssertFalse(announced.prediction.countdown?.contains("可能") == true)
        XCTAssertEqual(announced.prediction.typeTag, "全局重置")
    }

    func testQuietWindowHidesTheSameForecastOnly() {
        let when = now.addingTimeInterval(36 * 3600)
        let status = CodexResetStatus(scheduled: .init(id: "post-9", scheduledFor: when), watch: nil)
        let quiet = CodexResetQuiet.State(key: status.predictionKey, until: now.addingTimeInterval(120))
        let hidden = CodexResetQuiet.displayed(status, quiet: quiet, now: now)
        XCTAssertNil(hidden?.scheduled)
        XCTAssertTrue(hidden?.predictionKey.isEmpty == true)
        let later = CodexResetQuiet.displayed(status, quiet: quiet, now: now.addingTimeInterval(121))
        XCTAssertEqual(later?.explicitReset, when)
        var other = status
        other.scheduled?.id = "post-10"
        XCTAssertEqual(CodexResetQuiet.displayed(other, quiet: quiet, now: now)?.explicitReset, when)
        XCTAssertTrue(status.withoutPrediction().predictionKey.isEmpty)
    }

    func testReplyInterpretationAndSchedule() throws {
        let body = Data(#"{"data":{"scheduled_reset":null,"active_watch":null,"latest_reset":null}}"#.utf8)
        let parsed = CodexResetReply.interpret(
            statusCode: 200,
            headers: ["ETag": "W/\"1\"", "Cache-Control": "max-age=30, public"],
            body: body
        )
        guard case .parsed(let status) = parsed.payload else { return XCTFail("expected a document") }
        XCTAssertEqual(status.card, .empty)
        XCTAssertEqual(parsed.etag, "W/\"1\"")
        XCTAssertEqual(parsed.maxAge, 30)

        let notModified = CodexResetReply.interpret(statusCode: 304, headers: ["etag": "x"], body: Data())
        guard case .notModified = notModified.payload else { return XCTFail("expected 304") }

        let limited = CodexResetReply.interpret(statusCode: 429, headers: ["Retry-After": "45"], body: Data())
        XCTAssertEqual(limited.retryAfter, 45)
        let limitedDefault = CodexResetReply.interpret(statusCode: 429, headers: [:], body: Data())
        XCTAssertEqual(limitedDefault.retryAfter, CodexResetSchedule.floor)

        let garbage = CodexResetReply.interpret(statusCode: 200, headers: [:], body: Data("nope".utf8))
        guard case .failed = garbage.payload else { return XCTFail("expected a failed parse") }

        XCTAssertEqual(CodexResetSchedule.interval(maxAge: nil), 600)
        XCTAssertEqual(CodexResetSchedule.interval(maxAge: 10), 120)
        XCTAssertEqual(CodexResetSchedule.interval(maxAge: 10_000), 1_800)
        XCTAssertEqual(CodexResetSchedule.delay(maxAge: 10, retryAfter: nil, failed: true), 600)
        XCTAssertEqual(CodexResetSchedule.delay(maxAge: nil, retryAfter: 10, failed: true), 30)
        XCTAssertEqual(CodexResetSchedule.delay(maxAge: nil, retryAfter: 10_000, failed: false), 1_800)

        let counting = CodexResetStatus(scheduled: .init(id: "a", scheduledFor: now.addingTimeInterval(100)), watch: nil)
        XCTAssertEqual(CodexResetSchedule.paced(600, status: counting), 120)
        XCTAssertEqual(CodexResetSchedule.paced(600, status: nil), 600)
        XCTAssertFalse(CodexResetSchedule.lookIsDue(fetchedAt: now.addingTimeInterval(-119), now: now))
        XCTAssertTrue(CodexResetSchedule.lookIsDue(fetchedAt: now.addingTimeInterval(-120), now: now))

        let when = try XCTUnwrap(CodexResetDates.parse("2015-10-21T07:28:00Z"))
        XCTAssertEqual(
            CodexResetSchedule.retryAfter(from: "Wed, 21 Oct 2015 07:28:00 GMT", now: when),
            0
        )
    }

    func testRequestSkipsABlankValidator() {
        let open = CodexResetRequest.make(etag: nil)
        XCTAssertEqual(open.url, CodexResetEndpoint.status)
        XCTAssertEqual(open.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(open.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(CodexResetRequest.make(etag: "  ").value(forHTTPHeaderField: "If-None-Match"), nil)
        XCTAssertEqual(CodexResetRequest.make(etag: "abc").value(forHTTPHeaderField: "If-None-Match"), "abc")
        XCTAssertEqual(open.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testLegacyCacheOmitsTheConditionalRequest() throws {
        let status = CodexResetStatus(scheduled: .init(id: "post", scheduledFor: now.addingTimeInterval(3_600)), watch: nil)
        let current = CodexResetDisk(status: status, etag: "abc", fetchedAt: now, maxAge: 600, schema: 2)
        let round = try XCTUnwrap(CodexResetDisk.decode(try XCTUnwrap(CodexResetDisk.encode(current))))
        XCTAssertFalse(round.omitsForecastTiming)
        XCTAssertEqual(round.status.explicitReset, status.explicitReset)
        let fresh = CodexResetLoadPlan.make(disk: round, now: now)
        XCTAssertFalse(fresh.refetchingForecastTiming)
        XCTAssertFalse(fresh.forecastFetchIsDue(at: now))
        XCTAssertTrue(fresh.sendsConditionalRequest)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(CodexResetDisk.encode(current))) as? [String: Any])
        object.removeValue(forKey: "schema")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try XCTUnwrap(CodexResetDisk.decode(legacyData))
        XCTAssertEqual(legacy.schema, CodexResetDisk.legacySchema)
        XCTAssertTrue(legacy.omitsForecastTiming)
        let stale = CodexResetLoadPlan.make(disk: legacy, now: now)
        XCTAssertTrue(stale.refetchingForecastTiming)
        XCTAssertTrue(stale.forecastFetchIsDue(at: now))
        XCTAssertFalse(stale.sendsConditionalRequest)

        let defaults = isolatedDefaults()
        CodexResetDisk.save(current, to: defaults)
        XCTAssertEqual(CodexResetDisk.load(from: defaults)?.etag, "abc")
    }

    func testWeeklyRefillDropsOnlyTheWeeklyWindow() {
        let week = named("week", kind: .weekly, used: 0.4, seconds: 604_800, resetsAt: now.addingTimeInterval(200_000))
        let full = named("week", kind: .weekly, used: 0, seconds: 604_800, resetsAt: week.resetsAt)
        XCTAssertTrue(CodexResetSchedule.weeklyQuotaRestored(previous: [week], current: [full]))

        let five = named("five", kind: .fiveHour, used: 0.8, seconds: 18_000, resetsAt: now.addingTimeInterval(1_000))
        let fiveFull = named("five", kind: .fiveHour, used: 0, seconds: 18_000, resetsAt: now.addingTimeInterval(18_000))
        XCTAssertFalse(CodexResetSchedule.weeklyQuotaRestored(previous: [five], current: [fiveFull]))

        let idle = named("week", kind: .weekly, used: 0.01, seconds: 604_800, resetsAt: now.addingTimeInterval(100_000))
        let slid = named("week", kind: .weekly, used: 0, seconds: 604_800, resetsAt: idle.resetsAt?.addingTimeInterval(300))
        XCTAssertFalse(CodexResetSchedule.weeklyQuotaRestored(previous: [idle], current: [slid]))
        let jumped = named(
            "week", kind: .weekly, used: 0, seconds: 604_800,
            resetsAt: idle.resetsAt?.addingTimeInterval(3 * 86_400)
        )
        XCTAssertTrue(CodexResetSchedule.weeklyQuotaRestored(previous: [idle], current: [jumped]))
    }

    // MARK: - Predicted reminder

    func testPredictedReminderRequiresAnExplicitTime() throws {
        let when = now.addingTimeInterval(36 * 3600)
        let lead12: TimeInterval = 12 * 3600
        let timed = CodexResetStatus(
            scheduled: .init(id: "post-9", scheduledFor: when),
            watch: .init(level: "strong", chancePercent: 90, forecastWindow: "soon")
        )
        let reminder = try XCTUnwrap(AdvanceReminderPlanner.predicted(status: timed, lead: lead12, now: now))
        XCTAssertEqual(reminder.identifier, "pulse.advance.predicted|post-9|\(Int(when.timeIntervalSince1970))")
        XCTAssertEqual(reminder.fireAt, when.addingTimeInterval(-lead12))

        let watchOnly = CodexResetStatus(
            scheduled: .init(id: "post-9", scheduledFor: nil),
            watch: .init(
                level: "elevated", chancePercent: 40, forecastWindow: "this week",
                windowEnds: now.addingTimeInterval(20 * 3600)
            )
        )
        XCTAssertNil(watchOnly.explicitReset)
        XCTAssertNil(AdvanceReminderPlanner.predicted(status: watchOnly, lead: lead12, now: now))
        XCTAssertNil(AdvanceReminderPlanner.predicted(
            status: CodexResetStatus(scheduled: nil, watch: nil), lead: lead12, now: now
        ))
        XCTAssertNil(AdvanceReminderPlanner.predicted(
            status: CodexResetStatus(scheduled: .init(id: "old", scheduledFor: now.addingTimeInterval(-60)), watch: nil),
            lead: lead12, now: now
        ))
        let onlyLatest = CodexResetStatus(
            scheduled: nil, watch: nil,
            latest: .init(id: "banked-1", resetType: "banked", announcedAt: now.addingTimeInterval(6 * 3600))
        )
        XCTAssertNil(AdvanceReminderPlanner.predicted(status: onlyLatest, lead: lead12, now: now))
    }

    func testPredictedReminderDedupesAndHonoursTheLead() throws {
        let lead12: TimeInterval = 12 * 3600
        let lead48: TimeInterval = 48 * 3600
        let soon = now.addingTimeInterval(6 * 3600)
        let inside = CodexResetStatus(scheduled: .init(id: "post-3", scheduledFor: soon), watch: nil)
        let dueNow = AdvanceReminderPlanner.predicted(status: inside, lead: lead12, now: now)
        XCTAssertNil(dueNow?.fireAt)

        var book = AdvanceReminderBook()
        let first = book.reconcile(desired: dueNow.map { [$0] } ?? [], enabled: true, now: now)
        XCTAssertEqual(first.schedule.count, 1)
        let second = book.reconcile(desired: dueNow.map { [$0] } ?? [], enabled: true, now: now)
        XCTAssertTrue(second.schedule.isEmpty)
        XCTAssertTrue(second.cancel.isEmpty)

        let when = now.addingTimeInterval(60 * 3600)
        let status = CodexResetStatus(scheduled: .init(id: "post-5", scheduledFor: when), watch: nil)
        let early = try XCTUnwrap(AdvanceReminderPlanner.predicted(status: status, lead: lead48, now: now))
        let later = try XCTUnwrap(AdvanceReminderPlanner.predicted(status: status, lead: lead12, now: now))
        XCTAssertEqual(early.identifier, later.identifier)
        var movedBook = AdvanceReminderBook()
        _ = movedBook.reconcile(desired: [early], enabled: true, now: now)
        let moved = movedBook.reconcile(desired: [later], enabled: true, now: now)
        XCTAssertEqual(moved.cancel, [early.identifier])
        XCTAssertEqual(moved.schedule.map(\.identifier), [later.identifier])

        let off = movedBook.reconcile(desired: [], enabled: false, now: now)
        XCTAssertEqual(off.cancel, [later.identifier])
        XCTAssertTrue(movedBook.memory.pending.isEmpty)
        XCTAssertFalse(movedBook.memory.delivered.contains(later.identifier))
    }

    func testRegularReminderSkipsAShortWindow() {
        let lead12: TimeInterval = 12 * 3600
        let soon = now.addingTimeInterval(3 * 3600)
        let week = now.addingTimeInterval(5 * 24 * 3600)
        let windows = [
            AdvanceReminderPlanner.Window(
                accountID: "codex", accountLabel: "Codex", windowID: "five",
                windowName: "5-hour limit", resetsAt: soon, length: 5 * 3600
            ),
            AdvanceReminderPlanner.Window(
                accountID: "codex", accountLabel: "Codex", windowID: "week",
                windowName: "Weekly limit", resetsAt: week, length: 7 * 24 * 3600
            ),
            AdvanceReminderPlanner.Window(
                accountID: "kimi", accountLabel: "Kimi", windowID: "rolling",
                windowName: "Weekly limit", resetsAt: week, length: nil
            )
        ]
        let due = AdvanceReminderPlanner.regular(windows: windows, lead: lead12, now: now)
        XCTAssertEqual(due.map(\.identifier), [
            "pulse.advance.regular|codex|week|\(Int(week.timeIntervalSince1970))"
        ])
        XCTAssertEqual(due.first?.fireAt, week.addingTimeInterval(-lead12))
    }

    func testReminderBookRoundTrip() throws {
        let defaults = isolatedDefaults()
        var book = AdvanceReminderBook()
        let when = now.addingTimeInterval(36 * 3600)
        let reminder = try XCTUnwrap(AdvanceReminderPlanner.predicted(
            status: CodexResetStatus(scheduled: .init(id: "post", scheduledFor: when), watch: nil),
            lead: 12 * 3600, now: now
        ))
        _ = book.reconcile(desired: [reminder], enabled: true, now: now)
        AdvanceReminderBook.save(book, to: defaults)
        let loaded = AdvanceReminderBook.load(from: defaults)
        XCTAssertEqual(loaded.memory.pending[reminder.identifier], reminder.fireAt)
    }

    // MARK: - Helpers

    private func useEnglish() { AppLanguage.choose(.english) }
    private func useChinese() { AppLanguage.choose(.chineseSimplified) }

    private func isolatedDefaults() -> UserDefaults {
        let name = "forecast-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func pace(remaining: TimeInterval, length: Double = 604_800, elapsed: Double = 0.5) -> Double {
        let elapsedSeconds = length * elapsed
        return elapsedSeconds / (remaining + elapsedSeconds)
    }

    private func weekly(used: Double, elapsed: Double = 0.5) -> ForecastWindow {
        window("window", used: used, resetsAt: now.addingTimeInterval(604_800 * (1 - elapsed)))
    }

    private func window(
        _ id: String,
        kind: ForecastWindow.Kind = .weekly,
        scope: String? = nil,
        used: Double = 0.4,
        seconds: Int = 604_800,
        resetsAt: Date? = nil,
        reportsLength: Bool = true,
        omitReset: Bool = false
    ) -> ForecastWindow {
        ForecastWindow(
            id: id, kind: kind, scope: scope, usedFraction: used, windowSeconds: seconds,
            resetsAt: omitReset ? nil : (resetsAt ?? now.addingTimeInterval(302_400)),
            reportsLength: reportsLength
        )
    }

    private func named(
        _ id: String,
        kind: ForecastWindow.Kind,
        used: Double,
        seconds: Int,
        resetsAt: Date?,
        reportsLength: Bool = true
    ) -> ForecastWindow {
        ForecastWindow(
            id: id, kind: kind, usedFraction: used, windowSeconds: seconds,
            resetsAt: resetsAt, reportsLength: reportsLength
        )
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }
}
