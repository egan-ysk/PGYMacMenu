import Darwin
import Foundation
import XCTest
@testable import PGYMacMenu

final class PgyerClientTests: XCTestCase {
    func testCOSUploadEndpointAcceptsCleanHTTPSURL() throws {
        let endpoint = try PgyerNetworkSecurityPolicy.validatedCOSEndpoint(
            "https://cos.example.com:8443/releases/app.apk"
        )

        XCTAssertEqual(endpoint.absoluteString, "https://cos.example.com:8443/releases/app.apk")
    }

    func testCOSUploadEndpointRejectsHTTP() {
        XCTAssertThrowsError(
            try PgyerNetworkSecurityPolicy.validatedCOSEndpoint("http://cos.example.com/releases/app.apk")
        )
    }

    func testCOSUploadEndpointRejectsMissingHost() {
        XCTAssertThrowsError(
            try PgyerNetworkSecurityPolicy.validatedCOSEndpoint("https:///releases/app.apk")
        )
    }

    func testCOSUploadEndpointRejectsUserInfo() {
        XCTAssertThrowsError(
            try PgyerNetworkSecurityPolicy.validatedCOSEndpoint("https://user:password@cos.example.com/app.apk")
        )
    }

    func testCOSUploadEndpointRejectsQueryAndFragment() {
        XCTAssertThrowsError(
            try PgyerNetworkSecurityPolicy.validatedCOSEndpoint("https://cos.example.com/app.apk?signature=secret")
        )
        XCTAssertThrowsError(
            try PgyerNetworkSecurityPolicy.validatedCOSEndpoint("https://cos.example.com/app.apk#fragment")
        )
    }

    func testCOSUploadRedirectRejectsSameOrigin() throws {
        let source = try XCTUnwrap(URL(string: "https://cos.example.com/upload"))
        let destination = try XCTUnwrap(URL(string: "https://cos.example.com/upload-v2"))

        XCTAssertFalse(
            PgyerNetworkSecurityPolicy.permitsRedirect(from: source, to: destination, statusCode: 307)
        )
        XCTAssertFalse(
            PgyerNetworkSecurityPolicy.permitsRedirect(from: source, to: destination, statusCode: 308)
        )
    }

    func testCOSUploadRedirectRejectsCrossOrigin() throws {
        let source = try XCTUnwrap(URL(string: "https://cos.example.com/upload"))
        let destination = try XCTUnwrap(URL(string: "https://attacker.example/upload"))

        XCTAssertFalse(
            PgyerNetworkSecurityPolicy.permitsRedirect(from: source, to: destination, statusCode: 307)
        )
    }

    func testCOSUploadRedirectRejectsHTTPSDowngrade() throws {
        let source = try XCTUnwrap(URL(string: "https://cos.example.com/upload"))
        let destination = try XCTUnwrap(URL(string: "http://cos.example.com/upload"))

        XCTAssertFalse(
            PgyerNetworkSecurityPolicy.permitsRedirect(from: source, to: destination, statusCode: 307)
        )
    }

    func testBuildInfoRequestKeepsOfficialGETProtocolOutOfPersistentCaches() throws {
        let request = try PgyerClient.buildInfoRequest(
            apiKey: "private key&value",
            buildKey: "apps/example.apk"
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }),
            ["_api_key": "private key&value", "buildKey": "apps/example.apk"]
        )
    }

    func testMultipartBodyUsesPrivateDirectoriesAndFileThenCleansUp() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let sourceData = Data("private-apk-content".utf8)
        try sourceData.write(to: fixture.sourceURL)

        let multipart = try MultipartBodyFile.make(
            fields: ["signature": "private-signature", "key": "apps/key.apk"],
            fileFieldName: "file",
            fileURL: fixture.sourceURL,
            temporaryDirectory: fixture.baseURL
        )
        let storageURL = multipart.fileURL.deletingLastPathComponent()

        XCTAssertEqual(storageURL.lastPathComponent, MultipartBodyFile.storageDirectoryName)
        XCTAssertEqual(try permissions(at: storageURL), 0o700)
        XCTAssertEqual(try permissions(at: multipart.fileURL), 0o600)
        XCTAssertTrue(multipart.fileURL.lastPathComponent.hasSuffix(".multipart"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: storageURL.path)
                .contains(where: { $0.hasSuffix(".partial") })
        )

        let body = try Data(contentsOf: multipart.fileURL)
        XCTAssertTrue(body.contains(sourceData))
        XCTAssertTrue(body.contains(Data("private-signature".utf8)))

        try multipart.cleanup()
        try multipart.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: multipart.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testMultipartBodyCreationFailureRemovesTemporaryFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }

        XCTAssertThrowsError(
            try MultipartBodyFile.make(
                fields: ["signature": "private-signature"],
                fileFieldName: "file",
                fileURL: fixture.sourceURL,
                temporaryDirectory: fixture.baseURL
            )
        ) { error in
            XCTAssertEqual(error as? MultipartBodyFileError, .storageUnavailable)
        }

        let storageURL = MultipartBodyFile.storageDirectoryURL(in: fixture.baseURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storageURL.path), [])
    }

    func testMultipartBodyDeinitRemovesTemporaryFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        try Data("apk".utf8).write(to: fixture.sourceURL)

        var multipart: MultipartBodyFile? = try MultipartBodyFile.make(
            fields: [:],
            fileFieldName: "file",
            fileURL: fixture.sourceURL,
            temporaryDirectory: fixture.baseURL
        )
        let bodyURL = try XCTUnwrap(multipart?.fileURL)

        multipart = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path))
    }

    func testMultipartBodyRemovesOnlyExpiredFilesOwnedByDeadProcesses() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        try Data("apk".utf8).write(to: fixture.sourceURL)
        let fileManager = FileManager.default
        let storageURL = MultipartBodyFile.storageDirectoryURL(in: fixture.baseURL)
        try fileManager.createDirectory(
            at: storageURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let staleURL = storageURL.appendingPathComponent(
            "upload-\(pid_t.max)-\(UUID().uuidString).multipart",
            isDirectory: false
        )
        let activeURL = storageURL.appendingPathComponent(
            "upload-\(getpid())-\(UUID().uuidString).multipart",
            isDirectory: false
        )
        XCTAssertTrue(fileManager.createFile(atPath: staleURL.path, contents: Data("stale".utf8)))
        XCTAssertTrue(fileManager.createFile(atPath: activeURL.path, contents: Data("active".utf8)))
        let now = Date(timeIntervalSince1970: 10_000)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-MultipartBodyFile.staleFileLifetime - 1)],
            ofItemAtPath: staleURL.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-MultipartBodyFile.staleFileLifetime - 1)],
            ofItemAtPath: activeURL.path
        )

        let multipart = try MultipartBodyFile.make(
            fields: [:],
            fileFieldName: "file",
            fileURL: fixture.sourceURL,
            temporaryDirectory: fixture.baseURL,
            now: now
        )
        defer { try? multipart.cleanup() }

        XCTAssertFalse(fileManager.fileExists(atPath: staleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: activeURL.path))
    }

    func testMultipartBodyRejectsHeaderLineBreaksWithoutLeavingAFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        try Data("apk".utf8).write(to: fixture.sourceURL)

        XCTAssertThrowsError(
            try MultipartBodyFile.make(
                fields: ["signature\r\nInjected": "value"],
                fileFieldName: "file",
                fileURL: fixture.sourceURL,
                temporaryDirectory: fixture.baseURL
            )
        ) { error in
            XCTAssertEqual(error as? MultipartBodyFileError, .unsafeMetadata)
        }

        let storageURL = MultipartBodyFile.storageDirectoryURL(in: fixture.baseURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storageURL.path), [])
    }

    private func makeFixture() throws -> (baseURL: URL, sourceURL: URL) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PGYMacMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return (baseURL, baseURL.appendingPathComponent("source.apk", isDirectory: false))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
