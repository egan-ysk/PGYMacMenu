import Darwin
import Foundation

final class PgyerClient {
    private static let getCOSTokenURL = URL(string: "https://api.pgyer.com/apiv2/app/getCOSToken")!
    private static let buildInfoURL = URL(string: "https://api.pgyer.com/apiv2/app/buildInfo")!
    private static let buildInfoMaxRetryCount = 60
    private static let buildInfoRetryIntervalNanoseconds: UInt64 = 3_000_000_000

    private let redirectDelegate: PgyerRedirectRejectingDelegate
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var currentTask: URLSessionTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        let redirectDelegate = PgyerRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        session.invalidateAndCancel()
    }

    func upload(
        fileURL: URL,
        profile: APIKeyProfile,
        updateInfo: String,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> PgyerResponse {
        let apiKey = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw PGYMacMenuError.missingAPIKey
        }

        progress(.status("正在获取上传凭证..."))
        let token = try await getUploadToken(profile: profile, updateInfo: updateInfo)

        try Task.checkCancellation()
        progress(.fileUpload(fraction: 0, text: "正在上传 APK..."))
        try await uploadFileToCos(fileURL: fileURL, uploadToken: token, progress: progress)

        try Task.checkCancellation()
        progress(.status("正在发布应用..."))
        let response = try await waitBuildInfo(apiKey: apiKey, buildKey: token.key, progress: progress)
        progress(.status("上传成功"))
        return response
    }

    private func getUploadToken(profile: APIKeyProfile, updateInfo: String) async throws -> PgyerUploadToken {
        var fields: [String: String] = [
            "_api_key": profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "buildType": "android",
            "buildVersionType": "2"
        ]
        let password = profile.password.trimmingCharacters(in: .whitespacesAndNewlines)
        if password.isEmpty {
            fields["buildInstallType"] = "1"
        } else {
            fields["buildInstallType"] = "2"
            fields["buildPassword"] = password
        }

        let normalizedUpdateInfo = updateInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedUpdateInfo.isEmpty {
            fields["buildUpdateDescription"] = normalizedUpdateInfo
        }

        var request = URLRequest(url: Self.getCOSTokenURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody(fields)

        let (data, response) = try await data(for: request)
        try validateHTTPResponse(response, body: data)

        let tokenResponse = try decoder.decode(PgyerTokenResponse.self, from: data)
        guard tokenResponse.code == 0, let token = tokenResponse.data else {
            throw PGYMacMenuError.invalidResponse(tokenResponse.message ?? "获取上传凭证失败")
        }
        guard !token.key.isEmpty, !token.endpoint.isEmpty, !token.params.isEmpty else {
            throw PGYMacMenuError.invalidResponse("获取上传凭证失败：返回数据不完整")
        }
        return token
    }

    private func uploadFileToCos(
        fileURL: URL,
        uploadToken: PgyerUploadToken,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws {
        let endpoint = try PgyerNetworkSecurityPolicy.validatedCOSEndpoint(uploadToken.endpoint)

        let multipart = try MultipartBodyFile.make(
            fields: uploadToken.params.merging(["x-cos-meta-file-name": fileURL.lastPathComponent]) { current, _ in current },
            fileFieldName: "file",
            fileURL: fileURL
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")

        let uploader = URLSessionUploadDelegate(progress: progress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await uploader.upload(request: request, bodyFileURL: multipart.fileURL)
        } catch {
            do {
                try multipart.cleanup()
            } catch {
                throw MultipartBodyFileError.cleanupFailed
            }
            throw error
        }
        try multipart.cleanup()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PGYMacMenuError.invalidResponse("上传文件失败：服务器响应无效")
        }
        guard httpResponse.statusCode == 204 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PGYMacMenuError.httpStatus(httpResponse.statusCode, body)
        }
    }

    private func waitBuildInfo(
        apiKey: String,
        buildKey: String,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> PgyerResponse {
        for index in 1...Self.buildInfoMaxRetryCount {
            try Task.checkCancellation()
            progress(.polling(index: index, total: Self.buildInfoMaxRetryCount))

            let request = try Self.buildInfoRequest(apiKey: apiKey, buildKey: buildKey)
            let (data, response) = try await data(for: request)
            try validateHTTPResponse(response, body: data)

            let pgyResponse = try decoder.decode(PgyerResponse.self, from: data)
            if pgyResponse.code == 0 {
                return pgyResponse
            }
            if pgyResponse.code == 1216 {
                throw PGYMacMenuError.invalidResponse(pgyResponse.message ?? "应用发布失败")
            }
            if pgyResponse.code != 1246 && pgyResponse.code != 1247 {
                throw PGYMacMenuError.invalidResponse(pgyResponse.message ?? "获取发布结果失败")
            }
            try await Task.sleep(nanoseconds: Self.buildInfoRetryIntervalNanoseconds)
        }
        throw PGYMacMenuError.stillPublishing
    }

    static func buildInfoRequest(apiKey: String, buildKey: String) throws -> URLRequest {
        var components = URLComponents(url: Self.buildInfoURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "_api_key", value: apiKey),
            URLQueryItem(name: "buildKey", value: buildKey)
        ]
        guard let url = components.url else {
            throw PGYMacMenuError.invalidResponse("发布结果地址无效")
        }

        // Pgyer's v2 buildInfo API only supports GET. Keep its credential-bearing
        // URL out of persistent caches and do not allow cookie persistence.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        defer {
            currentTask = nil
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let response else {
                        continuation.resume(throwing: PGYMacMenuError.invalidResponse("服务器响应无效"))
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                currentTask = task
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, body: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PGYMacMenuError.invalidResponse("服务器响应无效")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: body, encoding: .utf8) ?? ""
            throw PGYMacMenuError.httpStatus(httpResponse.statusCode, responseBody)
        }
    }

    private func formURLEncodedBody(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum PgyerNetworkSecurityPolicy {
    static func validatedCOSEndpoint(_ rawValue: String) throws -> URL {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.percentEncodedUser == nil,
              components.percentEncodedPassword == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              let url = components.url else {
            throw PGYMacMenuError.invalidResponse("上传地址无效：仅允许安全的 HTTPS 地址")
        }
        return url
    }

    // A multipart upload contains both the APK and short-lived signing fields.
    // Reject every redirect unless the COS protocol explicitly documents one.
    static func permitsRedirect(
        from _: URL,
        to _: URL,
        statusCode _: Int
    ) -> Bool {
        false
    }
}

private final class PgyerRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = response.url,
              let destinationURL = request.url,
              PgyerNetworkSecurityPolicy.permitsRedirect(
                  from: sourceURL,
                  to: destinationURL,
                  statusCode: response.statusCode
              ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum MultipartBodyFileError: LocalizedError, Equatable {
    case unsafeMetadata
    case storageUnavailable
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .unsafeMetadata:
            return "上传文件名或表单字段无效"
        case .storageUnavailable:
            return "无法创建受保护的上传临时数据"
        case .cleanupFailed:
            return "无法清理上传临时数据，请重新启动应用后重试"
        }
    }
}

final class MultipartBodyFile {
    static let storageDirectoryName = "com.egan.PGYMacMenu.MultipartUploads"
    static let staleFileLifetime: TimeInterval = 60 * 60

    let fileURL: URL
    let boundary: String

    private init(fileURL: URL, boundary: String) {
        self.fileURL = fileURL
        self.boundary = boundary
    }

    deinit {
        try? cleanup()
    }

    static func storageDirectoryURL(in temporaryDirectory: URL) -> URL {
        temporaryDirectory.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    static func make(
        fields: [String: String],
        fileFieldName: String,
        fileURL sourceFileURL: URL,
        temporaryDirectory: URL? = nil,
        now: Date = Date()
    ) throws -> MultipartBodyFile {
        let fileManager = FileManager.default
        let rootURL = try prepareStorageDirectory(at: temporaryDirectory ?? fileManager.temporaryDirectory, now: now)
        let destinationURL = rootURL.appendingPathComponent(
            "upload-\(getpid())-\(UUID().uuidString).multipart",
            isDirectory: false
        )

        do {
            let boundary = "Boundary-\(UUID().uuidString)"
            try writeBody(
                fields: fields,
                fileFieldName: fileFieldName,
                sourceFileURL: sourceFileURL,
                boundary: boundary,
                destinationURL: destinationURL
            )
            try verifyItem(
                at: destinationURL,
                expectedType: .typeRegular,
                expectedPermissions: 0o600
            )
            return MultipartBodyFile(fileURL: destinationURL, boundary: boundary)
        } catch {
            do {
                try removeIfPresent(destinationURL)
            } catch {
                throw MultipartBodyFileError.cleanupFailed
            }
            if let multipartError = error as? MultipartBodyFileError {
                throw multipartError
            }
            throw MultipartBodyFileError.storageUnavailable
        }
    }

    func cleanup() throws {
        do {
            try Self.removeIfPresent(fileURL)
        } catch {
            throw MultipartBodyFileError.cleanupFailed
        }
    }

    private static func prepareStorageDirectory(at temporaryDirectory: URL, now: Date) throws -> URL {
        let fileManager = FileManager.default
        let rootURL = storageDirectoryURL(in: temporaryDirectory)
        do {
            if !fileManager.fileExists(atPath: rootURL.path) {
                do {
                    try fileManager.createDirectory(
                        at: rootURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: NSNumber(value: 0o700)]
                    )
                } catch {
                    guard fileManager.fileExists(atPath: rootURL.path) else {
                        throw error
                    }
                }
            }
            try verifyItem(at: rootURL, expectedType: .typeDirectory)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: rootURL.path
            )
            try verifyItem(at: rootURL, expectedType: .typeDirectory, expectedPermissions: 0o700)
            try removeStaleFiles(in: rootURL, now: now)
            return rootURL
        } catch let error as MultipartBodyFileError {
            throw error
        } catch {
            throw MultipartBodyFileError.storageUnavailable
        }
    }

    private static func writeBody(
        fields: [String: String],
        fileFieldName: String,
        sourceFileURL: URL,
        boundary: String,
        destinationURL: URL
    ) throws {
        let escapedFileFieldName = try escape(fileFieldName)
        let escapedFilename = try escape(sourceFileURL.lastPathComponent)
        let escapedFields = try fields.map { (try escape($0.key), $0.value) }.sorted { $0.0 < $1.0 }
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let descriptor = open(destinationURL.path, flags, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw MultipartBodyFileError.storageUnavailable
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            close(descriptor)
            throw MultipartBodyFileError.storageUnavailable
        }

        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            for (escapedKey, value) in escapedFields {
                try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
                try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(escapedKey)\"\r\n\r\n".utf8))
                try output.write(contentsOf: Data(value.utf8))
                try output.write(contentsOf: Data("\r\n".utf8))
            }

            try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(escapedFileFieldName)\"; filename=\"\(escapedFilename)\"\r\n".utf8))
            try output.write(contentsOf: Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

            let input = try FileHandle(forReadingFrom: sourceFileURL)
            do {
                while true {
                    let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                    if chunk.isEmpty {
                        break
                    }
                    try output.write(contentsOf: chunk)
                }
                try input.close()
            } catch {
                try? input.close()
                throw error
            }

            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
    }

    private static func escape(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw MultipartBodyFileError.unsafeMetadata
        }
        return value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func verifyItem(
        at url: URL,
        expectedType: FileAttributeType,
        expectedPermissions: Int? = nil
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expectedType,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw MultipartBodyFileError.storageUnavailable
        }
        if let expectedPermissions {
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o777 == expectedPermissions else {
                throw MultipartBodyFileError.storageUnavailable
            }
        }
    }

    private static func removeStaleFiles(in rootURL: URL, now: Date) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )
        for entry in entries where shouldRemoveStaleFile(entry, now: now) {
            do {
                try removeIfPresent(entry)
            } catch {
                throw MultipartBodyFileError.cleanupFailed
            }
        }
    }

    private static func shouldRemoveStaleFile(_ url: URL, now: Date) -> Bool {
        let name = url.lastPathComponent
        guard name.hasSuffix(".multipart") else {
            return false
        }
        let stem = name.dropLast(".multipart".count)
        let components = stem.split(separator: "-", maxSplits: 2)
        guard components.count == 3,
              components[0] == "upload",
              let ownerPID = pid_t(components[1]),
              ownerPID > 0,
              UUID(uuidString: String(components[2])) != nil else {
            return false
        }

        // Never remove a file while its creating process may still be alive,
        // regardless of age. This also protects concurrent app instances.
        errno = 0
        if kill(ownerPID, 0) == 0 || errno == EPERM {
            return false
        }
        guard errno == ESRCH,
              let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return now.timeIntervalSince(modificationDate) >= staleFileLifetime
    }

    private static func removeIfPresent(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            guard !fileManager.fileExists(atPath: url.path) else {
                throw error
            }
        }
    }
}

private final class URLSessionUploadDelegate: NSObject, URLSessionDataDelegate {
    private let progress: @Sendable (UploadProgress) -> Void
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var responseData = Data()
    private var task: URLSessionUploadTask?
    private var session: URLSession?

    init(progress: @escaping @Sendable (UploadProgress) -> Void) {
        self.progress = progress
    }

    deinit {
        task?.cancel()
        session?.invalidateAndCancel()
        responseData.removeAll(keepingCapacity: false)
    }

    func upload(request: URLRequest, bodyFileURL: URL) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 100
                configuration.timeoutIntervalForResource = 100
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never
                configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.uploadTask(with: request, fromFile: bodyFileURL)
                self.task = task
                task.resume()
            }
        } onCancel: {
            task?.cancel()
            session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else {
            return
        }
        let fraction = max(0, min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        let text = "\(readableFileSize(totalBytesSent))/\(readableFileSize(totalBytesExpectedToSend))   \(Int(fraction * 100))%"
        progress(.fileUpload(fraction: fraction, text: text))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = response.url,
              let destinationURL = request.url,
              PgyerNetworkSecurityPolicy.permitsRedirect(
                  from: sourceURL,
                  to: destinationURL,
                  statusCode: response.statusCode
              ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            responseData.removeAll(keepingCapacity: false)
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            self.task = nil
            self.continuation = nil
        }

        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let response = task.response else {
            continuation?.resume(throwing: PGYMacMenuError.invalidResponse("服务器响应无效"))
            return
        }
        continuation?.resume(returning: (responseData, response))
    }
}
