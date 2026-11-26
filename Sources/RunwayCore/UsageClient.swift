import Foundation
import os

public enum UsageFetchError: Error, Equatable, Sendable {
    /// 401: token expired or revoked.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case http(status: Int)
    case network(String)
    case decoding

    /// 429 and 5xx trigger exponential backoff.
    public var isThrottling: Bool {
        switch self {
        case .rateLimited, .server: true
        default: false
        }
    }
}

public protocol UsageFetching: Sendable {
    func fetchUsage(accessToken: String) async throws -> UsageResponse
}

public let runwayLog = Logger(subsystem: "com.rocapine.runway", category: "usage")

/// Prints to stderr when RUNWAY_DEBUG is set. Never pass secrets to it.
public func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["RUNWAY_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[runway] " + message() + "\n").utf8))
}

public struct HTTPUsageClient: UsageFetching {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    public static func makeRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("runway/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetchUsage(accessToken: String) async throws -> UsageResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.makeRequest(accessToken: accessToken))
        } catch {
            let code = (error as? URLError)?.code.rawValue ?? 0
            runwayLog.info("usage request failed: network \(code, privacy: .public)")
            debugLog("usage request failed: network error \(code)")
            throw UsageFetchError.network((error as? URLError)?.localizedDescription ?? "\(error)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        runwayLog.info("usage HTTP \(status, privacy: .public) (\(data.count, privacy: .public) bytes)")
        debugLog("usage HTTP \(status) (\(data.count) bytes)")
        try Self.check(status: status, response: response as? HTTPURLResponse)
        return try Self.decode(data)
    }

    static func check(status: Int, response: HTTPURLResponse?) throws {
        switch status {
        case 200..<300: return
        case 401: throw UsageFetchError.unauthorized
        case 429:
            throw UsageFetchError.rateLimited(retryAfter: retryAfter(response?.value(forHTTPHeaderField: "Retry-After")))
        case 500..<600: throw UsageFetchError.server(status: status)
        default: throw UsageFetchError.http(status: status)
        }
    }

    /// Retry-After is either seconds ("3566") or an HTTP date ("Wed, 26 Nov 2026 15:00:00 GMT").
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds.isFinite ? seconds : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { $0.timeIntervalSince(now) }
    }

    public static func decode(_ data: Data) throws -> UsageResponse {
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageFetchError.decoding
        }
    }
}

/// RUNWAY_FIXTURE=<path>: serves a JSON file instead of calling the API.
public struct FixtureUsageClient: UsageFetching {
    public var url: URL

    public init(url: URL) { self.url = url }

    public func fetchUsage(accessToken: String) async throws -> UsageResponse {
        guard let data = try? Data(contentsOf: url) else { throw UsageFetchError.network("fixture introuvable") }
        debugLog("fixture loaded (\(data.count) bytes)")
        return try HTTPUsageClient.decode(data)
    }
}
