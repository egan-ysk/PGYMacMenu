import Foundation

enum WebDAVProvider: Equatable, Sendable {
    case jianguoyun
}

struct WebDAVConfiguration: Codable, Hashable, Sendable {
    static let defaultRelativePath = "PGYMacMenu.sync"

    let rootURL: URL
    let relativePath: String
    let username: String
    let password: String

    init(
        rootURL: URL,
        relativePath: String = WebDAVConfiguration.defaultRelativePath,
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

    fileprivate var provider: WebDAVProvider? {
        rootURL.host?.caseInsensitiveCompare("dav.jianguoyun.com") == .orderedSame
            ? .jianguoyun
            : nil
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
        if host.caseInsensitiveCompare("dav.jianguoyun.com") == .orderedSame {
            let firstPathComponent = components.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .first
            guard firstPathComponent == "dav" else {
                throw WebDAVError.invalidJianguoyunRootURL
            }
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
    let strongETag: String?
}

struct WebDAVCollectionChild: Equatable, Hashable, Sendable {
    let name: String
    let url: URL
}

enum WebDAVConcurrencyCapability: Equatable, Sendable {
    case strongETag
    case exclusiveLock
}

struct WebDAVWriteLock: Equatable, Sendable {
    fileprivate let token: String
    fileprivate let resourceURL: URL
}

enum WebDAVUploadCondition: Equatable, Sendable {
    case createOnly
    case matching(String)
    case locked(WebDAVWriteLock)
}

enum WebDAVError: Error, Equatable, Sendable {
    case insecureRootURL
    case invalidRootURL
    case invalidJianguoyunRootURL
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
    case invalidCollectionResponse
    case collectionListingLimitExceeded
    case unsafeConditionalCreate
    case unsafeAtomicMove
    case unsafeConditionalUpdate
    case exclusiveLockUnavailable
    case unsafeExclusiveLock
    case collectionUnavailable(provider: WebDAVProvider?)
    case probeReadUnavailable
    case probeCleanupFailed
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
        case .invalidJianguoyunRootURL:
            return "坚果云根 URL 必须使用 https://dav.jianguoyun.com/dav/"
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
        case .invalidCollectionResponse:
            return "WebDAV 服务器返回了无效的目录列表"
        case .collectionListingLimitExceeded:
            return "WebDAV 目录列表超过安全限制"
        case .unsafeConditionalCreate:
            return "WebDAV 服务器未正确执行条件创建，已停止同步以避免配置被覆盖"
        case .unsafeAtomicMove:
            return "WebDAV 服务器的原子移动创建未通过安全校验，已停止同步以避免配置被覆盖"
        case .unsafeConditionalUpdate:
            return "WebDAV 服务器未正确执行条件更新，已停止同步以避免配置被覆盖"
        case .exclusiveLockUnavailable:
            return "WebDAV 服务器既未提供强 ETag，也不支持独占写锁，无法安全同步"
        case .unsafeExclusiveLock:
            return "WebDAV 服务器的独占写锁未通过安全校验，已停止同步以避免配置被覆盖"
        case .collectionUnavailable(let provider):
            if provider == .jianguoyun {
                return "坚果云目录不存在或不可写。根 URL 请填写 https://dav.jianguoyun.com/dav/，不要把同步文件名或尚未创建的子目录放进根 URL"
            }
            return "WebDAV 目录不存在或不可写；请将根 URL 指向已存在的目录，并把子目录填写在相对文件路径中"
        case .probeReadUnavailable:
            return "WebDAV 测试文件写入后仍无法读取，请稍后重试"
        case .probeCleanupFailed:
            return "WebDAV 测试文件无法删除，请检查目录删除权限"
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

private struct LockDiscoveryXML {
    let token: String
    let timeoutSeconds: Int
    let isExclusiveWrite: Bool
    let depth: String

    static func parse(_ data: Data) -> LockDiscoveryXML? {
        let delegate = LockDiscoveryXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil else {
            return nil
        }
        return delegate.discoveries.count == 1 ? delegate.discoveries[0] : nil
    }
}

private final class LockDiscoveryXMLParserDelegate: NSObject, XMLParserDelegate {
    private struct Element {
        let name: String
        let namespaceURI: String?
    }

    private struct PartialDiscovery {
        var token: String?
        var timeout: String?
        var depth: String?
        var hasExclusive = false
        var hasWrite = false
    }

    private var elementStack: [Element] = []
    private var text = ""
    private var current: PartialDiscovery?
    fileprivate private(set) var discoveries: [LockDiscoveryXML] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName, qualifiedName: qName)
        elementStack.append(Element(name: name, namespaceURI: namespaceURI))
        text = ""
        if hasDAVPath(["prop", "lockdiscovery", "activelock"]) {
            current = PartialDiscovery()
        } else if hasDAVPath(["activelock", "lockscope", "exclusive"]), current != nil {
            current?.hasExclusive = true
        } else if hasDAVPath(["activelock", "locktype", "write"]), current != nil {
            current?.hasWrite = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName, qualifiedName: qName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasDAVPath(["activelock", "locktoken", "href"]), current != nil {
            current?.token = "<\(value)>"
        } else if hasDAVPath(["activelock", "timeout"]), current != nil {
            current?.timeout = value
        } else if hasDAVPath(["activelock", "depth"]), current != nil {
            current?.depth = value
        } else if hasDAVPath(["prop", "lockdiscovery", "activelock"]), let current {
            if let token = current.token,
               let timeout = current.timeout,
               let depth = current.depth,
               timeout.hasPrefix("Second-"),
               let seconds = Int(timeout.dropFirst("Second-".count)) {
                discoveries.append(
                    LockDiscoveryXML(
                        token: token,
                        timeoutSeconds: seconds,
                        isExclusiveWrite: current.hasExclusive && current.hasWrite,
                        depth: depth
                    )
                )
            }
            self.current = nil
        }
        if elementStack.last?.name == name {
            elementStack.removeLast()
        }
        text = ""
    }

    private func normalizedName(_ elementName: String, qualifiedName: String?) -> String {
        let candidate = elementName.isEmpty ? (qualifiedName ?? "") : elementName
        return candidate.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
    }

    private func hasDAVPath(_ suffix: [String]) -> Bool {
        guard elementStack.count >= suffix.count else { return false }
        let elements = elementStack.suffix(suffix.count)
        return zip(elements, suffix).allSatisfy { element, expectedName in
            element.name == expectedName && element.namespaceURI == "DAV:"
        }
    }
}

private struct WebDAVMultiStatusItem {
    struct PropertyStatus {
        let statusCode: Int
        let isCollection: Bool
    }

    let href: String
    let statusCode: Int?
    let propertyStatuses: [PropertyStatus]

    var hasSuccessfulProperties: Bool {
        propertyStatuses.contains { (200..<300).contains($0.statusCode) }
    }

    var isCollection: Bool {
        propertyStatuses.contains {
            (200..<300).contains($0.statusCode) && $0.isCollection
        }
    }

    static func parse(_ data: Data, maximumItems: Int) throws -> [WebDAVMultiStatusItem] {
        guard maximumItems > 0 else {
            throw WebDAVError.collectionListingLimitExceeded
        }
        let delegate = WebDAVMultiStatusXMLParserDelegate(maximumItems: maximumItems)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), parser.parserError == nil, !delegate.isInvalid else {
            if delegate.exceededLimit {
                throw WebDAVError.collectionListingLimitExceeded
            }
            throw WebDAVError.invalidCollectionResponse
        }
        guard delegate.sawMultiStatus else {
            throw WebDAVError.invalidCollectionResponse
        }
        return delegate.items
    }
}

private final class WebDAVMultiStatusXMLParserDelegate: NSObject, XMLParserDelegate {
    private struct Element {
        let name: String
        let namespaceURI: String?
    }

    private struct PartialPropertyStatus {
        var statusCode: Int?
        var isCollection = false
    }

    private struct PartialItem {
        var href: String?
        var statusCode: Int?
        var propertyStatuses: [WebDAVMultiStatusItem.PropertyStatus] = []
    }

    private enum TextTarget {
        case href
        case responseStatus
        case propertyStatus
    }

    private static let maximumTextBytes = 8_192
    private static let maximumXMLDepth = 64
    private static let maximumPropertyStatusesPerItem = 16

    private let maximumItems: Int
    private var elementStack: [Element] = []
    private var currentItem: PartialItem?
    private var currentPropertyStatus: PartialPropertyStatus?
    private var textTarget: TextTarget?
    private var text = ""

    fileprivate private(set) var items: [WebDAVMultiStatusItem] = []
    fileprivate private(set) var sawMultiStatus = false
    fileprivate private(set) var isInvalid = false
    fileprivate private(set) var exceededLimit = false

    init(maximumItems: Int) {
        self.maximumItems = maximumItems
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Element(
            name: normalizedName(elementName, qualifiedName: qName),
            namespaceURI: namespaceURI
        )
        elementStack.append(element)
        guard elementStack.count <= Self.maximumXMLDepth else {
            invalidate(parser)
            return
        }
        if textTarget != nil {
            invalidate(parser)
            return
        }

        if elementStack.count == 1 {
            guard isDAVElement(element, named: "multistatus") else {
                invalidate(parser)
                return
            }
            sawMultiStatus = true
        } else if hasExactDAVPath(["multistatus", "response"]) {
            guard currentItem == nil else {
                invalidate(parser)
                return
            }
            currentItem = PartialItem()
        } else if hasExactDAVPath(["multistatus", "response", "href"]) {
            guard currentItem != nil, currentItem?.href == nil else {
                invalidate(parser)
                return
            }
            beginText(.href)
        } else if hasExactDAVPath(["multistatus", "response", "status"]) {
            guard currentItem != nil, currentItem?.statusCode == nil else {
                invalidate(parser)
                return
            }
            beginText(.responseStatus)
        } else if hasExactDAVPath(["multistatus", "response", "propstat"]) {
            guard currentItem != nil, currentPropertyStatus == nil else {
                invalidate(parser)
                return
            }
            currentPropertyStatus = PartialPropertyStatus()
        } else if hasExactDAVPath(["multistatus", "response", "propstat", "status"]) {
            guard currentPropertyStatus != nil, currentPropertyStatus?.statusCode == nil else {
                invalidate(parser)
                return
            }
            beginText(.propertyStatus)
        } else if hasExactDAVPath([
            "multistatus", "response", "propstat", "prop", "resourcetype", "collection"
        ]) {
            guard currentPropertyStatus != nil else {
                invalidate(parser)
                return
            }
            currentPropertyStatus?.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textTarget != nil else { return }
        guard text.utf8.count + string.utf8.count <= Self.maximumTextBytes else {
            invalidate(parser)
            return
        }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !isInvalid else { return }

        if hasExactDAVPath(["multistatus", "response", "href"]) {
            guard textTarget == .href else {
                invalidate(parser)
                return
            }
            let href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else {
                invalidate(parser)
                return
            }
            currentItem?.href = href
            endText()
        } else if hasExactDAVPath(["multistatus", "response", "status"]) {
            guard textTarget == .responseStatus, let statusCode = parseStatusCode(text) else {
                invalidate(parser)
                return
            }
            currentItem?.statusCode = statusCode
            endText()
        } else if hasExactDAVPath(["multistatus", "response", "propstat", "status"]) {
            guard textTarget == .propertyStatus, let statusCode = parseStatusCode(text) else {
                invalidate(parser)
                return
            }
            currentPropertyStatus?.statusCode = statusCode
            endText()
        } else if hasExactDAVPath(["multistatus", "response", "propstat"]) {
            guard let propertyStatus = currentPropertyStatus,
                  let statusCode = propertyStatus.statusCode else {
                invalidate(parser)
                return
            }
            guard (currentItem?.propertyStatuses.count ?? 0)
                    < Self.maximumPropertyStatusesPerItem else {
                invalidate(parser)
                return
            }
            currentItem?.propertyStatuses.append(
                WebDAVMultiStatusItem.PropertyStatus(
                    statusCode: statusCode,
                    isCollection: propertyStatus.isCollection
                )
            )
            currentPropertyStatus = nil
        } else if hasExactDAVPath(["multistatus", "response"]) {
            guard currentPropertyStatus == nil,
                  let item = currentItem,
                  let href = item.href else {
                invalidate(parser)
                return
            }
            guard items.count < maximumItems else {
                exceededLimit = true
                invalidate(parser)
                return
            }
            items.append(
                WebDAVMultiStatusItem(
                    href: href,
                    statusCode: item.statusCode,
                    propertyStatuses: item.propertyStatuses
                )
            )
            currentItem = nil
        }

        elementStack.removeLast()
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        invalidate(parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        invalidate(parser)
    }

    private func beginText(_ target: TextTarget) {
        textTarget = target
        text = ""
    }

    private func endText() {
        textTarget = nil
        text = ""
    }

    private func invalidate(_ parser: XMLParser) {
        isInvalid = true
        parser.abortParsing()
    }

    private func normalizedName(_ elementName: String, qualifiedName: String?) -> String {
        let candidate = elementName.isEmpty ? (qualifiedName ?? "") : elementName
        return candidate.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
    }

    private func isDAVElement(_ element: Element, named name: String) -> Bool {
        element.name == name && element.namespaceURI == "DAV:"
    }

    private func hasExactDAVPath(_ names: [String]) -> Bool {
        guard elementStack.count == names.count else { return false }
        return zip(elementStack, names).allSatisfy { element, name in
            isDAVElement(element, named: name)
        }
    }

    private func parseStatusCode(_ value: String) -> Int? {
        let components = value.split(whereSeparator: { $0.isWhitespace })
        guard components.count >= 2,
              components[0].uppercased().hasPrefix("HTTP/"),
              let statusCode = Int(components[1]),
              (100...599).contains(statusCode) else {
            return nil
        }
        return statusCode
    }
}

final class WebDAVClient: @unchecked Sendable {
    static let maximumResponseBytes = 5 * 1_024 * 1_024

    private static let maximumCollectionPages = 64
    private static let maximumCollectionEntries = 50_000
    private static let maximumCollectionResponseBytes = 20 * 1_024 * 1_024
    private static let probeReadRetryDelays: [UInt64] = [
        0,
        200_000_000,
        500_000_000,
        1_000_000_000
    ]

    let configuration: WebDAVConfiguration

    private let transport: any WebDAVTransport
    private let responseLimit: Int
    // A non-201 response to If-None-Match is only usable after this client
    // has independently proved the server preserves an existing resource.
    private var conditionalCreateSemanticsAttested = false
    // A staged MOVE with Overwrite: F is only usable after this client has
    // independently proved it creates a new target without replacing one.
    private var atomicMoveNoOverwriteSemanticsAttested = false

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

    func immutableCollectionURL() throws -> URL {
        let resourceURL = try configuration.resolvedResourceURL()
        let collectionName = resourceURL.lastPathComponent + ".d"
        guard isSafePathSegment(collectionName) else {
            throw WebDAVError.invalidRelativePath
        }
        return resourceURL.deletingLastPathComponent()
            .appendingPathComponent(collectionName, isDirectory: true)
    }

    @discardableResult
    func ensureImmutableCollection() async throws -> URL {
        try await createParentCollections()
        let collectionURL = try immutableCollectionURL()
        let createResponse = try await send(method: "MKCOL", url: collectionURL)
        if createResponse.statusCode != 201 && createResponse.statusCode != 405 {
            if createResponse.statusCode == 404 || createResponse.statusCode == 409 {
                throw collectionUnavailableError()
            }
            try validateSuccess(createResponse.statusCode)
            throw WebDAVError.invalidCollectionResponse
        }

        let response = try await propfind(url: collectionURL, depth: 0)
        guard response.statusCode == 207 else {
            try validateSuccess(response.statusCode)
            throw WebDAVError.invalidCollectionResponse
        }
        let items = try WebDAVMultiStatusItem.parse(response.data, maximumItems: 16)
        var foundCollection = false
        for item in items {
            guard isSuccessful(item) else { continue }
            let resolvedURL = try resolveDAVHref(item.href, relativeTo: collectionURL)
            if try isSameCollectionURL(resolvedURL, as: collectionURL) {
                guard item.isCollection else {
                    throw WebDAVError.invalidCollectionResponse
                }
                foundCollection = true
            } else {
                throw WebDAVError.invalidCollectionResponse
            }
        }
        guard foundCollection else {
            throw WebDAVError.invalidCollectionResponse
        }
        return collectionURL
    }

    func listImmutableChildren() async throws -> [WebDAVCollectionChild] {
        let collectionURL = try immutableCollectionURL()
        var currentPageURL = collectionURL
        var visitedPages: Set<String> = []
        var children: [String: WebDAVCollectionChild] = [:]
        var totalItemCount = 0
        var totalResponseBytes = 0
        var pageCount = 0
        var sawCollection = false

        while true {
            pageCount += 1
            guard pageCount <= Self.maximumCollectionPages else {
                throw WebDAVError.collectionListingLimitExceeded
            }
            currentPageURL = try validatePaginationURL(currentPageURL, collectionURL: collectionURL)
            let pageKey = currentPageURL.absoluteString
            guard visitedPages.insert(pageKey).inserted else {
                throw WebDAVError.invalidCollectionResponse
            }

            let response = try await propfind(url: currentPageURL, depth: 1)
            guard response.statusCode == 207 else {
                try validateSuccess(response.statusCode)
                throw WebDAVError.invalidCollectionResponse
            }
            if let finalURL = response.url {
                _ = try validatePaginationURL(finalURL, collectionURL: collectionURL)
            }
            guard response.data.count <= responseLimit else {
                throw WebDAVError.responseTooLarge(maxBytes: responseLimit)
            }
            totalResponseBytes += response.data.count
            guard totalResponseBytes <= Self.maximumCollectionResponseBytes else {
                throw WebDAVError.collectionListingLimitExceeded
            }

            let remainingItems = Self.maximumCollectionEntries - totalItemCount
            let items = try WebDAVMultiStatusItem.parse(
                response.data,
                maximumItems: max(remainingItems, 1)
            )
            totalItemCount += items.count
            guard totalItemCount <= Self.maximumCollectionEntries else {
                throw WebDAVError.collectionListingLimitExceeded
            }

            for item in items where isSuccessful(item) {
                let resolvedURL = try resolveDAVHref(item.href, relativeTo: currentPageURL)
                if try isSameCollectionURL(resolvedURL, as: collectionURL) {
                    guard item.isCollection else {
                        throw WebDAVError.invalidCollectionResponse
                    }
                    sawCollection = true
                    continue
                }

                let child = try validatedDirectChild(
                    resolvedURL,
                    itemIsCollection: item.isCollection,
                    collectionURL: collectionURL
                )
                if let existing = children[child.name], existing != child {
                    throw WebDAVError.invalidCollectionResponse
                }
                children[child.name] = child
            }

            guard let linkHeader = response.value(forHTTPHeaderField: "Link") else {
                break
            }
            guard let nextReference = try nextLinkReference(from: linkHeader) else {
                break
            }
            guard let nextURL = URL(string: nextReference, relativeTo: currentPageURL)?.absoluteURL else {
                throw WebDAVError.invalidCollectionResponse
            }
            currentPageURL = try validatePaginationURL(nextURL, collectionURL: collectionURL)
        }

        guard sawCollection else {
            throw WebDAVError.invalidCollectionResponse
        }
        return children.values.sorted { $0.name < $1.name }
    }

    func downloadImmutableChild(_ child: WebDAVCollectionChild) async throws -> Data? {
        let expected = try immutableChild(named: child.name)
        guard child == expected else {
            throw WebDAVError.invalidRelativePath
        }
        return try await downloadImmutableChild(at: child.url)
    }

    func downloadImmutableChild(named name: String) async throws -> Data? {
        try await downloadImmutableChild(at: immutableChild(named: name).url)
    }

    @discardableResult
    func createImmutableChild(_ data: Data, named name: String) async throws -> URL {
        let child = try immutableChild(named: name)
        if conditionalCreateSemanticsAttested {
            let response = try await putResponse(data, to: child.url, condition: .createOnly)
            switch response.statusCode {
            case 201:
                return child.url
            case 200, 204:
                try await verifyAttestedConditionalCreation(data, at: child.url)
                return child.url
            case 412:
                throw WebDAVError.preconditionFailed
            case 200..<300:
                throw WebDAVError.unsafeConditionalCreate
            default:
                try validateSuccess(response.statusCode)
                throw WebDAVError.invalidResponse
            }
        }

        guard atomicMoveNoOverwriteSemanticsAttested else {
            throw WebDAVError.unsafeAtomicMove
        }
        return try await createImmutableChildUsingAtomicMove(data, destination: child.url)
    }

    /// Verifies one safe immutable-create strategy for this client instance.
    /// A server that ignores If-None-Match may still be usable when it proves
    /// a same-collection MOVE with Overwrite: F cannot replace an existing file.
    func verifyImmutableCreateSafety() async throws {
        conditionalCreateSemanticsAttested = false
        atomicMoveNoOverwriteSemanticsAttested = false

        do {
            try await verifyConditionalCreateSafety()
        } catch WebDAVError.unsafeConditionalCreate {
            try await verifyAtomicMoveNoOverwriteSafety()
        }
    }

    func verifyConditionalCreateSafety() async throws {
        conditionalCreateSemanticsAttested = false
        try await createParentCollections()

        let resourceURL = try configuration.resolvedResourceURL()
        let collectionURL = resourceURL.deletingLastPathComponent()
            .appendingPathComponent(
                "PGYMacMenu-create-probe-\(UUID().uuidString).tmp.d",
                isDirectory: true
            )
        let probeURL = collectionURL.appendingPathComponent("conditional-create.tmp")
        let originalData = Data("PGYMacMenu create probe \(UUID().uuidString)".utf8)
        var ownsCollection = false
        var childWasCreated = false
        var operationError: Error?

        do {
            let createResponse = try await send(method: "MKCOL", url: collectionURL)
            guard createResponse.statusCode == 201 else {
                try validateSuccess(createResponse.statusCode)
                throw WebDAVError.invalidCollectionResponse
            }
            ownsCollection = true

            let collectionResponse = try await propfind(url: collectionURL, depth: 0)
            guard collectionResponse.statusCode == 207 else {
                try validateSuccess(collectionResponse.statusCode)
                throw WebDAVError.invalidCollectionResponse
            }
            let items = try WebDAVMultiStatusItem.parse(
                collectionResponse.data,
                maximumItems: 16
            )
            var foundCollection = false
            for item in items where isSuccessful(item) {
                let resolvedURL = try resolveDAVHref(item.href, relativeTo: collectionURL)
                guard try isSameCollectionURL(resolvedURL, as: collectionURL),
                      item.isCollection else {
                    throw WebDAVError.invalidCollectionResponse
                }
                foundCollection = true
            }
            guard foundCollection else {
                throw WebDAVError.invalidCollectionResponse
            }

            let initialWrite = try await putResponse(
                originalData,
                to: probeURL,
                condition: .createOnly
            )
            switch initialWrite.statusCode {
            case 201, 200, 204:
                childWasCreated = true
            case 200..<300:
                throw WebDAVError.unsafeConditionalCreate
            default:
                try validateSuccess(initialWrite.statusCode)
                throw WebDAVError.invalidResponse
            }

            let initialRead = try await readProbe(at: probeURL)
            guard initialRead.data == originalData else {
                throw WebDAVError.verificationFailed
            }

            _ = try await verifyCreateOnlyConflict(
                at: probeURL,
                preserving: originalData
            )
        } catch {
            operationError = error
        }

        if ownsCollection {
            try await cleanupConditionalCreateProbe(
                childURL: probeURL,
                childWasCreated: childWasCreated,
                collectionURL: collectionURL
            )
        }
        if let operationError {
            throw operationError
        }
        conditionalCreateSemanticsAttested = true
    }

    func verifyAtomicMoveNoOverwriteSafety() async throws {
        atomicMoveNoOverwriteSemanticsAttested = false
        try await createParentCollections()

        let resourceURL = try configuration.resolvedResourceURL()
        let collectionURL = resourceURL.deletingLastPathComponent()
            .appendingPathComponent(
                "PGYMacMenu-move-probe-\(UUID().uuidString).tmp.d",
                isDirectory: true
            )
        let initialSourceURL = collectionURL.appendingPathComponent(
            "stage-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let destinationURL = collectionURL.appendingPathComponent(
            "destination-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let conflictingSourceURL = collectionURL.appendingPathComponent(
            "collision-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let destinationData = Data("PGYMacMenu MOVE probe \(UUID().uuidString)".utf8)
        let conflictingData = Data("PGYMacMenu MOVE collision \(UUID().uuidString)".utf8)

        var ownsCollection = false
        var ownedResourceURLs: [URL] = []
        var operationError: Error?

        do {
            let createResponse = try await send(method: "MKCOL", url: collectionURL)
            guard createResponse.statusCode == 201 else {
                try validateSuccess(createResponse.statusCode)
                throw WebDAVError.invalidCollectionResponse
            }
            // A non-201 or ambiguous transport failure does not prove that the
            // UUID collection belongs to us, so it must never be deleted.
            ownsCollection = true
            try await verifyOwnedProbeCollection(at: collectionURL)

            ownedResourceURLs.append(initialSourceURL)
            try await stageAtomicMoveData(destinationData, at: initialSourceURL)

            // The random destination might be committed before the transport
            // reports a failure or an anomalous status, so clean it too.
            ownedResourceURLs.append(destinationURL)
            let initialMove = try await moveNoOverwrite(
                from: initialSourceURL,
                to: destinationURL
            )
            guard initialMove.statusCode == 201 else {
                if (200..<300).contains(initialMove.statusCode) {
                    throw WebDAVError.unsafeAtomicMove
                }
                try validateSuccess(initialMove.statusCode)
                throw WebDAVError.unsafeAtomicMove
            }
            try await verifyExactProbeData(destinationData, at: destinationURL)
            try await verifyMovedSourceWasRemoved(at: initialSourceURL)

            ownedResourceURLs.append(conflictingSourceURL)
            try await stageAtomicMoveData(conflictingData, at: conflictingSourceURL)

            let collisionMove = try await moveNoOverwrite(
                from: conflictingSourceURL,
                to: destinationURL
            )
            guard collisionMove.statusCode == 409 || collisionMove.statusCode == 412 else {
                if (200..<300).contains(collisionMove.statusCode) {
                    throw WebDAVError.unsafeAtomicMove
                }
                try validateSuccess(collisionMove.statusCode)
                throw WebDAVError.unsafeAtomicMove
            }
            try await verifyExactProbeData(destinationData, at: destinationURL)
            try await verifyExactProbeData(conflictingData, at: conflictingSourceURL)
        } catch {
            operationError = error
        }

        if ownsCollection {
            try await cleanupAtomicMoveProbe(
                resourceURLs: ownedResourceURLs,
                collectionURL: collectionURL
            )
        }
        if let operationError {
            throw operationError
        }
        atomicMoveNoOverwriteSemanticsAttested = true
    }

    var hasConditionalCreateAttestation: Bool {
        conditionalCreateSemanticsAttested
    }

    var hasAtomicMoveNoOverwriteAttestation: Bool {
        atomicMoveNoOverwriteSemanticsAttested
    }

    var hasImmutableCreateAttestation: Bool {
        conditionalCreateSemanticsAttested || atomicMoveNoOverwriteSemanticsAttested
    }

    func download() async throws -> WebDAVResource? {
        let url = try configuration.resolvedResourceURL()
        let response = try await send(method: "GET", url: url)
        if response.statusCode == 404 {
            return nil
        }
        try validateSuccess(response.statusCode)
        return WebDAVResource(data: response.data, strongETag: usableStrongETag(from: response))
    }

    @discardableResult
    func upload(_ data: Data, condition: WebDAVUploadCondition) async throws -> String? {
        let url = try configuration.resolvedResourceURL()
        let response: WebDAVTransportResponse
        switch condition {
        case .createOnly:
            response = try await putResponse(data, to: url, condition: condition)
            switch response.statusCode {
            case 201:
                break
            case 200, 204:
                try await verifyAttestedConditionalCreation(data, at: url)
            case 200..<300:
                throw WebDAVError.unsafeConditionalCreate
            default:
                try validateSuccess(response.statusCode)
            }
        case .matching:
            response = try await putResponse(data, to: url, condition: condition)
            switch response.statusCode {
            case 200, 204:
                break
            case 200..<300:
                throw WebDAVError.unsafeConditionalUpdate
            default:
                try validateSuccess(response.statusCode)
            }
        case .locked:
            response = try await putResponse(data, to: url, condition: condition)
            switch response.statusCode {
            case 200, 204:
                break
            case 200..<300:
                throw WebDAVError.unsafeExclusiveLock
            default:
                try validateSuccess(response.statusCode)
            }
        }
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            return nil
        }
        // The coordinator always verifies a write with a fresh GET. Some valid
        // WebDAV servers omit ETag here or return a weak representation ETag.
        return try? validateStrongETag(etag)
    }

    func acquireExclusiveWriteLock() async throws -> WebDAVWriteLock {
        try await acquireExclusiveWriteLock(at: configuration.resolvedResourceURL())
    }

    func releaseExclusiveWriteLock(_ lock: WebDAVWriteLock) async throws {
        let expectedURL = try configuration.resolvedResourceURL()
        guard lock.resourceURL == expectedURL else {
            throw WebDAVError.unsafeExclusiveLock
        }
        try await releaseExclusiveWriteLock(lock, at: expectedURL)
    }

    func createParentCollections() async throws {
        for url in try configuration.parentCollectionURLs {
            let response = try await send(method: "MKCOL", url: url)
            if response.statusCode == 405 {
                continue
            }
            if response.statusCode == 404 || response.statusCode == 409 {
                throw collectionUnavailableError()
            }
            try validateSuccess(response.statusCode)
        }
    }

    @discardableResult
    func testConnection() async throws -> WebDAVConcurrencyCapability {
        try await testConnection(requiringExclusiveLock: false)
    }

    func verifyExclusiveLockSafety() async throws {
        _ = try await testConnection(requiringExclusiveLock: true)
    }

    private func testConnection(
        requiringExclusiveLock: Bool
    ) async throws -> WebDAVConcurrencyCapability {
        conditionalCreateSemanticsAttested = false
        atomicMoveNoOverwriteSemanticsAttested = false
        try await createParentCollections()

        let resourceURL = try configuration.resolvedResourceURL()
        let probeURL = resourceURL.deletingLastPathComponent()
            .appendingPathComponent("PGYMacMenu-probe-\(UUID().uuidString).tmp", isDirectory: false)
        let probeData = Data("PGYMacMenu WebDAV probe \(UUID().uuidString)".utf8)
        var created = false
        var cleanupETag: String?

        do {
            let createResponse = try await putResponse(
                probeData,
                to: probeURL,
                condition: .createOnly
            )
            if createResponse.statusCode == 404 {
                throw collectionUnavailableError()
            }
            switch createResponse.statusCode {
            case 201, 200, 204:
                created = true
            case 200..<300:
                throw WebDAVError.unsafeConditionalCreate
            default:
                try validateSuccess(createResponse.statusCode)
            }

            let getResponse = try await readProbe(at: probeURL)
            guard getResponse.data == probeData else {
                throw WebDAVError.verificationFailed
            }
            let unchangedResponse = try await verifyCreateOnlyConflict(
                at: probeURL,
                preserving: probeData
            )

            let capability: WebDAVConcurrencyCapability
            if let currentETag = usableStrongETag(from: unchangedResponse),
               !requiringExclusiveLock {
                cleanupETag = currentETag

                let staleETag = "\"PGYMacMenu-stale-\(UUID().uuidString)\""
                let staleData = Data("PGYMacMenu stale ETag probe \(UUID().uuidString)".utf8)
                let staleResponse = try await putResponse(
                    staleData,
                    to: probeURL,
                    condition: .matching(staleETag)
                )
                guard staleResponse.statusCode == 412 else {
                    if !(200..<300).contains(staleResponse.statusCode) {
                        try validateSuccess(staleResponse.statusCode)
                    }
                    cleanupETag = nil
                    throw WebDAVError.unsafeConditionalUpdate
                }

                let staleRead = try await readProbe(at: probeURL)
                cleanupETag = usableStrongETag(from: staleRead)
                guard staleRead.data == probeData,
                      let verifiedETag = cleanupETag else {
                    throw WebDAVError.unsafeConditionalUpdate
                }

                let updatedData = Data("PGYMacMenu strong ETag probe \(UUID().uuidString)".utf8)
                let updateResponse = try await putResponse(
                    updatedData,
                    to: probeURL,
                    condition: .matching(verifiedETag)
                )
                if updateResponse.statusCode == 412 {
                    throw WebDAVError.unsafeConditionalUpdate
                }
                guard updateResponse.statusCode == 200 || updateResponse.statusCode == 204 else {
                    if (200..<300).contains(updateResponse.statusCode) {
                        throw WebDAVError.unsafeConditionalUpdate
                    }
                    try validateSuccess(updateResponse.statusCode)
                    throw WebDAVError.unsafeConditionalUpdate
                }

                let updatedRead = try await readProbe(at: probeURL)
                cleanupETag = usableStrongETag(from: updatedRead)
                guard updatedRead.data == updatedData,
                      let updatedETag = cleanupETag,
                      updatedETag != verifiedETag else {
                    throw WebDAVError.unsafeConditionalUpdate
                }
                do {
                    try await delete(url: probeURL, condition: .matching(updatedETag))
                    try await waitForProbeDeletion(at: probeURL)
                } catch WebDAVError.notFound {
                    throw WebDAVError.probeCleanupFailed
                } catch WebDAVError.probeCleanupFailed {
                    throw WebDAVError.probeCleanupFailed
                }
                capability = .strongETag
            } else {
                try await testExclusiveLockSafety(at: probeURL, initialData: probeData)
                capability = .exclusiveLock
            }
            created = false
            conditionalCreateSemanticsAttested = true
            return capability
        } catch {
            let operationError = error
            if created {
                let cleanupCondition = cleanupETag.map(WebDAVUploadCondition.matching)
                    ?? .createOnly
                do {
                    try await delete(url: probeURL, condition: cleanupCondition)
                    try await waitForProbeDeletion(at: probeURL)
                } catch {
                    throw WebDAVError.probeCleanupFailed
                }
            }
            throw operationError
        }
    }

    private func verifyCreateOnlyConflict(
        at url: URL,
        preserving originalData: Data
    ) async throws -> WebDAVTransportResponse {
        let conflictingData = Data("PGYMacMenu collision probe \(UUID().uuidString)".utf8)
        let conflictResponse = try await putResponse(
            conflictingData,
            to: url,
            condition: .createOnly
        )
        guard conflictResponse.statusCode == 412 else {
            if !(200..<300).contains(conflictResponse.statusCode) {
                try validateSuccess(conflictResponse.statusCode)
            }
            throw WebDAVError.unsafeConditionalCreate
        }

        let unchangedResponse = try await readProbe(at: url)
        guard unchangedResponse.data == originalData else {
            throw WebDAVError.unsafeConditionalCreate
        }
        return unchangedResponse
    }

    private func readProbe(at url: URL) async throws -> WebDAVTransportResponse {
        for (index, delay) in Self.probeReadRetryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let response = try await send(method: "GET", url: url)
            if response.statusCode == 404 {
                if index < Self.probeReadRetryDelays.count - 1 {
                    continue
                }
                throw WebDAVError.probeReadUnavailable
            }
            try validateSuccess(response.statusCode)
            return response
        }
        throw WebDAVError.probeReadUnavailable
    }

    private func verifyAttestedConditionalCreation(
        _ expectedData: Data,
        at url: URL
    ) async throws {
        guard conditionalCreateSemanticsAttested else {
            throw WebDAVError.unsafeConditionalCreate
        }

        for (index, delay) in Self.probeReadRetryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                let response = try await send(method: "GET", url: url)
                if response.statusCode == 404 {
                    if index < Self.probeReadRetryDelays.count - 1 {
                        continue
                    }
                    throw WebDAVError.unsafeConditionalCreate
                }
                guard response.statusCode == 200, response.data == expectedData else {
                    if (200..<300).contains(response.statusCode) {
                        throw WebDAVError.unsafeConditionalCreate
                    }
                    try validateSuccess(response.statusCode)
                    throw WebDAVError.unsafeConditionalCreate
                }
                return
            } catch {
                guard isTransientConditionalCreateReadError(error) else {
                    throw error
                }
                if index == Self.probeReadRetryDelays.count - 1 {
                    // Do not let the coordinator retry the create-only PUT after
                    // it has already succeeded. The read proof remains incomplete.
                    throw WebDAVError.verificationFailed
                }
            }
        }

        throw WebDAVError.verificationFailed
    }

    private func isTransientConditionalCreateReadError(_ error: Error) -> Bool {
        guard let error = error as? WebDAVError else { return false }
        switch error {
        case .transportFailure, .locked, .rateLimited, .serverError:
            return true
        case .httpStatus(let statusCode):
            return statusCode == 408
        default:
            return false
        }
    }

    private func verifyOwnedProbeCollection(at collectionURL: URL) async throws {
        let collectionResponse = try await propfind(url: collectionURL, depth: 0)
        guard collectionResponse.statusCode == 207 else {
            try validateSuccess(collectionResponse.statusCode)
            throw WebDAVError.invalidCollectionResponse
        }
        let items = try WebDAVMultiStatusItem.parse(
            collectionResponse.data,
            maximumItems: 16
        )
        var foundCollection = false
        for item in items where isSuccessful(item) {
            let resolvedURL = try resolveDAVHref(item.href, relativeTo: collectionURL)
            guard try isSameCollectionURL(resolvedURL, as: collectionURL),
                  item.isCollection else {
                throw WebDAVError.invalidCollectionResponse
            }
            foundCollection = true
        }
        guard foundCollection else {
            throw WebDAVError.invalidCollectionResponse
        }
    }

    private func createImmutableChildUsingAtomicMove(
        _ data: Data,
        destination: URL
    ) async throws -> URL {
        guard atomicMoveNoOverwriteSemanticsAttested else {
            throw WebDAVError.unsafeAtomicMove
        }

        let collectionURL = destination.deletingLastPathComponent()
        let stagingURL = collectionURL.appendingPathComponent(
            "stage-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var stagingMayExist = false
        var operationError: Error?
        var result: URL?

        do {
            // A transport failure can occur after the server committed the PUT.
            // The UUID staging file is safe to clean up if it does not exist.
            stagingMayExist = true
            try await stageAtomicMoveData(data, at: stagingURL)

            let moveResponse = try await moveNoOverwrite(from: stagingURL, to: destination)
            switch moveResponse.statusCode {
            case 201:
                try await verifyExactProbeData(data, at: destination)
                try await verifyMovedSourceWasRemoved(at: stagingURL)
                stagingMayExist = false
                result = destination
            case 409, 412:
                // A collision is only recoverable if the temporary source was
                // preserved. The coordinator verifies the existing destination.
                try await verifyExactProbeData(data, at: stagingURL)
                throw WebDAVError.preconditionFailed
            case 200..<300:
                throw WebDAVError.unsafeAtomicMove
            default:
                try validateSuccess(moveResponse.statusCode)
                throw WebDAVError.unsafeAtomicMove
            }
        } catch {
            operationError = error
        }

        var cleanupURLs: [URL] = []
        if stagingMayExist {
            cleanupURLs.append(stagingURL)
        }
        if !cleanupURLs.isEmpty {
            try await cleanupAtomicMoveResources(cleanupURLs)
        }

        if let operationError {
            throw operationError
        }
        guard let result else {
            throw WebDAVError.unsafeAtomicMove
        }
        return result
    }

    private func stageAtomicMoveData(_ data: Data, at url: URL) async throws {
        let response = try await putResponse(data, to: url, condition: nil)
        guard response.statusCode == 201 else {
            if (200..<300).contains(response.statusCode) {
                throw WebDAVError.unsafeAtomicMove
            }
            try validateSuccess(response.statusCode)
            throw WebDAVError.unsafeAtomicMove
        }
    }

    private func moveNoOverwrite(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws -> WebDAVTransportResponse {
        guard try isSameCollectionURL(
            sourceURL.deletingLastPathComponent(),
            as: destinationURL.deletingLastPathComponent()
        ) else {
            throw WebDAVError.unsafeAtomicMove
        }

        var request = request(method: "MOVE", url: sourceURL)
        request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        return try await transport.send(request, maximumResponseBytes: responseLimit)
    }

    private func verifyExactProbeData(_ expectedData: Data, at url: URL) async throws {
        let response = try await readProbe(at: url)
        guard response.statusCode == 200, response.data == expectedData else {
            throw WebDAVError.unsafeAtomicMove
        }
    }

    private func verifyMovedSourceWasRemoved(at sourceURL: URL) async throws {
        do {
            try await waitForProbeDeletion(at: sourceURL)
        } catch WebDAVError.probeCleanupFailed {
            throw WebDAVError.unsafeAtomicMove
        }
    }

    private func cleanupAtomicMoveProbe(
        resourceURLs: [URL],
        collectionURL: URL
    ) async throws {
        var cleanupFailed = false

        do {
            try await cleanupAtomicMoveResources(resourceURLs)
        } catch {
            cleanupFailed = true
        }

        do {
            try await delete(url: collectionURL, condition: .createOnly)
        } catch WebDAVError.notFound {
            // A missing owned probe collection is already cleaned up.
        } catch {
            cleanupFailed = true
        }
        do {
            try await waitForCollectionDeletion(at: collectionURL)
        } catch {
            cleanupFailed = true
        }

        if cleanupFailed {
            throw WebDAVError.probeCleanupFailed
        }
    }

    private func cleanupAtomicMoveResources(_ resourceURLs: [URL]) async throws {
        var cleanupFailed = false
        var seenURLs: Set<URL> = []

        for url in resourceURLs.reversed() where seenURLs.insert(url).inserted {
            do {
                try await delete(url: url, condition: .createOnly)
            } catch WebDAVError.notFound {
                // A successfully moved source is expected to be absent.
            } catch {
                cleanupFailed = true
            }

            do {
                try await waitForProbeDeletion(at: url)
            } catch {
                cleanupFailed = true
            }
        }

        if cleanupFailed {
            throw WebDAVError.probeCleanupFailed
        }
    }

    private func collectionUnavailableError() -> WebDAVError {
        .collectionUnavailable(provider: configuration.provider)
    }

    private func putRaw(
        _ data: Data,
        to url: URL,
        condition: WebDAVUploadCondition
    ) async throws -> WebDAVTransportResponse {
        let response = try await putResponse(data, to: url, condition: condition)
        try validateSuccess(response.statusCode)
        return response
    }

    private func putResponse(
        _ data: Data,
        to url: URL,
        condition: WebDAVUploadCondition?
    ) async throws -> WebDAVTransportResponse {
        var request = request(method: "PUT", url: url)
        request.setValue("application/vnd.pgymacmenu.encrypted+json", forHTTPHeaderField: "Content-Type")
        switch condition {
        case .createOnly?:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .matching(let etag)?:
            request.setValue(try validateStrongETag(etag), forHTTPHeaderField: "If-Match")
        case .locked(let lock)?:
            guard lock.resourceURL == url else {
                throw WebDAVError.unsafeExclusiveLock
            }
            addLockCondition(lock, to: &request)
        case nil:
            break
        }
        request.httpBody = data
        return try await transport.send(request, maximumResponseBytes: responseLimit)
    }

    private func delete(url: URL, condition: WebDAVUploadCondition) async throws {
        var request = request(method: "DELETE", url: url)
        switch condition {
        case .matching(let etag):
            request.setValue(try validateStrongETag(etag), forHTTPHeaderField: "If-Match")
        case .createOnly:
            request.setValue("*", forHTTPHeaderField: "If-Match")
        case .locked(let lock):
            guard lock.resourceURL == url else {
                throw WebDAVError.unsafeExclusiveLock
            }
            addLockCondition(lock, to: &request)
        }
        let response = try await transport.send(request, maximumResponseBytes: responseLimit)
        try validateSuccess(response.statusCode)
    }

    private func acquireExclusiveWriteLock(at url: URL) async throws -> WebDAVWriteLock {
        var request = request(method: "LOCK", url: url)
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("Second-120", forHTTPHeaderField: "Timeout")
        request.setValue("*", forHTTPHeaderField: "If-Match")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>
            """.utf8
        )

        let response = try await transport.send(request, maximumResponseBytes: responseLimit)
        if response.statusCode == 405 || response.statusCode == 501 {
            throw WebDAVError.exclusiveLockUnavailable
        }
        guard response.statusCode == 200 else {
            try validateSuccess(response.statusCode)
            throw WebDAVError.unsafeExclusiveLock
        }
        guard let header = response.value(forHTTPHeaderField: "Lock-Token") else {
            throw WebDAVError.unsafeExclusiveLock
        }
        let token = try validateLockToken(header)
        guard let discovery = LockDiscoveryXML.parse(response.data),
              discovery.token == token,
              discovery.isExclusiveWrite,
              discovery.depth == "0",
              (60...600).contains(discovery.timeoutSeconds) else {
            throw WebDAVError.unsafeExclusiveLock
        }
        return WebDAVWriteLock(token: token, resourceURL: url)
    }

    private func releaseExclusiveWriteLock(_ lock: WebDAVWriteLock, at url: URL) async throws {
        guard lock.resourceURL == url else {
            throw WebDAVError.unsafeExclusiveLock
        }
        var request = request(method: "UNLOCK", url: url)
        request.setValue(lock.token, forHTTPHeaderField: "Lock-Token")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let response = try await transport.send(request, maximumResponseBytes: responseLimit)
        guard response.statusCode == 204 else {
            try validateSuccess(response.statusCode)
            throw WebDAVError.unsafeExclusiveLock
        }
    }

    private func testExclusiveLockSafety(at url: URL, initialData: Data) async throws {
        let changedData = Data("PGYMacMenu locked probe \(UUID().uuidString)".utf8)
        let staleData = Data("PGYMacMenu stale probe \(UUID().uuidString)".utf8)
        let firstLock: WebDAVWriteLock
        do {
            firstLock = try await acquireExclusiveWriteLock(at: url)
        } catch WebDAVError.methodNotAllowed {
            throw WebDAVError.exclusiveLockUnavailable
        } catch WebDAVError.serverError(statusCode: 501) {
            throw WebDAVError.exclusiveLockUnavailable
        }

        var firstLockIsActive = true
        do {
            var conflictingLock: WebDAVWriteLock?
            do {
                conflictingLock = try await acquireExclusiveWriteLock(at: url)
            } catch WebDAVError.locked {
                // Expected: a second exclusive lock must conflict.
            }
            if let conflictingLock {
                try? await releaseExclusiveWriteLock(conflictingLock, at: url)
                throw WebDAVError.unsafeExclusiveLock
            }

            let unprotectedResponse = try await putResponse(initialData + Data([0]), to: url, condition: nil)
            guard unprotectedResponse.statusCode == 412 || unprotectedResponse.statusCode == 423 else {
                try validateSuccess(unprotectedResponse.statusCode)
                throw WebDAVError.unsafeExclusiveLock
            }
            let unchanged = try await readProbe(at: url)
            guard unchanged.data == initialData else {
                throw WebDAVError.unsafeExclusiveLock
            }

            _ = try await putRaw(changedData, to: url, condition: .locked(firstLock))
            let changed = try await readProbe(at: url)
            guard changed.data == changedData else {
                throw WebDAVError.unsafeExclusiveLock
            }

            try await releaseExclusiveWriteLock(firstLock, at: url)
            firstLockIsActive = false

            let staleResponse = try await putResponse(staleData, to: url, condition: .locked(firstLock))
            guard staleResponse.statusCode == 412 || staleResponse.statusCode == 423 else {
                try validateSuccess(staleResponse.statusCode)
                throw WebDAVError.unsafeExclusiveLock
            }
            let stillChanged = try await readProbe(at: url)
            guard stillChanged.data == changedData else {
                throw WebDAVError.unsafeExclusiveLock
            }

            let cleanupLock = try await acquireExclusiveWriteLock(at: url)
            do {
                try await delete(url: url, condition: .locked(cleanupLock))
                try await waitForProbeDeletion(at: url)
            } catch {
                try? await releaseExclusiveWriteLock(cleanupLock, at: url)
                throw error
            }
        } catch {
            if firstLockIsActive {
                try? await releaseExclusiveWriteLock(firstLock, at: url)
            }
            throw error
        }
    }

    private func addLockCondition(_ lock: WebDAVWriteLock, to request: inout URLRequest) {
        request.setValue("(\(lock.token))", forHTTPHeaderField: "If")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    }

    private func propfind(url: URL, depth: Int) async throws -> WebDAVTransportResponse {
        guard depth == 0 || depth == 1 else {
            throw WebDAVError.invalidResponse
        }
        var request = request(method: "PROPFIND", url: url)
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>
            """.utf8
        )
        let response = try await transport.send(request, maximumResponseBytes: responseLimit)
        guard response.data.count <= responseLimit else {
            throw WebDAVError.responseTooLarge(maxBytes: responseLimit)
        }
        return response
    }

    private func immutableChild(named name: String) throws -> WebDAVCollectionChild {
        guard isSafePathSegment(name) else {
            throw WebDAVError.invalidRelativePath
        }
        let collectionURL = try immutableCollectionURL()
        let url = collectionURL.appendingPathComponent(name, isDirectory: false)
        return WebDAVCollectionChild(name: name, url: url)
    }

    private func downloadImmutableChild(at url: URL) async throws -> Data? {
        _ = try validateImmutableChildURL(url)
        let response = try await send(method: "GET", url: url)
        if response.statusCode == 404 {
            return nil
        }
        try validateSuccess(response.statusCode)
        return response.data
    }

    private func waitForProbeDeletion(at url: URL) async throws {
        for (index, delay) in Self.probeReadRetryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let response = try await send(method: "GET", url: url)
            if response.statusCode == 404 {
                return
            }
            try validateSuccess(response.statusCode)
            if index == Self.probeReadRetryDelays.count - 1 {
                throw WebDAVError.probeCleanupFailed
            }
        }
        throw WebDAVError.probeCleanupFailed
    }

    private func cleanupConditionalCreateProbe(
        childURL: URL,
        childWasCreated: Bool,
        collectionURL: URL
    ) async throws {
        var cleanupFailed = false

        if childWasCreated {
            do {
                try await delete(url: childURL, condition: .createOnly)
                try await waitForProbeDeletion(at: childURL)
            } catch {
                cleanupFailed = true
            }
        }

        do {
            try await delete(url: collectionURL, condition: .createOnly)
            try await waitForCollectionDeletion(at: collectionURL)
        } catch {
            cleanupFailed = true
        }

        if cleanupFailed {
            throw WebDAVError.probeCleanupFailed
        }
    }

    private func waitForCollectionDeletion(at url: URL) async throws {
        for (index, delay) in Self.probeReadRetryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            let response = try await propfind(url: url, depth: 0)
            if response.statusCode == 404 {
                return
            }
            try validateSuccess(response.statusCode)
            if index == Self.probeReadRetryDelays.count - 1 {
                throw WebDAVError.probeCleanupFailed
            }
        }
        throw WebDAVError.probeCleanupFailed
    }

    private func isSuccessful(_ item: WebDAVMultiStatusItem) -> Bool {
        if let statusCode = item.statusCode {
            return (200..<300).contains(statusCode)
        }
        return item.hasSuccessfulProperties
    }

    private func validatedDirectChild(
        _ url: URL,
        itemIsCollection: Bool,
        collectionURL: URL
    ) throws -> WebDAVCollectionChild {
        guard !itemIsCollection,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              !urlHasTrailingSlash(url),
              isExpectedOrigin(url) else {
            throw WebDAVError.invalidCollectionResponse
        }
        let collectionSegments = try decodedPathSegments(collectionURL)
        let childSegments = try decodedPathSegments(url)
        guard childSegments.count == collectionSegments.count + 1,
              Array(childSegments.dropLast()) == collectionSegments,
              let name = childSegments.last,
              isSafePathSegment(name) else {
            throw WebDAVError.invalidCollectionResponse
        }

        let expected = try immutableChild(named: name)
        let expectedSegments = try decodedPathSegments(expected.url)
        guard childSegments == expectedSegments else {
            throw WebDAVError.invalidCollectionResponse
        }
        return expected
    }

    private func validateImmutableChildURL(_ url: URL) throws -> WebDAVCollectionChild {
        try validatedDirectChild(
            url,
            itemIsCollection: false,
            collectionURL: immutableCollectionURL()
        )
    }

    private func resolveDAVHref(_ href: String, relativeTo pageURL: URL) throws -> URL {
        guard href.utf8.count <= 8_192,
              !href.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
              isExpectedOrigin(url),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw WebDAVError.invalidCollectionResponse
        }
        return url
    }

    private func validatePaginationURL(_ url: URL, collectionURL: URL) throws -> URL {
        guard url.absoluteString.utf8.count <= 8_192,
              isExpectedOrigin(url),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              try decodedPathSegments(url) == decodedPathSegments(collectionURL) else {
            throw WebDAVError.invalidCollectionResponse
        }
        return url
    }

    private func isSameCollectionURL(_ url: URL, as collectionURL: URL) throws -> Bool {
        guard isExpectedOrigin(url),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw WebDAVError.invalidCollectionResponse
        }
        return try decodedPathSegments(url) == decodedPathSegments(collectionURL)
    }

    private func isExpectedOrigin(_ url: URL) -> Bool {
        let expectedPort = configuration.rootURL.port ?? 443
        let candidatePort = url.port ?? 443
        return url.scheme?.lowercased() == "https"
            && url.host?.caseInsensitiveCompare(configuration.rootURL.host ?? "") == .orderedSame
            && candidatePort == expectedPort
    }

    private func decodedPathSegments(_ url: URL) throws -> [String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasPrefix("/") else {
            throw WebDAVError.invalidCollectionResponse
        }
        var encodedSegments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard encodedSegments.first == "" else {
            throw WebDAVError.invalidCollectionResponse
        }
        encodedSegments.removeFirst()
        if encodedSegments.last == "" {
            encodedSegments.removeLast()
        }
        guard !encodedSegments.contains("") else {
            throw WebDAVError.invalidCollectionResponse
        }

        return try encodedSegments.map { encodedSegment in
            guard let segment = encodedSegment.removingPercentEncoding,
                  isSafePathSegment(segment) else {
                throw WebDAVError.invalidCollectionResponse
            }
            return segment
        }
    }

    private func urlHasTrailingSlash(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedPath.hasSuffix("/") == true
    }

    private func isSafePathSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("?")
            && !value.contains("#")
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private func nextLinkReference(from header: String) throws -> String? {
        guard header.utf8.count <= 16_384,
              !header.unicodeScalars.contains(where: {
                  ($0.value < 0x20 && $0.value != 0x09) || $0.value == 0x7f
              }) else {
            throw WebDAVError.invalidCollectionResponse
        }

        let values = try splitHeaderValue(header, separator: ",", angleBrackets: true)
        var nextReference: String?
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "<", let closingIndex = trimmed.firstIndex(of: ">") else {
                throw WebDAVError.invalidCollectionResponse
            }
            let referenceStart = trimmed.index(after: trimmed.startIndex)
            let reference = String(trimmed[referenceStart..<closingIndex])
            guard !reference.isEmpty else {
                throw WebDAVError.invalidCollectionResponse
            }

            let parametersStart = trimmed.index(after: closingIndex)
            let parameterText = String(trimmed[parametersStart...])
            let trimmedParameterText = parameterText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedParameterText.isEmpty || trimmedParameterText.first == ";" else {
                throw WebDAVError.invalidCollectionResponse
            }
            let parameters = try splitHeaderValue(parameterText, separator: ";", angleBrackets: false)
            var relations: [String] = []
            for (index, parameter) in parameters.enumerated() {
                let candidate = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty {
                    guard index == 0 else {
                        throw WebDAVError.invalidCollectionResponse
                    }
                    continue
                }
                guard let equalsIndex = candidate.firstIndex(of: "=") else {
                    throw WebDAVError.invalidCollectionResponse
                }
                let name = candidate[..<equalsIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard name == "rel" else { continue }
                guard relations.isEmpty else {
                    throw WebDAVError.invalidCollectionResponse
                }
                let rawValue = String(candidate[candidate.index(after: equalsIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rawValue.first != "\"", rawValue.contains(where: { $0.isWhitespace }) {
                    throw WebDAVError.invalidCollectionResponse
                }
                let relationValue = try unquoteLinkParameter(rawValue)
                relations = relationValue.split(whereSeparator: { $0.isWhitespace })
                    .map { $0.lowercased() }
            }

            if relations.contains("next") {
                guard nextReference == nil else {
                    throw WebDAVError.invalidCollectionResponse
                }
                nextReference = reference
            }
        }
        return nextReference
    }

    private func splitHeaderValue(
        _ value: String,
        separator: Character,
        angleBrackets: Bool
    ) throws -> [String] {
        var result: [String] = []
        var current = ""
        var insideAngles = false
        var insideQuotes = false
        var escaped = false

        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if insideQuotes && character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" && !insideAngles {
                insideQuotes.toggle()
                current.append(character)
                continue
            }
            if angleBrackets && !insideQuotes {
                if character == "<" {
                    guard !insideAngles else {
                        throw WebDAVError.invalidCollectionResponse
                    }
                    insideAngles = true
                } else if character == ">" {
                    guard insideAngles else {
                        throw WebDAVError.invalidCollectionResponse
                    }
                    insideAngles = false
                }
            }
            if character == separator && !insideAngles && !insideQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !insideAngles, !insideQuotes, !escaped else {
            throw WebDAVError.invalidCollectionResponse
        }
        result.append(current)
        return result
    }

    private func unquoteLinkParameter(_ value: String) throws -> String {
        guard !value.isEmpty else {
            throw WebDAVError.invalidCollectionResponse
        }
        guard value.first == "\"" else {
            return value
        }
        guard value.last == "\"", value.count >= 2 else {
            throw WebDAVError.invalidCollectionResponse
        }

        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                throw WebDAVError.invalidCollectionResponse
            } else {
                result.append(character)
            }
        }
        guard !escaped else {
            throw WebDAVError.invalidCollectionResponse
        }
        return result
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

    private func usableStrongETag(from response: WebDAVTransportResponse) -> String? {
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            return nil
        }
        return try? validateStrongETag(etag)
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

    private func validateLockToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count <= 2_048,
              token.first == "<",
              token.last == ">",
              token.count > 2 else {
            throw WebDAVError.unsafeExclusiveLock
        }
        let inner = String(token.dropFirst().dropLast())
        guard !inner.isEmpty,
              !inner.unicodeScalars.contains(where: {
                  $0.value <= 0x20 || $0.value == 0x3c || $0.value == 0x3e || $0.value == 0x7f
              }),
              let uri = URL(string: inner),
              uri.scheme != nil else {
            throw WebDAVError.unsafeExclusiveLock
        }
        return token
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
