import Foundation

/// Reads the public Codex Resets status document.
///
/// The same data the site exposes over HTTP. A failure leaves the last
/// status in place. The menu-bar sleep loop and the hover poke stay on Mac;
/// iOS asks while a ChatGPT card is open or the predicted reminder is on.
enum CodexResetClient {
    static func fetch(etag: String?, session: URLSession = .shared) async -> CodexResetReply {
        let request = CodexResetRequest.make(etag: etag)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return CodexResetReply(payload: .failed, etag: nil, maxAge: nil, retryAfter: nil)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String else { continue }
                if let text = value as? String {
                    headers[name] = text
                } else if let number = value as? NSNumber {
                    headers[name] = number.stringValue
                }
            }
            return CodexResetReply.interpret(statusCode: http.statusCode, headers: headers, body: data)
        } catch {
            return CodexResetReply(payload: .failed, etag: nil, maxAge: nil, retryAfter: nil)
        }
    }
}
