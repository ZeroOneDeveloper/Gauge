import SwiftUI
import ServiceManagement
import GaugeCore

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var codexPath = CodexConnection.executable()?.path ?? "미설정"
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            PageHeading(eyebrow: "MAKE YOURSELF AT HOME", title: "가볍게, 내 방식대로.", subtitle: "작업 흐름에 맞게 Gauge를 설정하세요.")
            Card {
                VStack(alignment: .leading, spacing: 24) {
                    SectionLabel(title: "일반")
                    HStack {
                        settingText("자동 새로고침", "계정별로 간격을 두고 사용량을 확인해요.")
                        Spacer()
                        Picker("갱신 주기", selection: Binding(get: { store.state.refreshInterval }, set: { store.setRefreshInterval($0) })) {
                            Text("1분").tag(60); Text("2분").tag(120); Text("5분").tag(300); Text("10분").tag(600)
                        }.labelsHidden().frame(width: 120)
                    }
                    Divider().overlay(Palette.line)
                    HStack {
                        settingText("로그인할 때 실행", "Mac을 켜면 메뉴 막대에서 바로 만나요.")
                        Spacer()
                        Toggle("로그인할 때 실행", isOn: $launchesAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .onChange(of: launchesAtLogin) { _, enabled in
                                do {
                                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                                } catch {
                                    store.globalError = "로그인 항목을 변경하지 못했어요. 앱을 Applications 폴더에 옮긴 후 다시 시도해 주세요."
                                    launchesAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                    Divider().overlay(Palette.line)
                    HStack {
                        settingText("한도 알림", "각 사용 한도의 80%, 95%에 도달하면 알려드려요.")
                        Spacer()
                        Toggle("한도 알림", isOn: Binding(get: { store.state.notificationsEnabled }, set: { enabled in Task { await store.setNotifications(enabled) } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 20) {
                    SectionLabel(title: "Codex 연결")
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Codex 실행 파일").font(.system(size: 14, weight: .medium))
                            Text(codexPath).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button("파일 선택…") { chooseCodex() }.buttonStyle(QuietButtonStyle())
                    }
                    Text("Codex 앱에 포함된 실행 파일 또는 설치된 CLI를 사용합니다. 계정마다 전용 프로필과 키체인을 사용해 자동으로 로그인을 갱신합니다.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield").foregroundStyle(Palette.green)
                        SectionLabel(title: "내 데이터는 내 Mac에")
                    }
                    Text("직접 연결한 인증 정보는 macOS 키체인에 보관해요. ‘이 Mac 로그인’ 계정은 원래 CLI의 인증 저장소를 사용합니다. 계정 이름과 사용량 기록은 이 Mac에 보관하며, 조회 요청은 각 서비스에 직접 전송됩니다.")
                        .font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(5)
                    HStack {
                        Button("데이터 폴더 열기") {
                            do { try LocalStorage.prepare(LocalStorage.root); NSWorkspace.shared.open(LocalStorage.root) }
                            catch { store.globalError = error.localizedDescription }
                        }.buttonStyle(QuietButtonStyle())
                        Button("이 Mac 계정 연결") { Task { await store.connectLocalAccounts() } }.buttonStyle(QuietButtonStyle()).disabled(store.isConnectingLocal)
                        Spacer()
                        Text("Gauge 1.0.0").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
    }
    private func settingText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.message = "codex 실행 파일을 선택하세요."
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { store.globalError = "실행 권한이 있는 Codex 파일을 선택해 주세요."; return }
        UserDefaults.standard.set(url.path, forKey: "codexExecutable")
        codexPath = url.path
    }
}
