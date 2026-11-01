import SwiftUI
import GaugeCore

struct AccountsView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: Account?
    @State private var deleting: Account?
    @State private var working = false
    @State private var deletionError: String?
    @State private var reconnecting: Account?
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                PageHeading(eyebrow: "YOUR CONNECTED ACCOUNTS", title: "계정마다, 각자의 공간.", subtitle: "개인 계정부터 팀 계정까지 편하게 관리하세요.")
                Spacer()
                Button { store.showAddAccount = true } label: { Label("계정 추가", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
            }
            if store.accounts.isEmpty { EmptyAccountsView() }
            else {
                VStack(spacing: 12) {
                    ForEach(store.accounts) { account in
                        Card {
                            HStack(spacing: 14) {
                                ProviderMark(provider: account.provider, size: 41)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(account.name).font(.system(size: 15, weight: .semibold))
                                        Text(account.provider.title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    }
                                    Text(account.identity ?? account.organizationName ?? "인증된 구독 계정").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    if let error = store.errors[account.id] {
                                        Text(error).font(.system(size: 12)).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
                                        if account.kind == .claudeLocal {
                                            Button("로그인 연결 복구") { reconnecting = account }
                                                .buttonStyle(QuietButtonStyle()).disabled(store.refreshing.contains(account.id))
                                        } else if store.keychainAccessNeeded.contains(account.id) {
                                            Button("키체인 접근 허용") { Task { await store.authorizeKeychain(account) } }
                                                .buttonStyle(QuietButtonStyle()).disabled(store.authorizingKeychain.contains(account.id) || store.refreshing.contains(account.id))
                                        } else if account.provider == .claude {
                                            Button("다시 로그인") { reconnecting = account }
                                                .buttonStyle(QuietButtonStyle()).disabled(store.refreshing.contains(account.id))
                                        }
                                    }
                                }
                                Spacer()
                                Text(account.kind.isLocal ? "이 Mac 로그인" : account.kind == .codex ? "OpenAI 로그인" : account.kind == .claudeCode ? "Claude 로그인" : account.kind == .claudeOAuth ? "OAuth 토큰" : "웹 세션")
                                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(Palette.background, in: Capsule())
                                Button { store.pin(account) } label: {
                                    Image(systemName: store.pinnedProvider == account.provider ? "pin.fill" : "pin")
                                }.buttonStyle(IconButtonStyle(selected: store.pinnedProvider == account.provider))
                                    .help("\(account.provider.title) 전체 계정의 잔여 한도 고정").accessibilityLabel("\(account.provider.title) 전체 계정 고정")
                                Menu {
                                    Button("이름 변경") { editing = account }
                                    Button("서비스 사용량 페이지 열기") { NSWorkspace.shared.open(account.provider.usageURL) }
                                    Button("새로고침") { Task { await store.refreshAll() } }.disabled(store.isRefreshing)
                                    if account.provider == .claude {
                                        Button("키체인 접근 허용…") { Task { await store.authorizeKeychain(account) } }
                                            .disabled(store.authorizingKeychain.contains(account.id) || store.refreshing.contains(account.id))
                                        Button(account.kind == .claudeLocal ? "Gauge 전용 로그인으로 전환…" : "다시 로그인…") { reconnecting = account }.disabled(store.refreshing.contains(account.id))
                                    }
                                    Divider()
                                    Button("계정 연결 해제…", role: .destructive) { deleting = account }
                                } label: {
                                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).frame(width: 32, height: 32)
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                                    .fixedSize().disabled(working).help("계정 메뉴").accessibilityLabel("\(account.name) 계정 메뉴")
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "pin").foregroundStyle(Palette.accent)
                    Text("핀을 누르면 같은 서비스의 모든 계정 잔여량을 합산해 메뉴 막대에 표시합니다. 3개 계정이면 총 300% 기준이며, 5시간·주간 한도는 따로 계산합니다.")
                        .foregroundStyle(Palette.secondary)
                }.font(.system(size: 13)).lineSpacing(4).padding(16)
            }
            if let deletionError { Text(deletionError).font(.system(size: 13)).foregroundStyle(Palette.red) }
        }
        .sheet(item: $editing) { account in RenameSheet(account: account).environmentObject(store) }
        .sheet(item: $reconnecting) { account in AddAccountView(reconnecting: account).environmentObject(store) }
        .alert("계정 연결을 해제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("연결 해제", role: .destructive) {
                guard let account = deleting else { return }
                deleting = nil; working = true; deletionError = nil
                Task {
                    defer { working = false }
                    do { try await store.remove(account) } catch { deletionError = error.localizedDescription }
                }
            }
        } message: {
            Text(deleting?.kind.isLocal == true
                 ? "Gauge의 연결 정보와 사용량 기록이 삭제됩니다. 이 Mac의 원래 CLI 로그인은 유지됩니다."
                 : "Gauge에 저장된 인증 정보와 이 계정의 사용량 기록이 삭제됩니다.")
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var account: Account
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("계정 이름 변경").font(.system(size: 18, weight: .semibold))
            TextField("계정 이름", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("저장") { store.rename(account, to: name); dismiss() }.buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(26).frame(width: 370).onAppear { name = account.name }
    }
}
