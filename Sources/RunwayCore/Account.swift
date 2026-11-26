import Foundation

public enum AccountKind: String, Sendable, Equatable {
    case personal, team, enterprise

    public var label: String {
        switch self {
        case .personal: tr("Personal")
        case .team: tr("Team")
        case .enterprise: tr("Enterprise")
        }
    }

    /// "claude_team" → team, "claude_enterprise" → enterprise, anything else (claude_max, claude_pro) → personal.
    /// The credentials' `subscriptionType` is the fallback when the config has no organization type.
    public static func from(organizationType: String?, subscriptionType: String?) -> AccountKind {
        let source = (organizationType ?? subscriptionType ?? "").lowercased()
        if source.contains("enterprise") { return .enterprise }
        if source.contains("team") { return .team }
        return .personal
    }
}

/// The Claude account Claude Code is logged into, as cached by Claude Code in `~/.claude.json`.
public struct ClaudeAccount: Sendable, Equatable {
    public var email: String?
    public var kind: AccountKind
    public var organizationName: String?
    /// Stable identity (account + organization UUIDs): a change means Claude Code switched accounts.
    public var id: String?

    public init(email: String?, kind: AccountKind, organizationName: String? = nil, id: String? = nil) {
        self.email = email
        self.kind = kind
        self.organizationName = organizationName
        self.id = id
    }

    /// Reads `oauthAccount` from the root of Claude Code's config file. Nil when logged out.
    public static func parse(_ data: Data, subscriptionType: String? = nil) -> ClaudeAccount? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        func nonEmpty(_ key: String) -> String? { (oauth[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let email = nonEmpty("emailAddress")
        let kind = AccountKind.from(organizationType: oauth["organizationType"] as? String,
                                    subscriptionType: subscriptionType)
        let org = nonEmpty("organizationName")
        let uuids = ["accountUuid", "organizationUuid"].compactMap(nonEmpty)
        let id = uuids.isEmpty ? email : uuids.joined(separator: "|")
        return ClaudeAccount(email: email, kind: kind, organizationName: kind == .personal ? nil : org, id: id)
    }
}

public protocol AccountProvider: Sendable {
    func loadAccount(subscriptionType: String?) async -> ClaudeAccount?
}

/// `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`. Checked on every poll (no network call);
/// the file (hundreds of KB, rewritten often by Claude Code) is only parsed again when it changed.
public struct ClaudeConfigAccountProvider: AccountProvider {
    public var url: URL
    private let memo = Memo()

    /// Last parse, keyed by the file's modification date and size.
    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var key: String?
        var account: ClaudeAccount?
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let dir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        url = dir.appendingPathComponent(".claude.json")
    }

    public func loadAccount(subscriptionType: String?) async -> ClaudeAccount? {
        let url = self.url
        let memo = self.memo
        return await Task.detached(priority: .utility) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = attributes.map { "\($0[.modificationDate] ?? "")|\($0[.size] ?? "")|\(subscriptionType ?? "")" }
            if let key, let hit = memo.lock.withLock({ memo.key == key ? memo.account : nil }) { return hit }
            // Unreadable or half-written (Claude Code rewriting it): nil, the store keeps the last account.
            guard let data = try? Data(contentsOf: url),
                  let account = ClaudeAccount.parse(data, subscriptionType: subscriptionType) else { return nil }
            memo.lock.withLock { memo.key = key; memo.account = account }
            return account
        }.value
    }
}

/// Used with RUNWAY_FIXTURE so QA never reads the real config.
public struct StaticAccountProvider: AccountProvider {
    public var account: ClaudeAccount?

    public init(_ account: ClaudeAccount?) { self.account = account }

    public func loadAccount(subscriptionType: String?) async -> ClaudeAccount? { account }
}
