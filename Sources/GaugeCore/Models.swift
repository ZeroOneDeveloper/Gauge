import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, gemini
    public var id: String { rawValue }
    public var title: String {
        switch self { case .claude: "Claude"; case .codex: "Codex"; case .gemini: "Gemini" }
    }
    public var usageURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .gemini: URL(string: "https://antigravity.google/docs/cli/commands/usage")!
        }
    }
}

public enum ConnectionKind: String, Codable {
    case claudeSession, claudeOAuth, codex, claudeLocal, codexLocal, claudeCode, geminiLocal
    public var isLocal: Bool { self == .claudeLocal || self == .codexLocal || self == .geminiLocal }
    public var usesClaudeOAuth: Bool { self == .claudeOAuth || self == .claudeLocal || self == .claudeCode }
}

public struct Account: Codable, Identifiable, Equatable {
    public var id: UUID
    public var provider: Provider
    public var name: String
    public var identity: String?
    public var plan: String?
    public var organizationID: String?
    public var organizationName: String?
    public var kind: ConnectionKind
    public var createdAt: Date

    public init(id: UUID = UUID(), provider: Provider, name: String, identity: String? = nil,
                plan: String? = nil, organizationID: String? = nil, organizationName: String? = nil,
                kind: ConnectionKind? = nil, createdAt: Date = Date()) {
        self.id = id; self.provider = provider; self.name = name; self.identity = identity
        self.plan = plan; self.organizationID = organizationID; self.organizationName = organizationName
        if let kind { self.kind = kind }
        else {
            switch provider {
            case .claude: self.kind = .claudeSession
            case .codex: self.kind = .codex
            case .gemini: self.kind = .geminiLocal
            }
        }
        self.createdAt = createdAt
    }
}

public struct UsageWindow: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil, durationMinutes: Int? = nil) {
        self.id = id; self.title = title; self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt; self.durationMinutes = durationMinutes
    }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public func isResetPending(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func isStale(at now: Date = Date(), fetchedAt: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > 600 || isResetPending(at: now)
    }
    public var level: UsageLevel { UsageLevel(percent: usedPercent) }
}

public enum UsageLevel: String {
    case good, caution, critical
    public init(percent: Double) { self = percent >= 90 ? .critical : percent >= 75 ? .caution : .good }
    public var title: String { switch self { case .good: "여유로워요"; case .caution: "주의가 필요해요"; case .critical: "한도에 가까워요" } }
}

/// Billed credits are separate from included subscription quota windows.
public struct UsageCredits: Codable, Equatable {
    public var usedMinorUnits: Double?
    public var limitMinorUnits: Double?
    public var currency: String?
    public var usedPercent: Double?

    public var amountLabel: String? {
        func format(_ value: Double?) -> String? {
            guard let value else { return nil }
            guard let currency, Locale.commonISOCurrencyCodes.contains(currency.uppercased()) else {
                return value.formatted() + " 크레딧 단위"
            }
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency.uppercased()
            let divisor = pow(10.0, Double(formatter.maximumFractionDigits))
            return formatter.string(from: NSNumber(value: value / divisor))
        }
        let used = format(usedMinorUnits), limit = format(limitMinorUnits)
        if let used, let limit { return "\(used) / \(limit)" }
        if let used { return "\(used) 사용" }
        return limit.map { "월 한도 " + $0 }
    }
}

public struct LimitResetGrant: Codable, Equatable {
    public var count: Int
    public var expiresAt: Date?
    public var fable: Bool = false
}

public struct LimitResetInventory: Codable, Equatable {
    public var grants: [LimitResetGrant]
    public var unlistedCount: Int = 0

    public func availableGrants(at date: Date, fable: Bool) -> [LimitResetGrant] {
        grants.filter { $0.fable == fable && ($0.expiresAt.map { $0 > date } ?? true) }
    }
}

public struct UsageSnapshot: Codable, Equatable {
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var plan: String?
    public var usageCredits: UsageCredits?
    public var limitResets: LimitResetInventory?
    public init(windows: [UsageWindow], fetchedAt: Date = Date(), plan: String? = nil, usageCredits: UsageCredits? = nil,
                limitResets: LimitResetInventory? = nil) {
        self.windows = windows; self.fetchedAt = fetchedAt; self.plan = plan
        self.usageCredits = usageCredits; self.limitResets = limitResets
    }
    public var peak: UsageWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
    public func currentPeak(at now: Date = Date()) -> UsageWindow? {
        windows.filter { !$0.isStale(at: now, fetchedAt: fetchedAt) }.max { $0.usedPercent < $1.usedPercent }
    }
}

public struct HistorySample: Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var windows: [UsageWindow]
    public init(date: Date = Date(), windows: [UsageWindow]) { id = UUID(); self.date = date; self.windows = windows }
}

public struct PersistedState: Codable {
    public var version: Int = 1
    public var accounts: [Account] = []
    public var snapshots: [String: UsageSnapshot] = [:]
    public var history: [String: [HistorySample]] = [:]
    public var pinnedAccountID: UUID?
    public var refreshInterval: Int = 120
    public var notificationsEnabled: Bool = false
    public init() {}
}

public enum GaugeError: LocalizedError {
    case message(String), unauthorized, keychainAccessRequired, keychainBusy, rateLimited(Int), unsupported
    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .unauthorized: return "저장된 인증을 갱신하지 못했어요. 계정 관리에서 ‘다시 로그인’을 눌러 주세요. 계정과 기록은 유지됩니다."
        case .keychainAccessRequired: return "키체인 접근 승인이 필요해요. 계정 관리에서 ‘키체인 접근 허용’을 눌러 주세요."
        case .keychainBusy: return "다른 계정의 키체인 승인이 진행 중이에요. 잠시 후 자동으로 다시 조회합니다."
        case .rateLimited(let seconds): return "요청이 많아 잠시 쉬고 있어요. \(seconds)초 후 다시 시도합니다."
        case .unsupported: return "사용량 정보가 없는 응답입니다. 구독 계정인지 확인하거나 앱 업데이트가 필요한지 확인해 주세요."
        }
    }
}

public enum UsageFormatting {
    public static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "초기화 시간 미제공" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "초기화 확인 중" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440)일 \((minutes % 1440) / 60)시간 후" }
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분 후" }
        return "\(minutes)분 후"
    }
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "방금 갱신" }
        if seconds < 3600 { return "\(seconds / 60)분 전 갱신" }
        if seconds < 86400 { return "\(seconds / 3600)시간 전 갱신" }
        return "\(seconds / 86400)일 전 갱신"
    }
    public static func duration(_ minutes: Int?) -> String {
        guard let minutes else { return "사용량" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }
}
