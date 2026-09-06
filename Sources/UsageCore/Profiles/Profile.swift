import Foundation

/// One agent home under one provider — the unit the app meters, one engine
/// each (multi-account metering, v0.96.0). "Profile" in code, "Account" in
/// the UI: what the person sees is which sign-in a home carries.
///
/// Every install has the implicit `default` profile (the provider's
/// standard home, `~/.claude`); its files and defaults keys keep the
/// pre-profile spelling. Further profiles are enrolled homes — a directory
/// Claude Code was pointed at through `CLAUDE_CONFIG_DIR` — identified by
/// `ProfileID.derive`, which doubles as Claude Code's Keychain suffix.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public static let defaultID = StorageScope.defaultProfileID

    public let id: String
    public let providerID: String
    /// The home directory; nil for providers that have no such notion
    /// (Codex, Gemini — one fixed set of paths).
    public let home: URL?
    /// The person's name for it ("Work"); nil = label from the sign-in.
    public var nickname: String?
    /// One character for the menu bar cell; nil = first letter of the label.
    public var monogram: String?
    /// Metered at all. Off = no engine, no strip row, no cell — the profile
    /// stays listed in Settings for re-enabling.
    public var enabled: Bool
    /// Whether the menu bar shows a cell for it (the strip still lists it).
    public var showInMenuBar: Bool
    /// The person's order in the strip and the bar; ties by `addedAt`.
    public var order: Int
    public let addedAt: Date
    /// Set on a DISCOVERED home the person dismissed rather than enrolled:
    /// the identity key the home carried at the time. The offer stays
    /// silent until `.claude.json` names another sign-in. Such a record is
    /// not a profile the engine meters (`isDismissed`).
    public var ignoredIdentityKey: String?

    enum CodingKeys: String, CodingKey {
        case id, providerID, homePath, nickname, monogram, enabled, showInMenuBar, order,
            addedAt, ignoredIdentityKey
    }

    public init(
        id: String, providerID: String, home: URL?, nickname: String? = nil,
        monogram: String? = nil, enabled: Bool = true, showInMenuBar: Bool = true,
        order: Int = 0, addedAt: Date, ignoredIdentityKey: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.home = home
        self.nickname = nickname
        self.monogram = monogram
        self.enabled = enabled
        self.showInMenuBar = showInMenuBar
        self.order = order
        self.addedAt = addedAt
        self.ignoredIdentityKey = ignoredIdentityKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(String.self, forKey: .providerID)
        home = try container.decodeIfPresent(String.self, forKey: .homePath).map { URL(filePath: $0) }
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        monogram = try container.decodeIfPresent(String.self, forKey: .monogram)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        showInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        ignoredIdentityKey = try container.decodeIfPresent(String.self, forKey: .ignoredIdentityKey)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encodeIfPresent(home?.path, forKey: .homePath)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encodeIfPresent(monogram, forKey: .monogram)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(showInMenuBar, forKey: .showInMenuBar)
        try container.encode(order, forKey: .order)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(ignoredIdentityKey, forKey: .ignoredIdentityKey)
    }

    public var isDefault: Bool { id == Self.defaultID }
    /// A dismissed discovery is remembered, not metered.
    public var isDismissed: Bool { ignoredIdentityKey != nil }
    /// Enrolled = a profile the host may run an engine for.
    public var isEnrolled: Bool { !isDismissed }

    /// "claude" for the default profile, "claude.<id>" otherwise — the
    /// prefix its per-meter popover prefs and ceiling key hang off.
    public var scopeKey: String {
        StorageScope.scopePrefix(providerID: providerID, profileID: id)
    }

    /// "~/.claude-personal"; nil for a home-less provider.
    public func displayHome(
        relativeTo userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        home.map { PathDisplay.abbreviated($0, home: userHome) }
    }

    /// The implicit default profile for a provider, as it stands before the
    /// person edits anything.
    public static func standard(for provider: any UsageProvider, addedAt: Date) -> Profile {
        Profile(id: defaultID, providerID: provider.id, home: provider.homeDirectory, addedAt: addedAt)
    }
}

/// What the faces call a profile, decided once so the strip, the bar's
/// monogram, the CLI's `accounts` table and the Settings card agree.
public enum ProfileFacts {
    /// The nickname when set, else the signed-in email, else the home's
    /// directory name without its leading dot, else the id.
    public static func label(profile: Profile, identity: AccountIdentity?) -> String {
        if let nickname = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty {
            return nickname
        }
        if let email = identity?.email, !email.isEmpty { return email }
        if let name = profile.home?.lastPathComponent, !name.isEmpty {
            return name.hasPrefix(".") ? String(name.dropFirst()) : name
        }
        return profile.id
    }

    /// The person's monogram when set, else the label's first grapheme,
    /// uppercased.
    public static func monogram(profile: Profile, label: String) -> String {
        if let monogram = profile.monogram?.trimmingCharacters(in: .whitespacesAndNewlines),
           let first = monogram.first {
            return String(first).uppercased()
        }
        return label.first.map { String($0).uppercased() } ?? "?"
    }
}
