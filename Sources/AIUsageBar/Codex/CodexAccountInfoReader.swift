import Foundation

/// Codex CLI 로그인 여부를 확인합니다. `codex login status`는 로그인/설정 메타데이터만
/// 반환하며 모델에 프롬프트를 보내지 않으므로 토큰을 소모하지 않습니다.
enum CodexAccountInfoReader {
    static func isLoggedIn() -> Bool {
        guard let executable = findCodex() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["login", "status"]
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = (String(data: data, encoding: .utf8) ?? "").lowercased()
            return !text.contains("not logged in") && !text.contains("not authenticated")
        } catch {
            return false
        }
    }

    private static func findCodex() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_PATH"],
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
