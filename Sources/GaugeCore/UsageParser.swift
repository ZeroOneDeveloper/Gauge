import Foundation
import CoreFoundation

/// Only provider-reported, numeric measurements become quota windows. Missing is never zero.
public enum UsageParser {
    public static func claude(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GaugeError.unsupported }
        let definitions: [(String, String, Int)] = [
            ("five_hour", "5시간", 300), ("seven_day", "주간", 10080),
            ("seven_day_sonnet", "Sonnet · 주간", 10080), ("seven_day_opus", "Opus · 주간", 10080),
            ("seven_day_oauth_apps", "OAuth 앱 · 주간", 10080),
            ("seven_day_cowork", "Cowork", 10080), ("seven_day_routines", "Routines", 10080),
        ]
        var windows = definitions.compactMap { key, title, duration -> UsageWindow? in
            guard let item = json[key] as? [String: Any], let percent = number(item["utilization"]) else { return nil }
            return UsageWindow(id: key, title: title, usedPercent: percent, resetsAt: date(item["resets_at"]), durationMinutes: duration)
        }
        // Forward-compatible model windows. Unknown metadata is not interpreted as a quota.
        for key in json.keys.sorted() where key.hasPrefix("seven_day_") && !definitions.contains(where: { $0.0 == key }) {
            guard let item = json[key] as? [String: Any], let percent = number(item["utilization"]) else { continue }
            windows.append(UsageWindow(id: key, title: key.replacingOccurrences(of: "seven_day_", with: "").capitalized + " · 주간",
                                       usedPercent: percent, resetsAt: date(item["resets_at"]), durationMinutes: 10080))
        }
        guard !windows.isEmpty else { throw GaugeError.unsupported }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GaugeError.unsupported }
        return try codex(json, now: now)
    }
    public static func codex(_ json: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        var windows: [UsageWindow] = []
        var plan: String?
        let buckets: [(String, [String: Any])]
        if let byID = json["rateLimitsByLimitId"] as? [String: [String: Any]], !byID.isEmpty {
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
