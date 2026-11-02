import Foundation

/// Public Codex Resets document. The site, not an account's own 5-hour or weekly clock.
enum CodexResetEndpoint {
    static let site = URL(string: "https://codex-resets.com")!
    static let status = URL(string: "https://codex-resets.com/api/v1/status")!
}

/// What [Codex Resets](https://codex-resets.com) currently says about an
/// irregular Codex reset.
///
/// `scheduled.scheduledFor` is an explicit instant. A watch is a forecast.
/// `windowEnds` is the end of that forecast (`expires_at`): the card counts
/// down to it as a bound a reset may fall before, and it is not an announced
/// reset. `explicitReset` never reads it, so a reminder cannot count down to
/// it either. `latest.announcedAt` is when the last announcement went out.
struct CodexResetStatus: Equatable, Sendable, Codable {
    struct Scheduled: Equatable, Sendable, Codable {
        var id: String
        var scheduledFor: Date?
        var resetType: String? = nil
    }

    /// An AI-classified forecast. Not an official reset time.
    struct Watch: Equatable, Sendable, Codable {
        var level: String
        var chancePercent: Int?
        var forecastWindow: String
        var windowEnds: Date? = nil
        var text: String? = nil
        var resetType: String? = nil
    }

    /// The most recent public announcement. Not a time a reminder may count down to.
    struct Latest: Equatable, Sendable, Codable {
        var id: String
        var resetType: String
        var announcedAt: Date
        var text: String? = nil
    }

    var scheduled: Scheduled?
    var watch: Watch?
    var latest: Latest? = nil

    /// What the prediction row says. An explicit `scheduledFor` wins over a
    /// watch. Neither, or a schedule that names no instant, is `.empty`.
    enum Card: Equatable, Sendable {
        case scheduled(Date)
        case watch(Watch)
        case empty
    }

    var card: Card {
        if let when = scheduled?.scheduledFor { return .scheduled(when) }
        if let watch { return .watch(watch) }
        return .empty
    }

    /// The only instant an advance reminder may count down to.
    var explicitReset: Date? { scheduled?.scheduledFor }

    /// The status document, or nil when the body is not one.
    ///
    /// A document whose schedule and watch are both null is a real answer
    /// (`.empty`), not a parse failure. `latest_reset` may still be present.
    static func parse(_ data: Data) -> CodexResetStatus? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = root["data"] as? [String: Any]
        else { return nil }
        return CodexResetStatus(
            scheduled: scheduled(body["scheduled_reset"]),
            watch: watch(body["active_watch"]),
            latest: latest(body["latest_reset"])
        )
    }

    private static func scheduled(_ value: Any?) -> Scheduled? {
        guard let object = value as? [String: Any] else { return nil }
        let id = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let when = CodexResetDates.parse(object["scheduled_for"] as? String)
        guard !id.isEmpty || when != nil else { return nil }
        let type = (object["reset_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resetType = (type?.isEmpty == false) ? type : nil
        return Scheduled(id: id, scheduledFor: when, resetType: resetType)
    }

    private static func watch(_ value: Any?) -> Watch? {
        guard
            let object = value as? [String: Any],
            let level = object["level"] as? String,
            !level.isEmpty
        else { return nil }

        let chance = object["reset_chance_percent"] as? Int
            ?? (object["reset_chance_percent"] as? Double).map { Int($0) }
            ?? (object["reset_chance_percent"] as? NSNumber)?.intValue
        let window = (object["forecast_window"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (note?.isEmpty == false) ? note : nil
        let ends = CodexResetDates.parse(object["expires_at"] as? String)
        guard !window.isEmpty || text != nil || ends != nil else { return nil }
        let type = (object["reset_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resetType = (type?.isEmpty == false) ? type : nil
        return Watch(
            level: level,
            chancePercent: chance,
            forecastWindow: window,
            windowEnds: ends,
            text: text,
            resetType: resetType
        )
    }

    private static func latest(_ value: Any?) -> Latest? {
        guard let object = value as? [String: Any] else { return nil }
        guard let announced = CodexResetDates.parse(object["announced_at"] as? String) else { return nil }
        let id = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let type = (object["reset_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (text?.isEmpty == false) ? text : nil
        return Latest(id: id, resetType: type, announcedAt: announced, text: body)
    }

    /// The forecast the card would count down to, coarse enough that a
    /// disk round trip and a fresh parse of the same post still match.
    /// Empty when there is nothing to drop.
    var predictionKey: String {
        let scheduledPart = scheduled.map {
            "\($0.id)|\(Self.minute($0.scheduledFor))|\($0.resetType ?? "")"
        } ?? ""
        let watchPart = watch.map {
            "\($0.level)|\(Self.minute($0.windowEnds))"
        } ?? ""
        guard !scheduledPart.isEmpty || !watchPart.isEmpty else { return "" }
        let latestPart = latest.map { "\($0.id)|\($0.resetType)" } ?? ""
        return "\(scheduledPart)|\(watchPart)||\(latestPart)"
    }

    /// The same status with the prediction taken off. The last announcement stays.
    func withoutPrediction() -> CodexResetStatus {
        var copy = self
        copy.scheduled = nil
        copy.watch = nil
        return copy
    }

    private static func minute(_ date: Date?) -> String {
        guard let date else { return "" }
        return String(Int(date.timeIntervalSince1970 / 60))
    }
}

enum CodexResetDates {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// How the card says a latest announcement and a forecast bound.
enum CodexResetPresentation {
    static func relative(announcedAt: Date, now: Date = Date(), locale: Locale = AppLanguage.current.locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: announcedAt, relativeTo: now)
    }

    static func absolute(
        announcedAt: Date,
        locale: Locale = AppLanguage.current.locale,
        calendar: Calendar = .current
    ) -> String {
        formatted(announcedAt, template: "MMMdjmm", locale: locale, calendar: calendar)
    }

    static func typeLabel(resetType: String) -> String {
        switch resetType {
        case "regular": ForecastCopy.text("Global reset")
        case "banked": ForecastCopy.text("Reset card")
        default: resetType
        }
    }

    static func detail(resetType: String, absolute: String) -> String {
        let label = typeLabel(resetType: resetType)
        guard !label.isEmpty else { return absolute }
        return ForecastCopy.format("%@ · %@", label, absolute)
    }

    /// A banked credit keeps the site's own explanation. Every other type
    /// shows `latest_reset.text` verbatim. Blank text is no note.
    static func help(resetType: String, announcement: String?) -> String? {
        if resetType == "banked" {
            return ForecastCopy.text("A reset credit you apply yourself when you need it. It does not restore usage right away. In the Codex app, open your profile from the sidebar, go to Usage, and apply an available reset credit.")
        }
        guard let announcement else { return nil }
        let body = announcement.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    static func spoken(relative: String, detail: String) -> String {
        ForecastCopy.format("%@, %@", relative, detail)
    }

    static func confidence(_ watch: CodexResetStatus.Watch) -> String {
        let level = switch watch.level {
        case "elevated": ForecastCopy.text("Elevated")
        case "strong": ForecastCopy.text("Strong")
        default: watch.level
        }
        guard let chance = watch.chancePercent else { return level }
        return ForecastCopy.format("%@ · %@ chance", level, "\(chance)%")
    }

    static func predictionStamp(
        date: Date,
        locale: Locale = AppLanguage.current.locale,
        calendar: Calendar = .current
    ) -> String {
        formatted(date, template: "MMMdEEEjmm", locale: locale, calendar: calendar)
    }

    static func mayReset(relative: String) -> String {
        ForecastCopy.format("May reset %@", relative)
    }

    static func resets(relative: String) -> String {
        ForecastCopy.format("Resets %@", relative)
    }

    static func expectedBefore(_ stamp: String) -> String {
        ForecastCopy.format("Expected before %@", stamp)
    }

    static func context(forecastWindow: String, text: String?) -> String? {
        if let text {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body }
        }
        let window = forecastWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        return window.isEmpty ? nil : window
    }

    private static func formatted(
        _ date: Date,
        template: String,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        var calendar = calendar
        calendar.locale = locale
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// What the card draws for the public forecast and the last announcement.
struct CodexResetCardLines: Equatable, Sendable {
    struct Prediction: Equatable, Sendable {
        var trailing: String?
        var countdown: String?
        var bound: String?
        var note: String?
        var typeTag: String? = nil
        var typeHelp: String? = nil

        /// No instant and no watch left to show. The row says there is no prediction.
        var isPlaceholder: Bool {
            countdown == nil && bound == nil && note == nil && typeTag == nil
        }
    }

    struct Latest: Equatable, Sendable {
        var relative: String
        var typeLabel: String
        var absolute: String
        var detail: String
        var help: String?
        var spoken: String
    }

    var prediction: Prediction
    var latest: Latest?

    static func make(
        _ status: CodexResetStatus?,
        now: Date = Date(),
        locale: Locale = AppLanguage.current.locale,
        calendar: Calendar = .current
    ) -> CodexResetCardLines {
        let prediction = Self.prediction(status, now: now, locale: locale, calendar: calendar)
        guard let announcement = status?.latest else {
            return CodexResetCardLines(prediction: prediction, latest: nil)
        }
        let relative = CodexResetPresentation.relative(
            announcedAt: announcement.announcedAt, now: now, locale: locale
        )
        let absolute = CodexResetPresentation.absolute(
            announcedAt: announcement.announcedAt, locale: locale, calendar: calendar
        )
        let typeLabel = CodexResetPresentation.typeLabel(resetType: announcement.resetType)
        let detail = CodexResetPresentation.detail(resetType: announcement.resetType, absolute: absolute)
        let help = CodexResetPresentation.help(
            resetType: announcement.resetType, announcement: announcement.text
        )
        return CodexResetCardLines(
            prediction: prediction,
            latest: Latest(
                relative: relative,
                typeLabel: typeLabel,
                absolute: absolute,
                detail: detail,
                help: help,
                spoken: CodexResetPresentation.spoken(relative: relative, detail: detail)
            )
        )
    }

    private static func prediction(
        _ status: CodexResetStatus?,
        now: Date,
        locale: Locale,
        calendar: Calendar
    ) -> Prediction {
        switch status?.card {
        case .scheduled(let date):
            guard date > now else { return noPrediction() }
            let stamp = CodexResetPresentation.predictionStamp(date: date, locale: locale, calendar: calendar)
            let countdown = CodexResetPresentation.resets(
                relative: CodexResetPresentation.relative(announcedAt: date, now: now, locale: locale)
            )
            let tag = typeTag(resetType: status?.scheduled?.resetType)
            return Prediction(
                trailing: nil,
                countdown: countdown,
                bound: stamp,
                note: nil,
                typeTag: tag?.label,
                typeHelp: tag?.help
            )
        case .watch(let watch):
            let note = CodexResetPresentation.context(forecastWindow: watch.forecastWindow, text: watch.text)
            let trailing = CodexResetPresentation.confidence(watch)
            let tag = typeTag(resetType: watch.resetType)
            guard let ends = watch.windowEnds, ends > now else {
                return Prediction(
                    trailing: trailing,
                    countdown: nil,
                    bound: nil,
                    note: note,
                    typeTag: tag?.label,
                    typeHelp: tag?.help
                )
            }
            let relative = CodexResetPresentation.relative(announcedAt: ends, now: now, locale: locale)
            let stamp = CodexResetPresentation.predictionStamp(date: ends, locale: locale, calendar: calendar)
            return Prediction(
                trailing: trailing,
                countdown: CodexResetPresentation.mayReset(relative: relative),
                bound: CodexResetPresentation.expectedBefore(stamp),
                note: note,
                typeTag: tag?.label,
                typeHelp: tag?.help
            )
        case .empty:
            return noPrediction()
        case nil:
            return noPrediction()
        }
    }

    private static func typeTag(resetType: String?) -> (label: String, help: String?)? {
        let raw = resetType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let label = CodexResetPresentation.typeLabel(resetType: raw)
        guard !label.isEmpty else { return nil }
        return (label, CodexResetPresentation.help(resetType: raw, announcement: nil))
    }

    private static func noPrediction() -> Prediction {
        Prediction(
            trailing: ForecastCopy.text("No prediction yet"),
            countdown: nil,
            bound: nil,
            note: nil
        )
    }

    static func identity(_ status: CodexResetStatus?) -> String {
        let latestPart: String
        if let latest = status?.latest {
            latestPart = "\(latest.id)|\(latest.resetType)|\(latest.announcedAt.timeIntervalSinceReferenceDate)|\(latest.text ?? "")"
        } else {
            latestPart = ""
        }
        let when = status?.scheduled?.scheduledFor
        let watch = status?.watch
        if latestPart.isEmpty, when == nil, watch == nil { return "" }
        let whenText = when.map { String($0.timeIntervalSinceReferenceDate) } ?? ""
        let endsText = watch?.windowEnds.map { String($0.timeIntervalSinceReferenceDate) } ?? ""
        let prediction = "\(whenText)|\(status?.scheduled?.resetType ?? "")|\(watch?.level ?? "")|\(endsText)|\(watch?.text ?? "")|\(watch?.forecastWindow ?? "")|\(watch?.resetType ?? "")"
        if latestPart.isEmpty { return prediction }
        return "\(latestPart)||\(prediction)"
    }
}

/// How often to ask Codex Resets, given what its own headers said.
enum CodexResetSchedule {
    static let floor: TimeInterval = 120
    static let `default`: TimeInterval = 600
    static let ceiling: TimeInterval = 1800

    static func interval(maxAge: TimeInterval?) -> TimeInterval {
        min(max(maxAge ?? Self.default, floor), ceiling)
    }

    static func delay(maxAge: TimeInterval?, retryAfter: TimeInterval?, failed: Bool) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 30), ceiling) }
        if failed { return Self.default }
        return interval(maxAge: maxAge)
    }

    static func countsDown(_ status: CodexResetStatus?) -> Bool {
        status?.scheduled?.scheduledFor != nil
    }

    /// While a countdown is still the cached prediction, wait the floor,
    /// never the document's own lifetime.
    static func paced(_ wait: TimeInterval, status: CodexResetStatus?) -> TimeInterval {
        guard countsDown(status) else { return wait }
        return min(wait, floor)
    }

    static func lookIsDue(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) >= floor
    }

    /// The account's weekly window has refilled since the previous reading.
    /// A five-hour window is not this: it rolls several times a day.
    static func weeklyQuotaRestored(previous: [ForecastWindow], current: [ForecastWindow]) -> Bool {
        for after in current where after.kind == .weekly {
            guard let before = previous.first(where: { $0.id == after.id }) else { continue }
            if weeklyWindowRestored(before: before, after: after) { return true }
        }
        return false
    }

    private static func weeklyWindowRestored(before: ForecastWindow, after: ForecastWindow) -> Bool {
        guard before.kind == .weekly, after.kind == .weekly else { return false }
        guard after.usedFraction <= 0.02 else { return false }
        if before.usedFraction - after.usedFraction >= 0.15 { return true }
        guard let new = after.resetsAt, let old = before.resetsAt else { return false }
        let jump = new.timeIntervalSince(old)
        let week = TimeInterval(max(after.windowSeconds, before.windowSeconds, 0))
        return before.usedFraction <= 0.02 && jump > max(6 * 3600, week * 0.25)
    }

    static func maxAge(from header: String?) -> TimeInterval? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard item.hasPrefix("max-age=") else { continue }
            return TimeInterval(item.dropFirst("max-age=".count))
        }
        return nil
    }

    static func retryAfter(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(text) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: text) else { return nil }
        return max(date.timeIntervalSince(now), 0)
    }
}

/// One HTTP result, reduced to the fields the poller acts on.
struct CodexResetReply: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case parsed(CodexResetStatus)
        case notModified
        case failed
    }

    var payload: Payload
    var etag: String?
    var maxAge: TimeInterval?
    var retryAfter: TimeInterval?

    static func interpret(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        now: Date = Date()
    ) -> CodexResetReply {
        let fields = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let etag = fields["etag"]
        let maxAge = CodexResetSchedule.maxAge(from: fields["cache-control"])
        let retry = CodexResetSchedule.retryAfter(from: fields["retry-after"], now: now)
        switch statusCode {
        case 304:
            return CodexResetReply(payload: .notModified, etag: etag, maxAge: maxAge, retryAfter: nil)
        case 200:
            guard let status = CodexResetStatus.parse(body) else {
                return CodexResetReply(payload: .failed, etag: nil, maxAge: nil, retryAfter: nil)
            }
            return CodexResetReply(payload: .parsed(status), etag: etag, maxAge: maxAge, retryAfter: nil)
        case 429:
            return CodexResetReply(
                payload: .failed,
                etag: nil,
                maxAge: nil,
                retryAfter: retry ?? CodexResetSchedule.floor
            )
        default:
            return CodexResetReply(payload: .failed, etag: nil, maxAge: nil, retryAfter: retry)
        }
    }
}

/// The status request. `cachePolicy` ignores the shared session's cache so a
/// four-hour `max-age` cannot hide a newly announced time.
enum CodexResetRequest {
    static func make(etag: String?) -> URLRequest {
        var request = URLRequest(
            url: CodexResetEndpoint.status,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Blinky", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }
}

/// Hides a forecast the weekly quota has already outgrown, until the floor passes
/// or a different forecast arrives.
enum CodexResetQuiet {
    struct State: Equatable, Sendable {
        var key = ""
        var until = Date.distantPast
    }

    static func displayed(_ status: CodexResetStatus?, quiet: State, now: Date) -> CodexResetStatus? {
        guard let status else { return nil }
        guard !quiet.key.isEmpty, now < quiet.until, status.predictionKey == quiet.key else {
            return status
        }
        return status.withoutPrediction()
    }
}

/// Cached status document. `schema` tells a file from before the window end
/// apart from one that saved it. A missing key is schema 1.
struct CodexResetDisk: Equatable, Codable, Sendable {
    static let legacySchema = 1
    static let timingSchema = 2
    static let storageKey = "forecasts.codexReset.v1"

    var status: CodexResetStatus
    var etag: String?
    var fetchedAt: Date
    var maxAge: TimeInterval?
    var schema: Int

    var omitsForecastTiming: Bool { schema < Self.timingSchema }

    init(
        status: CodexResetStatus,
        etag: String?,
        fetchedAt: Date,
        maxAge: TimeInterval?,
        schema: Int = timingSchema
    ) {
        self.status = status
        self.etag = etag
        self.fetchedAt = fetchedAt
        self.maxAge = maxAge
        self.schema = schema
    }

    private enum CodingKeys: String, CodingKey {
        case status, etag, fetchedAt, maxAge, schema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(CodexResetStatus.self, forKey: .status)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        maxAge = try container.decodeIfPresent(TimeInterval.self, forKey: .maxAge)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.legacySchema
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(etag, forKey: .etag)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encodeIfPresent(maxAge, forKey: .maxAge)
        try container.encode(schema, forKey: .schema)
    }

    static func decode(_ data: Data) -> CodexResetDisk? {
        try? JSONDecoder().decode(CodexResetDisk.self, from: data)
    }

    static func encode(_ disk: CodexResetDisk) -> Data? {
        try? JSONEncoder().encode(disk)
    }

    static func load(from defaults: UserDefaults = .standard) -> CodexResetDisk? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return decode(data)
    }

    static func save(_ disk: CodexResetDisk, to defaults: UserDefaults = .standard) {
        defaults.set(encode(disk), forKey: storageKey)
    }
}

/// What a restored cache is allowed to do next.
struct CodexResetLoadPlan: Equatable, Sendable {
    var etag: String?
    var maxAge: TimeInterval?
    var refetchingForecastTiming: Bool
    var sleepFor: TimeInterval
    var freshUntil: Date

    var sendsConditionalRequest: Bool { !(etag ?? "").isEmpty }

    func forecastFetchIsDue(at now: Date) -> Bool { now >= freshUntil }

    static func make(disk: CodexResetDisk, now: Date) -> CodexResetLoadPlan {
        if disk.omitsForecastTiming {
            return CodexResetLoadPlan(
                etag: nil,
                maxAge: nil,
                refetchingForecastTiming: true,
                sleepFor: 0,
                freshUntil: .distantPast
            )
        }
        let elapsed = now.timeIntervalSince(disk.fetchedAt)
        let interval = CodexResetSchedule.interval(maxAge: disk.maxAge)
        let cadence = CodexResetSchedule.paced(interval, status: disk.status)
        let remaining = cadence - elapsed
        if remaining > 0 {
            return CodexResetLoadPlan(
                etag: disk.etag,
                maxAge: disk.maxAge,
                refetchingForecastTiming: false,
                sleepFor: remaining,
                freshUntil: now.addingTimeInterval(remaining)
            )
        }
        return CodexResetLoadPlan(
            etag: disk.etag,
            maxAge: disk.maxAge,
            refetchingForecastTiming: false,
            sleepFor: 0,
            freshUntil: .distantPast
        )
    }
}
