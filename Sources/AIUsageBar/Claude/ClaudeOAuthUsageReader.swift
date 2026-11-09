import Foundation

/// Claude 계정 전체 사용량(5시간/주간)을 Anthropic 사용량 API로 직접 조회한다.
///
/// 사용량은 계정 단위라 웹·Desktop·터미널 어디서 썼든 같은 값이다. 그래서 어떤 앱을 열어 두었는지와
/// 상관없이 항상 최신값을 얻을 수 있다. 비용은 HTTPS GET 1회뿐이다(화면 읽기처럼 UI를 건드리지 않는다).
///
/// - Claude Code가 저장해 둔 OAuth 토큰을 읽어 api.anthropic.com 으로만 보낸다. 토큰은 메모리에만
///   캐시하고 로그에는 남기지 않는다.
/// - 만료된 토큰의 자동 갱신(refresh)은 사용자가 따로 허용했을 때(`allowRenewal`)만 한다. 갱신하면 refresh token이
///   바뀌어 Claude Code의 저장소(파일/키체인)를 이 앱이 다시 쓰게 되므로 기본은 끄고, 꺼져 있으면 만료 안내만 한다.
/// - 비공식(undocumented) 엔드포인트다. 형식이 바뀌어 실패하면 기존 파일/화면 읽기가 대신 동작한다.
final class ClaudeOAuthUsageReader: @unchecked Sendable {
    enum ReadError: LocalizedError {
        case noToken
        case tokenExpired
        case rateLimited
        case http(Int)
        case decodeFailed
        case network

        var errorDescription: String? {
            switch self {
            case .noToken:
                tr("Couldn't find your Claude Code sign-in. Please sign in once by running `claude` in Terminal.", "Claude Code 로그인 정보를 찾지 못했어요. 터미널에서 claude 로 한 번 로그인해 주세요.")
            case .tokenExpired:
                tr("Your Claude Code sign-in has expired. Please run `claude auth login` once in Terminal.", "Claude Code 로그인이 만료됐어요. 터미널에서 claude auth login 을 한 번 실행해 주세요.")
            case .rateLimited:
                tr("The usage lookup is paused for a moment. It will try again shortly.", "사용량 조회가 잠시 제한됐어요. 곧 다시 시도할게요.")
            case .http(let code):
                tr("The usage lookup failed (HTTP \(code)).", "사용량 조회에 실패했어요 (HTTP \(code)).")
            case .decodeFailed:
                tr("Couldn't read the usage response.", "사용량 응답 형식을 해석하지 못했어요.")
            case .network:
                tr("A network error occurred while looking up usage.", "사용량 조회 중 네트워크 오류가 발생했어요.")
            }
        }
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    private let lock = NSLock()
    private var cachedToken: String?
    private var cachedExpiry: Date?
    private let session: URLSession
    private let tokenProvider: (@Sendable (_ allowRenewal: Bool) async throws -> String)?

    /// `session`과 `tokenProvider`는 테스트에서 가짜 서버·가짜 토큰을 쓰려고 바꿀 수 있게 열어 둔 것이다.
    init(session: URLSession = .shared,
         tokenProvider: (@Sendable (_ allowRenewal: Bool) async throws -> String)? = nil) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func fetch(allowRenewal: Bool = false) async throws -> ClaudeUsageSnapshot {
        let token: String
        if let tokenProvider {
            token = try await tokenProvider(allowRenewal)
        } else {
            token = try await accessToken(allowRenewal: allowRenewal)
        }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AIUsageBar", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReadError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ReadError.network }
        switch http.statusCode {
        case 200:
            return try Self.parse(data)
        case 401, 403:
            // Claude Code가 토큰을 새로 발급했을 수 있으니 다음 시도에서 다시 읽는다.
            invalidateToken()
            throw ReadError.tokenExpired
        case 429:
            throw ReadError.rateLimited
        default:
            throw ReadError.http(http.statusCode)
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data, now: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.decodeFailed
        }
        let five = window(object["five_hour"])
        let week = window(object["seven_day"])
        guard five != nil || week != nil else { throw ReadError.decodeFailed }
        return ClaudeUsageSnapshot(fiveHour: five, weekly: week, updatedAt: now)
    }

    private static func window(_ value: Any?) -> ClaudeRateLimitWindow? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? NSNumber else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseISODate)
        return ClaudeRateLimitWindow(
            usedPercent: max(0, min(100, utilization.doubleValue)),
            resetsAt: resetsAt
        )
    }

    private static func parseISODate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Token

    private func accessToken(allowRenewal: Bool) async throws -> String {
        if let token = validCachedToken() { return token }
        // security(1)·토큰 갱신 요청은 블로킹이라 협력 스레드를 막지 않게 분리한다.
        let credentials: (token: String, expiry: Date?)? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var stored = Self.readStored()
                // 액세스 토큰은 8시간마다 만료되고, 터미널에서 claude를 안 쓰면 아무도 갱신하지 않는다.
                // 사용자가 허용했고 만료됐을 때만 Claude Code와 같은 방식으로 refresh token을 써서 갱신하고 원래 자리에 다시 저장한다.
                if allowRenewal, let current = stored, Self.isExpiring(current.object) {
                    stored = Self.renew(current) ?? current
                }
                continuation.resume(returning: stored.flatMap { Self.parseCredentials($0.object) })
            }
        }
        guard let credentials else { throw ReadError.noToken }
        if let expiry = credentials.expiry, expiry <= Date() {
            throw ReadError.tokenExpired
        }
        storeToken(credentials.token, expiry: credentials.expiry)
        return credentials.token
    }

    private func storeToken(_ token: String, expiry: Date?) {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = token
        cachedExpiry = expiry
    }

    private func validCachedToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = cachedToken else { return nil }
        if let expiry = cachedExpiry, expiry.timeIntervalSinceNow < 60 { return nil }
        return token
    }

    private func invalidateToken() {
        lock.lock()
        cachedToken = nil
        cachedExpiry = nil
        lock.unlock()
    }

    enum Store {
        case file(String)
        case keychain(account: String)
    }

    private static let credentialsFile = NSHomeDirectory() + "/.claude/.credentials.json"
    private static let tokenURLs = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!
    ]
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// 1) ~/.claude/.credentials.json  2) macOS 키체인 "Claude Code-credentials" 순서로 찾는다.
    private static func readStored() -> (object: [String: Any], store: Store)? {
        if let data = FileManager.default.contents(atPath: credentialsFile),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           parseCredentials(object) != nil {
            return (object, .file(credentialsFile))
        }
        if let output = run(
            "/usr/bin/security",
            ["find-generic-password", "-s", keychainService, "-w"],
            timeout: 60
        ), let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
           parseCredentials(object) != nil {
            return (object, .keychain(account: keychainAccount() ?? NSUserName()))
        }
        return nil
    }

    /// 키체인 항목의 계정 이름(비밀값 아님). 갱신한 값을 다른 항목으로 새로 만들지 않고 같은 항목에 덮어쓰려고 읽는다.
    private static func keychainAccount() -> String? {
        guard let output = run("/usr/bin/security", ["find-generic-password", "-s", keychainService], timeout: 30) else { return nil }
        for line in output.split(separator: "\n") where line.contains("\"acct\"<blob>=") {
            guard let first = line.firstIndex(of: "="), let open = line[first...].firstIndex(of: "\""),
                  let close = line.lastIndex(of: "\""), open < close else { continue }
            let value = String(line[line.index(after: open)..<close])
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func parseCredentials(_ object: [String: Any]) -> (token: String, expiry: Date?)? {
        guard let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiry = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        return (token, expiry)
    }

    static func isExpiring(_ object: [String: Any]) -> Bool {
        guard let expiry = parseCredentials(object)?.expiry else { return false }
        return expiry.timeIntervalSinceNow < 60
    }

    /// refresh token으로 새 액세스 토큰을 받아 원래 저장소에 다시 쓴다. refresh token도 함께 바뀌므로
    /// 저장에 실패하면 Claude Code 로그인이 풀린다(그때는 claude auth login 으로 다시 로그인).
    private static func renew(_ stored: (object: [String: Any], store: Store)) -> (object: [String: Any], store: Store)? {
        guard var oauth = stored.object["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: [
                  "grant_type": "refresh_token",
                  "refresh_token": refreshToken,
                  "client_id": clientID
              ]) else { return nil }

        for url in tokenURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard let data = synchronousData(for: request),
                  let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = response["access_token"] as? String, !accessToken.isEmpty else { continue }

            oauth["accessToken"] = accessToken
            if let newRefresh = response["refresh_token"] as? String, !newRefresh.isEmpty {
                oauth["refreshToken"] = newRefresh
            }
            if let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue {
                oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + expiresIn) * 1_000)
            }
            var object = stored.object
            object["claudeAiOauth"] = oauth
            guard write(object, to: stored.store) else {
                print("[claude-token] renewed but failed to save")
                return nil
            }
            print("[claude-token] renewed via \(url.host ?? "")")
            return (object, stored.store)
        }
        print("[claude-token] renew failed")
        return nil
    }

    private static func write(_ object: [String: Any], to store: Store) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        switch store {
        case .file(let path):
            return writeCredentialsFile(data, to: path)
        case .keychain(let account):
            // 비밀값이 프로세스 목록(argv)에 드러나지 않게 security -i 의 표준입력으로 넘긴다.
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let command = "add-generic-password -U -a \"\(account)\" -s \"\(keychainService)\" -X \(hex)\n"
            return run("/usr/bin/security", ["-i"], input: command, timeout: 30) != nil
        }
    }

    /// 자격 증명 파일을 안전하게 덮어쓴다. 새 파일을 만들 때부터 기존 권한(없으면 0600)으로 만들어,
    /// 갱신 과정에서 다른 사용자가 읽을 수 있는 권한으로 잠깐이라도 노출되지 않게 한다.
    static func writeCredentialsFile(_ data: Data, to path: String) -> Bool {
        let fileManager = FileManager.default
        let permissions = ((try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let temporary = path + ".aub-tmp"
        try? fileManager.removeItem(atPath: temporary)
        guard fileManager.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: permissions & 0o600]) else { return false }
        do {
            _ = try fileManager.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
            return true
        } catch {
            try? fileManager.removeItem(atPath: temporary)
            return false
        }
    }

    private static func synchronousData(for request: URLRequest) -> Data? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return box.data
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
    }

    private static func run(
        _ path: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let inputPipe = Pipe()
        if input != nil { process.standardInput = inputPipe }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
