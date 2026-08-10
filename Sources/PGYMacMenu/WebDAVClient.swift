import Foundation

struct WebDAVConfiguration: Codable, Hashable, Sendable {
    let rootURL: URL
    let relativePath: String
    let username: String
    let password: String

    init(
        rootURL: URL,
        relativePath: String = "PGYMacMenu.sync",
        username: String,
        password: String
    ) throws {
        self.rootURL = try Self.normalizeRootURL(rootURL)
        self.relativePath = try Self.validateRelativePath(relativePath)
        self.username = username
        self.password = password
    }

    func normalized() throws -> WebDAVConfiguration {
        try WebDAVConfiguration(
            rootURL: rootURL,
            relativePath: relativePath,
            username: username,
            password: password
        )
    }

    func resolvedResourceURL() throws -> URL {
        try Self.resolve(relativePath: relativePath, under: rootURL)
    }

    private enum CodingKeys: String, CodingKey {
        case rootURL
        case relativePath
        case username
        case password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rootURL: container.decode(URL.self, forKey: .rootURL),
            relativePath: container.decode(String.self, forKey: .relativePath),
            username: container.decode(String.self, forKey: .username),
            password: container.decode(String.self, forKey: .password)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootURL, forKey: .rootURL)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
    }

    fileprivate var parentCollectionURLs: [URL] {
        get throws {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1 else {
                return []
            }

            var result: [URL] = []
            var current = rootURL
            for component in components.dropLast() {
                current.appendPathComponent(String(component), isDirectory: true)
                result.append(current)
            }
            return result
        }
    }

    private static func normalizeRootURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else {
            throw WebDAVError.insecureRootURL
        }
        guard let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw WebDAVError.invalidRootURL
        }

        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        } else if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }

        guard let normalizedURL = components.url,
              normalizedURL.scheme == "https",
              normalizedURL.host?.caseInsensitiveCompare(host) == .orderedSame else {
            throw WebDAVError.invalidRootURL
        }
        return normalizedURL
    }

    private static func validateRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("?"),
              !path.contains("#") else {
            throw WebDAVError.invalidRelativePath
        }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw WebDAVError.invalidRelativePath
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WebDAVError.invalidRelativePath
        }
        return path
    }

    private static func resolve(relativePath: String, under rootURL: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        var result = rootURL
        for (index, component) in components.enumerated() {
            result.appendPathComponent(String(component), isDirectory: index < components.count - 1)
        }
        guard result.scheme == "https",
              result.host?.caseInsensitiveCompare(rootURL.host ?? "") == .orderedSame,
              result.port == rootURL.port else {
            throw WebDAVError.invalidRelativePath
        }
        return result
    }
}

struct WebDAVResource: Equatable, Sendable {
    let data: Data
    let strongETag: String
}

enum WebDAVUploadCondition: Equatable, Sendable {
    case createOnly
    case matching(String)
}

enum WebDAVError: Error, Equatable, Sendable {
    case insecureRootURL
    case invalidRootURL
    case invalidRelativePath
    case invalidResponse
    case responseTooLarge(maxBytes: Int)
    case redirectRejected
    case authenticationFailed
    case forbidden
    case notFound
    case methodNotAllowed
    case conflict
    case preconditionFailed
    case locked
    case rateLimited
    case insufficientStorage
    case serverError(statusCode: Int)
    case httpStatus(statusCode: Int)
    case missingStrongETag
    case invalidStrongETag
    case verificationFailed
    case transportFailure(String)
    case cancelled
}

extension WebDAVError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .insecureRootURL:
            return "WebDAV 地址必须使用 HTTPS"
        case .invalidRootURL:
            return "WebDAV 根地址无效"
        case .invalidRelativePath:
            return "WebDAV 同步文件路径无效"
        case .invalidResponse:
            return "WebDAV 服务器响应无效"
        case .responseTooLarge(let maxBytes):
            return "WebDAV 响应超过大小限制（\(maxBytes) 字节）"
        case .redirectRejected:
            return "WebDAV 服务器返回了不允许的重定向"
        case .authenticationFailed:
            return "WebDAV 用户名或密码错误"
        case .forbidden:
            return "WebDAV 服务器拒绝访问"
        case .notFound:
            return "WebDAV 文件不存在"
        case .methodNotAllowed:
            return "WebDAV 服务器不支持所需操作"
        case .conflict:
            return "WebDAV 目录不存在或资源发生冲突"
        case .preconditionFailed:
            return "WebDAV 文件已被其他设备修改"
        case .locked:
            return "WebDAV 文件已被锁定"
        case .rateLimited:
            return "WebDAV 请求过于频繁，请稍后重试"
        case .insufficientStorage:
            return "WebDAV 存储空间不足"
        case .serverError(let statusCode), .httpStatus(let statusCode):
            return "WebDAV 请求失败（HTTP \(statusCode)）"
        case .missingStrongETag:
            return "WebDAV 服务器未返回强 ETag，不支持安全并发同步"
        case .invalidStrongETag:
            return "WebDAV 服务器返回了无效或弱 ETag，不支持安全并发同步"
        case .verificationFailed:
            return "WebDAV 读写校验失败"
        case .transportFailure(let message):
            return "WebDAV 网络请求失败：\(message)"
        case .cancelled:
            return "WebDAV 请求已取消"
        }
    }
}

struct WebDAVTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    let url: URL?

    init(data: Data = Data(), statusCode: Int, headers: [String: String] = [:], url: URL? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        self.url = url
    }

    func value(forHTTPHeaderField field: String) -> String? {
        headers[field.lowercased()]
    }
}

protocol WebDAVTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> WebDAVTransportResponse
}

final class URLSessionWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    private let session: URLSession
    private let expectedHost: String
    private let expectedPort: Int
    private let username: String
    private let password: String

    init(configuration: WebDAVConfiguration, protocolClasses: [AnyClass]? = nil) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpMaximumConnectionsPerHost = 2
        if let protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }

        session = URLSession(configuration: sessionConfiguration)
        expectedHost = configuration.rootURL.host?.lowercased() ?? ""
        expectedPort = configuration.rootURL.port ?? 443
        username = configuration.username
        password = configuration.password
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> WebDAVTransportResponse {
        let delegate = SecureWebDAVTaskDelegate(
            expectedHost: expectedHost,
            expectedPort: expectedPort,
            username: username,
            password: password
        )

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.invalidResponse
            }
            if delegate.didRejectRedirect {
                throw WebDAVError.redirectRejected
            }
            if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
                throw WebDAVError.responseTooLarge(maxBytes: maximumResponseBytes)
            }

            var data = Data()
            if httpResponse.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(httpResponse.expectedContentLength), maximumResponseBytes))
            }
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw WebDAVError.responseTooLarge(maxBytes: maximumResponseBytes)
                }
                data.append(byte)
            }

            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key.lowercased()] = String(describing: value)
            }
            return WebDAVTransportResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: headers,
                url: httpResponse.url
            )
        } catch let error as WebDAVError {
            throw error
        } catch is CancellationError {
            throw WebDAVError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw WebDAVError.cancelled
            case .userAuthenticationRequired, .userCancelledAuthentication:
                throw WebDAVError.authenticationFailed
            default:
                throw WebDAVError.transportFailure(error.localizedDescription)
            }
        } catch {
            throw WebDAVError.transportFailure(error.localizedDescription)
        }
    }
}

private final class SecureWebDAVTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedHost: String
    private let expectedPort: Int
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var rejectedRedirect = false

    init(expectedHost: String, expectedPort: Int, username: String, password: String) {
        self.expectedHost = expectedHost
        self.expectedPort = expectedPort
        self.username = username
        self.password = password
    }

    var didRejectRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let destination = request.url
        let destinationPort = destination?.port ?? 443
        let isAllowed = (response.statusCode == 307 || response.statusCode == 308)
            && destination?.scheme?.lowercased() == "https"
            && destination?.host?.caseInsensitiveCompare(expectedHost) == .orderedSame
            && destinationPort == expectedPort
        if isAllowed {
            completionHandler(request)
        } else {
            lock.lock()
            rejectedRedirect = true
            lock.unlock()
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let isExpectedOrigin = protectionSpace.host.caseInsensitiveCompare(expectedHost) == .orderedSame
            && protectionSpace.protocol?.lowercased() == "https"
            && protectionSpace.port == expectedPort

        if protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(isExpectedOrigin ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
            return
        }

        let isSupportedAuthentication = protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest
        guard isExpectedOrigin, isSupportedAuthentication, challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(
            .useCredential,
            URLCredential(user: username, password: password, persistence: .none)
        )
    }
}

final class WebDAVClient: @unchecked Sendable {
    static let maximumResponseBytes = 5 * 1_024 * 1_024

    let configuration: WebDAVConfiguration

    private let transport: any WebDAVTransport
    private let responseLimit: Int

    init(
        configuration: WebDAVConfiguration,
        transport: (any WebDAVTransport)? = nil,
        maximumResponseBytes: Int = WebDAVClient.maximumResponseBytes
    ) throws {
        let normalizedConfiguration = try configuration.normalized()
        guard maximumResponseBytes > 0 else {
            throw WebDAVError.invalidResponse
        }
        self.configuration = normalizedConfiguration
        self.transport = transport ?? URLSessionWebDAVTransport(configuration: normalizedConfiguration)
        responseLimit = maximumResponseBytes
    }

    func download() async throws -> WebDAVResource? {
        let url = try configuration.resolvedResourceURL()
        let response = try await send(method: "GET", url: url)
        if response.statusCode == 404 {
            return nil
        }
        try validateSuccess(response.statusCode)
        return WebDAVResource(data: response.data, strongETag: try strongETag(from: response))
    }

    @discardableResult
    func upload(_ data: Data, condition: WebDAVUploadCondition) async throws -> String? {
        let url = try configuration.resolvedResourceURL()
        let response = try await put(data, to: url, condition: condition)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            return nil
        }
        // The coordinator always verifies a write with a fresh GET. Some valid
        // WebDAV servers omit ETag here or return a weak representation ETag.
        return try? validateStrongETag(etag)
    }

    func createParentCollections() async throws {
        for url in try configuration.parentCollectionURLs {
            let response = try await send(method: "MKCOL", url: url)
            if response.statusCode == 405 {
                continue
            }
            try validateSuccess(response.statusCode)
        }
    }

    func testConnection() async throws {
        try await createParentCollections()

        let resourceURL = try configuration.resolvedResourceURL()
        let probeURL = resourceURL.deletingLastPathComponent()
            .appendingPathComponent("PGYMacMenu-probe-\(UUID().uuidString).tmp", isDirectory: false)
        let probeData = Data("PGYMacMenu WebDAV probe \(UUID().uuidString)".utf8)
        var created = false
        var cleanupETag: String?

        do {
            _ = try await putRaw(probeData, to: probeURL, condition: .createOnly)
            created = true

            let getResponse = try await send(method: "GET", url: probeURL)
            try validateSuccess(getResponse.statusCode)
            let downloadedETag = try strongETag(from: getResponse)
            cleanupETag = downloadedETag
            guard getResponse.data == probeData else {
                throw WebDAVError.verificationFailed
            }

            try await delete(url: probeURL, matching: downloadedETag)
            created = false
        } catch {
            if created {
                try? await delete(url: probeURL, matching: cleanupETag)
            }
            throw error
        }
    }

    private func put(
        _ data: Data,
        to url: URL,
        condition: WebDAVUploadCondition
    ) async throws -> WebDAVTransportResponse {
        let response = try await putRaw(data, to: url, condition: condition)
        try validateSuccess(response.statusCode)
        return response
    }

    private func putRaw(
        _ data: Data,
        to url: URL,
        condition: WebDAVUploadCondition
    ) async throws -> WebDAVTransportResponse {
        var request = request(method: "PUT", url: url)
        request.setValue("application/vnd.pgymacmenu.encrypted+json", forHTTPHeaderField: "Content-Type")
        switch condition {
        case .createOnly:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .matching(let etag):
            request.setValue(try validateStrongETag(etag), forHTTPHeaderField: "If-Match")
        }
        request.httpBody = data
        let response = try await transport.send(request, maximumResponseBytes: responseLimit)
        try validateSuccess(response.statusCode)
        return response
    }

    private func delete(url: URL, matching etag: String?) async throws {
        var request = request(method: "DELETE", url: url)
        if let etag {
            request.setValue(try validateStrongETag(etag), forHTTPHeaderField: "If-Match")
        } else {
            request.setValue("*", forHTTPHeaderField: "If-Match")
        }
        let response = try await transport.send(request, maximumResponseBytes: responseLimit)
        try validateSuccess(response.statusCode)
    }

    private func send(method: String, url: URL) async throws -> WebDAVTransportResponse {
        try await transport.send(request(method: method, url: url), maximumResponseBytes: responseLimit)
    }

    private func request(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func strongETag(from response: WebDAVTransportResponse) throws -> String {
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw WebDAVError.missingStrongETag
        }
        return try validateStrongETag(etag)
    }

    private func validateStrongETag(_ value: String) throws -> String {
        let etag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !etag.isEmpty else {
            throw WebDAVError.invalidStrongETag
        }
        guard !etag.lowercased().hasPrefix("w/"),
              etag.first == "\"",
              etag.last == "\"",
              etag.count >= 2,
              !etag.dropFirst().dropLast().unicodeScalars.contains(where: {
                  $0.value < 0x21 || $0.value == 0x22 || $0.value == 0x7f
              }) else {
            throw WebDAVError.invalidStrongETag
        }
        return etag
    }

    private func validateSuccess(_ statusCode: Int) throws {
        guard !(200..<300).contains(statusCode) else {
            return
        }
        throw Self.error(for: statusCode)
    }

    private static func error(for statusCode: Int) -> WebDAVError {
        switch statusCode {
        case 300..<400:
            return .redirectRejected
        case 401:
            return .authenticationFailed
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 405:
            return .methodNotAllowed
        case 409:
            return .conflict
        case 412:
            return .preconditionFailed
        case 423:
            return .locked
        case 429:
            return .rateLimited
        case 507:
            return .insufficientStorage
        case 500..<600:
            return .serverError(statusCode: statusCode)
        default:
            return .httpStatus(statusCode: statusCode)
        }
    }
}
