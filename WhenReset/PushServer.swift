import Foundation
import Security
import UIKit

enum PushServerMode: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case custom

    var title: String {
        switch self {
        case .disabled: "Off"
        case .custom: "Self-hosted server"
        }
    }
}

struct PushServerSettings: Codable, Hashable, Sendable {
    var mode: PushServerMode = .disabled
    var customServerURL = ""

    init(mode: PushServerMode = .disabled, customServerURL: String = "") {
        self.mode = mode
        self.customServerURL = customServerURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(PushServerMode.self, forKey: .mode) ?? .disabled
        customServerURL = try values.decodeIfPresent(String.self, forKey: .customServerURL) ?? ""
    }

    func resolvedServerURL() throws -> URL? {
        switch mode {
        case .disabled:
            return nil
        case .custom:
            return try PushServerConfiguration.normalizedServerURL(customServerURL)
        }
    }
}

enum PushServerStatus: Equatable, Sendable {
    case disabled
    case waitingForDeviceToken
    case registering
    case registered
    case failed(String)

    var title: String {
        switch self {
        case .disabled: "Off"
        case .waitingForDeviceToken: "Waiting for APNs"
        case .registering: "Registering…"
        case .registered: "Registered"
        case let .failed(message): message
        }
    }
}

enum PushServerError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case serverRejected(Int)
    case missingRegistration
    case missingServerAccessKey
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid HTTPS server URL."
        case .invalidResponse: "The push server returned an invalid response."
        case let .serverRejected(code): "The push server returned HTTP \(code)."
        case .missingRegistration: "Register this device before sending a test refresh."
        case .missingServerAccessKey: "Enter the access key for this self-hosted server."
        case let .randomGenerationFailed(status): "Couldn’t create the device secret (\(status))."
        }
    }
}

enum PushServerConfiguration {
    static func normalizedServerURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw PushServerError.invalidServerURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil
        let trimmedPath = components.path.replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
        components.path = trimmedPath
        guard let url = components.url else { throw PushServerError.invalidServerURL }
        return url
    }
}

struct PushRegistrationCredentials: Codable, Equatable, Sendable {
    var deviceID: UUID
    var deviceSecret: String
    var serverURL: URL
}

enum PushServerClient {
    private struct RegistrationRequest: Encodable {
        var deviceID: String
        var deviceSecret: String
        var apnsToken: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceSecret = "device_secret"
            case apnsToken = "apns_token"
        }
    }

    static func register(settings: PushServerSettings, deviceToken: Data) async throws {
        guard let serverURL = try settings.resolvedServerURL() else { return }
        guard let serverAccessKey = try? KeychainStore.loadPushServerAccessKey(for: serverURL),
              serverAccessKey.count >= 32 else {
            throw PushServerError.missingServerAccessKey
        }
        let credentials = try registrationCredentials(for: serverURL)
        var request = URLRequest(url: serverURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(serverAccessKey, forHTTPHeaderField: "X-When-Reset-Server-Key")
        request.httpBody = try JSONEncoder().encode(RegistrationRequest(
            deviceID: credentials.deviceID.uuidString.lowercased(),
            deviceSecret: credentials.deviceSecret,
            apnsToken: deviceToken.hexadecimalString
        ))
        _ = try await send(request)
    }

    static func unregister(settings: PushServerSettings) async throws {
        guard let serverURL = try settings.resolvedServerURL() else { return }
        guard let credentials = try? KeychainStore.loadPushRegistration(for: serverURL) else {
            KeychainStore.deletePushServerAccessKey(for: serverURL)
            return
        }
        var request = URLRequest(
            url: serverURL.appending(path: "v1/devices/\(credentials.deviceID.uuidString.lowercased())")
        )
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
        KeychainStore.deletePushRegistration(for: serverURL)
        KeychainStore.deletePushServerAccessKey(for: serverURL)
    }

    static func requestTestRefresh(settings: PushServerSettings) async throws {
        guard let serverURL = try settings.resolvedServerURL(),
              let credentials = try? KeychainStore.loadPushRegistration(for: serverURL) else {
            throw PushServerError.missingRegistration
        }
        var request = URLRequest(
            url: serverURL.appending(
                path: "v1/devices/\(credentials.deviceID.uuidString.lowercased())/refresh"
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.deviceSecret)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    private static func registrationCredentials(for serverURL: URL) throws
        -> PushRegistrationCredentials {
        if let existing = try? KeychainStore.loadPushRegistration(for: serverURL) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PushServerError.randomGenerationFailed(status) }
        let secret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let credentials = PushRegistrationCredentials(
            deviceID: UUID(),
            deviceSecret: secret,
            serverURL: serverURL
        )
        try KeychainStore.savePushRegistration(credentials)
        return credentials
    }

    private static func send(_ request: URLRequest) async throws -> HTTPURLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let (_, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushServerError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PushServerError.serverRejected(httpResponse.statusCode)
        }
        return httpResponse
    }
}

@MainActor
final class RemotePushCoordinator {
    static let shared = RemotePushCoordinator()

    private weak var store: AppStore?
    private var deviceToken: Data?

    private init() {}

    func configure(store: AppStore) {
        self.store = store
        if let deviceToken {
            Task { await store.updatePushRegistration(deviceToken: deviceToken) }
        }
    }

    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken
        guard let store else { return }
        Task { await store.updatePushRegistration(deviceToken: deviceToken) }
    }

    func didFailToRegister(_ error: Error) {
        store?.pushRegistrationFailed(error)
    }

    func requestRegistrationIfNeeded() {
        guard let store, store.pushServerSettings.mode != .disabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if let deviceToken {
            Task { await store.updatePushRegistration(deviceToken: deviceToken) }
        }
    }

    func handle(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let marker = userInfo["when_reset"] as? [String: Any],
              marker["action"] as? String == "refresh",
              let store,
              store.pushServerSettings.mode != .disabled else { return .noData }
        if store.isRefreshing { return .noData }
        return await store.refreshAll(source: .background) ? .newData : .failed
    }
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
