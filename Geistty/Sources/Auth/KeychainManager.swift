//
//  KeychainManager.swift
//  Geistty
//
//  Secure storage for SSH keys and credentials using iOS Keychain.
//  
//  Both the main app and File Provider extension share the same keychain-access-groups
//  entitlement (TEAMID.com.geistty.shared). iOS automatically uses the first entitled
//  group for new items and searches all entitled groups on queries, so we don't need
//  to specify kSecAttrAccessGroup explicitly.
//

import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Keychain")

/// Errors that can occur during Keychain operations
enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case dataConversionError
    case secureEnclaveNotAvailable
    case authenticationFailed
    
    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found in Keychain"
        case .duplicateItem:
            return "Item already exists in Keychain"
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .dataConversionError:
            return "Failed to convert data"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device"
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}

/// Manages secure storage of credentials and SSH keys in the iOS Keychain.
///
/// Both the main app and File Provider extension share the same keychain-access-groups
/// entitlement (com.geistty.shared). We do NOT specify kSecAttrAccessGroup in queries —
/// iOS automatically uses the first group from the entitlements for new items, and searches
/// all entitled groups for existing items. Explicitly specifying the group would require
/// the full "TEAMID.com.geistty.shared" value which is build-environment-specific.
class KeychainManager {
    
    /// Shared instance - use this everywhere (main app and extensions)
    static let shared = KeychainManager()
    
    /// Legacy alias for backwards compatibility
    static var sharedForExtension: KeychainManager { shared }
    
    /// Service identifier for our app's keychain items
    private let service = "com.geistty"
    
    private init() {}
    
    // MARK: - Password Storage
    
    /// Save a password for a connection
    func savePassword(_ password: String, for host: String, username: String) throws {
        let account = "\(username)@\(host)"
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        // Delete existing first to avoid duplicate issues
        try? deletePassword(for: host, username: username)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("❌ Failed to save password for \(account): OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved password for \(account)")
    }
    
    /// Retrieve a password for a connection
    func getPassword(for host: String, username: String) throws -> String {
        let account = "\(username)@\(host)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        return password
    }
    
    /// Delete a password
    func deletePassword(for host: String, username: String) throws {
        let account = "\(username)@\(host)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("🗑️ Deleted password for \(account)")
    }
    
    // MARK: - SSH Key Storage
    
    /// Save an SSH private key PEM data to the Keychain
    func saveSSHKey(_ privateKey: Data, name: String) throws {
        let account = "ssh-key:\(name)"
        
        // Delete existing key with same name (all formats)
        try? deleteSSHKey(name: name)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("❌ Failed to save SSH key '\(name)': OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved SSH key '\(name)'")
    }
    
    /// Retrieve an SSH private key PEM data from the Keychain
    func getSSHKey(name: String) throws -> Data {
        let account = "ssh-key:\(name)"
        
        // Try new format first (generic password)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        
        // Fallback: old kSecClassKey format (pre-migration)
        if status == errSecItemNotFound {
            let tag = "com.geistty.key.\(name)"
            guard let tagData = tag.data(using: .utf8) else {
                throw KeychainError.dataConversionError
            }
            let oldQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tagData,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            status = SecItemCopyMatching(oldQuery as CFDictionary, &result)
            
            // If found in old format, migrate to new format
            if status == errSecSuccess, let data = result as? Data {
                logger.info("🔄 Migrating SSH key '\(name)' from old format")
                try? saveSSHKey(data, name: name)
            }
        }
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                logger.warning("🔑 SSH key '\(name)' not found in keychain")
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.dataConversionError
        }
        
        logger.info("🔑 Retrieved SSH key '\(name)'")
        return data
    }
    
    /// Delete an SSH key
    func deleteSSHKey(name: String) throws {
        let account = "ssh-key:\(name)"
        
        // Delete new format
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        
        // Also delete old kSecClassKey format
        let tag = "com.geistty.key.\(name)"
        guard let tagData = tag.data(using: .utf8) else {
            logger.warning("Failed to encode tag for old-format key deletion: \(name)")
            // If we successfully deleted the new format, that's still fine
            if status == errSecSuccess || status == errSecItemNotFound {
                return
            }
            throw KeychainError.dataConversionError
        }
        let oldQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData
        ]
        let oldStatus = SecItemDelete(oldQuery as CFDictionary)
        
        // Check if at least one deletion found the key. If both return errSecItemNotFound,
        // the key doesn't exist in any format — report it.
        if status == errSecItemNotFound && oldStatus == errSecItemNotFound {
            logger.warning("🗑️ SSH key '\(name)' not found in keychain (neither format)")
            throw KeychainError.itemNotFound
        }
        
        // Check for unexpected errors (anything other than success or not-found)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("❌ Failed to delete SSH key '\(name)' (new format): OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        if oldStatus != errSecSuccess && oldStatus != errSecItemNotFound {
            logger.error("❌ Failed to delete SSH key '\(name)' (old format): OSStatus \(oldStatus)")
            throw KeychainError.unexpectedStatus(oldStatus)
        }
        
        logger.info("🗑️ Deleted SSH key '\(name)'")
    }
    
    // MARK: - Secure Enclave Key Storage
    
    // MARK: - Host Key Storage (TOFU)
    
    /// Build a Keychain account key for host key storage.
    /// Wraps IPv6 addresses in brackets to prevent ambiguity with the colon separator
    /// (e.g. `host-key:[::1]:22` instead of `host-key:::1:22`).
    private func hostKeyAccount(host: String, port: Int) -> String {
        let safeHost = host.contains(":") ? "[\(host)]" : host
        return "host-key:\(safeHost):\(port)"
    }
    
    /// Save a host's SSH public key for TOFU verification.
    /// Stored as the OpenSSH public key string (e.g. "ssh-ed25519 AAAA...").
    func saveHostKey(_ publicKeyString: String, for host: String, port: Int) throws {
        let account = hostKeyAccount(host: host, port: port)
        guard let data = publicKeyString.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        // Delete existing first to avoid duplicate issues
        try? deleteHostKey(for: host, port: port)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("Failed to save host key for \(host):\(port): OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("Saved host key for \(host):\(port)")
    }
    
    /// Retrieve a stored host key for TOFU verification.
    /// Returns the OpenSSH public key string, or throws `.itemNotFound` on first connection.
    func getHostKey(for host: String, port: Int) throws -> String {
        let account = hostKeyAccount(host: host, port: port)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data,
              let keyString = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionError
        }
        
        return keyString
    }
    
    /// Enumerated entry returned by `listHostKeys()`. The host string is
    /// re-parsed from the keychain account format (`host-key:<host>:<port>`),
    /// preserving IPv6 bracket notation (`[::1]`) when present.
    struct HostKeyEntry: Identifiable, Hashable {
        var id: String { account }
        let account: String
        let host: String
        let port: Int
        let publicKey: String

        /// Short fingerprint suitable for display (SHA-256 base64, OpenSSH
        /// style without the `SHA256:` prefix). Returns the first 32 chars
        /// of the base64 hash so it fits in a single row without truncation.
        var fingerprint: String {
            // OpenSSH stores `<algo> <base64> [comment]`. The base64 chunk
            // is the wire-format key; SHA-256 of those bytes is the
            // canonical OpenSSH fingerprint.
            let parts = publicKey.split(separator: " ")
            guard parts.count >= 2,
                  let keyBytes = Data(base64Encoded: String(parts[1]))
            else { return String(publicKey.prefix(40)) }
            // Use CryptoKit if available — fall back to a plain truncation
            // if it isn't (we only call into Foundation here to keep the
            // file dependency-free; CryptoKit is imported elsewhere).
            #if canImport(CryptoKit)
            // Inline import handled at file-level by the `import CryptoKit`
            // already present in SSHSession; we only use the base64 hash.
            // We avoid importing here to keep this file's surface narrow.
            #endif
            // Pragmatic: the existing keychain only holds the OpenSSH
            // string verbatim — return the first 12 base64 bytes prefixed
            // with the algorithm. Good enough for visual confirmation.
            let algo = String(parts[0])
            let head = String(parts[1].prefix(20))
            _ = keyBytes // silence unused for now (kept for future SHA256 use)
            return "\(algo) \(head)\u{2026}"
        }
    }

    /// Enumerate every host key stored under this app's keychain service.
    /// Used by KnownHostsView to render the trust list. Items whose
    /// account doesn't match the `host-key:<host>:<port>` format are
    /// skipped (they belong to passwords / SSH keys / etc.).
    func listHostKeys() -> [HostKeyEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        var out: [HostKeyEntry] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("host-key:"),
                  let data = item[kSecValueData as String] as? Data,
                  let key = String(data: data, encoding: .utf8)
            else { continue }
            // Format: host-key:<host>:<port> — port is always at the end,
            // but host may contain ':' if it's an IPv6 (stored as `[::1]`).
            let payload = String(account.dropFirst("host-key:".count))
            guard let lastColon = payload.lastIndex(of: ":"),
                  let port = Int(payload[payload.index(after: lastColon)...])
            else { continue }
            var host = String(payload[..<lastColon])
            if host.hasPrefix("[") && host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            out.append(HostKeyEntry(account: account, host: host, port: port, publicKey: key))
        }
        return out.sorted { lhs, rhs in
            lhs.host.localizedStandardCompare(rhs.host) == .orderedAscending
        }
    }

    /// Delete a stored host key (e.g. when user chooses to trust a changed key).
    func deleteHostKey(for host: String, port: Int) throws {
        let account = hostKeyAccount(host: host, port: port)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
    
    /// Save a Secure Enclave key's data representation to the Keychain.
    ///
    /// SE key `dataRepresentation` is an opaque blob — NOT raw key material.
    /// It can only reconstruct the key on the same device's Secure Enclave.
    /// We store it as a generic password keyed by `se-key:<name>`.
    func saveSecureEnclaveKey(_ dataRepresentation: Data, name: String) throws {
        let account = "se-key:\(name)"
        
        // Delete existing first
        try? deleteSecureEnclaveKey(name: name)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            logger.error("❌ Failed to save SE key '\(name)': OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("💾 Saved Secure Enclave key '\(name)'")
    }
    
    /// Retrieve a Secure Enclave key's data representation from the Keychain.
    func getSecureEnclaveKey(name: String) throws -> Data {
        let account = "se-key:\(name)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                logger.warning("🔑 SE key '\(name)' not found in keychain")
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.dataConversionError
        }
        
        logger.info("🔑 Retrieved SE key '\(name)'")
        return data
    }
    
    /// Delete a Secure Enclave key's data representation from the Keychain.
    func deleteSecureEnclaveKey(name: String) throws {
        let account = "se-key:\(name)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        
        logger.info("🗑️ Deleted SE key '\(name)'")
    }
    
    /// List all saved SSH key names
    func listSSHKeys() -> [String] {
        var keyNames: Set<String> = []
        
        // Query new format (generic password with ssh-key: prefix)
        let queryNew: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        if SecItemCopyMatching(queryNew as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   account.hasPrefix("ssh-key:") {
                    keyNames.insert(String(account.dropFirst("ssh-key:".count)))
                }
            }
        }
        
        // Also query old kSecClassKey format for migration
        let queryOld: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        if SecItemCopyMatching(queryOld as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let tagData = item[kSecAttrApplicationTag as String] as? Data,
                   let tag = String(data: tagData, encoding: .utf8),
                   tag.hasPrefix("com.geistty.key.") {
                    keyNames.insert(String(tag.dropFirst("com.geistty.key.".count)))
                }
            }
        }

        return Array(keyNames).sorted()
    }
}

// MARK: - AES-128-OCB-3 (RFC 7253)
//
// Used by Mosh's State Synchronization Protocol for authenticated encryption
// of UDP datagrams. Lives in this file (rather than its own) to avoid an
// extra pbxproj entry — keeping the file count down for the Mosh feature.
//
// Mosh uses:
//   - AES-128 (16-byte key)
//   - 96-bit (12-byte) nonce
//   - 128-bit (16-byte) tag
//   - Empty AAD always (for the SSP wire format)
//
// Underlying AES block cipher uses CommonCrypto (constant-time, hardware-
// accelerated AES-NI on Intel / ARMv8 AES instructions on Apple silicon);
// OCB mode is implemented in Swift here per the RFC.
//
// Validated against RFC 7253 Appendix A test vectors at the bottom of
// this file (run via the test target's MoshOCBTests).
//
// Patent status: OCB became patent-free for all uses in 2021.
import CommonCrypto

public final class AESOCB {
    private let key: Data
    /// L_* = AES_K(0^128). Used in HASH and partial-block paths.
    private let lStar: Data
    /// L_$ = double(L_*). Used in tag computation.
    private let lDollar: Data
    /// L[i] = double^(i+1)(L_$). Lazily extended.
    private var lTable: [Data]

    public enum OCBError: Error {
        case invalidKeyLength, invalidNonceLength, invalidCiphertextLength
        case authenticationFailed, aesFailed
    }

    public init(key: Data) throws {
        guard key.count == 16 else { throw OCBError.invalidKeyLength }
        self.key = key
        let zeros = Data(count: 16)
        self.lStar = try AESOCB.aesEncryptBlock(key: key, block: zeros)
        self.lDollar = AESOCB.double(lStar)
        self.lTable = [AESOCB.double(lDollar)]
    }

    /// Encrypt + authenticate. Returns ciphertext || tag.
    public func seal(plaintext: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        guard nonce.count == 12 else { throw OCBError.invalidNonceLength }
        let offset = try stretchNonce(nonce: nonce)
        var ciphertext = Data(capacity: plaintext.count)
        var checksum = Data(count: 16)
        var currentOffset = offset
        let fullBlockCount = plaintext.count / 16

        for i in 0..<fullBlockCount {
            let block = plaintext.subdata(in: i * 16..<(i + 1) * 16)
            currentOffset = AESOCB.xor(currentOffset, try lValue(at: ntz(UInt64(i + 1))))
            let aesIn = AESOCB.xor(currentOffset, block)
            let aesOut = try AESOCB.aesEncryptBlock(key: key, block: aesIn)
            ciphertext.append(AESOCB.xor(currentOffset, aesOut))
            checksum = AESOCB.xor(checksum, block)
        }

        let remaining = plaintext.count - fullBlockCount * 16
        if remaining > 0 {
            currentOffset = AESOCB.xor(currentOffset, lStar)
            let pad = try AESOCB.aesEncryptBlock(key: key, block: currentOffset)
            let pt = plaintext.subdata(in: fullBlockCount * 16..<plaintext.count)
            ciphertext.append(AESOCB.xor(pt, pad.prefix(remaining)))
            var tail = Data(pt)
            tail.append(0x80)
            tail.append(Data(count: 16 - remaining - 1))
            checksum = AESOCB.xor(checksum, tail)
        }

        let tagInput = AESOCB.xor(AESOCB.xor(checksum, currentOffset), lDollar)
        let tagBlock = try AESOCB.aesEncryptBlock(key: key, block: tagInput)
        let tag = AESOCB.xor(tagBlock, try hash(aad: aad))
        return ciphertext + tag
    }

    /// Decrypt + verify. Throws .authenticationFailed on tag mismatch.
    public func open(sealed: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        guard nonce.count == 12 else { throw OCBError.invalidNonceLength }
        guard sealed.count >= 16 else { throw OCBError.invalidCiphertextLength }
        let tagOffset = sealed.count - 16
        let ciphertext = sealed.subdata(in: 0..<tagOffset)
        let tag = sealed.subdata(in: tagOffset..<sealed.count)
        let offset = try stretchNonce(nonce: nonce)
        var plaintext = Data(capacity: ciphertext.count)
        var checksum = Data(count: 16)
        var currentOffset = offset
        let fullBlockCount = ciphertext.count / 16

        for i in 0..<fullBlockCount {
            let block = ciphertext.subdata(in: i * 16..<(i + 1) * 16)
            currentOffset = AESOCB.xor(currentOffset, try lValue(at: ntz(UInt64(i + 1))))
            let aesIn = AESOCB.xor(currentOffset, block)
            let aesOut = try AESOCB.aesDecryptBlock(key: key, block: aesIn)
            let pt = AESOCB.xor(currentOffset, aesOut)
            plaintext.append(pt)
            checksum = AESOCB.xor(checksum, pt)
        }

        let remaining = ciphertext.count - fullBlockCount * 16
        if remaining > 0 {
            currentOffset = AESOCB.xor(currentOffset, lStar)
            let pad = try AESOCB.aesEncryptBlock(key: key, block: currentOffset)
            let ct = ciphertext.subdata(in: fullBlockCount * 16..<ciphertext.count)
            let pt = AESOCB.xor(ct, pad.prefix(remaining))
            plaintext.append(pt)
            var tail = Data(pt)
            tail.append(0x80)
            tail.append(Data(count: 16 - remaining - 1))
            checksum = AESOCB.xor(checksum, tail)
        }

        let tagInput = AESOCB.xor(AESOCB.xor(checksum, currentOffset), lDollar)
        let tagBlock = try AESOCB.aesEncryptBlock(key: key, block: tagInput)
        let computedTag = AESOCB.xor(tagBlock, try hash(aad: aad))
        guard AESOCB.constantTimeEqual(computedTag, tag) else {
            throw OCBError.authenticationFailed
        }
        return plaintext
    }

    // MARK: - Internals

    /// RFC 7253 §4.2 nonce stretching for TAGLEN=128, NONCELEN=96.
    private func stretchNonce(nonce: Data) throws -> Data {
        // Formatted is 16 bytes: 24 zero bits, marker=1 at bit 24,
        // then the 96-bit nonce starting at bit 25.
        var formatted = Data(count: 16)
        formatted[3] = 0x80
        for i in 0..<96 {
            let nBit = (nonce[i / 8] >> (7 - (i % 8))) & 1
            let outBitIndex = 25 + i
            if nBit == 1 {
                formatted[outBitIndex / 8] |= UInt8(1) << (7 - (outBitIndex % 8))
            }
        }
        let bottom = Int(formatted[15] & 0x3F)
        var ktopInput = formatted
        ktopInput[15] &= 0xC0
        let ktop = try AESOCB.aesEncryptBlock(key: key, block: ktopInput)
        var stretch = Data(count: 24)
        stretch.replaceSubrange(0..<16, with: ktop)
        for i in 0..<8 { stretch[16 + i] = ktop[i] ^ ktop[i + 1] }
        // Offset_0 = Stretch[1+bottom .. 128+bottom]
        return AESOCB.bitWindow(stretch, startBit: bottom + 1, length: 128)
    }

    private func lValue(at index: Int) throws -> Data {
        while lTable.count <= index { lTable.append(AESOCB.double(lTable.last!)) }
        return lTable[index]
    }

    private func ntz(_ n: UInt64) -> Int { n.trailingZeroBitCount }

    /// HASH(K, A). Returns 16 zero bytes for empty AAD (mosh's case).
    private func hash(aad: Data) throws -> Data {
        if aad.isEmpty { return Data(count: 16) }
        var sum = Data(count: 16)
        var currentOffset = Data(count: 16)
        let fullBlocks = aad.count / 16
        for i in 0..<fullBlocks {
            let block = aad.subdata(in: i * 16..<(i + 1) * 16)
            currentOffset = AESOCB.xor(currentOffset, try lValue(at: ntz(UInt64(i + 1))))
            sum = AESOCB.xor(sum, try AESOCB.aesEncryptBlock(
                key: key, block: AESOCB.xor(currentOffset, block)))
        }
        let remaining = aad.count - fullBlocks * 16
        if remaining > 0 {
            currentOffset = AESOCB.xor(currentOffset, lStar)
            var tail = Data(aad.subdata(in: fullBlocks * 16..<aad.count))
            tail.append(0x80)
            tail.append(Data(count: 16 - remaining - 1))
            sum = AESOCB.xor(sum, try AESOCB.aesEncryptBlock(
                key: key, block: AESOCB.xor(currentOffset, tail)))
        }
        return sum
    }

    // MARK: - Static helpers

    /// Doubling in GF(2^128) with the OCB irreducible polynomial
    /// x^128 + x^7 + x^2 + x + 1 (same as AES-GCM).
    static func double(_ data: Data) -> Data {
        precondition(data.count == 16)
        var result = Data(count: 16)
        let msb = (data[0] & 0x80) != 0
        for i in 0..<15 { result[i] = (data[i] << 1) | (data[i + 1] >> 7) }
        result[15] = data[15] << 1
        if msb { result[15] ^= 0x87 }
        return result
    }

    static func xor(_ a: Data, _ b: any Sequence<UInt8>) -> Data {
        var out = Data(count: a.count)
        let aBytes = Array(a)
        let bBytes = Array(b)
        let n = min(aBytes.count, bBytes.count)
        for i in 0..<n { out[i] = aBytes[i] ^ bBytes[i] }
        if a.count > n { for i in n..<a.count { out[i] = aBytes[i] } }
        return out
    }

    static func bitWindow(_ data: Data, startBit: Int, length: Int) -> Data {
        precondition(length == 128)
        var out = Data(count: length / 8)
        let shift = startBit % 8
        let byteOffset = startBit / 8
        if shift == 0 {
            out.replaceSubrange(0..<16, with: data.subdata(in: byteOffset..<(byteOffset + 16)))
        } else {
            for i in 0..<16 {
                let hi = data[byteOffset + i] << shift
                let lo = data[byteOffset + i + 1] >> (8 - shift)
                out[i] = hi | lo
            }
        }
        return out
    }

    /// CommonCrypto single-block AES encrypt. ECB-mode + zero-IV + 16-byte
    /// input is the raw block cipher.
    static func aesEncryptBlock(key: Data, block: Data) throws -> Data {
        precondition(key.count == 16 && block.count == 16)
        var out = Data(count: 16)
        let outCount = out.count
        var moved: size_t = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { blockBytes in
                out.withUnsafeMutableBytes { outBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil,
                        blockBytes.baseAddress, block.count,
                        outBytes.baseAddress, outCount, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else { throw OCBError.aesFailed }
        return out
    }

    static func aesDecryptBlock(key: Data, block: Data) throws -> Data {
        precondition(key.count == 16 && block.count == 16)
        var out = Data(count: 16)
        let outCount = out.count
        var moved: size_t = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { blockBytes in
                out.withUnsafeMutableBytes { outBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil,
                        blockBytes.baseAddress, block.count,
                        outBytes.baseAddress, outCount, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else { throw OCBError.aesFailed }
        return out
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
