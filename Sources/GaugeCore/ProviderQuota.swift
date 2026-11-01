import Foundation

public struct CombinedQuota: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let accountCount: Int
    public let confirmedCount: Int
    public let confirmedRemaining: Double
    public var capacity: Int { accountCount * 100 }
    public var isComplete: Bool { confirmedCount == accountCount }
    public var remaining: Double? { isComplete ? confirmedRemaining : nil }
    public var usedPercent: Double? { remaining.map { 100 - $0 / Double(capacity) * 100 } }
    public var remainingLabel: String {
        let value = remaining.map { String(Int($0.rounded())) } ?? "—"
        return "\(value) / \(capacity)%"
    }
}

public enum ProviderQuota {
    public static func combine(provider: Provider, accounts: [Account], snapshots: [String: UsageSnapshot],
                               unavailable: Set<UUID> = [], now: Date = Date()) -> [CombinedQuota] {
        let selected = accounts.filter { $0.provider == provider }
        var titles: [String: String] = [:]
        var samples: [String: [UUID: Double]] = [:]
        var order: [String] = []
        for account in selected {
            guard let snapshot = snapshots[account.id.uuidString] else { continue }
            for window in snapshot.windows {
                let key = key(window, provider: provider)
                if titles[key] == nil { titles[key] = window.title; order.append(key) }
                guard !unavailable.contains(account.id), !window.isStale(at: now, fetchedAt: snapshot.fetchedAt) else { continue }
                samples[key, default: [:]][account.id] = window.remainingPercent
            }
        }
        return order.map { key in
            let values = samples[key, default: [:]]
            return CombinedQuota(id: key, title: titles[key]!, accountCount: selected.count,
                                 confirmedCount: values.count, confirmedRemaining: values.values.reduce(0, +))
        }
    }

    // Codex can report the same period in primary on one account and secondary
    // on another. Match the actual period and bucket, never the array position.
    private static func key(_ window: UsageWindow, provider: Provider) -> String {
        guard provider == .codex, let duration = window.durationMinutes else { return window.id }
        let bucket = window.id.split(separator: ".").dropLast().joined(separator: ".")
        return "\(bucket).\(duration)"
    }

    public static func menuWindow(_ windows: [CombinedQuota]) -> CombinedQuota? {
        windows.first { $0.id == "seven_day" || $0.id == "codex.10080" }
            ?? windows.first { $0.id == "five_hour" || $0.id == "codex.300" }
            ?? windows.first
    }
}
