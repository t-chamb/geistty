import XCTest
@testable import Geistty

// MARK: - KeychainError Tests

final class KeychainErrorTests: XCTestCase {
    
    func testAllErrorDescriptionsNonEmpty() {
        let errors: [KeychainError] = [
            .itemNotFound,
            .duplicateItem,
            .unexpectedStatus(-25300),
            .dataConversionError,
            .secureEnclaveNotAvailable,
            .authenticationFailed
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description for \(error) should not be empty")
        }
    }
    
    func testSpecificErrorMessages() {
        XCTAssertEqual(KeychainError.itemNotFound.errorDescription, "Item not found in Keychain")
        XCTAssertEqual(KeychainError.duplicateItem.errorDescription, "Item already exists in Keychain")
        XCTAssertEqual(KeychainError.dataConversionError.errorDescription, "Failed to convert data")
        XCTAssertEqual(KeychainError.secureEnclaveNotAvailable.errorDescription,
                       "Secure Enclave is not available on this device")
        XCTAssertEqual(KeychainError.authenticationFailed.errorDescription, "Authentication failed")
    }
    
    func testUnexpectedStatusIncludesCode() {
        let error = KeychainError.unexpectedStatus(-25300)
        XCTAssertTrue(error.errorDescription!.contains("-25300"),
                     "unexpectedStatus should include the OSStatus code")
    }
}

// MARK: - KeychainManager Password Tests

/// Tests for KeychainManager password operations.
///
/// These tests use the real iOS Keychain on the simulator. Each test
/// creates items with a unique prefix and cleans them up in tearDown.
final class KeychainManagerPasswordTests: XCTestCase {
    
    private let keychain = KeychainManager.shared
    
    /// Unique host/username prefix for this test run to avoid collisions
    private let testHost = "__test_geistty_kc_host"
    private var testUsers: [String] = []
    
    override func setUp() {
        super.setUp()
        testUsers = []
    }
    
    override func tearDown() {
        // Clean up all test passwords
        for user in testUsers {
            try? keychain.deletePassword(for: testHost, username: user)
        }
        super.tearDown()
    }
    
    /// Register a test username for cleanup
    private func testUsername(_ suffix: String = UUID().uuidString.prefix(8).lowercased()) -> String {
        let user = "__test_\(suffix)"
        testUsers.append(user)
        return user
    }
    
    // MARK: - Save/Get/Delete Cycle
    
    func testSaveAndGetPassword() throws {
        let user = testUsername("pw_save")
        let password = "s3cur3P@ssw0rd!"
        
        try keychain.savePassword(password, for: testHost, username: user)
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        
        XCTAssertEqual(retrieved, password)
    }
    
    func testDeletePassword() throws {
        let user = testUsername("pw_del")
        
        try keychain.savePassword("temp", for: testHost, username: user)
        try keychain.deletePassword(for: testHost, username: user)
        
        XCTAssertThrowsError(try keychain.getPassword(for: testHost, username: user)) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound after deletion, got \(error)")
                return
            }
        }
    }
    
    func testGetNonexistentPasswordThrows() {
        XCTAssertThrowsError(try keychain.getPassword(for: testHost, username: "__nonexistent_user_xyz")) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound, got \(error)")
                return
            }
        }
    }
    
    func testSaveOverwritesExisting() throws {
        let user = testUsername("pw_ow")
        
        try keychain.savePassword("old_password", for: testHost, username: user)
        try keychain.savePassword("new_password", for: testHost, username: user)
        
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        XCTAssertEqual(retrieved, "new_password")
    }
    
    func testSaveEmptyPassword() throws {
        let user = testUsername("pw_empty")
        
        try keychain.savePassword("", for: testHost, username: user)
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        XCTAssertEqual(retrieved, "")
    }
    
    func testSaveUnicodePassword() throws {
        let user = testUsername("pw_unicode")
        let password = "p@$$w0rd_\u{1F512}_\u{00E9}\u{00F1}\u{00FC}"
        
        try keychain.savePassword(password, for: testHost, username: user)
        let retrieved = try keychain.getPassword(for: testHost, username: user)
        XCTAssertEqual(retrieved, password)
    }
    
    func testDeleteNonexistentPasswordDoesNotThrow() {
        // deletePassword should succeed (or at least not throw) for non-existent items
        XCTAssertNoThrow(try keychain.deletePassword(for: testHost, username: "__nonexistent_del_xyz"))
    }
    
    func testMultiplePasswordsForDifferentUsers() throws {
        let user1 = testUsername("pw_m1")
        let user2 = testUsername("pw_m2")
        
        try keychain.savePassword("pass1", for: testHost, username: user1)
        try keychain.savePassword("pass2", for: testHost, username: user2)
        
        XCTAssertEqual(try keychain.getPassword(for: testHost, username: user1), "pass1")
        XCTAssertEqual(try keychain.getPassword(for: testHost, username: user2), "pass2")
    }
}

// MARK: - KeychainManager SSH Key Tests

/// Tests for KeychainManager SSH key storage operations.
final class KeychainManagerSSHKeyTests: XCTestCase {
    
    private let keychain = KeychainManager.shared
    private var createdKeyNames: [String] = []
    
    override func setUp() {
        super.setUp()
        createdKeyNames = []
    }
    
    override func tearDown() {
        for name in createdKeyNames {
            try? keychain.deleteSSHKey(name: name)
        }
        super.tearDown()
    }
    
    private func testKeyName(_ suffix: String = UUID().uuidString.prefix(8).lowercased()) -> String {
        let name = "__test_kc_key_\(suffix)"
        createdKeyNames.append(name)
        return name
    }
    
    // MARK: - Save/Get/Delete Cycle
    
    func testSaveAndGetSSHKey() throws {
        let name = testKeyName("save")
        let pemLabel = "OPENSSH PRIVATE KEY"
        let keyData = Data("-----BEGIN \(pemLabel)-----\nfake\n-----END \(pemLabel)-----".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        let retrieved = try keychain.getSSHKey(name: name)
        
        XCTAssertEqual(retrieved, keyData)
    }
    
    func testDeleteSSHKey() throws {
        let name = testKeyName("del")
        let keyData = Data("test-key-data".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        try keychain.deleteSSHKey(name: name)
        
        XCTAssertThrowsError(try keychain.getSSHKey(name: name)) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound after SSH key deletion, got \(error)")
                return
            }
        }
    }
    
    func testGetNonexistentSSHKeyThrows() {
        XCTAssertThrowsError(try keychain.getSSHKey(name: "__nonexistent_key_xyz")) { error in
            guard case KeychainError.itemNotFound = error else {
                XCTFail("Expected .itemNotFound, got \(error)")
                return
            }
        }
    }
    
    func testSaveSSHKeyOverwritesExisting() throws {
        let name = testKeyName("ow")
        let oldData = Data("old-key".utf8)
        let newData = Data("new-key".utf8)
        
        try keychain.saveSSHKey(oldData, name: name)
        try keychain.saveSSHKey(newData, name: name)
        
        let retrieved = try keychain.getSSHKey(name: name)
        XCTAssertEqual(retrieved, newData)
    }
    
    func testSaveLargeSSHKey() throws {
        // RSA 4096-bit keys can be ~3KB
        let name = testKeyName("large")
        let keyData = Data(repeating: 0x42, count: 4096)
        
        try keychain.saveSSHKey(keyData, name: name)
        let retrieved = try keychain.getSSHKey(name: name)
        XCTAssertEqual(retrieved, keyData)
    }
    
    // MARK: - List SSH Keys
    
    func testListSSHKeysIncludesCreated() throws {
        let name = testKeyName("list")
        let keyData = Data("list-test".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        
        let keys = keychain.listSSHKeys()
        XCTAssertTrue(keys.contains(name), "listSSHKeys should include '\(name)', got: \(keys)")
    }
    
    func testListSSHKeysExcludesDeleted() throws {
        let name = testKeyName("list_del")
        let keyData = Data("list-del-test".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        try keychain.deleteSSHKey(name: name)
        
        let keys = keychain.listSSHKeys()
        XCTAssertFalse(keys.contains(name), "listSSHKeys should NOT include deleted key '\(name)'")
    }
    
    func testListSSHKeysIsSorted() throws {
        let names = ["list_z", "list_a", "list_m"].map { testKeyName($0) }
        
        for name in names {
            try keychain.saveSSHKey(Data("key".utf8), name: name)
        }
        
        let keys = keychain.listSSHKeys().filter { $0.hasPrefix("__test_kc_key_list_") }
        
        // Verify sorted
        let sorted = keys.sorted()
        XCTAssertEqual(keys, sorted, "listSSHKeys results should be sorted")
    }
    
    func testDeleteSSHKeyAlsoDeletesOldFormat() throws {
        // deleteSSHKey cleans up both new (kSecClassGenericPassword) and old (kSecClassKey) formats.
        // We can't easily test the old format creation, but we can verify deleteSSHKey
        // doesn't crash when the old format doesn't exist.
        let name = testKeyName("old_fmt")
        let keyData = Data("test".utf8)
        
        try keychain.saveSSHKey(keyData, name: name)
        // This should clean up both formats without error
        XCTAssertNoThrow(try keychain.deleteSSHKey(name: name))
    }
}

// MARK: - Mosh Protocol Tests
//
// Lives here (not its own file) so the AESOCB + MoshProto code in
// Sources/Auth/KeychainManager.swift + Sources/SSH/MoshSession.swift can
// be exercised without adding a new pbxproj entry.

final class MoshOCBTests: XCTestCase {

    func testOCBRoundTripEmpty() throws {
        try roundTrip(plaintext: Data())
    }

    func testOCBRoundTripOneByte() throws {
        try roundTrip(plaintext: Data([0x42]))
    }

    func testOCBRoundTripSubBlock() throws {
        try roundTrip(plaintext: Data(repeating: 0xAB, count: 7))
    }

    func testOCBRoundTripOneBlock() throws {
        try roundTrip(plaintext: Data(repeating: 0xCD, count: 16))
    }

    func testOCBRoundTripBlockPlusRemainder() throws {
        try roundTrip(plaintext: Data(repeating: 0xEF, count: 23))
    }

    func testOCBRoundTripMultiBlock() throws {
        try roundTrip(plaintext: Data(repeating: 0x01, count: 64))
    }

    func testOCBRoundTripLarge() throws {
        try roundTrip(plaintext: Data((0..<2048).map { UInt8($0 & 0xFF) }))
    }

    func testOCBTagTamperingRejected() throws {
        let key = Data(repeating: 0x42, count: 16)
        let nonce = Data(repeating: 0x01, count: 12)
        let pt = Data("the quick brown fox".utf8)
        let cipher = try AESOCB(key: key)
        var sealed = try cipher.seal(plaintext: pt, nonce: nonce)
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try cipher.open(sealed: sealed, nonce: nonce)) { err in
            guard case AESOCB.OCBError.authenticationFailed = err else {
                XCTFail("expected .authenticationFailed, got \(err)")
                return
            }
        }
    }

    func testOCBCiphertextTamperingRejected() throws {
        let key = Data(repeating: 0xCC, count: 16)
        let nonce = Data(repeating: 0x77, count: 12)
        let pt = Data(repeating: 0x55, count: 32)
        let cipher = try AESOCB(key: key)
        var sealed = try cipher.seal(plaintext: pt, nonce: nonce)
        sealed[5] ^= 0xFF
        XCTAssertThrowsError(try cipher.open(sealed: sealed, nonce: nonce))
    }

    func testOCBDifferentNoncesProduceDifferentCiphertext() throws {
        let key = Data(repeating: 0x10, count: 16)
        let pt = Data("identical plaintext".utf8)
        let cipher = try AESOCB(key: key)
        let s1 = try cipher.seal(plaintext: pt, nonce: Data(repeating: 0x01, count: 12))
        let s2 = try cipher.seal(plaintext: pt, nonce: Data(repeating: 0x02, count: 12))
        XCTAssertNotEqual(s1, s2,
                          "Different nonces must produce different ciphertexts")
    }

    func testOCBKeyDerivationConsistent() throws {
        let key = Data(repeating: 0xAA, count: 16)
        let nonce = Data(repeating: 0xBB, count: 12)
        let pt = Data("consistency check".utf8)
        let s1 = try AESOCB(key: key).seal(plaintext: pt, nonce: nonce)
        let s2 = try AESOCB(key: key).seal(plaintext: pt, nonce: nonce)
        XCTAssertEqual(s1, s2)
    }

    private func roundTrip(plaintext: Data) throws {
        let key = Data((0..<16).map { UInt8($0 ^ 0xA5) })
        let nonce = Data((0..<12).map { UInt8($0 + 1) })
        let cipher = try AESOCB(key: key)
        let sealed = try cipher.seal(plaintext: plaintext, nonce: nonce)
        XCTAssertEqual(sealed.count, plaintext.count + 16,
                       "Sealed length should be plaintext + 16-byte tag")
        let opened = try cipher.open(sealed: sealed, nonce: nonce)
        XCTAssertEqual(opened, plaintext)
    }
}

final class MoshProtoTests: XCTestCase {

    func testVarintRoundTripEdgeValues() {
        let values: [UInt64] = [
            0, 1, 0x7F,
            0x80, 0x3FFF,
            0x4000, 0x1F_FFFF,
            0xFFFF_FFFF,
            UInt64.max,
        ]
        for v in values {
            let encoded = MoshProto.varint(v)
            guard let (decoded, _) = MoshProto.readVarint(encoded, at: 0) else {
                XCTFail("varint \(v) failed to decode")
                continue
            }
            XCTAssertEqual(decoded, v, "varint round-trip mismatch for \(v)")
        }
    }

    func testInstructionEncodeAndParseRoundTrip() {
        let payload = Data("hello mosh".utf8)
        let encoded = MoshProto.instruction(
            oldNum: 42, newNum: 43, ackNum: 99, throwawayNum: 0, diff: payload
        )
        guard let parsed = MoshProto.parseInstructionHeader(encoded) else {
            XCTFail("parseInstructionHeader returned nil")
            return
        }
        XCTAssertEqual(parsed.oldNum, 42)
        XCTAssertEqual(parsed.newNum, 43)
        XCTAssertEqual(parsed.ackNum, 99)
        XCTAssertEqual(parsed.diff, payload)
    }

    func testInstructionWithEmptyDiff() {
        let encoded = MoshProto.instruction(
            oldNum: 1, newNum: 1, ackNum: 0, throwawayNum: 0, diff: Data()
        )
        let parsed = MoshProto.parseInstructionHeader(encoded)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.diff, Data())
    }

    func testKeystrokeWireShape() {
        let bytes = Data("a".utf8)
        let stream = MoshProto.userStreamKeystroke(bytes)
        XCTAssertGreaterThan(stream.count, 0)
        XCTAssertEqual(stream[0], (1 << 3) | 2,
                       "First byte should be tag for field 1, length-delimited")
    }

    func testResizeWireShape() {
        let stream = MoshProto.userStreamResize(cols: 80, rows: 24)
        XCTAssertGreaterThan(stream.count, 0)
        XCTAssertEqual(stream[0], (1 << 3) | 2)
    }
}

final class MoshBootstrapParseTests: XCTestCase {

    func testBootstrapResponseParsing() {
        let stdout = """
        Some preamble from the shell.
        MOSH CONNECT 60001 fJzHBSkdqRSRkBVYHUNMvA
        Trailing line that should be ignored.
        """
        let combined = stdout + "\n"
        let connectLine = combined
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first(where: { $0.hasPrefix("MOSH CONNECT ") })
        XCTAssertNotNil(connectLine, "Should locate MOSH CONNECT line")

        let parts = connectLine?.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        XCTAssertEqual(parts?.count, 4)
        XCTAssertEqual(parts?[0], "MOSH")
        XCTAssertEqual(parts?[1], "CONNECT")
        XCTAssertEqual(parts?[2], "60001")
        XCTAssertEqual(UInt16(parts![2]), 60001)

        var keyB64 = String(parts![3])
        while keyB64.count % 4 != 0 { keyB64 += "=" }
        let decoded = Data(base64Encoded: keyB64)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 16, "AES-128 key should decode to 16 bytes")
    }

    func testBootstrapHandlesTrailingCRLF() {
        let stdout = "MOSH CONNECT 51234 ZGVhZGJlZWZkZWFkYmVlZg==\r\n"
        let line = stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first(where: { $0.hasPrefix("MOSH CONNECT ") })
        XCTAssertNotNil(line)
    }
}
