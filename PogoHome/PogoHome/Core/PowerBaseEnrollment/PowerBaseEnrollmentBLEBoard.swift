import Foundation
import PowerBaseBLEKit

// What Power Base enrollment (the product screen and the DEBUG "BLE 등록 시험") needs from
// Bluetooth, as protocols, so the controller can be tested against scripted boards. The real implementation is `PowerBaseEnrollmentBLECentral`
// (CoreBluetooth) with `PowerBaseBLEBoardClient` (the package: Espressif's Security 2 and the
// pb-* messages).

/// Whether this device can use Bluetooth right now.
nonisolated enum PowerBaseBLEAvailability: Equatable, Sendable {
    /// Not asked yet, or the system hasn't answered.
    case unknown
    case resetting
    /// This device has no Bluetooth LE.
    case unsupported
    /// The user (or a restriction) refused Bluetooth to this app.
    case denied
    case restricted
    case poweredOff
    case poweredOn
}

/// A peripheral that advertises the enrollment service. Nothing here is authenticated: the name
/// and the EUI-64 inside it are whatever the advertiser chose to send.
nonisolated struct PowerBaseBLEDiscoveredBoard: Identifiable, Equatable, Sendable {
    /// CoreBluetooth's identifier for the peripheral on this device.
    let id: UUID
    /// The advertised name, when one came with the advertisement.
    var name: String?
    /// The EUI-64 in a well-formed name (`POGO-PB-<16 hex digits>`), lower case. A hint only.
    var advertisedEUI64: String?
    var rssi: Int
}

/// An authenticated Security 2 session with one connected board.
nonisolated protocol PowerBaseBLEBoardSession: Sendable {
    /// What the board listed in `proto-ver` before the handshake (`pb_enroll.cap`).
    func capabilities() async -> PowerBaseBLECapabilities
    func status(issueChallenge: Bool, requestID: PowerBaseBLERequestID?) async throws -> PowerBaseBLEStatus
    /// `pb-start` with the hub's bridge endpoint (message 0x04). The test sends no other start:
    /// the first start message (PSKd only) is never used in its place.
    func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) async throws -> PowerBaseBLECode
    /// `pb-start` with the hub's bridge endpoint and its management credential (message 0x06):
    /// what the product enrollment sends, and only to a board that lists `mgmt_v1`.
    func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint, management: PowerBaseBLEManagementCredential
    ) async throws -> PowerBaseBLECode
    func cancel(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) async throws -> PowerBaseBLECode
    /// The board's release receipt (message 0x07 on `pb-status`), or `nil` when it has none. Only
    /// asked of a board that lists `release_receipt_v1`. Changes nothing on the board.
    func releaseReceipt(target: PowerBaseBLEEUI64) async throws -> PowerBaseBLEReleaseReceipt?
    /// What the board holds and, with `operationID`, what became of that local reset (message 0x08
    /// on `pb-status`). Only asked of a board that lists `local_reset_v1`. Changes nothing on the
    /// board.
    func localResetStatus(target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID?) async throws -> PowerBaseBLELocalResetStatus
    /// The local reset command (message 0x09 on `pb-start`): the board erases its own registration
    /// and stored network. Only sent to a board that lists `local_reset_v1`, and only with the
    /// user's confirmation.
    func localReset(
        target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID, challenge: PowerBaseBLEChallenge,
        confirmation: PowerBaseBLELocalResetConfirmation
    ) async throws -> PowerBaseBLECode
    /// Drops the session keys and ends the connection.
    func close() async
}

extension PowerBaseBLEBoardSession {
    /// A session type that knows nothing of message 0x06 sends nothing in its place.
    func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint, management: PowerBaseBLEManagementCredential
    ) async throws -> PowerBaseBLECode {
        throw PowerBaseBLEClientError.invalidInput("capability")
    }

    /// A session type that knows nothing of the release receipt asks for none.
    func releaseReceipt(target: PowerBaseBLEEUI64) async throws -> PowerBaseBLEReleaseReceipt? {
        throw PowerBaseBLEClientError.invalidInput("capability")
    }

    /// A session type that knows nothing of the local reset asks nothing about one...
    func localResetStatus(target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID?) async throws -> PowerBaseBLELocalResetStatus {
        throw PowerBaseBLEClientError.invalidInput("capability")
    }

    /// ...and sends none, and nothing in its place.
    func localReset(
        target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID, challenge: PowerBaseBLEChallenge,
        confirmation: PowerBaseBLELocalResetConfirmation
    ) async throws -> PowerBaseBLECode {
        throw PowerBaseBLEClientError.invalidInput("capability")
    }
}

extension PowerBaseBLEBoardClient: PowerBaseBLEBoardSession {}

/// Why no authenticated session could be opened. Never carries the setup code or any payload.
nonisolated enum PowerBaseBLEOpenError: Error, Equatable, Sendable {
    case bluetoothUnavailable(PowerBaseBLEAvailability)
    /// The peripheral isn't known any more (it was never discovered in this scan).
    case boardNotFound
    /// No connection, or it ended before the session existed. `detail` is a short technical word.
    case connectionFailed(String)
    /// The GATT service isn't the one in the specification: a missing, duplicated or unknown
    /// endpoint description, a wrong characteristic UUID, or a characteristic that can't be
    /// read and written.
    case gattMismatch(String)
    /// `proto-ver` or the Security 2 handshake failed (see `PowerBaseBLEClientError`).
    case client(PowerBaseBLEClientError)
    case cancelled
}

/// Scanning for boards and opening sessions with them.
@MainActor
protocol PowerBaseBLEBoardProviding: AnyObject, Sendable {
    var availability: PowerBaseBLEAvailability { get }
    /// The boards seen since scanning started, in the order they were first seen.
    var boards: [PowerBaseBLEDiscoveredBoard] { get }
    /// Called when `availability` or `boards` changed.
    var onChange: (() -> Void)? { get set }

    /// Starts using Bluetooth. The first call makes the system ask for permission.
    func activate()
    /// Forgets the boards seen so far and scans (as soon as Bluetooth is on).
    func startScanning()
    /// Scans again (as soon as Bluetooth is on) and keeps the boards seen so far: the same search
    /// going on after a pause, not a new one.
    func resumeScanning()
    func stopScanning()

    /// Connects to `boardID`, checks its GATT service and `proto-ver`, and runs the Security 2
    /// handshake once with `eui64` as the user name and `setupCode` as the password. On any
    /// failure the connection is closed before this throws. Never retries.
    ///
    /// `permit` is asked before the connection is made and before each of `proto-ver` and the two
    /// handshake messages is sent: while it waits nothing new is sent, and when it throws the
    /// opening ends there. A connection to the same board that was closed before is waited for
    /// until it has really ended; if that can't be established, this throws without connecting.
    /// `permit` is asked (again) after that wait, right before the radio connects.
    func openSession(
        boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String, permit: @escaping PowerBaseBLESendPermit
    ) async throws -> any PowerBaseBLEBoardSession

    /// Stops scanning and ends any connection.
    func shutdown()
}
