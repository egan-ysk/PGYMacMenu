import Foundation
import XCTest
@testable import PGYMacMenu

final class WebDAVClientTests: XCTestCase {
    func testDefaultRelativePathPreservesVersionOneLocation() throws {
        let configuration = try WebDAVConfiguration(
            rootURL: try XCTUnwrap(URL(string: "https://dav.example.com/root")),
            username: "user",
            password: "password"
        )

        XCTAssertEqual(configuration.relativePath, "PGYMacMenu.sync")
        XCTAssertEqual(
            try configuration.resolvedResourceURL().absoluteString,
            "https://dav.example.com/root/PGYMacMenu.sync"
        )
    }

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

    func testJianguoyunRootURLMustPointUnderDav() throws {
        XCTAssertThrowsError(
            try makeConfiguration(root: "https://dav.jianguoyun.com/")
        ) { error in
            XCTAssertEqual(error as? WebDAVError, .invalidJianguoyunRootURL)
        }

        let configuration = try makeConfiguration(root: "https://dav.jianguoyun.com/dav/")
        XCTAssertEqual(configuration.rootURL.absoluteString, "https://dav.jianguoyun.com/dav/")
    }

    func testCodableDecodeRevalidatesConfiguration() throws {
        let encoded = Data(
            #"{"rootURL":"http:\/\/dav.example.com","relativePath":"sync.bin","username":"u","password":"p"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(WebDAVConfiguration.self, from: encoded)) { error in
            XCTAssertEqual(error as? WebDAVError, .insecureRootURL)
        }
    }

    func testCodableDecodePreservesExistingRootLevelPath() throws {
        let encoded = Data(
            #"{"rootURL":"https://dav.example.com/root/","relativePath":"PGYMacMenu.sync","username":"u","password":"p"}"#.utf8
        )

        let configuration = try JSONDecoder().decode(WebDAVConfiguration.self, from: encoded)

        XCTAssertEqual(configuration.relativePath, "PGYMacMenu.sync")
        XCTAssertEqual(
            try configuration.resolvedResourceURL().absoluteString,
            "https://dav.example.com/root/PGYMacMenu.sync"
        )
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

    func testDownloadReturnsWeakOrMissingETagAsLockOnlyResource() async throws {
        let body = Data("encrypted".utf8)
        for headers in [["ETag": "W/\"weak\""], [:]] {
            let transport = MockWebDAVTransport { _, _, _ in
                WebDAVTransportResponse(data: body, statusCode: 200, headers: headers)
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            let resource = try await client.download()

            XCTAssertEqual(resource, WebDAVResource(data: body, strongETag: nil))
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
            return WebDAVTransportResponse(statusCode: 201)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let etag = try await client.upload(Data(), condition: .createOnly)

        XCTAssertNil(etag)
    }

    func testUploadIgnoresWeakResponseETagForPostWriteVerification() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(statusCode: 201, headers: ["ETag": "W/\"representation\""])
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let etag = try await client.upload(Data(), condition: .createOnly)

        XCTAssertNil(etag)
    }

    func testUploadRejectsSuccessfulNonCreationStatusForCreateOnlyWrite() async throws {
        for statusCode in [200, 204] {
            let transport = MockWebDAVTransport { request, _, _ in
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                return WebDAVTransportResponse(statusCode: statusCode)
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                _ = try await client.upload(Data(), condition: .createOnly)
                XCTFail("Expected status \(statusCode) to be rejected")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeConditionalCreate)
            }
        }
    }

    func testUploadCreateOnlyMaps412ToPreconditionFailure() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return WebDAVTransportResponse(statusCode: 412)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.upload(Data(), condition: .createOnly)
            XCTFail("Expected precondition failure")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .preconditionFailed)
        }
    }

    func testUploadMatchingConditionStillAccepts204UpdateStatus() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"old\"")
            return WebDAVTransportResponse(statusCode: 204)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let etag = try await client.upload(Data(), condition: .matching("\"old\""))

        XCTAssertNil(etag)
    }

    func testUploadMatchingConditionRejectsNonUpdateSuccessStatus() async throws {
        for statusCode in [201, 202] {
            let transport = MockWebDAVTransport { request, _, _ in
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"old\"")
                return WebDAVTransportResponse(statusCode: statusCode)
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                _ = try await client.upload(Data(), condition: .matching("\"old\""))
                XCTFail("Expected status \(statusCode) to be rejected")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeConditionalUpdate)
            }
        }
    }

    func testUploadLockedConditionRejectsNonUpdateSuccessStatus() async throws {
        let token = "opaquelocktoken:upload-lock"
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                return validLockResponse(token: token)
            case 1:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If"), "(<\(token)>)")
                return WebDAVTransportResponse(statusCode: 201)
            case 2:
                XCTAssertEqual(request.httpMethod, "UNLOCK")
                return WebDAVTransportResponse(statusCode: 204)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)
        let lock = try await client.acquireExclusiveWriteLock()

        do {
            _ = try await client.upload(Data(), condition: .locked(lock))
            XCTFail("Expected resource recreation under a lock to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeExclusiveLock)
        }
        try await client.releaseExclusiveWriteLock(lock)
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

    func testAcquireExclusiveWriteLockUsesStrictRequestAndParsesTokenForUnlock() async throws {
        let token = "opaquelocktoken:test-lock"
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "LOCK")
                XCTAssertEqual(request.url?.absoluteString, "https://dav.example.com/root/PGYMacMenu.sync")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/xml")
                XCTAssertNil(request.value(forHTTPHeaderField: "If"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Lock-Token"))
                let timeout = try XCTUnwrap(request.value(forHTTPHeaderField: "Timeout"))
                let timeoutSeconds = try XCTUnwrap(Int(timeout.replacingOccurrences(of: "Second-", with: "")))
                XCTAssertTrue((60...600).contains(timeoutSeconds))
                let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
                XCTAssertTrue(body.contains("lockscope"))
                XCTAssertTrue(body.contains("exclusive"))
                XCTAssertTrue(body.contains("locktype"))
                XCTAssertTrue(body.contains("write"))
                return validLockResponse(token: token)
            case 1:
                XCTAssertEqual(request.httpMethod, "UNLOCK")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Lock-Token"), "<\(token)>")
                XCTAssertNil(request.value(forHTTPHeaderField: "If"))
                return WebDAVTransportResponse(statusCode: 204)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let lock = try await client.acquireExclusiveWriteLock()
        try await client.releaseExclusiveWriteLock(lock)

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testLockResponseRejectsWrongDAVNamespaceOrDepth() async throws {
        for response in [
            validLockResponse(token: "opaquelocktoken:wrong-namespace", namespace: "urn:not-dav"),
            validLockResponse(token: "opaquelocktoken:wrong-depth", depth: "infinity")
        ] {
            let transport = MockWebDAVTransport { _, _, _ in response }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                _ = try await client.acquireExclusiveWriteLock()
                XCTFail("Expected strict lock discovery validation")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeExclusiveLock)
            }
        }
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

    func testEnsureImmutableCollectionCreatesAndConfirmsSiblingCollection() async throws {
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "MKCOL")
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://dav.example.com/root/PGYMacMenu.sync.d/"
                )
                return WebDAVTransportResponse(statusCode: 201)
            case 1:
                XCTAssertEqual(request.httpMethod, "PROPFIND")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/xml")
                return WebDAVTransportResponse(
                    data: multiStatusXML(
                        collectionHref: "/root/PGYMacMenu.sync.d/",
                        children: []
                    ),
                    statusCode: 207
                )
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let collectionURL = try await client.ensureImmutableCollection()

        XCTAssertEqual(
            collectionURL.absoluteString,
            "https://dav.example.com/root/PGYMacMenu.sync.d/"
        )
    }

    func testEnsureImmutableCollectionAcceptsExistingConfirmedCollection() async throws {
        let transport = MockWebDAVTransport { request, index, _ in
            if index == 0 {
                XCTAssertEqual(request.httpMethod, "MKCOL")
                return WebDAVTransportResponse(statusCode: 405)
            }
            return WebDAVTransportResponse(
                data: multiStatusXML(
                    collectionHref: "https://dav.example.com/root/PGYMacMenu.sync.d/",
                    children: []
                ),
                statusCode: 207
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        _ = try await client.ensureImmutableCollection()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testListImmutableChildrenFollowsSameCollectionPaginationAndDeduplicates() async throws {
        let firstPage = multiStatusXML(
            collectionHref: "/root/PGYMacMenu.sync.d/",
            children: [
                ("/root/PGYMacMenu.sync.d/genesis.pgy", false),
                ("/root/PGYMacMenu.sync.d/a%20b.pgy", false)
            ]
        )
        let secondPage = multiStatusXML(
            collectionHref: "/root/PGYMacMenu.sync.d/",
            children: [
                ("/root/PGYMacMenu.sync.d/genesis.pgy", false),
                ("/root/PGYMacMenu.sync.d/0123456789abcdef.pgy", false)
            ]
        )
        let transport = MockWebDAVTransport { request, index, _ in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            switch index {
            case 0:
                XCTAssertNil(request.url?.query)
                return WebDAVTransportResponse(
                    data: firstPage,
                    statusCode: 207,
                    headers: [
                        "Link": "</root/PGYMacMenu.sync.d/?cursor=2>; rel=\"next\", </previous>; rel=\"prev\""
                    ]
                )
            case 1:
                XCTAssertEqual(request.url?.query, "cursor=2")
                return WebDAVTransportResponse(data: secondPage, statusCode: 207)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        let children = try await client.listImmutableChildren()

        XCTAssertEqual(children.map(\.name), [
            "0123456789abcdef.pgy", "a b.pgy", "genesis.pgy"
        ])
        XCTAssertEqual(
            children[1].url.absoluteString,
            "https://dav.example.com/root/PGYMacMenu.sync.d/a%20b.pgy"
        )
    }

    func testListImmutableChildrenRejectsCrossOriginPaginationBeforeRequestingIt() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(
                data: multiStatusXML(
                    collectionHref: "/root/PGYMacMenu.sync.d/",
                    children: []
                ),
                statusCode: 207,
                headers: ["Link": "<https://attacker.example/next>; rel=\"next\""]
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected unsafe pagination URL to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testListImmutableChildrenRejectsSameOriginPaginationOutsideCollection() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(
                data: multiStatusXML(
                    collectionHref: "/root/PGYMacMenu.sync.d/",
                    children: []
                ),
                statusCode: 207,
                headers: ["Link": "</root/other/?cursor=2>; rel=next"]
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected out-of-collection pagination URL to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testListImmutableChildrenRejectsHrefOutsideCollection() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(
                data: multiStatusXML(
                    collectionHref: "/root/PGYMacMenu.sync.d/",
                    children: [("/root/outside.pgy", false)]
                ),
                statusCode: 207
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected out-of-collection href to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
    }

    func testListImmutableChildrenRejectsPercentEncodedTraversalHref() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(
                data: multiStatusXML(
                    collectionHref: "/root/PGYMacMenu.sync.d/",
                    children: [("/root/PGYMacMenu.sync.d/%2E%2E/outside.pgy", false)]
                ),
                statusCode: 207
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected encoded traversal href to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
    }

    func testListImmutableChildrenRejectsMalformedNextLinkParameters() async throws {
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(
                data: multiStatusXML(
                    collectionHref: "/root/PGYMacMenu.sync.d/",
                    children: []
                ),
                statusCode: 207,
                headers: ["Link": "</root/PGYMacMenu.sync.d/?cursor=2> rel=next"]
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected malformed Link header to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testListImmutableChildrenRejectsPaginationLoop() async throws {
        let page = multiStatusXML(
            collectionHref: "/root/PGYMacMenu.sync.d/",
            children: []
        )
        let transport = MockWebDAVTransport { _, index, _ in
            WebDAVTransportResponse(
                data: page,
                statusCode: 207,
                headers: [
                    "Link": index == 0
                        ? "<?cursor=2>; rel=\"next\""
                        : "<https://dav.example.com/root/PGYMacMenu.sync.d/>; rel=\"next\""
                ]
            )
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected pagination loop to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testListImmutableChildrenRejectsXMLWithEntityDeclaration() async throws {
        let xml = Data(
            """
            <?xml version="1.0"?>
            <!DOCTYPE multistatus [<!ENTITY injected "genesis.pgy">]>
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/root/PGYMacMenu.sync.d/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
              <D:response><D:href>/root/PGYMacMenu.sync.d/&amp;injected;</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            </D:multistatus>
            """.utf8
        )
        let transport = MockWebDAVTransport { _, _, _ in
            WebDAVTransportResponse(data: xml, statusCode: 207)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected XML entity declaration to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .invalidCollectionResponse)
        }
    }

    func testListImmutableChildrenEnforcesResponseLimitForCustomTransport() async throws {
        let xml = multiStatusXML(
            collectionHref: "/root/PGYMacMenu.sync.d/",
            children: []
        )
        let transport = MockWebDAVTransport { _, _, maximumResponseBytes in
            XCTAssertEqual(maximumResponseBytes, 64)
            return WebDAVTransportResponse(data: xml, statusCode: 207)
        }
        let client = try WebDAVClient(
            configuration: makeConfiguration(),
            transport: transport,
            maximumResponseBytes: 64
        )

        do {
            _ = try await client.listImmutableChildren()
            XCTFail("Expected response size limit")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .responseTooLarge(maxBytes: 64))
        }
    }

    func testImmutableChildCreateRequiresAnAttestedStrategy() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTFail("Unattested immutable creation must not send \(request.httpMethod ?? "unknown")")
            return WebDAVTransportResponse(statusCode: 500)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            _ = try await client.createImmutableChild(Data(), named: "genesis.pgy")
            XCTFail("Expected unattested immutable creation to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testAttestedImmutableChildCreateVerifies200Or204Readback() async throws {
        for (actualStatusCode, matchesReadback) in [
            (200, true), (204, true), (200, false), (204, false)
        ] {
            let probeData = LockedDataBox()
            let immutableData = Data("immutable ciphertext".utf8)
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    XCTAssertEqual(request.httpMethod, "MKCOL")
                    return WebDAVTransportResponse(statusCode: 201)
                case 1:
                    XCTAssertEqual(request.httpMethod, "PROPFIND")
                    return WebDAVTransportResponse(
                        data: multiStatusXML(
                            collectionHref: try XCTUnwrap(request.url?.path),
                            children: []
                        ),
                        statusCode: 207
                    )
                case 2:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    probeData.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 201)
                case 3, 5:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(probeData.value),
                        statusCode: 200
                    )
                case 4:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    return WebDAVTransportResponse(statusCode: 412)
                case 6:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    return WebDAVTransportResponse(statusCode: 204)
                case 7:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                case 8:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    return WebDAVTransportResponse(statusCode: 204)
                case 9:
                    XCTAssertEqual(request.httpMethod, "PROPFIND")
                    return WebDAVTransportResponse(statusCode: 404)
                case 10:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.url?.lastPathComponent, "genesis.pgy")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    XCTAssertEqual(request.httpBody, immutableData)
                    return WebDAVTransportResponse(statusCode: actualStatusCode)
                case 11:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: matchesReadback ? immutableData : Data("different ciphertext".utf8),
                        statusCode: 200
                    )
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            try await client.verifyConditionalCreateSafety()
            if matchesReadback {
                let url = try await client.createImmutableChild(immutableData, named: "genesis.pgy")
                XCTAssertEqual(url.lastPathComponent, "genesis.pgy")
            } else {
                do {
                    _ = try await client.createImmutableChild(immutableData, named: "genesis.pgy")
                    XCTFail("Expected mismatched non-201 readback to be rejected")
                } catch let error as WebDAVError {
                    XCTAssertEqual(error, .unsafeConditionalCreate)
                }
            }
        }
    }

    func testImmutableCreateSafetyFallsBackToAttestedAtomicMove() async throws {
        let transport = AtomicMoveNoOverwriteTransport()
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        try await client.verifyImmutableCreateSafety()

        XCTAssertFalse(client.hasConditionalCreateAttestation)
        XCTAssertTrue(client.hasAtomicMoveNoOverwriteAttestation)
        XCTAssertTrue(client.hasImmutableCreateAttestation)
    }

    func testAttestedAtomicMoveCreatesAndDownloadsImmutableChild() async throws {
        let transport = AtomicMoveNoOverwriteTransport()
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)
        let data = Data("atomic immutable ciphertext".utf8)

        try await client.verifyAtomicMoveNoOverwriteSafety()
        let url = try await client.createImmutableChild(data, named: "genesis.pgy")
        let downloaded = try await client.downloadImmutableChild(named: "genesis.pgy")

        XCTAssertEqual(
            url.absoluteString,
            "https://dav.example.com/root/PGYMacMenu.sync.d/genesis.pgy"
        )
        XCTAssertEqual(downloaded, data)

        let requests = await transport.requests
        let moves = requests.filter { $0.httpMethod == "MOVE" }
        XCTAssertGreaterThanOrEqual(moves.count, 3)
        for request in moves {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Destination"))
        }
        let stagingPuts = requests.filter {
            $0.httpMethod == "PUT" && $0.url?.lastPathComponent.hasPrefix("stage-") == true
        }
        XCTAssertFalse(stagingPuts.isEmpty)
        XCTAssertTrue(stagingPuts.allSatisfy {
            $0.value(forHTTPHeaderField: "If-None-Match") == nil
        })
    }

    func testAttestedAtomicMoveCollisionMapsToPreconditionFailureWithoutOverwritingTarget() async throws {
        let transport = AtomicMoveNoOverwriteTransport()
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)
        let data = Data("content-addressed immutable ciphertext".utf8)

        try await client.verifyAtomicMoveNoOverwriteSafety()
        _ = try await client.createImmutableChild(data, named: "genesis.pgy")

        do {
            _ = try await client.createImmutableChild(data, named: "genesis.pgy")
            XCTFail("Expected immutable MOVE collision")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .preconditionFailed)
        }

        let targetURL = try client.immutableCollectionURL()
            .appendingPathComponent("genesis.pgy", isDirectory: false)
        let targetData = await transport.data(at: targetURL)
        XCTAssertEqual(targetData, data)
    }

    func testAtomicMoveProbeRejectsCollisionThatChangesDestinationOrSource() async throws {
        let transport = AtomicMoveNoOverwriteTransport(
            unsafeCollisionBehavior: .returnConflictAfterOverwritingDestination
        )
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyAtomicMoveNoOverwriteSafety()
            XCTFail("Expected unsafe collision behavior")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        XCTAssertFalse(client.hasAtomicMoveNoOverwriteAttestation)
        let probeCollectionWasDeleted = await transport.probeCollectionWasDeleted
        XCTAssertTrue(probeCollectionWasDeleted)
    }

    func testAtomicMoveProbeRequires201ForStagingWrite() async throws {
        let transport = AtomicMoveNoOverwriteTransport(stagingStatusCode: 204)
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyAtomicMoveNoOverwriteSafety()
            XCTFail("Expected non-201 staging write to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.httpMethod == "MOVE" })
    }

    func testAtomicMoveProbeReportsCleanupFailure() async throws {
        let transport = AtomicMoveNoOverwriteTransport(failProbeCleanup: true)
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyAtomicMoveNoOverwriteSafety()
            XCTFail("Expected failed probe cleanup")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .probeCleanupFailed)
        }

        let didAttemptCollectionCleanup = await transport.didAttemptProbeCollectionCleanup
        XCTAssertTrue(didAttemptCollectionCleanup)
        XCTAssertFalse(client.hasAtomicMoveNoOverwriteAttestation)
    }

    func testAtomicMoveProbeCleansCommittedResourcesAfterMoveTransportFailure() async throws {
        let transport = AtomicMoveNoOverwriteTransport(
            initialProbeMoveBehavior: .commitThenTransportFailure
        )
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyAtomicMoveNoOverwriteSafety()
            XCTFail("Expected lost MOVE response")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .transportFailure("MOVE response lost"))
        }

        let resourcesAreAbsent = await transport.probeResourcesAreAbsent
        let probeCollectionWasDeleted = await transport.probeCollectionWasDeleted
        XCTAssertTrue(resourcesAreAbsent)
        XCTAssertTrue(probeCollectionWasDeleted)
    }

    func testAtomicMoveProbeCleansCommittedDestinationAfterAnomalousMoveStatus() async throws {
        let transport = AtomicMoveNoOverwriteTransport(
            initialProbeMoveBehavior: .commitThenStatus(204)
        )
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyAtomicMoveNoOverwriteSafety()
            XCTFail("Expected anomalous MOVE success status to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        let resourcesAreAbsent = await transport.probeResourcesAreAbsent
        let probeCollectionWasDeleted = await transport.probeCollectionWasDeleted
        XCTAssertTrue(resourcesAreAbsent)
        XCTAssertTrue(probeCollectionWasDeleted)
    }

    func testAtomicMoveProbeNeverDeletesAmbiguouslyCreatedCollection() async throws {
        let transport = AtomicMoveNoOverwriteTransport(
            throwAfterProbeCollectionCreation: true
        )
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyAtomicMoveNoOverwriteSafety()
            XCTFail("Expected lost MKCOL response")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .transportFailure("probe collection response lost"))
        }

        let requests = await transport.requests
        let probeCollectionWasDeleted = await transport.probeCollectionWasDeleted
        XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" })
        XCTAssertFalse(probeCollectionWasDeleted)
    }

    func testAtomicMoveReadbackFailureDoesNotDeleteFormalDestination() async throws {
        let transport = AtomicMoveNoOverwriteTransport(
            corruptFormalDestinationAfterMove: true
        )
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)
        let data = Data("expected immutable ciphertext".utf8)
        let targetURL = try client.immutableCollectionURL()
            .appendingPathComponent("genesis.pgy", isDirectory: false)

        try await client.verifyAtomicMoveNoOverwriteSafety()
        do {
            _ = try await client.createImmutableChild(data, named: "genesis.pgy")
            XCTFail("Expected failed post-MOVE verification")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeAtomicMove)
        }

        let targetData = await transport.data(at: targetURL)
        XCTAssertEqual(targetData, Data("corrupt MOVE target".utf8))
        let requests = await transport.requests
        XCTAssertFalse(requests.contains {
            $0.httpMethod == "DELETE" && $0.url == targetURL
        })
    }

    func testConditionalCreateProbeAccepts200Or204AfterCollision412AndUnchangedContent() async throws {
        for initialStatusCode in [201, 200, 204] {
            let storedData = LockedDataBox()
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    XCTAssertEqual(request.httpMethod, "MKCOL")
                    return WebDAVTransportResponse(statusCode: 201)
                case 1:
                    XCTAssertEqual(request.httpMethod, "PROPFIND")
                    let href = try XCTUnwrap(request.url?.path)
                    return WebDAVTransportResponse(
                        data: multiStatusXML(collectionHref: href, children: []),
                        statusCode: 207
                    )
                case 2:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    storedData.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: initialStatusCode)
                case 3:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(storedData.value),
                        statusCode: 200
                    )
                case 4:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    XCTAssertNotEqual(request.httpBody, storedData.value)
                    return WebDAVTransportResponse(statusCode: 412)
                case 5:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(storedData.value),
                        statusCode: 200
                    )
                case 6:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                    return WebDAVTransportResponse(statusCode: 204)
                case 7:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                case 8:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                    return WebDAVTransportResponse(statusCode: 204)
                case 9:
                    XCTAssertEqual(request.httpMethod, "PROPFIND")
                    return WebDAVTransportResponse(statusCode: 404)
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            try await client.verifyConditionalCreateSafety()
            XCTAssertTrue(client.hasConditionalCreateAttestation)

            let requests = await transport.requests
            XCTAssertEqual(requests.count, 10)
            let collectionURL = try XCTUnwrap(requests.first?.url)
            XCTAssertTrue(collectionURL.lastPathComponent.hasPrefix("PGYMacMenu-create-probe-"))
            XCTAssertTrue(collectionURL.lastPathComponent.hasSuffix(".tmp.d"))
            XCTAssertEqual(requests[1].url, collectionURL)
            XCTAssertEqual(requests.last?.url, collectionURL)

            let childURLs = requests[2...7].compactMap(\.url)
            XCTAssertEqual(Set(childURLs).count, 1)
            XCTAssertEqual(childURLs[0].deletingLastPathComponent(), collectionURL)

            let formalCollectionURL = try client.immutableCollectionURL()
            XCTAssertFalse(requests.contains { request in
                guard let url = request.url else { return false }
                return url == formalCollectionURL
                    || url.absoluteString.hasPrefix(formalCollectionURL.absoluteString)
            })
        }
    }

    func testConditionalCreateProbeFailsClosedWhenCollisionWriteIsAccepted() async throws {
        for collisionStatusCode in [200, 204] {
            let storedData = LockedDataBox()
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    return WebDAVTransportResponse(statusCode: 201)
                case 1:
                    return WebDAVTransportResponse(
                        data: multiStatusXML(
                            collectionHref: try XCTUnwrap(request.url?.path),
                            children: []
                        ),
                        statusCode: 207
                    )
                case 2:
                    storedData.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 201)
                case 3:
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(storedData.value),
                        statusCode: 200
                    )
                case 4:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    return WebDAVTransportResponse(statusCode: collisionStatusCode)
                case 5:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    return WebDAVTransportResponse(statusCode: 204)
                case 6:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                case 7:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    return WebDAVTransportResponse(statusCode: 204)
                case 8:
                    XCTAssertEqual(request.httpMethod, "PROPFIND")
                    return WebDAVTransportResponse(statusCode: 404)
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                try await client.verifyConditionalCreateSafety()
                XCTFail("Expected ignored condition to be rejected")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeConditionalCreate)
            }
        }
    }

    func testConditionalCreateProbeNeverDeletesPreexistingRandomCollection() async throws {
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.httpMethod, "MKCOL")
            return WebDAVTransportResponse(statusCode: 405)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyConditionalCreateSafety()
            XCTFail("Expected an unowned collection to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .methodNotAllowed)
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" })
        XCTAssertNotEqual(requests.first?.url, try client.immutableCollectionURL())
    }

    func testConditionalCreateProbeReportsCleanupFailureAndStillDeletesOwnedCollection() async throws {
        let storedData = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                return WebDAVTransportResponse(statusCode: 201)
            case 1:
                return WebDAVTransportResponse(
                    data: multiStatusXML(
                        collectionHref: try XCTUnwrap(request.url?.path),
                        children: []
                    ),
                    statusCode: 207
                )
            case 2:
                storedData.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 3, 5:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(storedData.value),
                    statusCode: 200
                )
            case 4:
                return WebDAVTransportResponse(statusCode: 412)
            case 6:
                XCTAssertEqual(request.httpMethod, "DELETE")
                return WebDAVTransportResponse(statusCode: 500)
            case 7:
                XCTAssertEqual(request.httpMethod, "DELETE")
                return WebDAVTransportResponse(statusCode: 204)
            case 8:
                XCTAssertEqual(request.httpMethod, "PROPFIND")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.verifyConditionalCreateSafety()
            XCTFail("Expected cleanup failure")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .probeCleanupFailed)
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(requests.last?.url, requests.first?.url)
    }

    func testConnectionProvesCreateOnlyAndStrongETagSemanticsBeforeCleanup() async throws {
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
                    headers: ["ETag": "\"probe-1\""]
                )
            case 3:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                XCTAssertNotEqual(request.httpBody, probeBody.value)
                return WebDAVTransportResponse(statusCode: 412)
            case 4:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 5:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertNotEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                return WebDAVTransportResponse(statusCode: 412)
            case 6:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 7:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 204)
            case 8:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-2\""]
                )
            case 9:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-2\"")
                return WebDAVTransportResponse(statusCode: 204)
            case 10:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        try await client.testConnection()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 11)
        let probeURLs = requests.dropFirst().compactMap(\.url)
        XCTAssertEqual(Set(probeURLs).count, 1)
        XCTAssertTrue(probeURLs[0].lastPathComponent.hasPrefix("PGYMacMenu-probe-"))
        XCTAssertNotEqual(probeURLs[0], try configuration.resolvedResourceURL())
        XCTAssertFalse(requests.contains { $0.httpMethod == "LOCK" || $0.httpMethod == "UNLOCK" })
    }

    func testConnectionRejectsIgnoredCreateOnlyConditionForStrongAndWeakETags() async throws {
        for etag in ["\"strong\"", "W/\"weak\""] {
            let probeBody = LockedDataBox()
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    probeBody.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 201)
                case 1:
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(probeBody.value),
                        statusCode: 200,
                        headers: ["ETag": etag]
                    )
                case 2:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    return WebDAVTransportResponse(statusCode: 204)
                case 3:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                    return WebDAVTransportResponse(statusCode: 204)
                case 4:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                try await client.testConnection()
                XCTFail("Expected ignored create-only condition to be rejected for \(etag)")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeConditionalCreate)
            }
        }
    }

    func testConnectionAcceptsNonCreationCreateResponseOnlyAfterFullSemanticProof() async throws {
        for initialStatusCode in [200, 204] {
            let storedData = LockedDataBox()
            let uploadData = Data("verified create-only upload".utf8)
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    storedData.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: initialStatusCode)
                case 1, 3, 5:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(storedData.value),
                        statusCode: 200,
                        headers: ["ETag": "\"probe-1\""]
                    )
                case 2:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    XCTAssertNotEqual(request.httpBody, storedData.value)
                    return WebDAVTransportResponse(statusCode: 412)
                case 4:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertNotEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                    return WebDAVTransportResponse(statusCode: 412)
                case 6:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                    storedData.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 204)
                case 7:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(storedData.value),
                        statusCode: 200,
                        headers: ["ETag": "\"probe-2\""]
                    )
                case 8:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-2\"")
                    return WebDAVTransportResponse(statusCode: 204)
                case 9:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                case 10:
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    XCTAssertEqual(request.httpBody, uploadData)
                    storedData.value = uploadData
                    return WebDAVTransportResponse(statusCode: 204)
                case 11:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                case 12:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(
                        data: uploadData,
                        statusCode: 200
                    )
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            try await client.testConnection()
            XCTAssertTrue(client.hasConditionalCreateAttestation)
            let etag = try await client.upload(uploadData, condition: .createOnly)
            XCTAssertNil(etag)

            let requests = await transport.requests
            XCTAssertEqual(requests.count, 13)
        }
    }

    func testAttestedCreateOnlyRetriesTransientReadWithoutRepeatingPUT() async throws {
        for createStatusCode in [200, 204] {
            for readFailure in ConditionalCreateReadFailure.allCases {
                let transport = ConditionalCreateReadRetryTransport(
                    createStatusCode: createStatusCode,
                    readFailure: readFailure
                )
                let client = try WebDAVClient(
                    configuration: makeConfiguration(),
                    transport: transport
                )
                let data = Data("eventually visible encrypted data".utf8)

                try await client.testConnection()
                _ = try await client.upload(data, condition: .createOnly)

                let actualCreateOnlyPUTCount = await transport.actualCreateOnlyPUTCount
                XCTAssertEqual(
                    actualCreateOnlyPUTCount,
                    1,
                    "\(readFailure) must retry only GET after HTTP \(createStatusCode)"
                )
            }
        }
    }

    func testAttestedCreateOnlyPersistent404DoesNotRetryPUT() async throws {
        let transport = ConditionalCreateReadRetryTransport(
            createStatusCode: 204,
            readFailure: .rateLimited,
            persistentNotFound: true
        )
        let client = try WebDAVClient(
            configuration: makeConfiguration(),
            transport: transport
        )

        try await client.testConnection()
        do {
            _ = try await client.upload(
                Data("never visible encrypted data".utf8),
                condition: .createOnly
            )
            XCTFail("Expected persistent post-create 404 to fail closed")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeConditionalCreate)
        }

        let actualCreateOnlyPUTCount = await transport.actualCreateOnlyPUTCount
        let actualGETCount = await transport.actualGETCount
        XCTAssertEqual(actualCreateOnlyPUTCount, 1)
        XCTAssertEqual(actualGETCount, 4)
    }

    func testConnectionRejectsCreateOnly412ThatStillChangesContentForStrongAndWeakETags() async throws {
        for etag in ["\"strong\"", "W/\"weak\""] {
            let probeBody = LockedDataBox()
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    probeBody.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 201)
                case 1:
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(probeBody.value),
                        statusCode: 200,
                        headers: ["ETag": etag]
                    )
                case 2:
                    probeBody.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 412)
                case 3:
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(probeBody.value),
                        statusCode: 200,
                        headers: ["ETag": etag]
                    )
                case 4:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                    return WebDAVTransportResponse(statusCode: 204)
                case 5:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                try await client.testConnection()
                XCTFail("Expected changed content to be rejected for \(etag)")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeConditionalCreate)
            }
        }
    }

    func testConnectionPreservesRateLimitFromCreateOnlyCollisionProbe() async throws {
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 1:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 2:
                return WebDAVTransportResponse(statusCode: 429)
            case 3:
                XCTAssertEqual(request.httpMethod, "DELETE")
                return WebDAVTransportResponse(statusCode: 204)
            case 4:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected rate limit")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testConnectionRejectsStrongETagServerThatAcceptsStaleIfMatch() async throws {
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 1, 3:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 2:
                return WebDAVTransportResponse(statusCode: 412)
            case 4:
                XCTAssertNotEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 204)
            case 5:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                return WebDAVTransportResponse(statusCode: 204)
            case 6:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected stale If-Match acceptance to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeConditionalUpdate)
        }
    }

    func testConnectionRejectsStaleIfMatch412ThatStillChangesContent() async throws {
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 1, 3:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 2:
                return WebDAVTransportResponse(statusCode: 412)
            case 4:
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 412)
            case 5:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-2\""]
                )
            case 6:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-2\"")
                return WebDAVTransportResponse(statusCode: 204)
            case 7:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected stale conditional overwrite to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeConditionalUpdate)
        }
    }

    func testConnectionRejectsUnchangedStrongETagAfterSuccessfulUpdate() async throws {
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 1, 3, 5:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 2, 4:
                return WebDAVTransportResponse(statusCode: 412)
            case 6:
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 204)
            case 7:
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 8:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                return WebDAVTransportResponse(statusCode: 204)
            case 9:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected unchanged strong ETag to be rejected")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeConditionalUpdate)
        }
    }

    func testConnectionRejectsNonUpdateSuccessForCorrectIfMatch() async throws {
        for statusCode in [201, 202] {
            let probeBody = LockedDataBox()
            let transport = MockWebDAVTransport { request, index, _ in
                switch index {
                case 0:
                    probeBody.value = request.httpBody
                    return WebDAVTransportResponse(statusCode: 201)
                case 1, 3, 5:
                    return WebDAVTransportResponse(
                        data: try XCTUnwrap(probeBody.value),
                        statusCode: 200,
                        headers: ["ETag": "\"probe-1\""]
                    )
                case 2, 4:
                    return WebDAVTransportResponse(statusCode: 412)
                case 6:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                    return WebDAVTransportResponse(statusCode: statusCode)
                case 7:
                    XCTAssertEqual(request.httpMethod, "DELETE")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                    return WebDAVTransportResponse(statusCode: 204)
                case 8:
                    XCTAssertEqual(request.httpMethod, "GET")
                    return WebDAVTransportResponse(statusCode: 404)
                default:
                    XCTFail("Unexpected request")
                    return WebDAVTransportResponse(statusCode: 500)
                }
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            do {
                try await client.testConnection()
                XCTFail("Expected status \(statusCode) to be rejected")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .unsafeConditionalUpdate)
            }
        }
    }

    func testConnectionUsesStrictExclusiveLockProbeForWeakOrMissingETag() async throws {
        for representationETag: String? in ["W/\"weak-representation\"", nil] {
            let server = WeakETagLockProbeServer(
                unsafeBehavior: nil,
                representationETag: representationETag
            )
            let transport = MockWebDAVTransport { request, index, _ in
                try await server.respond(to: request, index: index)
            }
            let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

            try await client.testConnection()

            let requests = await transport.requests
            XCTAssertEqual(requests.count, 16)
            XCTAssertEqual(requests.map(\.httpMethod), [
                "PUT", "GET", "PUT", "GET", "LOCK", "LOCK", "PUT", "GET",
                "PUT", "GET", "UNLOCK", "PUT", "GET", "LOCK", "DELETE", "GET"
            ])
        }
    }

    func testConnectionRejectsLockDeleteThatLeavesProbeBehind() async throws {
        let server = WeakETagLockProbeServer(unsafeBehavior: .retainAfterCleanupDelete)
        let transport = MockWebDAVTransport { request, index, _ in
            try await server.respond(to: request, index: index)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected persistent probe cleanup failure")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .probeCleanupFailed)
        }

        let requests = await transport.requests
        let methods = requests.map(\.httpMethod)
        XCTAssertEqual(Array(methods.suffix(8)), [
            "DELETE", "GET", "GET", "GET", "GET", "UNLOCK", "DELETE", "GET"
        ])
    }

    func testConnectionFailsClosedWhenUnlockedWriteIsAccepted() async throws {
        try await assertUnsafeLockProbeIsRejected(.acceptUnlockedWrite)
    }

    func testConnectionFailsClosedWhenSecondExclusiveLockIsAccepted() async throws {
        try await assertUnsafeLockProbeIsRejected(.acceptSecondLock)
    }

    func testConnectionFailsClosedWhenExpiredLockTokenIsAccepted() async throws {
        try await assertUnsafeLockProbeIsRejected(.acceptExpiredToken)
    }

    func testConnectionRetriesTemporaryProbeRead404() async throws {
        let configuration = try makeConfiguration(path: "sync.bin")
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "PUT")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 3:
                XCTAssertEqual(request.httpMethod, "PUT")
                return WebDAVTransportResponse(statusCode: 412)
            case 4, 6:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 5:
                XCTAssertEqual(request.httpMethod, "PUT")
                return WebDAVTransportResponse(statusCode: 412)
            case 7:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-1\"")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 204)
            case 8:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-2\""]
                )
            case 9:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"probe-2\"")
                return WebDAVTransportResponse(statusCode: 204)
            case 10:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        try await client.testConnection()

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 11)
    }

    func testConnectionReportsPersistentProbeRead404AfterBoundedRetries() async throws {
        let configuration = try makeConfiguration(path: "sync.bin")
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "PUT")
                return WebDAVTransportResponse(statusCode: 201)
            case 1...4:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            case 5:
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
                return WebDAVTransportResponse(statusCode: 204)
            case 6:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected a probe read error")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .probeReadUnavailable)
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 7)
    }

    func testConnectionReportsProbeCleanup404Separately() async throws {
        let configuration = try makeConfiguration(path: "sync.bin")
        let probeBody = LockedDataBox()
        let transport = MockWebDAVTransport { request, index, _ in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "PUT")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 201)
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "PUT")
                return WebDAVTransportResponse(statusCode: 412)
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 4:
                XCTAssertEqual(request.httpMethod, "PUT")
                return WebDAVTransportResponse(statusCode: 412)
            case 5:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-1\""]
                )
            case 6:
                XCTAssertEqual(request.httpMethod, "PUT")
                probeBody.value = request.httpBody
                return WebDAVTransportResponse(statusCode: 204)
            case 7:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(
                    data: try XCTUnwrap(probeBody.value),
                    statusCode: 200,
                    headers: ["ETag": "\"probe-2\""]
                )
            case 8:
                XCTAssertEqual(request.httpMethod, "DELETE")
                return WebDAVTransportResponse(statusCode: 404)
            case 9:
                XCTAssertEqual(request.httpMethod, "DELETE")
                return WebDAVTransportResponse(statusCode: 204)
            case 10:
                XCTAssertEqual(request.httpMethod, "GET")
                return WebDAVTransportResponse(statusCode: 404)
            default:
                XCTFail("Unexpected request")
                return WebDAVTransportResponse(statusCode: 500)
            }
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected a probe cleanup error")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .probeCleanupFailed)
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 11)
    }

    func testConnectionMapsJianguoyunProbeWrite404ToActionableError() async throws {
        let configuration = try makeConfiguration(
            root: "https://dav.jianguoyun.com/dav/",
            path: "sync.bin"
        )
        let transport = MockWebDAVTransport { request, _, _ in
            XCTAssertEqual(request.httpMethod, "PUT")
            return WebDAVTransportResponse(statusCode: 404)
        }
        let client = try WebDAVClient(configuration: configuration, transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected an unavailable collection error")
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .collectionUnavailable(provider: .jianguoyun))
            XCTAssertTrue(error.localizedDescription.contains("https://dav.jianguoyun.com/dav/"))
            XCTAssertFalse(error.localizedDescription.contains("user"))
        }
    }

    func testConnectionMapsParentCollection404And409ToActionableError() async throws {
        for statusCode in [404, 409] {
            let configuration = try makeConfiguration(path: "missing/sync.bin")
            let transport = MockWebDAVTransport { request, _, _ in
                XCTAssertEqual(request.httpMethod, "MKCOL")
                return WebDAVTransportResponse(statusCode: statusCode)
            }
            let client = try WebDAVClient(configuration: configuration, transport: transport)

            do {
                try await client.testConnection()
                XCTFail("Expected status \(statusCode) to report an unavailable collection")
            } catch let error as WebDAVError {
                XCTAssertEqual(error, .collectionUnavailable(provider: nil))
            }
        }
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
        path: String = WebDAVConfiguration.defaultRelativePath
    ) throws -> WebDAVConfiguration {
        try WebDAVConfiguration(
            rootURL: XCTUnwrap(URL(string: root)),
            relativePath: path,
            username: "user",
            password: "password"
        )
    }

    private func assertUnsafeLockProbeIsRejected(
        _ behavior: WeakETagLockProbeServer.UnsafeBehavior,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let server = WeakETagLockProbeServer(unsafeBehavior: behavior)
        let transport = MockWebDAVTransport { request, index, _ in
            try await server.respond(to: request, index: index)
        }
        let client = try WebDAVClient(configuration: makeConfiguration(), transport: transport)

        do {
            try await client.testConnection()
            XCTFail("Expected unsafe lock semantics to be rejected", file: file, line: line)
        } catch let error as WebDAVError {
            XCTAssertEqual(error, .unsafeExclusiveLock, file: file, line: line)
        }
    }
}

private actor WeakETagLockProbeServer {
    enum UnsafeBehavior {
        case acceptSecondLock
        case acceptUnlockedWrite
        case acceptExpiredToken
        case retainAfterCleanupDelete
    }

    private static let firstToken = "opaquelocktoken:probe-1"
    private static let secondToken = "opaquelocktoken:probe-2"
    private static let cleanupToken = "opaquelocktoken:probe-cleanup"

    private let unsafeBehavior: UnsafeBehavior?
    private let representationETag: String?
    private var probeData: Data?
    private var lockedData: Data?
    private var unsafeResultReturned = false
    private var cleanupDeleteWasIgnored = false
    private var fallbackCleanupCompleted = false

    init(
        unsafeBehavior: UnsafeBehavior?,
        representationETag: String? = "W/\"weak-representation\""
    ) {
        self.unsafeBehavior = unsafeBehavior
        self.representationETag = representationETag
    }

    func respond(to request: URLRequest, index: Int) throws -> WebDAVTransportResponse {
        if cleanupDeleteWasIgnored {
            return try retainedCleanupResponse(to: request)
        }
        if unsafeResultReturned {
            return try cleanupResponse(to: request)
        }

        switch index {
        case 0:
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            probeData = try XCTUnwrap(request.httpBody)
            return WebDAVTransportResponse(statusCode: 201)
        case 1:
            XCTAssertEqual(request.httpMethod, "GET")
            return weakResource(data: try XCTUnwrap(probeData))
        case 2:
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            XCTAssertNotEqual(request.httpBody, probeData)
            return WebDAVTransportResponse(statusCode: 412)
        case 3:
            XCTAssertEqual(request.httpMethod, "GET")
            return weakResource(data: try XCTUnwrap(probeData))
        case 4:
            assertLockRequest(request)
            return validLockResponse(token: Self.firstToken)
        case 5:
            assertLockRequest(request)
            if unsafeBehavior == .acceptSecondLock {
                unsafeResultReturned = true
                return validLockResponse(token: Self.secondToken)
            }
            return WebDAVTransportResponse(statusCode: 423)
        case 6:
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertNil(request.value(forHTTPHeaderField: "If"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Lock-Token"))
            if unsafeBehavior == .acceptUnlockedWrite {
                unsafeResultReturned = true
                return WebDAVTransportResponse(statusCode: 204)
            }
            return WebDAVTransportResponse(statusCode: 423)
        case 7:
            XCTAssertEqual(request.httpMethod, "GET")
            return weakResource(data: try XCTUnwrap(probeData))
        case 8:
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If"), "(<\(Self.firstToken)>)")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
            lockedData = try XCTUnwrap(request.httpBody)
            XCTAssertNotEqual(lockedData, probeData)
            return WebDAVTransportResponse(statusCode: 204)
        case 9:
            XCTAssertEqual(request.httpMethod, "GET")
            return weakResource(data: try XCTUnwrap(lockedData))
        case 10:
            XCTAssertEqual(request.httpMethod, "UNLOCK")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Lock-Token"), "<\(Self.firstToken)>")
            return WebDAVTransportResponse(statusCode: 204)
        case 11:
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If"), "(<\(Self.firstToken)>)")
            if unsafeBehavior == .acceptExpiredToken {
                unsafeResultReturned = true
                return WebDAVTransportResponse(statusCode: 204)
            }
            return WebDAVTransportResponse(statusCode: 412)
        case 12:
            XCTAssertEqual(request.httpMethod, "GET")
            return weakResource(data: try XCTUnwrap(lockedData))
        case 13:
            assertLockRequest(request)
            return validLockResponse(token: Self.cleanupToken)
        case 14:
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If"), "(<\(Self.cleanupToken)>)")
            if unsafeBehavior == .retainAfterCleanupDelete {
                cleanupDeleteWasIgnored = true
            }
            return WebDAVTransportResponse(statusCode: 204)
        case 15:
            XCTAssertEqual(request.httpMethod, "GET")
            return WebDAVTransportResponse(statusCode: 404)
        default:
            XCTFail("Unexpected request")
            return WebDAVTransportResponse(statusCode: 500)
        }
    }

    private func cleanupResponse(to request: URLRequest) throws -> WebDAVTransportResponse {
        switch request.httpMethod {
        case "LOCK":
            return validLockResponse(token: Self.cleanupToken)
        case "UNLOCK", "DELETE":
            return WebDAVTransportResponse(statusCode: 204)
        case "GET":
            return WebDAVTransportResponse(statusCode: 404)
        default:
            XCTFail("Client continued the capability probe after unsafe lock behavior")
            return WebDAVTransportResponse(statusCode: 500)
        }
    }

    private func retainedCleanupResponse(to request: URLRequest) throws -> WebDAVTransportResponse {
        switch request.httpMethod {
        case "GET":
            if fallbackCleanupCompleted {
                return WebDAVTransportResponse(statusCode: 404)
            }
            return weakResource(data: try XCTUnwrap(lockedData))
        case "UNLOCK":
            XCTAssertEqual(request.value(forHTTPHeaderField: "Lock-Token"), "<\(Self.cleanupToken)>")
            return WebDAVTransportResponse(statusCode: 204)
        case "DELETE":
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
            fallbackCleanupCompleted = true
            return WebDAVTransportResponse(statusCode: 204)
        default:
            XCTFail("Unexpected cleanup request")
            return WebDAVTransportResponse(statusCode: 500)
        }
    }

    private func assertLockRequest(_ request: URLRequest) {
        XCTAssertEqual(request.httpMethod, "LOCK")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "*")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Timeout"))
    }

    private func weakResource(data: Data) -> WebDAVTransportResponse {
        var headers: [String: String] = [:]
        if let representationETag {
            headers["ETag"] = representationETag
        }
        return WebDAVTransportResponse(
            data: data,
            statusCode: 200,
            headers: headers
        )
    }
}

private func multiStatusXML(
    collectionHref: String,
    children: [(String, Bool)]
) -> Data {
    func response(href: String, isCollection: Bool) -> String {
        let escapedHref = href
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let resourceType = isCollection ? "<D:collection/>" : ""
        return """
        <D:response>
          <D:href>\(escapedHref)</D:href>
          <D:propstat>
            <D:prop><D:resourcetype>\(resourceType)</D:resourcetype></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }

    let childResponses = children.map { response(href: $0.0, isCollection: $0.1) }
        .joined(separator: "\n")
    return Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          \(response(href: collectionHref, isCollection: true))
          \(childResponses)
        </D:multistatus>
        """.utf8
    )
}

private func validLockResponse(
    token: String,
    timeoutSeconds: Int = 120,
    namespace: String = "DAV:",
    depth: String = "0"
) -> WebDAVTransportResponse {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:prop xmlns:D="\(namespace)">
      <D:lockdiscovery>
        <D:activelock>
          <D:locktype><D:write/></D:locktype>
          <D:lockscope><D:exclusive/></D:lockscope>
          <D:depth>\(depth)</D:depth>
          <D:timeout>Second-\(timeoutSeconds)</D:timeout>
          <D:locktoken><D:href>\(token)</D:href></D:locktoken>
        </D:activelock>
      </D:lockdiscovery>
    </D:prop>
    """
    return WebDAVTransportResponse(
        data: Data(xml.utf8),
        statusCode: 200,
        headers: [
            "Lock-Token": "<\(token)>",
            "Timeout": "Second-\(timeoutSeconds)"
        ]
    )
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

private enum ConditionalCreateReadFailure: CaseIterable, Sendable {
    case rateLimited
    case serviceUnavailable
    case locked
    case requestTimeout
    case transport
}

private actor ConditionalCreateReadRetryTransport: WebDAVTransport {
    private let createStatusCode: Int
    private let readFailure: ConditionalCreateReadFailure
    private let persistentNotFound: Bool
    private var resources: [URL: Data] = [:]
    private var etags: [URL: String] = [:]
    private var etagSequence = 0
    private var injectedActualReadFailure = false
    private(set) var actualCreateOnlyPUTCount = 0
    private(set) var actualGETCount = 0

    init(
        createStatusCode: Int,
        readFailure: ConditionalCreateReadFailure,
        persistentNotFound: Bool = false
    ) {
        self.createStatusCode = createStatusCode
        self.readFailure = readFailure
        self.persistentNotFound = persistentNotFound
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> WebDAVTransportResponse {
        guard let url = request.url else {
            throw WebDAVError.invalidResponse
        }
        let isActualResource = url.lastPathComponent == WebDAVConfiguration.defaultRelativePath

        switch request.httpMethod {
        case "PUT":
            if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                guard resources[url] == nil else {
                    return WebDAVTransportResponse(statusCode: 412)
                }
                store(request.httpBody ?? Data(), at: url)
                if isActualResource {
                    actualCreateOnlyPUTCount += 1
                }
                return WebDAVTransportResponse(statusCode: createStatusCode)
            }

            guard let expectedETag = request.value(forHTTPHeaderField: "If-Match"),
                  expectedETag == etags[url] else {
                return WebDAVTransportResponse(statusCode: 412)
            }
            store(request.httpBody ?? Data(), at: url)
            return WebDAVTransportResponse(statusCode: 204)

        case "GET":
            if isActualResource, resources[url] != nil {
                actualGETCount += 1
                if persistentNotFound {
                    return WebDAVTransportResponse(statusCode: 404)
                }
                if !injectedActualReadFailure {
                    injectedActualReadFailure = true
                    switch readFailure {
                    case .rateLimited:
                        return WebDAVTransportResponse(statusCode: 429)
                    case .serviceUnavailable:
                        return WebDAVTransportResponse(statusCode: 503)
                    case .locked:
                        return WebDAVTransportResponse(statusCode: 423)
                    case .requestTimeout:
                        return WebDAVTransportResponse(statusCode: 408)
                    case .transport:
                        throw WebDAVError.transportFailure("temporary read failure")
                    }
                }
            }
            guard let data = resources[url], let etag = etags[url] else {
                return WebDAVTransportResponse(statusCode: 404)
            }
            return WebDAVTransportResponse(
                data: data,
                statusCode: 200,
                headers: ["ETag": etag]
            )

        case "DELETE":
            guard resources.removeValue(forKey: url) != nil else {
                return WebDAVTransportResponse(statusCode: 404)
            }
            etags.removeValue(forKey: url)
            return WebDAVTransportResponse(statusCode: 204)

        default:
            return WebDAVTransportResponse(statusCode: 405)
        }
    }

    private func store(_ data: Data, at url: URL) {
        etagSequence += 1
        resources[url] = data
        etags[url] = "\"etag-\(etagSequence)\""
    }
}

private actor AtomicMoveNoOverwriteTransport: WebDAVTransport {
    enum UnsafeCollisionBehavior: Sendable {
        case none
        case returnConflictAfterOverwritingDestination
    }

    enum InitialProbeMoveBehavior: Sendable {
        case normal
        case commitThenTransportFailure
        case commitThenStatus(Int)
    }

    private let stagingStatusCode: Int
    private let unsafeCollisionBehavior: UnsafeCollisionBehavior
    private let failProbeCleanup: Bool
    private let corruptFormalDestinationAfterMove: Bool
    private let initialProbeMoveBehavior: InitialProbeMoveBehavior
    private let throwAfterProbeCollectionCreation: Bool
    private var injectedCleanupFailure = false
    private var appliedInitialProbeMoveBehavior = false
    private var resources: [URL: Data] = [:]
    private var collections: Set<URL> = []
    private(set) var requests: [URLRequest] = []
    private(set) var probeCollectionWasDeleted = false
    private(set) var didAttemptProbeCollectionCleanup = false

    init(
        stagingStatusCode: Int = 201,
        unsafeCollisionBehavior: UnsafeCollisionBehavior = .none,
        failProbeCleanup: Bool = false,
        corruptFormalDestinationAfterMove: Bool = false,
        initialProbeMoveBehavior: InitialProbeMoveBehavior = .normal,
        throwAfterProbeCollectionCreation: Bool = false
    ) {
        self.stagingStatusCode = stagingStatusCode
        self.unsafeCollisionBehavior = unsafeCollisionBehavior
        self.failProbeCleanup = failProbeCleanup
        self.corruptFormalDestinationAfterMove = corruptFormalDestinationAfterMove
        self.initialProbeMoveBehavior = initialProbeMoveBehavior
        self.throwAfterProbeCollectionCreation = throwAfterProbeCollectionCreation
    }

    func data(at url: URL) -> Data? {
        resources[url]
    }

    var probeResourcesAreAbsent: Bool {
        resources.keys.allSatisfy { !isMoveProbeResource($0) }
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> WebDAVTransportResponse {
        requests.append(request)
        guard let url = request.url, let method = request.httpMethod else {
            throw WebDAVError.invalidResponse
        }

        switch method {
        case "MKCOL":
            collections.insert(url)
            if throwAfterProbeCollectionCreation, isMoveProbeCollection(url) {
                throw WebDAVError.transportFailure("probe collection response lost")
            }
            return WebDAVTransportResponse(statusCode: 201)

        case "PROPFIND":
            guard collections.contains(url) else {
                return WebDAVTransportResponse(statusCode: 404)
            }
            return WebDAVTransportResponse(
                data: multiStatusXML(collectionHref: url.path, children: []),
                statusCode: 207
            )

        case "PUT":
            let data = request.httpBody ?? Data()
            if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                if resources[url] != nil {
                    // Model the unsafe Jianguoyun conditional PUT behavior so
                    // the generic probe must continue with MOVE attestation.
                    resources[url] = data
                    return WebDAVTransportResponse(statusCode: 204)
                }
                resources[url] = data
                return WebDAVTransportResponse(statusCode: 201)
            }

            resources[url] = data
            if url.lastPathComponent.hasPrefix("stage-") {
                return WebDAVTransportResponse(statusCode: stagingStatusCode)
            }
            return WebDAVTransportResponse(statusCode: 201)

        case "MOVE":
            guard request.value(forHTTPHeaderField: "Overwrite") == "F",
                  let destinationValue = request.value(forHTTPHeaderField: "Destination"),
                  let destinationURL = URL(string: destinationValue),
                  destinationURL.deletingLastPathComponent() == url.deletingLastPathComponent(),
                  let sourceData = resources[url] else {
                throw WebDAVError.invalidResponse
            }

            if resources[destinationURL] != nil {
                if unsafeCollisionBehavior == .returnConflictAfterOverwritingDestination {
                    resources[destinationURL] = sourceData
                }
                return WebDAVTransportResponse(statusCode: 409)
            }

            resources.removeValue(forKey: url)
            if corruptFormalDestinationAfterMove,
               destinationURL.deletingLastPathComponent().lastPathComponent
                == "\(WebDAVConfiguration.defaultRelativePath).d" {
                resources[destinationURL] = Data("corrupt MOVE target".utf8)
            } else {
                resources[destinationURL] = sourceData
            }
            if isMoveProbeResource(url), !appliedInitialProbeMoveBehavior {
                appliedInitialProbeMoveBehavior = true
                switch initialProbeMoveBehavior {
                case .normal:
                    break
                case .commitThenTransportFailure:
                    throw WebDAVError.transportFailure("MOVE response lost")
                case .commitThenStatus(let statusCode):
                    return WebDAVTransportResponse(statusCode: statusCode)
                }
            }
            return WebDAVTransportResponse(statusCode: 201)

        case "GET":
            guard let data = resources[url] else {
                return WebDAVTransportResponse(statusCode: 404)
            }
            return WebDAVTransportResponse(data: data, statusCode: 200)

        case "DELETE":
            if isMoveProbeResource(url), failProbeCleanup, !injectedCleanupFailure {
                injectedCleanupFailure = true
                resources.removeValue(forKey: url)
                return WebDAVTransportResponse(statusCode: 500)
            }
            if resources.removeValue(forKey: url) != nil {
                return WebDAVTransportResponse(statusCode: 204)
            }
            if collections.remove(url) != nil {
                if isMoveProbeCollection(url) {
                    didAttemptProbeCollectionCleanup = true
                    probeCollectionWasDeleted = true
                }
                return WebDAVTransportResponse(statusCode: 204)
            }
            return WebDAVTransportResponse(statusCode: 404)

        default:
            return WebDAVTransportResponse(statusCode: 405)
        }
    }

    private func isMoveProbeCollection(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("PGYMacMenu-move-probe-")
    }

    private func isMoveProbeResource(_ url: URL) -> Bool {
        isMoveProbeCollection(url.deletingLastPathComponent())
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
