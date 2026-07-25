import Foundation

/// Persists accounts and their secrets under ~/Library/Application Support/UsageBar/.
///
/// v0.1 stores secrets in a chmod-600 JSON file — the same posture as
/// ~/.codex/auth.json. Keychain migration is planned once the app ships as a
/// signed bundle (stable code signature avoids per-build ACL prompts).
final class AccountStore {
    static let shared = AccountStore()

    private let directory: URL
    private let accountsURL: URL
    private let secretsURL: URL
    private let queue = DispatchQueue(label: "dev.daybreak.usagebar.store")

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("UsageBar", isDirectory: true)
        self.directory = base
        self.accountsURL = base.appendingPathComponent("accounts.json")
        self.secretsURL = base.appendingPathComponent("secrets.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - Accounts

    func loadAccounts() -> [Account] {
        queue.sync {
            guard let data = try? Data(contentsOf: accountsURL) else { return [] }
            return (try? Self.decoder.decode([Account].self, from: data)) ?? []
        }
    }

    func add(_ account: Account, secrets: AccountSecrets) throws {
        try queue.sync {
            var accounts = (try? Data(contentsOf: accountsURL))
                .flatMap { try? Self.decoder.decode([Account].self, from: $0) } ?? []
            accounts.append(account)
            try write(accounts, to: accountsURL)

            var all = readSecrets()
            all[account.id.uuidString] = secrets
            try writeSecrets(all)
        }
    }

    /// Update an account's rolling priority (nil = default 1).
    func updatePriority(for id: UUID, _ priority: Int?) throws {
        try queue.sync {
            var accounts = (try? Data(contentsOf: accountsURL))
                .flatMap { try? Self.decoder.decode([Account].self, from: $0) } ?? []
            guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[idx].rollPriority = priority
            try write(accounts, to: accountsURL)
        }
    }

    /// Update a persisted account's display label — the local-CLI row follows
    /// whatever account Claude Code is currently logged into.
    func updateLabel(for id: UUID, _ label: String) throws {
        try queue.sync {
            var accounts = (try? Data(contentsOf: accountsURL))
                .flatMap { try? Self.decoder.decode([Account].self, from: $0) } ?? []
            guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[idx].label = label
            try write(accounts, to: accountsURL)
        }
    }

    func remove(id: UUID) throws {
        try queue.sync {
            var accounts = (try? Data(contentsOf: accountsURL))
                .flatMap { try? Self.decoder.decode([Account].self, from: $0) } ?? []
            accounts.removeAll { $0.id == id }
            try write(accounts, to: accountsURL)

            var all = readSecrets()
            all.removeValue(forKey: id.uuidString)
            try writeSecrets(all)
        }
    }

    // MARK: - Secrets

    func secrets(for id: UUID) -> AccountSecrets? {
        queue.sync { readSecrets()[id.uuidString] }
    }

    /// Codex tokens rotate on refresh — persisting the new refresh token
    /// immediately is what keeps the lineage alive.
    func updateSecrets(for id: UUID, _ secrets: AccountSecrets) throws {
        try queue.sync {
            var all = readSecrets()
            all[id.uuidString] = secrets
            try writeSecrets(all)
        }
    }

    // MARK: - Plumbing

    private func readSecrets() -> [String: AccountSecrets] {
        guard let data = try? Data(contentsOf: secretsURL) else { return [:] }
        return (try? Self.decoder.decode([String: AccountSecrets].self, from: data)) ?? [:]
    }

    private func writeSecrets(_ value: [String: AccountSecrets]) throws {
        try write(value, to: secretsURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: secretsURL.path
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
