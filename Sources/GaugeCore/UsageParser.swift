import Foundation
import CoreFoundation

/// Only provider-reported, numeric measurements become quota windows. Missing is never zero.
public enum UsageParser {
    public static func claude(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GaugeError.unsupported }
        let definitions: [(String, String, Int)] = [
            ("five_hour", "5시간", 300), ("seven_day", "주간", 10080),
            ("seven_day_fable", "Fable · 주간", 10080),
            ("seven_day_sonnet", "Sonnet · 주간", 10080), ("seven_day_opus", "Opus · 주간", 10080),
            ("seven_day_oauth_apps", "OAuth 앱 · 주간", 10080),
            ("seven_day_cowork", "Cowork", 10080), ("seven_day_routines", "Routines", 10080),
        ]
        let legacy = Dictionary(uniqueKeysWithValues: definitions.map { ($0.0, ($0.1, $0.2)) })
        var windows: [UsageWindow] = []
        var seen: Set<String> = []
        func append(_ window: UsageWindow) {
            if seen.insert(window.id).inserted { windows.append(window) }
        }

        // New responses provide the rows shown in Claude's usage panel here.
        // Prefer these measurements over equivalent legacy fields.
        for case let row as [String: Any] in json["limits"] as? [Any] ?? [] {
            guard let kind = label(row["kind"]), let percent = number(row["percent"]) else { continue }
            let group = label(row["group"]) ?? kind.split(separator: "_").first.map(String.init)
            let period: (id: String, title: String, duration: Int?)
            switch group {
            case "session": period = ("five_hour", "5시간", 300)
            case "weekly": period = ("seven_day", "주간", 10080)
            case "daily": period = ("one_day", "일간", 1440)
            case "monthly": period = ("monthly", "월간", nil)
            default: period = (slug(kind), "", nil)
            }
            let scope = row["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let surface = scope?["surface"] as? [String: Any]
            let modelName = label(model?["display_name"])
            let surfaceName = label(surface?["display_name"])
            let name = modelName ?? surfaceName ?? label(row["display_name"])
            let unscoped = ["session", "weekly_all", "daily_all", "monthly_all"].contains(kind)
                && modelName == nil && surfaceName == nil
            let id: String
            let title: String
            if unscoped {
                id = period.id
                title = period.title
            } else if let name {
                let normalized = slug(name)
                guard !normalized.isEmpty else { continue }
                let suffix = normalized.range(of: #"^fable(?:_[0-9]+)*$"#, options: .regularExpression) == nil
                    ? normalized : "fable"
                id = "\(period.id)_\(suffix)"
                title = legacy[id]?.0 ?? (period.title.isEmpty ? name : "\(name) · \(period.title)")
            } else { continue }
            let fallback = json[id] as? [String: Any]
            append(UsageWindow(id: id, title: title, usedPercent: percent,
                               resetsAt: date(row["resets_at"]) ?? date(fallback?["resets_at"]),
                               durationMinutes: period.duration))
        }

        for (key, title, duration) in definitions {
            let item = (json[key] as? [String: Any])
                ?? (key == "seven_day_fable" ? json["seven_day_overage_included"] as? [String: Any] : nil)
            guard let item, let percent = number(item["utilization"]) else { continue }
            append(UsageWindow(id: key, title: title, usedPercent: percent, resetsAt: date(item["resets_at"]), durationMinutes: duration))
        }
        // Older responses also expose separate buckets as period-prefixed keys.
        let periods = [("five_hour_", "5시간", 300), ("seven_day_", "주간", 10080), ("one_day_", "일간", 1440)]
        for key in json.keys.sorted() where legacy[key] == nil && key != "seven_day_overage_included" {
            guard let (prefix, title, minutes) = periods.first(where: { key.hasPrefix($0.0) }),
                  let item = json[key] as? [String: Any], let percent = number(item["utilization"]) else { continue }
            let name = key.dropFirst(prefix.count).replacingOccurrences(of: "_", with: " ").capitalized
            guard !name.isEmpty else { continue }
            append(UsageWindow(id: key, title: "\(name) · \(title)", usedPercent: percent,
                               resetsAt: date(item["resets_at"]), durationMinutes: minutes))
        }
        for (key, title) in [("cinder_cove", "Claude Code 및 Cowork 크레딧"), ("wattle_ember", "프로모션 크레딧")] {
            guard let item = json[key] as? [String: Any], let percent = number(item["utilization"]) else { continue }
            append(UsageWindow(id: key, title: label(item["label"]) ?? title, usedPercent: percent,
                               resetsAt: date(item["resets_at"])))
        }

        let credits = claudeCredits(json["extra_usage"])
        guard !windows.isEmpty || credits != nil else { throw GaugeError.unsupported }
        // Keep the general usage rows first regardless of which format supplied them.
        let general = ["five_hour", "seven_day"]
        let ordered = general.compactMap { id in windows.first { $0.id == id } }
            + windows.filter { !general.contains($0.id) }
        return UsageSnapshot(windows: ordered, fetchedAt: now, usageCredits: credits)
    }

    private static func label(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func slug(_ value: String) -> String {
        value.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
    }

    private static func claudeCredits(_ value: Any?) -> UsageCredits? {
        guard let item = value as? [String: Any], let enabled = item["is_enabled"] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue else { return nil }
        let used = number(item["used_credits"]).flatMap { $0 >= 0 ? $0 : nil }
        let limit = number(item["monthly_limit"]).flatMap { $0 >= 0 ? $0 : nil }
        let percent = number(item["utilization"]) ?? used.flatMap { amount in
            limit.flatMap { cap in cap > 0 ? (amount / cap) * 100 : nil }
        }
        guard used != nil || limit != nil || percent?.isFinite == true else { return nil }
        return UsageCredits(usedMinorUnits: used, limitMinorUnits: limit, currency: label(item["currency"]),
                            usedPercent: percent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil })
    }

    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GaugeError.unsupported }
        return try codex(json, now: now)
    }
    public static func codex(_ json: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        var windows: [UsageWindow] = []
        var plan: String?
        let buckets: [(String, [String: Any])]
        let byID = (json["rateLimitsByLimitId"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        if !byID.isEmpty {
            // Use the richer response exclusively so the legacy view cannot duplicate it.
            buckets = byID.sorted { a, b in
                if a.key == "codex" { return b.key != "codex" }
                if b.key == "codex" { return false }
                return a.key < b.key
            }
        } else if let legacy = json["rateLimits"] as? [String: Any] {
            buckets = [(legacy["limitId"] as? String ?? "codex", legacy)]
        } else { throw GaugeError.unsupported }
        for (bucketID, bucket) in buckets {
            plan = plan ?? bucket["planType"] as? String
            for key in ["primary", "secondary"] {
                guard let item = bucket[key] as? [String: Any], let percent = number(item["usedPercent"]) else { continue }
                let minutes = number(item["windowDurationMins"]).flatMap { value -> Int? in
                    guard value >= 1, value < Double(Int.max) else { return nil }
                    return Int(value)
                }
                let duration = minutes == 10080 ? "주간" : UsageFormatting.duration(minutes)
                let prefix = bucketID == "codex" ? "" : ((bucket["limitName"] as? String ?? bucketID) + " · ")
                windows.append(UsageWindow(id: "\(bucketID).\(key)", title: prefix + duration, usedPercent: percent,
                                           resetsAt: date(item["resetsAt"]), durationMinutes: minutes))
            }
        }
        guard !windows.isEmpty else { throw GaugeError.unsupported }
        return UsageSnapshot(windows: windows, fetchedAt: now, plan: plan)
    }
    public static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    public static func date(_ raw: Any?) -> Date? {
        if let seconds = number(raw), seconds > 0, seconds < 253402300800 { return Date(timeIntervalSince1970: seconds) }
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Backoff is per account; retry-after always wins over the user's polling interval.
public struct RefreshPolicy {
    public static func delay(failures: Int, interval: Int, retryAfter: Int? = nil) -> TimeInterval {
        let base = Double(max(60, interval))
        let exponent = max(0, min(failures - 1, 5))
        return max(Double(retryAfter ?? 0), min(3600, base * pow(2, Double(exponent))))
    }
}

/// One alert per threshold per actual reset window. Repeated polling cannot spam alerts.
public struct ThresholdTracker {
    private var alerted: Set<String> = []
    public init() {}
    public mutating func crossings(accountID: UUID, snapshot: UsageSnapshot, now: Date = Date()) -> [UsageWindow] {
        snapshot.windows.filter { window in
            guard !window.isStale(at: now, fetchedAt: snapshot.fetchedAt), window.usedPercent >= 80 else { return false }
            let threshold = window.usedPercent >= 95 ? 95 : 80
            let epoch = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            let key = "\(accountID).\(window.id).\(epoch).\(threshold)"
            return alerted.insert(key).inserted
        }
    }
}
