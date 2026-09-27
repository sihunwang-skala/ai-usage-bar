import Foundation

/// 계정 부가 정보(로그인 여부, 요금제, 기본 모델)를 읽어옵니다.
/// 모델은 로컬 settings.json 파일만 읽고, 로그인/요금제만 `claude auth status`를 아주 가끔 호출합니다.
/// 두 경로 모두 로그인/설정 메타데이터만 다루며 모델에 프롬프트를 보내지 않으므로 토큰을 소모하지 않습니다.
enum ClaudeAccountInfoReader {
    struct Info: Equatable {
        let loggedIn: Bool
        let plan: String?
        let model: String?
    }

    static func read() -> Info {
        let (loggedIn, plan) = readAuthStatus()
        return Info(loggedIn: loggedIn, plan: plan, model: readModel())
    }

    private static func readModel() -> String? {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["model"] as? String
    }

    private static func readAuthStatus() -> (loggedIn: Bool, plan: String?) {
        guard let executable = findClaude() else { return (false, nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, nil)
            }
            let loggedIn = (object["loggedIn"] as? Bool) ?? false
            return (loggedIn, object["subscriptionType"] as? String)
        } catch {
            return (false, nil)
        }
    }

    private static func findClaude() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_PATH"],
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ].compactMap { $0 }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
