import Foundation

/// Decoded shape of `/api/oauth/usage`.
///
/// The endpoint is undocumented, so decoding is maximally defensive: every
/// field is optional, unknown limit kinds pass through untouched, and fields
/// this app doesn't use are ignored entirely. The `limits` array is canonical;
/// the legacy top-level buckets (`five_hour`, `seven_day`) are deliberately
/// not modeled.
public struct UsageResponse: Decodable, Sendable, Equatable {
    public let limits: [UsageLimit]?
    public let spend: UsageSpend?

    public static func decode(from data: Data) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    public init(limits: [UsageLimit]?, spend: UsageSpend?) {
        self.limits = limits
        self.spend = spend
    }
}

public struct UsageLimit: Decodable, Sendable, Equatable {
    public let kind: String?
    /// 0–100 as sent; consumers clamp. Decoded as Double because sibling
    /// fields in the payload use floats and the server may drift.
    public let percent: Double?
    public let severity: String?
    public let resetsAt: Date?
    public let scope: UsageScope?

    private enum CodingKeys: String, CodingKey {
        case kind, percent, severity, scope
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        severity = try container.decodeIfPresent(String.self, forKey: .severity)
        scope = try container.decodeIfPresent(UsageScope.self, forKey: .scope)
        // An unparseable timestamp degrades to nil, never a decode failure.
        let raw = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        resetsAt = raw.flatMap(FlexibleISO8601.date(from:))
    }

    public init(kind: String?, percent: Double?, severity: String?, resetsAt: Date?, scope: UsageScope?) {
        self.kind = kind
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scope = scope
    }
}

public struct UsageScope: Decodable, Sendable, Equatable {
    public let model: ScopeModel?

    public struct ScopeModel: Decodable, Sendable, Equatable {
        public let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }

        public init(displayName: String?) {
            self.displayName = displayName
        }
    }

    public init(model: ScopeModel?) {
        self.model = model
    }
}

public struct UsageSpend: Decodable, Sendable, Equatable {
    public let used: Money?
    public let limit: Money?
    public let enabled: Bool?

    public struct Money: Decodable, Sendable, Equatable {
        public let amountMinor: Int?
        public let currency: String?
        public let exponent: Int?

        private enum CodingKeys: String, CodingKey {
            case currency, exponent
            case amountMinor = "amount_minor"
        }

        public init(amountMinor: Int?, currency: String?, exponent: Int?) {
            self.amountMinor = amountMinor
            self.currency = currency
            self.exponent = exponent
        }
    }

    public init(used: Money?, limit: Money?, enabled: Bool?) {
        self.used = used
        self.limit = limit
        self.enabled = enabled
    }
}
