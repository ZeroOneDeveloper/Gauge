import XCTest
@testable import GaugeCore

final class ProviderQuotaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)

    func testThreeClaudeAccountsSumRemainingOutOfThreeHundredPerPeriod() {
        let accounts = (0..<3).map { Account(provider: .claude, name: "Account \($0)") }
        let snapshots = Dictionary(uniqueKeysWithValues: zip(accounts, [20.0, 60.0, 40.0]).map { account, used in
            (account.id.uuidString, UsageSnapshot(windows: [
                UsageWindow(id: "five_hour", title: "5시간", usedPercent: used / 2),
                UsageWindow(id: "seven_day", title: "주간", usedPercent: used),
            ], fetchedAt: now))
        })
        let totals = ProviderQuota.combine(provider: .claude, accounts: accounts, snapshots: snapshots, now: now)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].remaining, 240)
        XCTAssertEqual(totals[1].remaining, 180)
        XCTAssertEqual(totals[1].capacity, 300)
        XCTAssertEqual(totals[1].remainingLabel, "180 / 300%")
        XCTAssertEqual(ProviderQuota.menuWindow(totals)?.title, "주간")
    }

    func testMissingFailedStaleOrResetAccountsCannotLookLikeFullCapacity() {
        let accounts = (0..<3).map { Account(provider: .claude, name: "Account \($0)") }
        let window = UsageWindow(id: "seven_day", title: "주간", usedPercent: 20)
        var snapshots = [accounts[0].id.uuidString: UsageSnapshot(windows: [window], fetchedAt: now)]
        var total = ProviderQuota.combine(provider: .claude, accounts: accounts, snapshots: snapshots, now: now)[0]
        XCTAssertNil(total.remaining)
        XCTAssertEqual(total.capacity, 300)
        XCTAssertEqual(total.confirmedCount, 1)
        XCTAssertEqual(total.confirmedRemaining, 80)
        snapshots[accounts[1].id.uuidString] = UsageSnapshot(windows: [window], fetchedAt: now.addingTimeInterval(-601))
        snapshots[accounts[2].id.uuidString] = UsageSnapshot(windows: [window], fetchedAt: now)
        total = ProviderQuota.combine(provider: .claude, accounts: accounts, snapshots: snapshots, unavailable: [accounts[2].id], now: now)[0]
        XCTAssertEqual(total.confirmedCount, 1)
        var reset = window; reset.resetsAt = now
        snapshots[accounts[1].id.uuidString] = UsageSnapshot(windows: [reset], fetchedAt: now)
        XCTAssertNil(ProviderQuota.combine(provider: .claude, accounts: accounts, snapshots: snapshots, now: now)[0].remaining)
    }

    func testProvidersAndModelLimitsStaySeparateAndNewAccountChangesCapacity() {
        let claude = Account(provider: .claude, name: "Claude")
        let codex = Account(provider: .codex, name: "Codex")
        let snapshots = [claude.id.uuidString: UsageSnapshot(windows: [
            UsageWindow(id: "seven_day", title: "주간", usedPercent: 100),
            UsageWindow(id: "seven_day_sonnet", title: "Sonnet · 주간", usedPercent: 10),
        ], fetchedAt: now), codex.id.uuidString: UsageSnapshot(windows: [UsageWindow(id: "seven_day", title: "주간", usedPercent: 0)], fetchedAt: now)]
        let totals = ProviderQuota.combine(provider: .claude, accounts: [claude, codex], snapshots: snapshots, now: now)
        XCTAssertEqual(totals.map(\.capacity), [100, 100])
        XCTAssertEqual(totals.map(\.remaining), [0, 90])
        let updated = ProviderQuota.combine(provider: .claude, accounts: [claude, codex, Account(provider: .claude, name: "New")], snapshots: snapshots, now: now)
        XCTAssertEqual(updated[0].capacity, 200)
        XCTAssertNil(updated[0].remaining)
    }

    func testCodexMatchesDurationAcrossPrimaryAndSecondary() {
        let first = Account(provider: .codex, name: "First"), second = Account(provider: .codex, name: "Second")
        let snapshots = [first.id.uuidString: UsageSnapshot(windows: [UsageWindow(id: "codex.primary", title: "주간", usedPercent: 25, durationMinutes: 10080)], fetchedAt: now),
                         second.id.uuidString: UsageSnapshot(windows: [UsageWindow(id: "codex.secondary", title: "주간", usedPercent: 50, durationMinutes: 10080)], fetchedAt: now)]
        let totals = ProviderQuota.combine(provider: .codex, accounts: [first, second], snapshots: snapshots, now: now)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].remaining, 125)
        XCTAssertEqual(totals[0].capacity, 200)
    }
}
