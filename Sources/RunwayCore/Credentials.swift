import Foundation

/// Claude Code OAuth credentials. Only the access token is used; the refresh token is
/// never read into memory (it is single-use and belongs to Claude Code).
public struct ClaudeCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var description: String {
        "ClaudeCredentials(token: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"), tier: \(rateLimitTier ?? "nil"))"
    }

    public var debugDescription: String { description }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public var planName: String? { PlanName.from(rateLimitTier: rateLimitTier, subscriptionType: subscriptionType) }

    /// Parses the JSON stored by Claude Code in the "Claude Code-credentials" keychain item.
    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw CredentialsError.malformed }

        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int {
            expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return ClaudeCredentials(accessToken: token,
                                 expiresAt: expiresAt,
                                 subscriptionType: oauth["subscriptionType"] as? String,
                                 rateLimitTier: oauth["rateLimitTier"] as? String)
    }
}

public enum PlanName {
    /// "default_claude_max_5x" → "Max 5x"; falls back to the capitalized subscription type (never "Team").
    public static func from(rateLimitTier: String?, subscriptionType: String?) -> String? {
        if let tier = rateLimitTier?.lowercased() {
            if let range = tier.range(of: #"max_(\d+x)"#, options: .regularExpression) {
                let multiplier = tier[range].dropFirst("max_".count)
                return "Max \(multiplier)"
            }
            if tier.contains("max") { return "Max" }
            if tier.contains("pro") { return "Pro" }
        }
        // "team" / "enterprise" are account types, not plans: the account line already says them.
        guard let sub = subscriptionType, !sub.isEmpty,
              !["team", "enterprise"].contains(sub.lowercased()) else { return nil }
        return sub.prefix(1).uppercased() + sub.dropFirst()
    }
}

public enum CredentialsError: Error, Equatable {
    /// No "Claude Code-credentials" item: Claude Code is not installed or never logged in.
    case notFound
    case unreadable(status: Int32)
    case malformed
}

public protocol CredentialsProvider: Sendable {
    func loadCredentials() async throws -> ClaudeCredentials
}

/// Reads the token by running `/usr/bin/security` as a subprocess. That tool is already in the
/// item's ACL (Claude Code uses it), so no keychain prompt appears. Re-read on every poll.
public struct KeychainCredentialsProvider: CredentialsProvider {
    public var service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func loadCredentials() async throws -> ClaudeCredentials {
        let service = self.service
        return try await Task.detached(priority: .utility) {
            try Self.readKeychain(service: service)
        }.value
    }

    static func readKeychain(service: String) throws -> ClaudeCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CredentialsError.unreadable(status: -1)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0: break
        case 44: throw CredentialsError.notFound // errSecItemNotFound
        case let status: throw CredentialsError.unreadable(status: status)
        }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try ClaudeCredentials.parse(Data(trimmed.utf8))
    }
}

/// Used with RUNWAY_FIXTURE so QA never touches the keychain.
public struct StaticCredentialsProvider: CredentialsProvider {
    public var result: Result<ClaudeCredentials, CredentialsError>

    public init(_ result: Result<ClaudeCredentials, CredentialsError>) {
        self.result = result
    }

    public func loadCredentials() async throws -> ClaudeCredentials {
        try result.get()
    }
}
