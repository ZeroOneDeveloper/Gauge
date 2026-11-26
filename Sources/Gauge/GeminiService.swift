import Foundation
import GaugeCore

enum GeminiService {
    static let installURL = URL(string: "https://antigravity.google/docs/install?tab=cli")!

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/agy").path, "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    static func usage(executable: URL? = executable()) async throws -> UsageSnapshot {
        guard let executable else {
            throw GaugeError.message("Antigravity CLI를 설치하고 터미널에서 agy를 실행해 Google 계정에 로그인해 주세요.")
        }
        let directory = LocalStorage.root.appendingPathComponent("GeminiQuota", isDirectory: true)
        try LocalStorage.prepare(directory)
        let version = try await LocalCLI.run(executable, ["--version"], in: directory, timeout: .seconds(5))
        guard version.status == 0, let text = String(data: version.output, encoding: .utf8), supportsUsage(text) else {
            throw GaugeError.message("Gemini 사용량을 보려면 Antigravity CLI 1.1.11 이상으로 업데이트해 주세요.")
        }
        // Older versions can send /usage to the model. Require a version with the
        // built-in command and override settings that would make it a prompt.
        let settings = #"{"disableSlashCommands":false,"modelProvider":""}"#
        let result = try await LocalCLI.run(executable, ["--settings", settings, "--disable-slash-commands=false",
                                               "--print", "/usage", "--output-format", "json", "--print-timeout", "15s"],
                                   in: directory, timeout: .seconds(25))
        guard result.status == 0 else {
            throw GaugeError.message("Gemini 사용량을 가져오지 못했어요. 터미널에서 agy를 열고 Google 로그인과 /usage를 확인해 주세요.")
        }
        do { return try UsageParser.gemini(result.output) }
        catch { throw GaugeError.message("표시할 Gemini 한도가 없어요. 터미널에서 agy를 열고 Google 로그인과 /usage를 확인해 주세요.") }
    }

    static func supportsUsage(_ version: String) -> Bool {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let release = version.split(separator: "+", maxSplits: 1).first ?? ""
        let numbers = release.drop(while: { $0 == "v" }).split(separator: ".", omittingEmptySubsequences: false)
        let components = numbers.compactMap { Int($0) }
        guard numbers.count == 3, components.count == 3, components.allSatisfy({ $0 >= 0 }) else { return false }
        return !components.lexicographicallyPrecedes([1, 1, 11])
    }

}
