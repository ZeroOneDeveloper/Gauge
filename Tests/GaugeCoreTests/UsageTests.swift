import XCTest
@testable import GaugeCore

final class UsageTests: XCTestCase {
    func testClaudeMissingAndNullAreNotZero() throws {
        let data = Data(#"{"five_hour":null,"seven_day":{"utilization":42.5,"resets_at":"2026-10-22T10:15:00.123Z"},"seven_day_opus":{"utilization":null},"seven_day_sonnet":{"utilization":true}}"#.utf8)
        let snapshot = try UsageParser.claude(data)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 42.5)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.windows[0].durationMinutes, 10080)
    }
    func testClaudeZeroIsValidAndOutOfRangeIsClamped() throws {
        let snapshot = try UsageParser.claude(Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":122}}"#.utf8))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 100])
    }
    func testNoMeasurementsThrowsRatherThanReportingHealthy() {
        XCTAssertThrowsError(try UsageParser.claude(Data(#"{"five_hour":null}"#.utf8)))
        XCTAssertThrowsError(try UsageParser.codex(Data(#"{"rateLimits":{"primary":null}}"#.utf8)))
    }
    func testCodexPrefersMultipleBucketsAndPreservesActualDuration() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":25,"windowDurationMins":15,"resetsAt":1792400400},"secondary":{"usedPercent":70,"windowDurationMins":10080}},"review":{"limitName":"Code review","primary":{"usedPercent":5,"windowDurationMins":10080}}}}"#.utf8)
        let snapshot = try UsageParser.codex(data)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].title, "15분")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25)
        XCTAssertEqual(snapshot.windows[1].title, "주간")
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 3)
    }
    func testCodexLegacyWeeklyOnlyAndInvalidSiblings() throws {
        let snapshot = try UsageParser.codex(Data(#"{"rateLimits":{"primary":null,"secondary":{"usedPercent":0,"windowDurationMins":10080}}}"#.utf8))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].title, "주간")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 0)
    }
    func testNonNumericPercentagesAreIgnored() throws {
        let snapshot = try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":true},"secondary":{"usedPercent":15,"windowDurationMins":300}}}"#.utf8))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 15)
        let oversized = try UsageParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":1e100,"resetsAt":1e100}}}"#.utf8))
        XCTAssertNil(oversized.windows[0].durationMinutes)
        XCTAssertNil(oversized.windows[0].resetsAt)
        XCTAssertEqual(oversized.windows[0].title, "사용량")
    }
    func testStaleSnapshotAndPassedResetCannotDriveMenuBar() {
        let now = Date(timeIntervalSince1970: 10000)
        let window = UsageWindow(id: "session", title: "5시간", usedPercent: 95, resetsAt: now.addingTimeInterval(10))
        let snapshot = UsageSnapshot(windows: [window], fetchedAt: now)
        XCTAssertNotNil(snapshot.currentPeak(at: now))
        XCTAssertNil(snapshot.currentPeak(at: now.addingTimeInterval(11)))
        XCTAssertNil(snapshot.currentPeak(at: now.addingTimeInterval(601)))
    }
    func testBackoffRespectsProviderAndCapsExponent() {
        XCTAssertEqual(RefreshPolicy.delay(failures: 1, interval: 120), 120)
        XCTAssertEqual(RefreshPolicy.delay(failures: 3, interval: 120), 480)
        XCTAssertEqual(RefreshPolicy.delay(failures: 100, interval: 120), 3600)
        XCTAssertEqual(RefreshPolicy.delay(failures: 1, interval: 60, retryAfter: 7200), 7200)
    }
    func testAlertsAreScopedToAccountWindowAndReset() {
        var tracker = ThresholdTracker()
        let now = Date()
        let id = UUID()
        let window = UsageWindow(id: "weekly", title: "주간", usedPercent: 82, resetsAt: now.addingTimeInterval(300))
        let snapshot = UsageSnapshot(windows: [window], fetchedAt: now)
        XCTAssertEqual(tracker.crossings(accountID: id, snapshot: snapshot, now: now).count, 1)
        XCTAssertEqual(tracker.crossings(accountID: id, snapshot: snapshot, now: now).count, 0)
        XCTAssertEqual(tracker.crossings(accountID: UUID(), snapshot: snapshot, now: now).count, 1)
        var critical = window; critical.usedPercent = 97
        XCTAssertEqual(tracker.crossings(accountID: id, snapshot: UsageSnapshot(windows: [critical], fetchedAt: now), now: now).count, 1)
        var reset = window; reset.resetsAt = now.addingTimeInterval(600)
        XCTAssertEqual(tracker.crossings(accountID: id, snapshot: UsageSnapshot(windows: [reset], fetchedAt: now), now: now).count, 1)
    }
    func testCountdownAndMissingTime() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertEqual(UsageFormatting.countdown(to: nil, now: now), "초기화 시간 미제공")
        XCTAssertEqual(UsageFormatting.countdown(to: now, now: now), "초기화 확인 중")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(7201), now: now), "2시간 1분 후")
    }
}
