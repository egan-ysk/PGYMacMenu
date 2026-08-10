import Foundation
import XCTest
@testable import PGYMacMenu

final class WebDAVClientTests: XCTestCase {
    func testConfigurationNormalizesRootAndResolvesEscapedRelativePath() throws {
        let configuration = try WebDAVConfiguration(
            rootURL: try XCTUnwrap(URL(string: "https://DAV.Example.com:443/backups")),
            relativePath: "team folder/%2E%2E/data.sync",
            username: "user",
            password: "password"
        )

        XCTAssertEqual(configuration.rootURL.absoluteString, "https://dav.example.com/backups/")
        XCTAssertEqual(
            try configuration.resolvedResourceURL().absoluteString,
            "https://dav.example.com/backups/team%20folder/%252E%252E/data.sync"
        )
    }

    func testConfigurationRejectsInsecureOrUnsafeLocations() throws {
        XCTAssertThrowsError(try makeConfiguration(root: "http://dav.example.com")) { error in
            XCTAssertEqual(error as? WebDAVError, .insecureRootURL)
        }
        XCTAssertThrowsError(try makeConfiguration(root: "https://user:secret@dav.example.com")) { error in
            XCTAssertEqual(error as? WebDAVError, .invalidRootURL)
        }
        XCTAssertThrowsError(try makeConfiguration(root: "https://dav.example.com?redirect=elsewhere")) { error in
            XCTAssertEqual(error as? WebDAVError, .invalidRootURL)
        }

        for path in [
            "", "/absolute.sync", "../escape.sync", "folder/../escape.sync",
            "folder//file", "folder\\file", "file?query", "file#fragment"
        ] {
            XCTAssertThrowsError(
                try WebDAVConfiguration(
                    rootURL: try XCTUnwrap(URL(string: "https://dav.example.com/root")),
                    relativePath: path,
                    username: "user",
                    password: "password"
                )
            ) { error in
                XCTAssertEqual(error as? WebDAVError, .invalidRelativePath)
            }
        }
    }

    func testCodableDecodeRevalidatesConfiguration() throws {
        let encoded = Data(
            #"{"rootURL":"http:\/\/dav.example.com","relativePath":"sync.bin","username":"u","password":"p"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(WebDAVConfiguration.self, from: encoded)) { error in
            XCTAssertEqual(error as? WebDAVError, .insecureRootURL)
        }
    }

    func testDownloadReturnsDataAndStrongETag() async throws {
        let body = Data("encrypted".utf8)
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            return WebDAVTransportResponse(
                data: body,
                statusCode: 200,
                headers: ["ETag": "\"generation-1\""]
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let resource = try await client.download()

        XCTAssertEqual(resource, WebDAVResource(data: body, strongETag: "\"generation-1\""))
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testDownloadReturnsNilForMissingFile() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(statusCode: 404)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let resource = try await client.download()

        XCTAssertNil(resource)
    }

    func testRequestsDoNotPreemptivelyExposeCredentials() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
            XCTAssertNil(request.url?.user)
            XCTAssertNil(request.url?.password)
            return WebDAVTransportResponse(statusCode: 404)
        }
        let configuration = try WebDAVConfiguration(
            rootURL: XCTUnwrap(URL(string: "https://dav.example.com/root")),
            relativePath: "PGYMacMenu.sync",
            username: "private-user",
            password: "private-password"
        )
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        let resource = try await client.download()

        XCTAssertNil(resource)
    }

    func testDownloadRejectsWeakOrMissingETag() async throws {
        for headers in [["ETag": "W/\"weak\""], [:]] {
            let transport = MockWebDAVTransport { _, _, _ in
                WebDAVTransportResponse(data: Data(), statusCode: 200, headers: headers)
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                _ = try await client.download()
                XCTFail("Expected an ETag error")
            } catch let error as WebDAVError {
                XCTAssertTrue(error == .invalidStrongETag || error == .missingStrongETag)
            }
        }
    }

    func testUploadUsesCreateOnlyCondition() async throws {
        let body = Data([0x01, 0x02, 0x03])
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
            XCTAssertEqual(request.httpBody, body)
            return WebDAVTransportResponse(statusCode: 201, headers: ["etag": "\"new\""])
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let etag = try await client.upload(body, condition: .createOnly)

        XCTAssertEqual(etag, "\"new\"")
    }

    func testUploadAllowsMissingResponseETagForPostWriteVerification() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.httpMethod, "PUT")
            return WebDAVTransportResponse(statusCode: 204)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let etag = try await client.upload(Data(), condition: .createOnly)

        XCTAssertNil(etag)
    }

    func testUploadIgnoresWeakResponseETagForPostWriteVerification() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(statusCode: 204, headers: ["ETag": "W/\"representation\""])
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let etag = try await client.upload(Data(), condition: .createOnly)

        XCTAssertNil(etag)
    }

    func testUploadUsesMatchingConditionAndMapsPreconditionFailure() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"old\"")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            return WebDAVTransportResponse(statusCode: 412)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.upload(Data(), condition: .matching("\"old\""))
            XCTFail("Expected precondition failure")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .preconditionFailed)
        }
    }

    func testUploadRejectsUnsafeETagBeforeSending() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            XCTFail("The request must not be sent")
            return WebDAVTransportResponse(statusCode: 500)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.upload(Data(), condition: .matching("W/\"weak\""))
            XCTFail("Expected invalid ETag")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidStrongETag)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testUploadRejectsMalformedQuotedETagBeforeSending() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            XCTFail("The request must not be sent")
            return WebDAVTransportResponse(statusCode: 500)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.upload(Data(), condition: .matching("\"bad\"tag\""))
            XCTFail("Expected invalid ETag")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidStrongETag)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testCreateParentCollectionsBuildsEachLevelAndAcceptsExistingDirectory() async throws {
        let configuration = try makeConfiguration(path: "one/two/sync.bin")
        let transport = MockWebDAVTransport { request, index, _ in
            XCTAssertEqual(request.httpMethod, "MKCOL")
            return WebDAVTransportResponse(statusCode: index == 0 ? 405 : 201)
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        try await client.createParentCollections()

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://dav.example.com/root/one/",
            "https://dav.example.com/root/one/two/"
        ])
    }

    func testConnectionPerformsConditionalPutGetAndDelete() async throws {
        let configuration = try makeConfiguration(path: "nested/sync.bin")
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "MKCOL")
                return WebDAVTransportResponse(statusCode: 405)
            case 1:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-get\""]
                )
            case 3:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-get\"")
                return WebDAVTransportResponse(statusCode: 204)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        try await client.testConnection()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        let probeURLs = requests.dropFirst().compactMap(\.url)
        XCTAssertEqual(Set(probeURLs).count, 1)
        XCTAssertTrue(probeURLs[0].lastPathComponent.hasPrefix("PGYMacMenu-probe-"))
        XCTAssertNotEqual(probeURLs[0], try configuration.resolvedResourceURL())
    }

    func testStatusCodesMapToTypedErrors() async throws {
        let cases: [(Int, WebDAVError)] = [
            (401, .authenticationFailed),
            (403, .forbidden),
            (409, .conflict),
            (423, .locked),
            (429, .rateLimited),
            (507, .insufficientStorage),
            (503, .serverError(statusCode: 503)),
            (302, .redirectRejected)
        ]

        for (statusCode, expectedError) in cases {
            let transport = MockWebDAVTransport { _, _, _ in
                WebDAVTransportResponse(statusCode: statusCode)
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)
            do {
                _ = try await client.download()
                XCTFail("Expected status mapping for \(statusCode)")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testURLSessionTransportEnforcesResponseLimit() async throws {
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["ETag": "\"large\""]
                )!,
                Data(repeating: 0x7f, count: 5)
            )
        }
        defer { URLProtocolStub.handler = nil }

        let configuration = try makeConfiguration()
        let transport = URLSessionWebDAVTransport(
            configuration: configuration,
            protocolClasses: [URLProtocolStub.self]
        )
        let client = try WebDAVClient(
            configuration: configuration,
            transport: transport,
            maximumResponseBytes: 4
        )

        do {
            _ = try await client.download()
            XCTFail("Expected response size error")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .responseTooLarge(maxBytes: 4))
        }
    }

    private func makeConfiguration(
        root: String = "https://dav.example.com/root",
        path: String = "PGYMacMenu.sync"
    ) throws -> WebDAVConfiguration {
        try WebDAVConfiguration(
            rootURL: XCTUnwrap(URL(string: root)),
            relativePath: path,
            username: "user",
            password: "password"
        )
    }
}

private actor MockWebDAVTransport: WebDAVTransport {
    typealias Handler = @Sendable (URLRequest, Int, Int) async throws -> WebDAVTransportResponse

    private(set) var requests: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requestCount: Int {
        requests.count
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> WebDAVTransportResponse {
        let index = requests.count
        requests.append(request)
        return try await handler(request, index, maximumResponseBytes)
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data?

    var value: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: WebDAVError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
