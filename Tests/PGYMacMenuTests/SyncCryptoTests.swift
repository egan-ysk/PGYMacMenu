import Foundation
import XCTest
@testable import PGYMacMenu

final class SyncCryptoTests: XCTestCase {
    private let passphrase = "correct horse"
    private let salt = Data(0 ... 15)
    private let nonce = Data(16 ... 27)

    func testPBKDF2SHA256FixedVector() throws {
        let key = try SyncCrypto.deriveKeyData(passphrase: passphrase, salt: salt)
        XCTAssertEqual(
            key.hexString,
            "96a5904c2e08c8da42305dbcc5d7cf18ead2636d49f59526b606f26696281473"
        )
    }

    func testDeterministicSealRoundTripsWithFixedSaltAndNonce() throws {
        let plaintext = Data("encrypted payload".utf8)
        let first = try SyncCrypto.seal(
            plaintext,
            passphrase: passphrase,
            salt: salt,
            nonce: nonce
        )
        let second = try SyncCrypto.seal(
            plaintext,
            passphrase: passphrase,
            salt: salt,
            nonce: nonce
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.salt.count, 16)
        XCTAssertEqual(first.nonce.count, 12)
        XCTAssertEqual(first.tag.count, 16)
        XCTAssertEqual(first.ciphertext.hexString, "6b2d1170628c8c5d038f9ee597a1639f88")
        XCTAssertEqual(first.tag.hexString, "82ab6b60e1a182c97ac1c91f32601cf2")
        XCTAssertEqual(try SyncCrypto.open(first, passphrase: passphrase), plaintext)
    }

    func testProductionSealUsesFreshSaltAndNonce() throws {
        let plaintext = Data("same payload".utf8)
        let first = try SyncCrypto.seal(plaintext, passphrase: passphrase)
        let second = try SyncCrypto.seal(plaintext, passphrase: passphrase)

        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.ciphertext + first.tag, second.ciphertext + second.tag)
    }

    func testDocumentRoundTripPreservesUnicodeAndPassphraseSpaces() throws {
        let passwordWithSpaces = "  同步 pass phrase  "
        let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let document = SyncDocument(
            datasetID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            generation: 7,
            previousHash: "abc",
            apiKeyProfiles: [
                VersionedRecord(
                    id: profileID,
                    order: 1,
                    revision: .init(wallTimeMilliseconds: 100, counter: 2),
                    writerDeviceID: "MacBook-设备",
                    value: SyncAPIKeyProfileValue(
                        name: "生产环境",
                        apiKey: "secret-api-key",
                        password: "install-password",
                        updateTemplate: "修复问题"
                    )
                )
            ]
        )

        let encrypted = try SyncCrypto.encrypt(document: document, passphrase: passwordWithSpaces)
        let decrypted = try SyncCrypto.decryptDocument(from: encrypted, passphrase: passwordWithSpaces)
        XCTAssertEqual(decrypted, try document.normalized())

        XCTAssertThrowsError(
            try SyncCrypto.decryptDocument(
                from: encrypted,
                passphrase: passwordWithSpaces.trimmingCharacters(in: .whitespaces)
            )
        ) { error in
            XCTAssertEqual(error as? SyncCryptoError, .authenticationFailed)
        }
    }

    func testWrongPassphraseAndTamperedCiphertextFailClosed() throws {
        let envelope = try SyncCrypto.seal(
            Data("top secret".utf8),
            passphrase: passphrase,
            salt: salt,
            nonce: nonce
        )

        XCTAssertThrowsError(try SyncCrypto.open(envelope, passphrase: "incorrect key")) { error in
            XCTAssertEqual(error as? SyncCryptoError, .authenticationFailed)
        }

        var tampered = envelope
        tampered.tag = Data(tampered.tag.enumerated().map { index, byte in
            index == 0 ? byte ^ 0x01 : byte
        })
        XCTAssertThrowsError(try SyncCrypto.open(tampered, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? SyncCryptoError, .authenticationFailed)
        }
    }

    func testEnvelopeAndKDFLimitsAreValidatedBeforeExpensiveWork() throws {
        XCTAssertThrowsError(
            try SyncCrypto.seal(
                Data(repeating: 0, count: SyncCrypto.maximumFileSize + 1),
                passphrase: passphrase
            )
        ) { error in
            XCTAssertEqual(error as? SyncCryptoError, .fileTooLarge)
        }

        XCTAssertThrowsError(
            try SyncCrypto.decodeEnvelope(
                from: Data(repeating: 0, count: SyncCrypto.maximumFileSize + 1)
            )
        ) { error in
            XCTAssertEqual(error as? SyncCryptoError, .fileTooLarge)
        }

        var envelope = try SyncCrypto.seal(
            Data("payload".utf8),
            passphrase: passphrase,
            salt: salt,
            nonce: nonce
        )
        envelope.kdf.iterations += 1
        XCTAssertThrowsError(try SyncCrypto.open(envelope, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? SyncCryptoError, .invalidKDFParameters)
        }

        envelope.kdf.iterations = SyncCrypto.pbkdf2Iterations
        envelope.version = 2
        XCTAssertThrowsError(try SyncCrypto.open(envelope, passphrase: passphrase)) { error in
            XCTAssertEqual(error as? SyncCryptoError, .unsupportedEnvelopeVersion(2))
        }
    }

    func testShortPassphraseIsRejectedWithoutTrimmingValidWhitespace() throws {
        XCTAssertThrowsError(
            try SyncCrypto.seal(Data(), passphrase: "short")
        ) { error in
            XCTAssertEqual(error as? SyncCryptoError, .passphraseTooShort)
        }

        XCTAssertNoThrow(
            try SyncCrypto.seal(
                Data(),
                passphrase: String(repeating: " ", count: SyncCrypto.minimumPassphraseLength),
                salt: salt,
                nonce: nonce
            )
        )
    }

    func testCanonicallyEquivalentUnicodePassphrasesDeriveTheSameKey() throws {
        let composed = String(repeating: "é", count: SyncCrypto.minimumPassphraseLength)
        let decomposedCharacter = "e\u{301}"
        let decomposed = String(repeating: decomposedCharacter, count: SyncCrypto.minimumPassphraseLength)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))

        let envelope = try SyncCrypto.seal(
            Data("canonical unicode".utf8),
            passphrase: composed,
            salt: salt,
            nonce: nonce
        )
        XCTAssertEqual(
            try SyncCrypto.open(envelope, passphrase: decomposed),
            Data("canonical unicode".utf8)
        )
    }

    func testPassphraseUTF8ByteLimitIsEnforcedAfterNormalization() {
        let oversized = String(repeating: "a", count: SyncCrypto.maximumPassphraseByteCount + 1)
        XCTAssertThrowsError(try SyncCrypto.seal(Data(), passphrase: oversized)) { error in
            XCTAssertEqual(error as? SyncCryptoError, .passphraseTooLong)
        }
    }

    func testEnvelopeEncodingContainsNoPlaintextSecrets() throws {
        let secret = "API-KEY-PLAINTEXT-MARKER"
        let document = SyncDocument(
            apiKeyProfiles: [
                VersionedRecord(
                    id: UUID(),
                    order: 0,
                    revision: .init(wallTimeMilliseconds: 1),
                    writerDeviceID: "device",
                    value: SyncAPIKeyProfileValue(
                        name: "name",
                        apiKey: secret,
                        password: "password",
                        updateTemplate: "template"
                    )
                )
            ]
        )
        let encrypted = try SyncCrypto.encrypt(document: document, passphrase: passphrase)
        XCTAssertNil(String(data: encrypted, encoding: .utf8)?.range(of: secret))
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
