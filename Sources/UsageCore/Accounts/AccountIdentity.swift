import Foundation

/// One signed-in identity, as the agent's own config records it. This is
/// what an account-presence epoch is an observation OF — never fetched,
/// never transmitted, read from a local file the agent already maintains.
public struct AccountIdentity: Codable, Sendable, Equatable {
    public let accountUuid: String
    /// Epoch identity is the (account, organization) PAIR: quotas and
    /// billing attach to the organization, and one account in two orgs is
    /// two different budgets. Empty when the agent records none.
    public let organizationUuid: String
    public let email: String?
    public let displayName: String?
    public let organizationName: String?
    /// The org's rate-limit tier ("default_claude_max_20x") — display only.
    public let tier: String?

    public init(
        accountUuid: String, organizationUuid: String, email: String? = nil,
        displayName: String? = nil, organizationName: String? = nil,
        tier: String? = nil
    ) {
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
        self.email = email
        self.displayName = displayName
        self.organizationName = organizationName
        self.tier = tier
    }

    /// The comparison key deciding "same signed-in identity". Tier, name,
    /// and even email may be edited server-side without a re-login — only
    /// the uuid pair defines an epoch boundary.
    public var key: String { "\(accountUuid)|\(organizationUuid)" }

    /// What surfaces call this account. Email is the label of record; the
    /// uuid prefix is the last resort for a record that carries none.
    public var label: String { email ?? String(accountUuid.prefix(8)) }
}

/// Where a provider's agent records which account is signed in — the
/// account-presence seam, opt-in exactly like `statusFeed`: nil means the
/// provider tracks no accounts and every presence surface simply doesn't
/// exist for it.
///
/// Sources are read-only by contract, and local-only by §10: an identity
/// read must never spend a network request, and must never touch credential
/// stores (the Keychain path stays exactly as the credentials chain left
/// it — no new reads, so no new consent prompts, ever).
public protocol AccountIdentitySource: Sendable {
    /// One read of "who is signed in right now". Nil is a real observation
    /// — signed out, or the record is missing/unreadable — never an error.
    func currentIdentity() -> AccountIdentity?
    /// What the privacy card names ("~/.claude.json (read-only)").
    var displayPath: String { get }
}

/// Claude Code's identity record: the `oauthAccount` block of
/// `~/.claude.json`, which `/login` rewrites. Only that one key is decoded;
/// the file's dozens of cache keys churn constantly and are never looked at.
///
/// Deliberately NOT the Keychain: the credentials item carries tokens but
/// no identity, is rewritten on every routine token refresh (change ≠
/// switch), and reading it any new way risks re-opening the consent-prompt
/// story v0.82.1 closed. This is a plain file read, same class as the
/// transcript scans.
public struct ClaudeAccountIdentitySource: AccountIdentitySource {
    let fileURL: URL

    public init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude.json")
    ) {
        self.fileURL = fileURL
    }

    public var displayPath: String { "~/.claude.json" }

    private struct Shell: Decodable {
        let oauthAccount: OAuthAccount?
    }

    private struct OAuthAccount: Decodable {
        let accountUuid: String?
        let organizationUuid: String?
        let emailAddress: String?
        let fullName: String?
        let displayName: String?
        let organizationName: String?
        let organizationRateLimitTier: String?
    }

    public func currentIdentity() -> AccountIdentity? {
        guard let data = try? Data(contentsOf: fileURL),
              let shell = try? JSONDecoder().decode(Shell.self, from: data),
              let account = shell.oauthAccount,
              let uuid = account.accountUuid, !uuid.isEmpty
        else { return nil }
        return AccountIdentity(
            accountUuid: uuid,
            organizationUuid: account.organizationUuid ?? "",
            email: account.emailAddress,
            displayName: account.fullName ?? account.displayName,
            organizationName: account.organizationName,
            tier: account.organizationRateLimitTier)
    }
}
