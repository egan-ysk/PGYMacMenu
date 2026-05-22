import Foundation

final class PgyerClient {
    private static let getCOSTokenURL = URL(string: "https://api.pgyer.com/apiv2/app/getCOSToken")!
    private static let buildInfoURL = URL(string: "https://api.pgyer.com/apiv2/app/buildInfo")!
    private static let buildInfoMaxRetryCount = 60
    private static let buildInfoRetryIntervalNanoseconds: UInt64 = 3_000_000_000

    private let session: URLSession
    private let decoder = JSONDecoder()
    private var currentTask: URLSessionTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
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
        guard let endpoint = URL(string: uploadToken.endpoint) else {
            throw PGYMacMenuError.invalidResponse("上传地址无效")
        }

        let multipart = try MultipartBodyFile.make(
            fields: uploadToken.params.merging(["x-cos-meta-file-name": fileURL.lastPathComponent]) { current, _ in current },
            fileFieldName: "file",
            fileURL: fileURL
        )
        defer {
            try? FileManager.default.removeItem(at: multipart.fileURL)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")

        let uploader = URLSessionUploadDelegate(progress: progress)
        let (data, response) = try await uploader.upload(request: request, bodyFileURL: multipart.fileURL)
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

            var components = URLComponents(url: Self.buildInfoURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "_api_key", value: apiKey),
                URLQueryItem(name: "buildKey", value: buildKey)
            ]
            guard let url = components.url else {
                throw PGYMacMenuError.invalidResponse("发布结果地址无效")
            }

            let (data, response) = try await data(for: URLRequest(url: url))
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

private struct MultipartBodyFile {
    var fileURL: URL
    var boundary: String

    static func make(fields: [String: String], fileFieldName: String, fileURL sourceFileURL: URL) throws -> MultipartBodyFile {
        let boundary = "Boundary-\(UUID().uuidString)"
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PGYMacMenu-\(UUID().uuidString).multipart")

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? output.close()
        }

        for (key, value) in fields {
            try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(escape(key))\"\r\n\r\n".utf8))
            try output.write(contentsOf: Data(value.utf8))
            try output.write(contentsOf: Data("\r\n".utf8))
        }

        try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(escape(fileFieldName))\"; filename=\"\(escape(sourceFileURL.lastPathComponent))\"\r\n".utf8))
        try output.write(contentsOf: Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

        let input = try FileHandle(forReadingFrom: sourceFileURL)
        defer {
            try? input.close()
        }
        while true {
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try output.write(contentsOf: chunk)
        }

        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return MultipartBodyFile(fileURL: destinationURL, boundary: boundary)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
