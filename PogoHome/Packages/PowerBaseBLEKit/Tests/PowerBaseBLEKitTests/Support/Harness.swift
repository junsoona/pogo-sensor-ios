#if DEBUG && os(macOS)
import Foundation
import XCTest
@testable import PowerBaseBLEKit

/// The test-only credentials `make_harness_fixture.py` made, and where the harness is.
struct HarnessFixture {
    let harnessPath: String
    let record: Data
    let eui64: PowerBaseBLEEUI64
    let setupCode: String
    /// An SRP private key whose public key starts with a zero byte.
    let leadingZeroKey: Data

    /// Skips the test (visibly) when the harness or the fixture isn't there. See README.md.
    static func load() throws -> HarnessFixture {
        let environment = ProcessInfo.processInfo.environment
        let harness = environment["PB_BLE_HARNESS"]
            ?? NSString(string: "~/esp-builds/pogo_host_ble_sec2/pb_ble_sec2_harness.elf").expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: harness) else {
            throw XCTSkip("host harness not built: \(harness) (firmware repository, tools/host_ble_sec2)")
        }
        guard let directory = environment["PB_BLE_FIXTURE_DIR"] else {
            throw XCTSkip("PB_BLE_FIXTURE_DIR not set: run Tests/PowerBaseBLEKitTests/Support/make_harness_fixture.py first")
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        func text(_ name: String) throws -> String {
            try String(contentsOf: base.appendingPathComponent(name), encoding: .ascii).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let record = try Data(contentsOf: base.appendingPathComponent("record.bin"))
        let eui64 = try XCTUnwrap(PowerBaseBLEEUI64(hex: try text("eui64.txt")))
        let key = try XCTUnwrap(Data(hexString: try text("leading-zero-key.hex")))
        return HarnessFixture(harnessPath: harness, record: record, eui64: eui64, setupCode: try text("board.setup-code"), leadingZeroKey: key)
    }
}

extension Data {
    init?(hexString: String) {
        let characters = Array(hexString)
        guard characters.count % 2 == 0 else { return nil }
        var data = Data(capacity: characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

/// One process of the firmware repository's `tools/host_ble_sec2` harness = one boot of a board:
/// ESP-IDF's real protocomm + Security 2 server and the real BLE enrollment service, with the BLE
/// transport replaced by the pipe protocol in harness_main.c (and OpenThread by a fake). Its
/// stdout and stderr -- the firmware's own log -- go to `logURL`.
final class Harness: @unchecked Sendable {
    struct Stats {
        var state: UInt8
        var last: UInt8
        var attempt: UInt32
        var joinerStarts: UInt32
        var joinerStops: UInt32
        var threadEnabled: Bool
        var servicesAllowed: Bool
        var marker: UInt8
        var pskd: String
        /// The bridge endpoint the controller holds in RAM for the attempt in progress.
        var pendingEndpoint: Endpoint?
        /// The bridge endpoint of an enrolled controller (what the exporter would be given).
        var activeEndpoint: Endpoint?
        /// The bridge endpoint in the stored version 2 enrollment record.
        var storedEndpoint: Endpoint?
    }

    struct Endpoint: Equatable {
        var address: Data
        var port: UInt16
    }

    enum CloseReason: UInt8 {
        case open = 0, enrolled, authLocked, windowExpired
    }

    let logURL: URL
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var writeFD: Int32 = -1
    private var readFD: Int32 = -1

    init(path: String, logURL: URL) throws {
        self.logURL = logURL
        var toChild: [Int32] = [0, 0]
        var fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { throw HarnessError(description: "pipe") }
        // Where the child finds its ends; far above anything this process has open.
        let childIn: Int32 = 200
        let childOut: Int32 = 201
        precondition(![toChild[0], toChild[1], fromChild[0], fromChild[1]].contains { $0 >= childIn })

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], childIn)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], childOut)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors named above reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var environment = ProcessInfo.processInfo.environment
        environment["PB_HARNESS_IN_FD"] = String(childIn)
        environment["PB_HARNESS_OUT_FD"] = String(childOut)
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer {
            envp.forEach { free($0) }
            argv.forEach { free($0) }
        }
        var child: pid_t = 0
        let result = posix_spawn(&child, path, &actions, &attributes, argv, envp)
        close(toChild[0])
        close(fromChild[1])
        guard result == 0 else {
            close(toChild[1])
            close(fromChild[0])
            throw HarnessError(description: "posix_spawn: \(result)")
        }
        pid = child
        writeFD = toChild[1]
        readFD = fromChild[0]
    }

    deinit { quit() }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(writeFD, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw HarnessError(description: "harness pipe closed (see its log)") }
                offset += written
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { read(readFD, $0.baseAddress! + offset, count - offset) }
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { throw HarnessError(description: "harness exited unexpectedly (see its log)") }
            offset += got
        }
        return data
    }

    /// `cmd(1) len(2, big-endian) payload` -> `status(1) len(2) payload`.
    func command(_ command: Character, _ payload: Data = Data()) throws -> (status: UInt8, payload: Data) {
        try lock.withLock {
            guard writeFD >= 0 else { throw HarnessError(description: "harness stopped") }
            var frame = Data([command.asciiValue!, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
            frame.append(payload)
            try writeAll(frame)
            let header = [UInt8](try readExactly(3))
            let length = Int(header[1]) << 8 | Int(header[2])
            return (header[0], length > 0 ? try readExactly(length) : Data())
        }
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data)
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    /// The board boots with this credential record in its `cfg`. -> `pb_ble_auth_status_t` (0 = the
    /// service started).
    func boot(eui64: PowerBaseBLEEUI64, record: Data, joinerOK: Bool = true) throws -> UInt8 {
        try command("I", eui64.bytes + Data([joinerOK ? 1 : 0]) + record).status
    }

    func connect(_ session: UInt32) throws -> Bool { try command("O", Self.u32(session)).status == 0 }

    func disconnect(_ session: UInt32) throws -> Bool { try command("X", Self.u32(session)).status == 0 }

    /// What one characteristic write + read does. -> (`esp_err_t`, the response).
    func request(session: UInt32, endpoint: String, data: Data) throws -> (error: UInt32, response: Data) {
        let name = Data(endpoint.utf8)
        let reply = try command("R", Self.u32(session) + Data([UInt8(name.count)]) + name + data)
        guard reply.status == 0, reply.payload.count >= 4 else { throw HarnessError(description: "harness refused the request frame") }
        return (Self.u32(reply.payload, 0), Data(reply.payload.dropFirst(4)))
    }

    /// Advances the board's monotonic clock.
    func advance(milliseconds: UInt32) throws { _ = try command("T", Self.u32(milliseconds)) }

    /// One pass of the enrollment worker.
    @discardableResult
    func poll() throws -> CloseReason {
        let reply = try command("P")
        return CloseReason(rawValue: reply.payload.first ?? 0xff) ?? .open
    }

    /// The Joiner callback's outcome for the current attempt (0 = success).
    func joinerDone(outcome: UInt8) throws { _ = try command("J", Data([outcome])) }

    /// One controller tick.
    func tick(attached: Bool, datasetComplete: Bool) throws { _ = try command("A", Data([attached ? 1 : 0, datasetComplete ? 1 : 0])) }

    func stats() throws -> Stats {
        let payload = try command("S").payload
        let bytes = [UInt8](payload)
        let pskd = String(decoding: bytes[17..<50].prefix { $0 != 0 }, as: UTF8.self)
        // present(1) address(16) port(2, big-endian), three times, after the 33-byte PSKd buffer.
        func endpoint(_ offset: Int) -> Endpoint? {
            guard bytes.count >= offset + 19, bytes[offset] != 0 else { return nil }
            return Endpoint(address: Data(bytes[(offset + 1)..<(offset + 17)]), port: UInt16(bytes[offset + 17]) << 8 | UInt16(bytes[offset + 18]))
        }
        return Stats(
            state: bytes[0], last: bytes[1], attempt: Self.u32(payload, 2), joinerStarts: Self.u32(payload, 6),
            joinerStops: Self.u32(payload, 10), threadEnabled: bytes[14] != 0, servicesAllowed: bytes[15] != 0,
            marker: bytes[16], pskd: pskd, pendingEndpoint: endpoint(50), activeEndpoint: endpoint(69), storedEndpoint: endpoint(88)
        )
    }

    func quit() {
        lock.withLock {
            guard writeFD >= 0 else { return }
            let frame = Data([Character("Q").asciiValue!, 0, 0])
            try? writeAll(frame)
            _ = try? readExactly(3)
            close(writeFD)
            close(readFD)
            writeFD = -1
            readFD = -1
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }
}

/// The harness as a `PowerBaseBLELink`: one exchange = one `protocomm_req_handle()`, the call
/// protocomm_nimble.c makes for a characteristic write. A handler error is what the BLE client
/// sees as an ATT error on that write. Records what was sent, and can change bytes in transit.
final class HarnessLink: PowerBaseBLELink, @unchecked Sendable {
    struct Exchange {
        let endpoint: PowerBaseBLEProtocol.Endpoint
        let request: Data
        let response: Data?
    }

    private let harness: Harness
    private let session: UInt32
    private let lock = NSLock()
    private var log: [Exchange] = []
    private var requestFilter: ((PowerBaseBLEProtocol.Endpoint, Data) -> Data)?
    private var responseFilter: ((PowerBaseBLEProtocol.Endpoint, Data) -> Data)?
    private var isClosed = false

    init(harness: Harness, session: UInt32) {
        self.harness = harness
        self.session = session
    }

    var exchanges: [Exchange] { lock.withLock { log } }
    var closed: Bool { lock.withLock { isClosed } }

    func exchangeCount(_ endpoint: PowerBaseBLEProtocol.Endpoint) -> Int { exchanges.filter { $0.endpoint == endpoint }.count }

    /// Changes requests on their way to the board.
    func tamperRequests(_ filter: ((PowerBaseBLEProtocol.Endpoint, Data) -> Data)?) { lock.withLock { requestFilter = filter } }

    /// Changes the board's answers on their way back.
    func tamperResponses(_ filter: ((PowerBaseBLEProtocol.Endpoint, Data) -> Data)?) { lock.withLock { responseFilter = filter } }

    func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
        let (requestFilter, responseFilter) = lock.withLock { (self.requestFilter, self.responseFilter) }
        let sent = requestFilter?(endpoint, payload) ?? payload
        let result: (error: UInt32, response: Data)
        do {
            result = try harness.request(session: session, endpoint: endpoint.rawValue, data: sent)
        } catch {
            lock.withLock { log.append(Exchange(endpoint: endpoint, request: sent, response: nil)) }
            throw PowerBaseBLELinkError.disconnected
        }
        guard result.error == 0 else {
            lock.withLock { log.append(Exchange(endpoint: endpoint, request: sent, response: nil)) }
            throw PowerBaseBLELinkError.rejected
        }
        lock.withLock { log.append(Exchange(endpoint: endpoint, request: sent, response: result.response)) }
        return responseFilter?(endpoint, Data(result.response)) ?? Data(result.response)
    }

    func close() async {
        lock.withLock { isClosed = true }
    }
}
#endif
