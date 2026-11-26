import Foundation

/// Where the persisted state lives: UserDefaults in the app, memory in tests and fixture mode.
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
}

extension UserDefaults: KeyValueStore {
    public func setData(_ data: Data?, forKey key: String) { set(data, forKey: key) }
}

public final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    public func setData(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

extension KeyValueStore {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func encode<T: Encodable>(_ value: T?, forKey key: String) {
        setData(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

/// Last good snapshot and the account it belongs to: a relaunch shows it at once, with its age,
/// unless Claude Code is now logged into another account.
public struct SnapshotCache: Sendable {
    static let key = "runway.snapshot"

    struct Entry: Codable {
        var accountID: String?
        var snapshot: UsageSnapshot
    }

    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    public func load() -> (snapshot: UsageSnapshot, accountID: String?)? {
        store.decode(Entry.self, forKey: Self.key).map { ($0.snapshot, $0.accountID) }
    }

    public func save(_ snapshot: UsageSnapshot, accountID: String?) {
        store.encode(Entry(accountID: accountID, snapshot: snapshot), forKey: Self.key)
    }
}
