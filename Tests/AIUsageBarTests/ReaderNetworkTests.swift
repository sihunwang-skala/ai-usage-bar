import Foundation
import Testing
@testable import AIUsageBar

/// 네트워크 없이 HTTP 응답을 흉내 내는 URLProtocol.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite("Claude usage endpoint: auth failure, rate limit, outage", .serialized)
struct ReaderNetworkTests {
    private func makeReader(token: String = "TEST-TOKEN", provider: (@Sendable (Bool) async throws -> String)? = nil) -> ClaudeOAuthUsageReader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return ClaudeOAuthUsageReader(session: session, tokenProvider: provider ?? { _ in token })
    }

    private func respond(_ status: Int, _ body: String = "{}") {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private func expectReadError(_ expected: (ClaudeOAuthUsageReader.ReadError) -> Bool, reader: ClaudeOAuthUsageReader) async {
        do {
            _ = try await reader.fetch()
            Issue.record("expected a ReadError")
        } catch let error as ClaudeOAuthUsageReader.ReadError {
            #expect(expected(error))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func successSendsBearerTokenOnlyToAnthropic() async throws {
        respond(200, #"{"five_hour":{"utilization":12},"seven_day":{"utilization":3}}"#)
        let snapshot = try await makeReader().fetch()
        #expect(snapshot.fiveHour?.usedPercent == 12)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-TOKEN")
        #expect(request.httpMethod == "GET")
    }

    @Test func authFailureMapsToTokenExpired() async {
        for status in [401, 403] {
            respond(status)
            await expectReadError({ if case .tokenExpired = $0 { true } else { false } }, reader: makeReader())
        }
    }

    @Test func rateLimitMapsToRateLimited() async {
        respond(429)
        await expectReadError({ if case .rateLimited = $0 { true } else { false } }, reader: makeReader())
    }

    @Test func serverErrorKeepsStatusCode() async {
        respond(503)
        await expectReadError({ if case .http(503) = $0 { true } else { false } }, reader: makeReader())
    }

    @Test func garbageBodyIsDecodeFailure() async {
        respond(200, "<html>maintenance</html>")
        await expectReadError({ if case .decodeFailed = $0 { true } else { false } }, reader: makeReader())
    }

    @Test func connectionLossIsNetworkError() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await expectReadError({ if case .network = $0 { true } else { false } }, reader: makeReader())
    }

    @Test func missingLoginIsReportedWithoutCallingTheServer() async {
        StubURLProtocol.lastRequest = nil
        respond(200)
        let reader = makeReader(provider: { _ in throw ClaudeOAuthUsageReader.ReadError.noToken })
        await expectReadError({ if case .noToken = $0 { true } else { false } }, reader: reader)
        #expect(StubURLProtocol.lastRequest == nil)
    }

    @Test func renewalFlagIsPassedToTokenSourceAndDefaultsOff() async throws {
        final class Box: @unchecked Sendable { var seen: [Bool] = [] }
        let box = Box()
        respond(200, #"{"five_hour":{"utilization":1}}"#)
        let reader = makeReader(provider: { allow in box.seen.append(allow); return "T" })
        _ = try await reader.fetch()
        _ = try await reader.fetch(allowRenewal: true)
        #expect(box.seen == [false, true])
    }
}

@Suite("Claude credentials handling")
struct CredentialsTests {
    @Test func parsesTokenAndExpiry() throws {
        let object: [String: Any] = ["claudeAiOauth": ["accessToken": "abc", "expiresAt": 1_700_000_000_000]]
        let parsed = try #require(ClaudeOAuthUsageReader.parseCredentials(object))
        #expect(parsed.token == "abc")
        #expect(parsed.expiry == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func rejectsMissingOrEmptyToken() {
        #expect(ClaudeOAuthUsageReader.parseCredentials([:]) == nil)
        #expect(ClaudeOAuthUsageReader.parseCredentials(["claudeAiOauth": ["accessToken": ""]]) == nil)
    }

    @Test func expiryDetection() {
        let past: [String: Any] = ["claudeAiOauth": ["accessToken": "a", "expiresAt": 1_000]]
        let future: [String: Any] = ["claudeAiOauth": ["accessToken": "a", "expiresAt": Int64((Date().timeIntervalSince1970 + 3600) * 1000)]]
        let unknown: [String: Any] = ["claudeAiOauth": ["accessToken": "a"]]
        #expect(ClaudeOAuthUsageReader.isExpiring(past))
        #expect(!ClaudeOAuthUsageReader.isExpiring(future))
        #expect(!ClaudeOAuthUsageReader.isExpiring(unknown))
    }

    @Test func rewrittenCredentialsFileKeepsOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".credentials.json").path
        FileManager.default.createFile(atPath: path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o600])

        #expect(ClaudeOAuthUsageReader.writeCredentialsFile(Data("new".utf8), to: path))

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: path + ".aub-tmp"))
    }

    @Test func newCredentialsFileDefaultsToOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.json").path
        #expect(ClaudeOAuthUsageReader.writeCredentialsFile(Data("x".utf8), to: path))
        let mode = ((try FileManager.default.attributesOfItem(atPath: path))[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }
}
