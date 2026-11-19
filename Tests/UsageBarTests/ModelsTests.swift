import XCTest
@testable import usagebar

/// 옛 accounts.json/secrets.json(main 8a551d3 스키마)이 그대로 읽혀야 한다.
final class ModelsTests: XCTestCase {
    static let legacyAccounts = """
    [
      {
        "addedAt" : "2026-07-10T03:12:45Z",
        "id" : "11111111-1111-1111-1111-111111111111",
        "kind" : "localClaudeCLI",
        "label" : "one@example.com (로컬)",
        "provider" : "claude"
      },
      {
        "addedAt" : "2026-07-24T09:00:00Z",
        "id" : "22222222-2222-2222-2222-222222222222",
        "kind" : "storedToken",
        "label" : "two@example.com",
        "provider" : "claude",
        "rollPriority" : 2
      },
      {
        "addedAt" : "2026-07-11T00:00:00Z",
        "id" : "33333333-3333-3333-3333-333333333333",
        "kind" : "storedToken",
        "label" : "codex@example.com",
        "provider" : "codex"
      }
    ]
    """

    static let legacySecrets = """
    {
      "22222222-2222-2222-2222-222222222222" : {
        "accessToken" : "sk-ant-oat01-old",
        "claudeKeychainItem" : "{\\"claudeAiOauth\\":{}}",
        "expiresAtMs" : 1790000000000,
        "refreshToken" : "sk-ant-ort01-old",
        "scopes" : ["user:inference", "user:profile"]
      },
      "33333333-3333-3333-3333-333333333333" : {
        "accessToken" : "codex-access",
        "accountId" : "acct-1",
        "idToken" : "id.tok.en",
        "refreshToken" : "codex-refresh"
      }
    }
    """

    func testLegacyAccountsJSONDecodes() throws {
        let dir = makeTempDir()
        try Data(Self.legacyAccounts.utf8).write(to: dir.appendingPathComponent("accounts.json"))
        let accounts = AccountStore(directory: dir).loadAccounts()
        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts[0].kind, .localClaudeCLI)
        XCTAssertEqual(accounts[1].kind, .storedToken)
        XCTAssertEqual(accounts[1].priority, 2)
        XCTAssertNil(accounts[1].organizationId)
        XCTAssertEqual(accounts[2].provider, .codex)

        // 옛 Claude 행은 재등록 필요, Codex 저장 행은 아님.
        XCTAssertTrue(accounts[0].needsReregistration)
        XCTAssertTrue(accounts[1].needsReregistration)
        XCTAssertFalse(accounts[2].needsReregistration)
        XCTAssertFalse(accounts.contains(where: \.isClaudeToken))
    }

    /// 새 계정을 추가해도(secrets.json 전체 재작성) 옛 행의 시크릿 필드가 보존된다.
    func testAddingAccountPreservesLegacySecrets() throws {
        let dir = makeTempDir()
        try Data(Self.legacyAccounts.utf8).write(to: dir.appendingPathComponent("accounts.json"))
        try Data(Self.legacySecrets.utf8).write(to: dir.appendingPathComponent("secrets.json"))
        let store = AccountStore(directory: dir)

        let fresh = Account(provider: .claude, kind: .setupToken, label: "new@example.com",
                            organizationId: "org-x")
        try store.add(fresh, secrets: AccountSecrets(accessToken: "sk-ant-oat01-new"))

        let reloaded = AccountStore(directory: dir)
        let old = try XCTUnwrap(reloaded.secrets(for: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!))
        XCTAssertEqual(old.refreshToken, "sk-ant-ort01-old")
        XCTAssertEqual(old.claudeKeychainItem, "{\"claudeAiOauth\":{}}")
        XCTAssertEqual(old.expiresAtMs, 1790000000000)
        XCTAssertEqual(old.scopes, ["user:inference", "user:profile"])
        let codex = try XCTUnwrap(reloaded.secrets(for: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!))
        XCTAssertEqual(codex.accountId, "acct-1")

        let accounts = reloaded.loadAccounts()
        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(accounts[3].kind, .setupToken)
        XCTAssertEqual(accounts[3].organizationId, "org-x")
        XCTAssertTrue(accounts[3].isClaudeToken)
        XCTAssertEqual(reloaded.secrets(for: fresh.id)?.accessToken, "sk-ant-oat01-new")
        XCTAssertEqual(posixMode(dir.appendingPathComponent("secrets.json")), 0o600)
    }

    func testUpdateOrganizationId() throws {
        let dir = makeTempDir()
        let store = AccountStore(directory: dir)
        let a = Account(provider: .claude, kind: .setupToken, label: "a@example.com")
        try store.add(a, secrets: AccountSecrets(accessToken: "t"))
        try store.updateOrganizationId(for: a.id, "org-1")
        XCTAssertEqual(AccountStore(directory: dir).loadAccounts().first?.organizationId, "org-1")
    }
}
