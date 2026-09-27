import Foundation

final class CodexAppServerClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai-usage-bar.codex.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var initialized = false

    func fetchUsage(completion: @escaping @Sendable (Result<CodexUsageSnapshot, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.process?.isRunning != true { try self.start() }
                self.initializeIfNeeded { result in
                    switch result {
                    case .failure(let error): completion(.failure(error))
                    case .success:
                        self.request(method: "account/rateLimits/read", params: ["excludeResetCreditDetails": true]) { result in
                            switch result.flatMap({ response in Result { try CodexUsageParser.parse(response: response) } }) {
                            case .failure(let error): completion(.failure(error))
                            case .success(let snapshot): self.fetchModel(for: snapshot, completion: completion)
                            }
                        }
                    }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func fetchModel(for snapshot: CodexUsageSnapshot, completion: @escaping @Sendable (Result<CodexUsageSnapshot, Error>) -> Void) {
        request(method: "config/read", params: ["includeLayers": false]) { result in
            let configuredModel: String?
            let reasoningEffort: String?
            if case .success(let response) = result,
               let payload = response["result"] as? [String: Any],
               let config = payload["config"] as? [String: Any] {
                configuredModel = config["model"] as? String
                reasoningEffort = config["model_reasoning_effort"] as? String
            } else {
                configuredModel = nil
                reasoningEffort = nil
            }
            completion(.success(CodexUsageSnapshot(
                primary: snapshot.primary,
                secondary: snapshot.secondary,
                planType: snapshot.planType,
                model: configuredModel ?? snapshot.model,
                reasoningEffort: reasoningEffort
            )))
        }
    }

    private func start() throws {
        let executable = Self.findCodex()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ClientError.codexNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.queue.async { self.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.failAll(ClientError.serverStopped) }
        }
        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
    }

    private func initializeIfNeeded(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard !initialized else { completion(.success(())); return }
        request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "ai-usage-bar", "title": "AI Usage Bar", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                do {
                    try self.send(["method": "initialized"])
                    self.initialized = true
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func request(method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = nextID
        nextID += 1
        pending[id] = completion
        do { try send(["id": id, "method": method, "params": params]) }
        catch {
            pending.removeValue(forKey: id)
            completion(.failure(error))
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input?.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue,
                  let callback = pending.removeValue(forKey: id) else { continue }

            if let error = object["error"] as? [String: Any] {
                callback(.failure(ClientError.serverError(error["message"] as? String ?? "알 수 없는 오류")))
            } else {
                callback(.success(object))
            }
        }
    }

    private func failAll(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        initialized = false
        process = nil
        input = nil
        callbacks.forEach { $0(.failure(error)) }
    }

    private static func findCodex() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_PATH"],
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? ""
    }

    enum ClientError: LocalizedError {
        case codexNotFound, serverStopped, serverError(String)
        var errorDescription: String? {
            switch self {
            case .codexNotFound: "Codex CLI를 찾지 못했습니다. CODEX_PATH를 설정해 주세요."
            case .serverStopped: "Codex app-server가 종료되었습니다."
            case .serverError(let message): "Codex 오류: \(message)"
            }
        }
    }
}
