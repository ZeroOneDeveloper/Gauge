import SwiftUI
import UniformTypeIdentifiers
import GaugeCore

struct AddAccountView: View {
    let reconnecting: Account?
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var credential = ""
    @State private var error: String?
    @State private var status = ""
    @State private var busy = false
    @State private var organizations: [ClaudeOrganization] = []
    @State private var organizationID = ""
    @State private var loginURL: URL?
    @State private var manualClaude = false
    @State private var authorizationCode = ""
    @State private var claudeConnection: ClaudeConnection?
    @State private var pendingClaudeID: UUID?
    @State private var connection: CodexConnection?
    @State private var pendingID: UUID?
    @State private var connectTask: Task<Void, Never>?
    @State private var completed = false

    init(reconnecting: Account? = nil) {
        self.reconnecting = reconnecting
        _provider = State(initialValue: reconnecting?.provider ?? .claude)
        _name = State(initialValue: reconnecting?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                BrandMark(size: 29)
                Text(reconnecting == nil ? "계정 연결" : reconnecting?.kind == .claudeLocal ? "로그인 연결 복구" : "다시 로그인").font(.system(size: 19, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14)).foregroundStyle(Palette.secondary).frame(width: 25, height: 25) }.buttonStyle(.plain)
            }
            Text(reconnecting == nil ? "하나의 앱에, 필요한 만큼의 계정을." : reconnecting?.kind == .claudeLocal ? "Claude Code의 계정 변경과 별도로 유지되는 전용 로그인으로 연결합니다. 기존 계정과 기록은 유지됩니다." : "기존 계정과 사용량 기록을 유지한 채 인증을 갱신합니다.").font(.system(size: 14)).foregroundStyle(Palette.secondary).padding(.top, -12)
            HStack(spacing: 12) {
                ForEach(Provider.allCases) { item in
                    Button {
                        provider = item; error = nil; organizations = []; credential = ""
                    } label: {
                        HStack(spacing: 10) {
                            ProviderMark(provider: item, size: 31)
                            Text(item.title).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Image(systemName: provider == item ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(provider == item ? Palette.ink : Palette.line)
                        }.padding(13).frame(maxWidth: .infinity)
                            .background(provider == item ? Palette.background : .white, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(provider == item ? Palette.ink.opacity(0.5) : Palette.line, lineWidth: 1))
                    }.buttonStyle(.plain).disabled(busy || reconnecting != nil)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("계정 이름").font(.system(size: 13, weight: .semibold))
                TextField(provider == .claude ? "예: 개인 Claude, 회사 Claude" : "예: 개인 Codex, 프로젝트 계정", text: $name)
                    .textFieldStyle(.roundedBorder).controlSize(.large).disabled(busy || reconnecting != nil)
            }
            if provider == .claude { claudeFields } else { codexFields }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if busy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    Spacer()
                }
            }
            if let loginURL {
                HStack {
                    Button("로그인 다시 열기") { NSWorkspace.shared.open(loginURL) }.buttonStyle(QuietButtonStyle())
                    Button("로그인 링크 복사") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(loginURL.absoluteString, forType: .string)
                    }.buttonStyle(QuietButtonStyle())
                }
                Text("다른 계정을 추가하려면 해당 계정으로 로그인한 브라우저 프로필에서 링크를 여세요.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                if provider == .claude {
                    DisclosureGroup("브라우저에 인증 코드가 표시되었나요?") {
                        HStack {
                            SecureField("브라우저의 인증 코드를 붙여 넣으세요", text: $authorizationCode).textFieldStyle(.roundedBorder)
                            Button("코드 확인") {
                                do { try claudeConnection?.submit(code: authorizationCode); authorizationCode = ""; error = nil }
                                catch { self.error = error.localizedDescription }
                            }.buttonStyle(QuietButtonStyle()).disabled(authorizationCode.isEmpty)
                        }.padding(.top, 8)
                    }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack {
                Label("인증 정보는 이 Mac의 키체인에 저장", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button {
                    if provider == .claude {
                        if manualClaude { connectClaude() } else { connectClaudeBrowser() }
                    } else { connectCodex() }
                } label: {
                    Text(provider == .claude && manualClaude ? "토큰으로 연결" : "브라우저에서 로그인")
                }.buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (provider == .claude && manualClaude && credential.isEmpty))
            }
        }.padding(28).frame(width: 560).background(.white).foregroundStyle(Palette.ink)
            .onDisappear { cleanup() }
    }

    private var claudeFields: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Label("기본 브라우저에서 Claude에 로그인", systemImage: "globe").font(.system(size: 15, weight: .semibold))
                Text("Google·Apple·이메일 로그인을 사용할 수 있어요. 로그인 후 이 창으로 돌아오면 계정이 자동으로 연결됩니다.")
                    .font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(4)
                Label(ClaudeConnection.executable() == nil ? "Claude Code 설치 필요 · 또는 토큰으로 연결" : "이 Mac의 Claude Code를 찾았어요", systemImage: ClaudeConnection.executable() == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("sessionKey / OAuth 토큰으로 직접 연결", isExpanded: $manualClaude) {
                VStack(alignment: .leading, spacing: 8) {
                SecureField("sk-ant-…", text: $credential).textFieldStyle(.roundedBorder).controlSize(.large)
                    .disabled(busy).onChange(of: credential) { _, _ in organizations = []; organizationID = "" }
                HStack {
                    DisclosureGroup("sessionKey는 어디서 찾나요?") {
                        Text("브라우저에서 claude.ai에 로그인 → 개발자 도구 → Application(저장소) → Cookies → https://claude.ai → sessionKey 값을 복사하세요. Claude Code 인증 JSON 파일도 가져올 수 있어요.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4).padding(.top, 7)
                    }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("인증 파일 가져오기…") { importFile() }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Palette.secondary).disabled(busy)
                }
                Text("Claude 웹 사용량 조회는 비공개 인터페이스를 사용하며, 서비스 변경 시 재연결이 필요할 수 있어요.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            }.font(.system(size: 13, weight: .semibold)).disabled(busy || reconnecting != nil)
            if !organizations.isEmpty {
                Picker("워크스페이스", selection: $organizationID) {
                    ForEach(organizations) { Text($0.name).tag($0.id) }
                }.font(.system(size: 13)).disabled(busy)
                Text("사용량을 볼 워크스페이스를 선택한 후 연결하기를 누르세요.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }
    }
    private var codexFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("ChatGPT 구독 계정으로 연결합니다", systemImage: "globe").font(.system(size: 15, weight: .semibold))
            Text("기본 브라우저에서 OpenAI 로그인 페이지가 열립니다. Gauge 전용 프로필로 로그인하므로 다른 Codex 계정도 함께 등록할 수 있어요.")
                .font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(5)
            HStack(spacing: 7) {
                Image(systemName: CodexConnection.executable() == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(CodexConnection.executable() == nil ? Palette.amber : Palette.green)
                Text(CodexConnection.executable() == nil ? "Codex 실행 파일 없음 · 설정에서 경로를 지정하세요" : "이 Mac의 Codex를 찾았어요")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.background, in: RoundedRectangle(cornerRadius: 11))
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.message = "Claude Code의 .credentials.json 또는 내보낸 인증 JSON을 선택하세요. 토큰은 화면에 표시되지 않습니다."
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let normalized = try ClaudeService.normalize(text)
            credential = normalized.0
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func connectClaude() {
        busy = true; error = nil; status = "Claude 계정을 확인하고 있어요…"
        connectTask = Task { @MainActor in
            defer { busy = false }
            do {
                let (secret, kind) = try ClaudeService.normalize(credential)
                var organization: ClaudeOrganization?
                if kind == .claudeSession {
                    if organizations.isEmpty {
                        let fetched = try await ClaudeService.shared.organizations(secret: secret)
                        organizations = fetched
                        organizationID = fetched[0].id
                        if fetched.count > 1 { return }
                    }
                    organization = organizations.first { $0.id == organizationID }
                }
                try await store.saveClaude(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), secret: secret, kind: kind, organization: organization)
                completed = true
                credential = ""
                dismiss()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func connectClaudeBrowser() {
        busy = true; error = nil; status = "브라우저 로그인을 준비하고 있어요…"
        if let reconnecting {
            do { try store.beginReauthentication(reconnecting) }
            catch { self.error = error.localizedDescription; busy = false; return }
        }
        let id = reconnecting?.id ?? UUID()
        let client = ClaudeConnection()
        pendingClaudeID = id
        claudeConnection = client
        connectTask = Task { @MainActor in
            defer { busy = false }
            do {
                let profile = try LocalStorage.claudeProfile(id)
                try await client.login(profile: profile) { url in
                    loginURL = url
                    status = "브라우저에서 Claude 로그인을 완료해 주세요…"
                    // Claude Code opens the callback URL itself. The printed
                    // link is retained for manual-code recovery only.
                }
                try Task.checkCancellation()
                // This is an explicit login action. A newly created CLI item
                // may need its one-time Gauge ACL grant before quiet polling.
                status = "macOS에서 로그인 정보 접근을 승인해 주세요…"
                try await Task.detached { try ClaudeProfile.authorize(id) }.value
                try Task.checkCancellation()
                status = "구독 사용량을 가져오고 있어요…"
                ClaudeProfile.resetPending(id)
                let local = try await ClaudeProfile.account(id)
                let identity = await ClaudeService.shared.identity(secret: local.accessToken, kind: .claudeCode) ?? local.email
                let account = Account(id: id, provider: .claude,
                                      name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
                                      identity: identity, plan: local.plan, kind: .claudeCode)
                let snapshot = try await ClaudeService.shared.usage(account: account, secret: local.accessToken)
                try Task.checkCancellation()
                if let reconnecting {
                    try store.finishReauthentication(reconnecting, replacement: account, snapshot: snapshot)
                } else { try store.add(account, snapshot: snapshot) }
                completed = true
                pendingClaudeID = nil; claudeConnection = nil; loginURL = nil
                dismiss()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            if !completed { cleanup() }
        }
    }
    private func connectCodex() {
        busy = true; error = nil; status = "브라우저 로그인을 준비하고 있어요…"
        let id = UUID()
        pendingID = id
        let client = CodexConnection()
        connection = client
        connectTask = Task { @MainActor in
            defer { busy = false }
            do {
                try await client.start(accountID: id)
                let url = try await client.login()
                loginURL = url
                NSWorkspace.shared.open(url)
                status = "브라우저에서 로그인을 완료해 주세요…"
                for _ in 0..<150 {
                    try await Task.sleep(for: .seconds(2))
                    if let failure = client.loginFailure { throw GaugeError.message(failure) }
                    if let info = try await client.account() {
                        status = "구독 사용량을 가져오고 있어요…"
                        let snapshot = try await client.usage()
                        try Task.checkCancellation()
                        let account = Account(id: id, provider: .codex,
                                              name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
                                              identity: info.email, plan: info.plan)
                        try store.add(account, snapshot: snapshot)
                        completed = true
                        client.close()
                        connection = nil
                        pendingID = nil
                        dismiss()
                        return
                    }
                }
                throw GaugeError.message("로그인 대기 시간이 지났어요. 다시 시도해 주세요.")
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            if !completed { cleanup() }
        }
    }
    private func cleanup() {
        connectTask?.cancel()
        if let reconnecting { store.endReauthentication(reconnecting) }
        guard !completed else { return }
        let client = connection
        let id = pendingID
        let claude = claudeConnection
        let claudeID = reconnecting?.kind == .claudeCode ? nil : pendingClaudeID
        connection = nil; pendingID = nil; loginURL = nil
        claudeConnection = nil; pendingClaudeID = nil; authorizationCode = ""
        Task { @MainActor in
            await claude?.cancel()
            if let claudeID { try? ClaudeProfile.remove(claudeID) }
            if let client {
                await client.cancelLogin()
                try? await client.logout()
                client.close()
            }
            if let id, let directory = try? LocalStorage.profile(id) { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
