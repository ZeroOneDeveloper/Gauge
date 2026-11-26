import SwiftUI
import GaugeCore

struct MenuPopover: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) var openWindow
    var dashboardAction: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BrandLockup(markSize: 30, titleSize: 23, spacing: 8, tracking: -0.7)
                Spacer()
                Button { Task { await store.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(IconButtonStyle()).disabled(store.isRefreshing).help("새로고침").accessibilityLabel("새로고침")
            }.padding(20)
            Divider().overlay(Palette.line)
            if store.accounts.isEmpty {
                VStack(spacing: 10) {
                    Text("계정을 연결하고 사용량을 확인하세요").font(.system(size: 14, weight: .medium))
                    Button("계정 연결하기") { showDashboard(); store.showAddAccount = true }.buttonStyle(PrimaryButtonStyle())
                }.padding(.vertical, 30)
            } else {
                HStack(spacing: 8) {
                    ForEach(Provider.allCases.filter { provider in store.accounts.contains { $0.provider == provider } }) { provider in
                        Button { store.pin(provider) } label: {
                            HStack(spacing: 8) {
                                ProviderMark(provider: provider, size: 25)
                                Text(provider.title).font(.system(size: 14, weight: .semibold))
                                Spacer(minLength: 4)
                                Image(systemName: store.pinnedProvider == provider ? "pin.fill" : "pin")
                                    .font(.system(size: 13)).foregroundStyle(store.pinnedProvider == provider ? Palette.accent : Palette.secondary)
                            }.padding(10).frame(maxWidth: .infinity)
                                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.pinnedProvider == provider ? Palette.accent : Palette.line, lineWidth: 1))
                        }.buttonStyle(.plain).help("\(provider.title) 모든 계정의 잔여 한도를 메뉴 막대에 고정")
                            .accessibilityLabel("\(provider.title) 전체 계정 고정")
                    }
                }.padding(.horizontal, 16).padding(.top, 14)
                ScrollView {
                    VStack(spacing: 16) {
                        if let provider = store.pinnedProvider {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("\(provider.title) 전체 잔여 한도").font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Text("\(store.accounts.filter { $0.provider == provider }.count)개 계정").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                }
                                ForEach(store.combinedQuotas) { quota in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(quota.title).font(.system(size: 14)).foregroundStyle(Palette.secondary)
                                            Spacer()
                                            Text(quota.remainingLabel).font(.system(size: 16, weight: .semibold, design: .monospaced))
                                        }
                                        if let used = quota.usedPercent { UsageBar(percent: used, height: 6, showsRemaining: true) }
                                        else { Text("\(quota.confirmedCount)/\(quota.accountCount)개 계정 확인 · 전체 합계 갱신 필요").font(.system(size: 12)).foregroundStyle(Palette.amber) }
                                    }
                                }
                                if store.combinedQuotas.isEmpty { Text("사용량을 확인하고 있어요…").font(.system(size: 13)).foregroundStyle(Palette.secondary) }
                                Text("계정당 100% 기준 · 같은 기간의 잔여량 합산")
                                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(store.accounts) { account in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 9) {
                                    ProviderMark(provider: account.provider, size: 38)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(account.name).font(.system(size: 16, weight: .semibold))
                                        Text(account.provider.title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    }
                                    Spacer()
                                }
                                if let snapshot = store.snapshots[account.id.uuidString] {
                                    let failed = store.errors[account.id] != nil
                                    ForEach(snapshot.windows) { window in
                                        let stale = failed || window.isStale(at: store.now, fetchedAt: snapshot.fetchedAt)
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(window.title).font(.system(size: 14)).foregroundStyle(Palette.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                Spacer(minLength: 8)
                                                Text("\(Int(window.usedPercent.rounded()))%").font(.system(size: 14, weight: .semibold, design: .monospaced))
                                            }
                                            UsageBar(percent: window.usedPercent, muted: stale, height: 6)
                                            if window.resetsAt != nil {
                                                Text(UsageFormatting.countdown(to: window.resetsAt, now: store.now))
                                                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                            }
                                        }.accessibilityElement(children: .combine)
                                    }
                                    if let credits = snapshot.usageCredits {
                                        UsageCreditsRow(credits: credits, stale: failed || store.now.timeIntervalSince(snapshot.fetchedAt) > 600)
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let resets = snapshot.limitResets {
                                            LimitResetRow(inventory: resets, now: store.now,
                                                          stale: failed || store.now.timeIntervalSince(snapshot.fetchedAt) > 600)
                                        }
                                        Text(failed ? "갱신 실패 · 마지막 확인값" : UsageFormatting.age(snapshot.fetchedAt, now: store.now))
                                            .font(.system(size: 12)).foregroundStyle(failed ? Palette.red : Palette.secondary)
                                    }
                                } else {
                                    Text(store.errors[account.id] ?? "갱신 대기 중").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                }
                            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(16)
                }.frame(maxHeight: 580)
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 12) {
                Button { showDashboard() } label: {
                    Label("대시보드 열기", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .medium))
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                Button { showDashboard(); store.page = .settings } label: {
                    Label("설정", systemImage: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
                }.buttonStyle(.plain).help("설정 열기")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(IconButtonStyle()).help("Gauge 종료").accessibilityLabel("Gauge 종료")
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(width: 400).background(Palette.background).foregroundStyle(Palette.ink)
    }
    private func showDashboard() {
        if let dashboardAction { dashboardAction(); return }
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}
