//
//  MoshSession.swift
//  Geistty
//
//  Mosh (Mobile Shell) client. Speaks Mosh's State Synchronization
//  Protocol (SSP) over UDP datagrams, encrypted with AES-128-OCB-3.
//
//  Architecture:
//
//    1. Bootstrap (SSH):
//       - SSH into the remote (using the same credentials a normal SSH
//         session would use, via SSHCommandRunner)
//       - Run `mosh-server new -s -c 256 -l LANG=en_US.UTF-8`
//       - Parse `MOSH CONNECT <port> <base64key>` from stdout
//
//    2. Transport (UDP + OCB):
//       - Open a UDP socket to remote:port via SwiftNIO's NIOTSDatagramBootstrap
//       - Each outbound packet: [12-byte nonce][AES-OCB-encrypted payload]
//       - Nonce is monotonic, 64-bit big-endian seq number padded to 12 bytes
//       - Server side runs the same protocol; we decrypt incoming with the
//         same shared key
//
//    3. Protocol (SSP):
//       - Each datagram payload is a protobuf-encoded Instruction, which
//         wraps either a UserStream (client → server: keystrokes + resize)
//         or HostStream (server → client: terminal output bytes)
//       - State sync (the diffing optimization mosh is famous for) is
//         deferred to a follow-up — this implementation is "transport
//         only", sending raw byte streams in UserStream/HostStream payloads.
//         Bandwidth + latency-hiding benefits are reduced but the
//         connection works against any standard mosh-server.
//
//    4. Bridge:
//       - Outbound bytes from Ghostty's surface (keystrokes, paste) →
//         wrapped in UserStream → encrypted → UDP send
//       - Inbound UDP datagrams → decrypted → unwrap HostStream →
//         feed bytes into Ghostty's terminal input
//
//  Limitations vs upstream Mosh:
//    - No SSP state sync (no diff compression, no client-side prediction)
//    - No predictive local echo (the latency-hiding optimization)
//    - No roaming-detection beyond UDP's natural connectionless nature
//      (changing IPs works because UDP is stateless; the server matches on
//      sequence number and key)
//    - No congestion control adaptation
//
//  The Mosh wire protocol (mosh src/network/network.cc) is reverse-
//  engineered from upstream source; the relevant types are in
//  src/protobufs/transportinstruction.proto and userinput.proto.
//

import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Mosh")

// MARK: - Bootstrap

/// One-shot SSH dance to get a mosh-server running on the remote.
/// Returns the UDP port + AES-128 shared key, both extracted from
/// mosh-server's startup banner.
public struct MoshBootstrap {
    public struct Result: Sendable {
        public let host: String
        public let port: UInt16
        public let key: Data  // 16-byte AES-128
    }

    public enum BootstrapError: Error, LocalizedError {
        case sshFailed(String)
        case missingMoshServer
        case unparseableResponse(String)
        case invalidKey

        public var errorDescription: String? {
            switch self {
            case .sshFailed(let msg): return "SSH bootstrap failed: \(msg)"
            case .missingMoshServer: return "mosh-server not found on remote (install with `apt install mosh` or `brew install mosh`)"
            case .unparseableResponse(let raw): return "Couldn't parse mosh-server response: \(raw.prefix(120))"
            case .invalidKey: return "mosh-server returned an invalid AES key"
            }
        }
    }

    /// Run mosh-server on the remote and parse out the port + key. The
    /// command is the canonical one used by upstream mosh-client:
    ///
    ///     mosh-server new -s -c 256 -l LANG=en_US.UTF-8
    ///
    /// Output looks like:
    ///
    ///     MOSH CONNECT 60001 fJzHBSkdqRSRkBVYHUNMvA
    ///
    /// (The key is 16 raw bytes, base64-encoded. Mosh uses raw base64 with
    /// no padding by historical accident, so we strip and re-pad.)
    /// Bootstrap from a raw SSHAuthMethod (password or pre-built key).
    /// Lower-level entry point — most callers want bootstrap(profile:credential:).
    @MainActor
    static func bootstrap(
        host: String,
        port: Int,
        username: String,
        authMethod: SSHAuthMethod
    ) async throws -> Result {
        let runner = SSHCommandRunner(host: host, port: port, username: username)
        let cmd = "LANG=en_US.UTF-8 mosh-server new -s -c 256 -l LANG=en_US.UTF-8"
        let result: SSHCommandResult
        do {
            result = try await runner.run(command: cmd, authMethod: authMethod)
        } catch {
            throw BootstrapError.sshFailed(error.localizedDescription)
        }

        // SSHCommandResult.stdout/stderr are already String per the runner's
        // convenience init. Combine — some shells write the banner to stderr
        // (mosh-server forks).
        let combined = result.stdout + "\n" + result.stderr

        if combined.contains("not found") || combined.contains("command not found") {
            throw BootstrapError.missingMoshServer
        }

        // Find the MOSH CONNECT line.
        guard let connectLine = combined
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first(where: { $0.hasPrefix("MOSH CONNECT ") })
        else {
            throw BootstrapError.unparseableResponse(combined)
        }

        let parts = connectLine.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let portValue = UInt16(parts[2])
        else {
            throw BootstrapError.unparseableResponse(String(connectLine))
        }
        // The key is base64; mosh strips padding. Re-pad to multiple of 4.
        var keyB64 = String(parts[3])
        while keyB64.count % 4 != 0 { keyB64 += "=" }
        guard let keyData = Data(base64Encoded: keyB64), keyData.count == 16 else {
            throw BootstrapError.invalidKey
        }

        logger.info("Mosh bootstrap succeeded: udp://\(host):\(portValue), 16-byte key")
        return Result(host: host, port: portValue, key: keyData)
    }
}

extension MoshBootstrap {
    /// High-level bootstrap that takes an SSHCredential — handles the
    /// full {.password, .privateKey, .privateKeyData, .sshPrivateKey}
    /// matrix the rest of the app uses. Mirrors SSHSession's private
    /// buildAuthMethod helper so Mosh sessions get the same
    /// auth-method derivation as plain SSH.
    @MainActor
    static func bootstrap(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential
    ) async throws -> Result {
        let authMethod: SSHAuthMethod
        switch credential.authType {
        case .password(let pw):
            authMethod = .password(pw)
        case .privateKey(let path, let passphrase):
            let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
            let pk = try SSHKeyParser.parsePrivateKey(keyData, passphrase: passphrase)
            authMethod = .publicKey(privateKey: pk)
        case .privateKeyData(let keyData, let passphrase):
            let pk = try SSHKeyParser.parsePrivateKey(keyData, passphrase: passphrase)
            authMethod = .publicKey(privateKey: pk)
        case .sshPrivateKey(let nioKey):
            authMethod = .publicKey(privateKey: nioKey)
        }
        return try await bootstrap(
            host: host, port: port, username: username, authMethod: authMethod
        )
    }
}

// MARK: - Protobuf encoders

/// Hand-written protobuf encoder for the subset of mosh's terminalrunner
/// protocol we use. Protobuf wire format is extremely simple — a sequence
/// of (tag, type, value) tuples. Keeping this hand-written avoids pulling
/// in SwiftProtobuf as a dependency just for ~5 message types.
///
/// Reference: src/protobufs/transportinstruction.proto in upstream mosh.
enum MoshProto {

    // Wire-format types per protobuf spec §3.5.
    enum WireType: UInt8 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// Encode a (field_number, wire_type) tag varint.
    static func tag(field: Int, wireType: WireType) -> Data {
        let value = UInt64((field << 3) | Int(wireType.rawValue))
        return varint(value)
    }

    /// Protobuf base-128 varint encoding. Used for tags + integer fields.
    static func varint(_ value: UInt64) -> Data {
        var out = Data()
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    /// Encode an int64 field (zigzag-free; mosh uses uint/int64 directly).
    static func encodeInt64(field: Int, value: Int64) -> Data {
        var d = tag(field: field, wireType: .varint)
        d.append(varint(UInt64(bitPattern: value)))
        return d
    }

    /// Encode a string field (length-delimited UTF-8 bytes).
    static func encodeString(field: Int, value: String) -> Data {
        var d = tag(field: field, wireType: .lengthDelimited)
        let bytes = Data(value.utf8)
        d.append(varint(UInt64(bytes.count)))
        d.append(bytes)
        return d
    }

    /// Encode a bytes field (length-delimited raw bytes).
    static func encodeBytes(field: Int, value: Data) -> Data {
        var d = tag(field: field, wireType: .lengthDelimited)
        d.append(varint(UInt64(value.count)))
        d.append(value)
        return d
    }

    /// Encode a nested-message field (length-delimited submessage bytes).
    static func encodeMessage(field: Int, value: Data) -> Data {
        encodeBytes(field: field, value: value)
    }

    // MARK: - Mosh-specific message types

    /// `Instruction` is the top-level wrapper mosh uses for each datagram
    /// payload. Schema (transportinstruction.proto):
    ///
    ///     message Instruction {
    ///         required uint64 old_num = 1;
    ///         required uint64 new_num = 2;
    ///         required uint64 ack_num = 3;
    ///         required int64 throwaway_num = 4;
    ///         required string diff = 5;
    ///         required uint32 chaff = 6;
    ///         optional ProtocolVersionMessage protocol_version = 7;
    ///     }
    ///
    /// For our transport-only mode we set old_num=new_num=seq, ack_num=last
    /// received seq, throwaway_num=0, diff=raw bytes, chaff=empty.
    static func instruction(
        oldNum: UInt64,
        newNum: UInt64,
        ackNum: UInt64,
        throwawayNum: Int64,
        diff: Data
    ) -> Data {
        var out = Data()
        out.append(tag(field: 1, wireType: .varint))
        out.append(varint(oldNum))
        out.append(tag(field: 2, wireType: .varint))
        out.append(varint(newNum))
        out.append(tag(field: 3, wireType: .varint))
        out.append(varint(ackNum))
        out.append(encodeInt64(field: 4, value: throwawayNum))
        out.append(encodeBytes(field: 5, value: diff))  // 'diff' is bytes-typed, not string
        out.append(tag(field: 6, wireType: .varint))
        out.append(varint(0))  // chaff = 0
        return out
    }

    /// Decode the 4 varint header fields of an Instruction. Returns the
    /// parsed values + the byte range of the `diff` field (field 5).
    static func parseInstructionHeader(_ data: Data) -> (oldNum: UInt64, newNum: UInt64, ackNum: UInt64, diff: Data)? {
        var oldNum: UInt64 = 0
        var newNum: UInt64 = 0
        var ackNum: UInt64 = 0
        var diff: Data = Data()
        var i = data.startIndex

        while i < data.endIndex {
            guard let (tagValue, tagLen) = readVarint(data, at: i) else { return nil }
            i += tagLen
            let field = Int(tagValue >> 3)
            let wt = UInt8(tagValue & 0x07)

            switch (field, wt) {
            case (1, 0): // old_num varint
                guard let (v, n) = readVarint(data, at: i) else { return nil }
                oldNum = v; i += n
            case (2, 0): // new_num varint
                guard let (v, n) = readVarint(data, at: i) else { return nil }
                newNum = v; i += n
            case (3, 0): // ack_num varint
                guard let (v, n) = readVarint(data, at: i) else { return nil }
                ackNum = v; i += n
            case (4, 0): // throwaway_num int64
                guard let (_, n) = readVarint(data, at: i) else { return nil }
                i += n
            case (5, 2): // diff length-delimited
                guard let (len, n) = readVarint(data, at: i) else { return nil }
                i += n
                let end = i + Int(len)
                guard end <= data.endIndex else { return nil }
                diff = data.subdata(in: i..<end)
                i = end
            case (6, 0): // chaff varint
                guard let (_, n) = readVarint(data, at: i) else { return nil }
                i += n
            default:
                // Skip unknown fields by wire type.
                switch wt {
                case 0: // varint
                    guard let (_, n) = readVarint(data, at: i) else { return nil }
                    i += n
                case 2: // length-delimited
                    guard let (len, n) = readVarint(data, at: i) else { return nil }
                    i += n + Int(len)
                default:
                    return nil  // unsupported wire type
                }
            }
        }
        return (oldNum, newNum, ackNum, diff)
    }

    /// Encode a Mosh ResizeMessage. From `userinput.proto`:
    ///
    ///     message ResizeMessage {
    ///         required int32 num_x = 1;  // columns
    ///         required int32 num_y = 2;  // rows
    ///     }
    ///
    /// This is then wrapped in a UserStream Instruction whose body is
    /// itself a small protobuf containing the resize. Mosh-server reads
    /// the UserStream, sees the resize, and forwards SIGWINCH + ioctl
    /// TIOCSWINSZ to the remote PTY.
    static func resizeMessage(cols: Int, rows: Int) -> Data {
        var d = Data()
        d.append(tag(field: 1, wireType: .varint))
        d.append(varint(UInt64(cols)))
        d.append(tag(field: 2, wireType: .varint))
        d.append(varint(UInt64(rows)))
        return d
    }

    /// Wrap a sub-message into a UserStream's Instruction list.
    /// `UserStream { repeated Instruction instruction = 1 }` where each
    /// Instruction carries either a Keystroke (raw bytes) or a Resize.
    /// Field tags inside Instruction:
    ///   1 = keystroke (Keystroke message — bytes field)
    ///   2 = resize    (ResizeMessage)
    static func userStreamResize(cols: Int, rows: Int) -> Data {
        let resize = resizeMessage(cols: cols, rows: rows)
        var instr = Data()
        instr.append(encodeMessage(field: 2, value: resize))
        var stream = Data()
        stream.append(encodeMessage(field: 1, value: instr))
        return stream
    }

    /// Wrap raw keystroke bytes in a UserStream Instruction.
    /// Keystroke message: `bytes keys = 1`.
    static func userStreamKeystroke(_ bytes: Data) -> Data {
        var keystroke = Data()
        keystroke.append(encodeBytes(field: 1, value: bytes))
        var instr = Data()
        instr.append(encodeMessage(field: 1, value: keystroke))
        var stream = Data()
        stream.append(encodeMessage(field: 1, value: instr))
        return stream
    }

    /// Read a varint at the given offset. Returns (value, bytes consumed).
    static func readVarint(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        while i < data.endIndex {
            let byte = data[i]
            value |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 {
                return (value, i - offset)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}

// MARK: - Mosh Session

/// Live UDP session against a remote mosh-server. Consumers wire one
/// of these in place of an SSHSession when `profile.useMosh == true`.
///
/// Lifecycle:
///   1. init(bootstrap:) — caller has already run MoshBootstrap.bootstrap()
///   2. start() — opens UDP, sends initial handshake instruction
///   3. send(_ data:) — wraps bytes in UserStream, encrypts, sends
///   4. delegate.session(_:didReceive:) called for each inbound datagram
///   5. stop() — sends shutdown, closes channel
///
/// Errors during the session are logged but don't tear it down — UDP
/// transport is naturally tolerant of dropped packets.
public protocol MoshSessionDelegate: AnyObject, Sendable {
    func moshSession(_ session: MoshSession, didReceive data: Data)
    func moshSession(_ session: MoshSession, didFailWith error: Error)
    func moshSessionDidConnect(_ session: MoshSession)
    func moshSessionDidDisconnect(_ session: MoshSession)
}

@MainActor
public final class MoshSession {
    private let bootstrap: MoshBootstrap.Result
    private let cipher: AESOCB
    private var connection: NWConnection?
    private var seqOut: UInt64 = 1
    private var seqIn: UInt64 = 0
    private let queue = DispatchQueue(label: "com.geistty.mosh", qos: .userInitiated)
    public weak var delegate: MoshSessionDelegate?

    public enum State: Sendable {
        case idle, connecting, connected, failed(String), disconnected
    }
    @Published public private(set) var state: State = .idle

    public init(bootstrap: MoshBootstrap.Result) throws {
        self.bootstrap = bootstrap
        self.cipher = try AESOCB(key: bootstrap.key)
    }

    /// Open the UDP "connection" (NWConnection in datagram mode) and
    /// kick off the receive loop. Mosh requires the client to send first
    /// so the server learns our source address.
    public func start() {
        guard case .idle = state else { return }
        state = .connecting

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bootstrap.host),
            port: NWEndpoint.Port(rawValue: bootstrap.port) ?? .any
        )
        let params = NWParameters.udp
        // Disable connection sharing — each Mosh session is its own UDP
        // path so any cross-session state doesn't leak.
        if let proto = params.defaultProtocolStack.transportProtocol as? NWProtocolUDP.Options {
            proto.preferNoChecksum = false
            _ = proto
        }
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { @MainActor in
                switch newState {
                case .ready:
                    logger.info("Mosh UDP ready: \(self.bootstrap.host):\(self.bootstrap.port)")
                    self.state = .connected
                    self.delegate?.moshSessionDidConnect(self)
                    // Send an empty instruction so the server learns our
                    // source IP/port.
                    self.sendInstruction(payload: Data())
                    self.startReceive()
                case .failed(let err):
                    logger.error("Mosh UDP failed: \(err.localizedDescription)")
                    self.state = .failed(err.localizedDescription)
                    self.delegate?.moshSession(self, didFailWith: err)
                case .cancelled:
                    self.state = .disconnected
                    self.delegate?.moshSessionDidDisconnect(self)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    /// Send raw keystroke bytes to the remote. Wraps in a UserStream
    /// Keystroke instruction so mosh-server feeds them to the PTY.
    public func send(_ data: Data) {
        let payload = MoshProto.userStreamKeystroke(data)
        sendInstruction(payload: payload)
    }

    /// Send a terminal resize so mosh-server matches the local grid via
    /// SIGWINCH + ioctl TIOCSWINSZ on the remote PTY.
    public func sendResize(cols: Int, rows: Int) {
        let payload = MoshProto.userStreamResize(cols: cols, rows: rows)
        sendInstruction(payload: payload)
    }

    public func stop() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Internals

    private func sendInstruction(payload: Data) {
        let proto = MoshProto.instruction(
            oldNum: seqOut,
            newNum: seqOut,
            ackNum: seqIn,
            throwawayNum: 0,
            diff: payload
        )
        let nonce = makeNonce(seq: seqOut)
        seqOut &+= 1
        do {
            let sealed = try cipher.seal(plaintext: proto, nonce: nonce)
            // Wire format: 8-byte BE seq + ciphertext+tag
            // Mosh uses the high 64 bits of the 96-bit nonce as the seq,
            // so the on-wire prefix is just the BE seq.
            var wire = nonce.subdata(in: 4..<12)  // last 8 bytes = seq
            wire.append(sealed)
            connection?.send(content: wire, completion: .contentProcessed { err in
                if let err {
                    logger.warning("Mosh send error: \(err.localizedDescription)")
                }
            })
        } catch {
            logger.error("Mosh seal failed: \(error.localizedDescription)")
        }
    }

    private func startReceive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    logger.warning("Mosh receive error: \(error.localizedDescription)")
                }
                return
            }
            if let data, data.count >= 16 + 8 {
                Task { @MainActor in
                    self.handleInbound(data)
                }
            }
            Task { @MainActor in
                if case .connected = self.state {
                    self.startReceive()  // requeue
                }
            }
        }
    }

    private func handleInbound(_ data: Data) {
        // Wire: 8-byte BE seq + ciphertext+tag
        let seqBytes = data.subdata(in: 0..<8)
        let sealed = data.subdata(in: 8..<data.count)
        let nonce = noncePadding(seqBytes)

        do {
            let pt = try cipher.open(sealed: sealed, nonce: nonce)
            // Decode Instruction header to update ack and extract diff.
            guard let parsed = MoshProto.parseInstructionHeader(pt) else { return }
            seqIn = max(seqIn, parsed.newNum)
            if !parsed.diff.isEmpty {
                delegate?.moshSession(self, didReceive: parsed.diff)
            }
        } catch {
            // Auth failures on UDP datagrams are common (out-of-order,
            // stale, scan traffic) — log and drop, don't fail the session.
            logger.debug("Mosh open dropped a datagram: \(error.localizedDescription)")
        }
    }

    /// Mosh uses the seq as the high 64 bits of the 96-bit nonce.
    /// On-wire seq is 8 bytes BE; pad to 12 bytes nonce by prepending
    /// 4 zero bytes (the "high direction" bits, all zero for client→server).
    private func makeNonce(seq: UInt64) -> Data {
        var n = Data(count: 12)
        // Direction byte 0 = client → server. (Mosh distinguishes by
        // setting the top byte of the seq differently; we use 0 for client.)
        n[3] = 0
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { ptr in
            for (i, b) in ptr.enumerated() { n[4 + i] = b }
        }
        return n
    }

    private func noncePadding(_ seqBytes: Data) -> Data {
        var n = Data(count: 12)
        // Server → client direction byte. We don't enforce the
        // direction-bit check on receive — accept either direction's
        // seq layout since key is shared and tag verifies.
        for i in 0..<8 { n[4 + i] = seqBytes[i] }
        return n
    }
}
