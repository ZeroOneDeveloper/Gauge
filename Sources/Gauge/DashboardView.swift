import SwiftUI
import GaugeCore

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if let error = store.globalError {
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.circle")
                                Text(error).textSelection(.enabled)
                                Spacer()
                                Button { store.globalError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }.font(.system(size: 14)).foregroundStyle(Palette.red)
                                .padding(14).frame(maxWidth: .infinity).background(Palette.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        switch store.page {
                        case .overview: OverviewView()
                        case .history: HistoryView()
                        case .accounts: AccountsView()
                        case .settings: SettingsView()
                        }
                    }.padding(32).frame(maxWidth: 1220)
                        .frame(maxWidth: .infinity)
                }
            }.background(Palette.background)
        }
        .foregroundStyle(Palette.ink)
        .frame(minWidth: 1000, minHeight: 720)
        .sheet(isPresented: $store.showAddAccount) { AddAccountView().environmentObject(store) }
    }
    var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                Text("내 워크스페이스").foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium)).foregroundStyle(Palette.secondary.opacity(0.6))
                Text(store.page.title).fontWeight(.medium)
            }.font(.system(size: 13))
            Spacer()
            Button { store.openMenuBar?() } label: {
                Label("메뉴 막대에서 보기", systemImage: "menubar.rectangle")
                    .font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(Palette.secondary).padding(.trailing, 14)
                .help("맥 상단의 Gauge 사용량 메뉴 열기 · 큰 창을 닫아도 계속 사용할 수 있어요")
            Circle().fill(Palette.green).frame(width: 5, height: 5)
            Text("로컬 전용").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }.padding(.horizontal, 32).frame(height: 58).background(.white.opacity(0.8))
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .foregroundStyle(.white).padding(.horizontal, 24).padding(.top, 52).padding(.bottom, 40)
            Text("WORKSPACE").font(.system(size: 12, weight: .semibold)).tracking(1.6)
                .foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 26).padding(.bottom, 13)
            VStack(spacing: 5) {
                ForEach(AppPage.allCases) { page in
                    Button {
                        store.page = page
                        if page != .overview { store.providerFilter = nil }
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: page.icon).font(.system(size: 14)).frame(width: 18)
                            Text(page.title).font(.system(size: 14, weight: store.page == page ? .semibold : .regular))
                            Spacer()
                            if page == .accounts && !store.accounts.isEmpty {
                                Text("\(store.accounts.count)").font(.system(size: 12, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }.foregroundStyle(store.page == page ? .white : .white.opacity(0.48))
                            .padding(.horizontal, 13).frame(height: 41)
                            .background(store.page == page ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 14)
            Text("CONNECTED").font(.system(size: 12, weight: .semibold)).tracking(1.6)
                .foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 26).padding(.top, 36).padding(.bottom, 18)
            ForEach(Provider.allCases) { provider in
                Button { store.page = .overview; store.providerFilter = provider } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Palette.provider(provider)).frame(width: 6, height: 6)
                        Text(provider.title).font(.system(size: 14))
                        Spacer()
                        Text("\(store.accounts.filter { $0.provider == provider }.count)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                    }.foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 26).padding(.vertical, 10)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: "leaf").font(.system(size: 18)).foregroundStyle(Color(hex: 0x93B3A3))
                Text("흐름은 길게,\n확인은 짧게.").font(.system(size: 15, weight: .medium)).lineSpacing(5).foregroundStyle(.white.opacity(0.8))
                Text("작업에 집중하세요.\n사용량은 Gauge가 살펴볼게요.").font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.35))
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).padding(16)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("이 Mac에만 안전하게").font(.system(size: 12))
                Spacer()
                Text(GaugeVersion.current).font(.system(size: 12, design: .monospaced))
            }.foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 23).padding(.bottom, 22)
        }.frame(width: 212).background(Palette.sidebar)
    }
}

struct PageHeading: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
            Text(title).font(.system(size: 29, weight: .bold)).tracking(-0.8)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Palette.secondary)
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    private var validSnapshots: [(Account, UsageSnapshot)] {
        store.accounts.compactMap { account in
            guard store.errors[account.id] == nil, let snapshot = store.snapshots[account.id.uuidString], snapshot.currentPeak(at: store.now) != nil else { return nil }
            return (account, snapshot)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 27) {
            HStack(alignment: .center) {
                PageHeading(eyebrow: "YOUR DAILY CHECK-IN", title: "모든 계정, 한눈에.", subtitle: "한도 걱정은 덜고, 하던 일에 집중하세요.")
                Spacer()
                Button { Task { await store.connectLocalAccounts() } } label: {
                    if store.isConnectingLocal { Label("연결 중…", systemImage: "arrow.triangle.2.circlepath") }
                    else { Label("이 Mac 계정 연결", systemImage: "laptopcomputer") }
                }.buttonStyle(QuietButtonStyle()).disabled(store.isConnectingLocal)
                Button { store.showAddAccount = true } label: { Label("계정 추가", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 13) {
                MetricCard(title: "연결된 계정", value: "\(store.accounts.count)", unit: "개", icon: "person.2", tint: Palette.ink,
                           detail: "Claude · Codex · Gemini")
                MetricCard(title: "여유 있는 계정", value: "\(validSnapshots.filter { ($0.1.currentPeak(at: store.now)?.usedPercent ?? 100) < 75 }.count)", unit: "개", icon: "checkmark.circle", tint: Palette.green,
                           detail: "모든 사용 한도 75% 미만")
                MetricCard(title: "확인이 필요한 계정", value: "\(store.accounts.count - validSnapshots.filter { ($0.1.currentPeak(at: store.now)?.usedPercent ?? 100) < 75 }.count)", unit: "개", icon: "flag", tint: Palette.amber,
                           detail: "한도 주의 또는 갱신 필요")
            }
            HStack {
                SectionLabel(title: "내 계정", detail: "\(store.visibleAccounts.count)개")
                HStack(spacing: 3) {
                    filterButton("전체", provider: nil)
                    ForEach(Provider.allCases) { filterButton($0.title, provider: $0) }
                }.padding(3).background(Palette.line.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                Button { Task { await store.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(IconButtonStyle()).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(store.isRefreshing).help("사용량 새로고침 (⌘R)")
            }
            if store.visibleAccounts.isEmpty {
                EmptyAccountsView()
            } else {
                VStack(spacing: 20) {
                    ForEach(Array(stride(from: 0, to: store.visibleAccounts.count, by: 2)), id: \.self) { index in
                        AccountCardRow {
                            AccountCard(account: store.visibleAccounts[index])
                            if index + 1 < store.visibleAccounts.count { AccountCard(account: store.visibleAccounts[index + 1]) }
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle").font(.system(size: 17)).foregroundStyle(Palette.accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text("작업을 시작하기 전, 가볍게 확인하세요.").font(.system(size: 14, weight: .semibold))
                    Text("각 카드에서는 계정별 사용률을 확인하세요. 메뉴 막대에 서비스를 고정하면 해당 서비스 전체 계정의 잔여량을 합산해 볼 수 있어요.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xF0EBE5).opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
            HStack(spacing: 6) {
                Circle().fill(store.isRefreshing ? Palette.amber : Palette.green).frame(width: 4, height: 4)
                Text(store.isRefreshing ? "사용량을 확인하고 있어요" : store.lastUpdated.map { UsageFormatting.age($0, now: store.now) } ?? "계정을 연결하면 자동으로 갱신됩니다")
                Spacer()
                Text("\(store.state.refreshInterval / 60)분마다 자동 갱신").foregroundStyle(Palette.secondary.opacity(0.8))
            }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
    private func filterButton(_ title: String, provider: Provider?) -> some View {
        Button { store.providerFilter = provider } label: {
            Text(title).font(.system(size: 12, weight: store.providerFilter == provider ? .semibold : .regular))
                .foregroundStyle(store.providerFilter == provider ? Palette.ink : Palette.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(store.providerFilter == provider ? .white : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}

struct MetricCard: View {
    var title: String; var value: String; var unit: String; var icon: String; var tint: Color; var detail: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(title).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint.opacity(0.75))
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                    Text(unit).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
    }
}

struct AccountCard: View {
    @EnvironmentObject var store: AppStore
    var account: Account
    var snapshot: UsageSnapshot? { store.snapshots[account.id.uuidString] }
    var error: String? { store.errors[account.id] }
    var body: some View {
        Card(fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ProviderMark(provider: account.provider)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(account.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            if account.provider == store.pinnedProvider {
                                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Palette.secondary).help("메뉴 막대에 표시 중")
                            }
                        }
                        Text("\(account.provider.title)\(account.plan.map { " · " + $0.capitalized } ?? "")").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0)
                    if error != nil {
                        StatusPill(title: "확인 필요", color: Palette.red)
                    } else if let snapshot, let peak = snapshot.currentPeak(at: store.now) {
                        StatusPill(title: peak.level.title, color: Palette.usage(peak.usedPercent))
                    } else { StatusPill(title: "갱신 필요", color: Palette.secondary) }
                }.padding(.bottom, 24)
                if let snapshot {
                    VStack(spacing: 22) {
                        ForEach(snapshot.windows) { window in
                            UsageWindowRow(window: window, fetchedAt: snapshot.fetchedAt, now: store.now, hasError: error != nil)
                        }
                        if let credits = snapshot.usageCredits {
                            UsageCreditsRow(credits: credits, stale: error != nil || store.now.timeIntervalSince(snapshot.fetchedAt) > 600)
                        }
                        if let resets = snapshot.limitResets {
                            LimitResetRows(inventory: resets, now: store.now,
                                           stale: error != nil || store.now.timeIntervalSince(snapshot.fetchedAt) > 600)
                        }
                    }
                } else {
                    Text("사용량 정보를 기다리고 있어요").font(.system(size: 14)).foregroundStyle(Palette.secondary).frame(height: 85)
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                }
                Spacer(minLength: 24)
                HStack(spacing: 6) {
                    Text(account.identity ?? account.organizationName ?? "연결된 계정").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if store.refreshing.contains(account.id) { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "clock").font(.system(size: 11)) }
                    if let snapshot { Text(UsageFormatting.age(snapshot.fetchedAt, now: store.now)).fixedSize() }
                }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .padding(.top, 16).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
            }
        }
    }
}

struct UsageCreditsRow: View {
    var credits: UsageCredits
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("추가 사용 크레딧").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                if let percent = credits.usedPercent {
                    Text("\(Int(percent.rounded()))% 사용").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
            }
            if let percent = credits.usedPercent { UsageBar(percent: percent, muted: stale, height: 6) }
            if let amount = credits.amountLabel {
                Text(amount).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            if stale { Text("마지막 확인값").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct LimitResetRows: View {
    let inventory: LimitResetInventory
    let now: Date
    let stale: Bool

    var body: some View {
        let general = inventory.availableGrants(at: now, fable: false)
        let fable = inventory.availableGrants(at: now, fable: true)
        VStack(alignment: .leading, spacing: 8) {
            if !general.isEmpty || inventory.unlistedCount > 0 || fable.isEmpty {
                row("리셋 사용권", grants: general, unlisted: inventory.unlistedCount)
            }
            if !fable.isEmpty { row("Fable 리셋 사용권", grants: fable) }
            if stale {
                Text("마지막 확인값").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
    }

    private func row(_ title: String, grants: [LimitResetGrant], unlisted: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                Text("\(grants.reduce(unlisted) { $0 + $1.count })개 남음").font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            if let expiry = grants.compactMap(\.expiresAt).min() {
                Text("가장 가까운 만료 \(expiry.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct UsageWindowRow: View {
    var window: UsageWindow
    var fetchedAt: Date
    var now: Date
    var hasError = false
    private var stale: Bool { hasError || window.isStale(at: now, fetchedAt: fetchedAt) }
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 14, weight: .medium))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(stale ? Palette.secondary : Palette.ink)
                Text("% 사용").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.leading, -5)
            }
            UsageBar(percent: window.usedPercent, muted: stale)
            HStack {
                Text(stale ? "마지막 확인값" : "\(Int(window.remainingPercent))% 남음")
                Spacer()
                Text(UsageFormatting.countdown(to: window.resetsAt, now: now))
            }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyAccountsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: -6) {
                ProviderMark(provider: .claude, size: 48).rotationEffect(.degrees(-9))
                ProviderMark(provider: .codex, size: 48).offset(y: -2)
                ProviderMark(provider: .gemini, size: 48).rotationEffect(.degrees(9)).offset(y: 4)
            }.padding(.bottom, 5)
            Text("첫 계정을 연결해 볼까요?").font(.system(size: 19, weight: .semibold))
            Text("Claude, Codex, Gemini 사용량을\n한곳에서 확인하세요.")
                .font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(5).multilineTextAlignment(.center)
            HStack(spacing: 9) {
                Button { store.showAddAccount = true } label: { Label("계정 연결하기", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                Button("이 Mac 계정 연결") { Task { await store.connectLocalAccounts() } }.buttonStyle(QuietButtonStyle()).disabled(store.isConnectingLocal)
            }.padding(.top, 7)
            Label("인증 정보는 macOS 키체인에 보관됩니다", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 5)
        }.frame(maxWidth: .infinity).padding(.vertical, 42)
            .background(.white, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
