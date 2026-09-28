import Foundation

/// claude/codex 실행 파일 경로를 찾는다.
///
/// 이 앱은 launchd(로그인 항목)로 뜨기 때문에 최소 PATH(`/usr/bin:/bin:/usr/sbin:/sbin`)만
/// 물려받는다. 반면 사용자가 터미널에서 `claude`/`codex`를 칠 때는 `.zshrc`/`.zprofile`에서
/// 설정한 PATH(`~/.local/bin`, nvm, pyenv 등)를 쓴다 — 이 둘의 차이 때문에, CLI가 실제로는
/// 설치·로그인까지 다 돼있는데도 이 앱만 "못 찾음"으로 오판하는 문제가 있었다.
/// 흔한 설치 경로를 먼저 보고, 못 찾으면 사용자의 로그인 셸에게 직접 물어봐서 어디 깔려있든 찾는다.
enum CLILocator {
    static func find(_ name: String, envOverrideKey: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment[envOverrideKey],
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.claude/local/\(name)"
        ].compactMap { $0 }
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return found
        }
        return findViaLoginShell(name)
    }

    /// `zsh -ilc 'command -v <name>'`로 사용자의 실제 대화형 로그인 셸 PATH를 그대로 물어본다.
    /// 인터랙티브 셸이 시작하며 찍는 배너/플러그인 로그가 섞일 수 있어, 출력 중 "/"로 시작하는
    /// 마지막 줄만 경로로 취급한다.
    private static func findViaLoginShell(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            guard let path = text.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") }),
                  FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
