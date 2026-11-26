import Foundation
import Darwin
import GaugeCore

enum LocalCLI {
    static func run(_ executable: URL, _ arguments: [String], in directory: URL, timeout: Duration)
        async throws -> (output: Data, status: Int32) {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw GaugeError.message("CLI 출력을 준비하지 못했어요.")
        }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw GaugeError.message("CLI를 실행하지 못했어요. 설치 상태를 확인해 주세요.") }
        defer {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while clock.now < deadline {
            try Task.checkCancellation()
            let running = process.isRunning
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                output.append(contentsOf: chunk.prefix(count))
                guard output.count <= 1_048_576 else { throw GaugeError.unsupported }
            } else {
                if count < 0 && errno != EAGAIN && errno != EINTR { throw GaugeError.unsupported }
                if !running { return (output, process.terminationStatus) }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        throw GaugeError.message("CLI 응답 시간이 초과되었어요. 네트워크를 확인하고 다시 시도해 주세요.")
    }
}
