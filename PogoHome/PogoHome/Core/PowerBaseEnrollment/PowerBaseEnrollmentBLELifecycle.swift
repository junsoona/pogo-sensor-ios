#if DEBUG
import Foundation
import PowerBaseBLEKit

/// What the connection lifecycle asks of CoreBluetooth's central manager. A peripheral is named by
/// its identifier, so the lifecycle can be driven by a scripted radio in a test.
@MainActor
protocol PowerBaseBLERadio: AnyObject {
    /// Whether Bluetooth can be used right now. A connection is only started while it is on.
    var availability: PowerBaseBLEAvailability { get }
    /// `CBCentralManager.connect`. Answered by `didConnect` or `didFailToConnect`.
    func connect(_ peripheral: UUID)
    /// `CBCentralManager.cancelPeripheralConnection`. Answered by `didDisconnect` (or, for a
    /// connection that was still being made, `didFailToConnect`).
    func cancelConnection(_ peripheral: UUID)
    /// The system holds no connection and no pending connection to the peripheral.
    func isDisconnected(_ peripheral: UUID) -> Bool
}

/// One connection's own side (GATT discovery, requests), as the lifecycle sees it.
@MainActor
protocol PowerBaseBLELinkOwner: AnyObject {
    /// The radio connected: check the GATT service and report through `setupDidFinish`.
    func linkDidConnect()
    /// The connection is over, whoever ended it. Nothing more may be sent on it.
    func linkDidEnd(_ error: PowerBaseBLELinkError)
}

/// Which connection a CoreBluetooth connection callback belongs to, and when the next connection
/// to the same board may start. The real central (`PowerBaseEnrollmentBLECentral`) forwards its
/// delegate callbacks here and connects only through here.
///
/// CoreBluetooth's `didConnect` / `didFailToConnect` / `didDisconnectPeripheral` name a
/// peripheral, not a connection attempt, and the same board is the same `CBPeripheral` every
/// time. So the order is made explicit instead:
///
/// - Every `connect` this side made is answered by exactly one end (`didFailToConnect`, or
///   `didDisconnect` after it connected). A link this side gave up is `closing` until that end
///   arrived; it has no owner any more, so a callback for it reaches nobody.
/// - The next connection to that peripheral is not started -- and has no link a callback could be
///   routed to -- before that end was consumed. The wait has a time limit; when it passes, the
///   open fails without connecting. The link stays `closing` unless the system itself reports
///   the peripheral disconnected, in which case a later open may connect.
/// - No `connect` without the opening's permit, asked right before it -- at once, or after the
///   wait for the previous connection's end, however long that took. While the permit is asked
///   the opening has no link and no time limit (the app may stay away for long), and it can still
///   end: cancelled, replaced, shut down, Bluetooth gone. A permit that answers after that, or
///   for an opening that is no longer the one that asked, connects nothing and fails nothing.
/// - Bluetooth switching off or resetting ends every connection without callbacks: all links are
///   forgotten and a waiting open fails.
/// - There is one connection at a time. A new open ends the previous one, whatever its peripheral.
/// - An owner that isn't the owner of a link (any more) can't cancel anything: its late `close`
///   changes nothing.
/// - Each `open` is resumed exactly once.
@MainActor
final class PowerBaseEnrollmentBLELifecycle {
    private enum Link {
        /// `connect` was called for this owner; no callback yet.
        case connecting(any PowerBaseBLELinkOwner)
        case connected(any PowerBaseBLELinkOwner)
        /// Given up by this side; CoreBluetooth has not reported its end yet.
        case closing
    }

    /// What an opening waits for. One thing at a time, each with a task of its own that is
    /// cancelled when the wait is over, so nothing of an earlier wait acts on a later one.
    private enum Step {
        /// The end of the previous connection to the peripheral: nothing asked, no `connect` yet.
        /// `limit` fails the opening after `closeTimeout`.
        case previousEnd(limit: Task<Void, Never>)
        /// The permit. No link yet and no time limit.
        case permit(Task<Void, Never>)
        /// `connect` was called: `didConnect`, then the owner's GATT check. `limit` fails the
        /// opening after `setupTimeout`.
        case setup(limit: Task<Void, Never>)

        var task: Task<Void, Never> {
            switch self {
            case let .previousEnd(task), let .permit(task), let .setup(task): return task
            }
        }
    }

    private struct Opening {
        let id: Int
        let peripheral: UUID
        let owner: any PowerBaseBLELinkOwner
        let permit: PowerBaseBLESendPermit
        let asker: Asker
        let continuation: CheckedContinuation<Void, Error>
        var step: Step
    }

    /// Whether the task that asked for an opening was cancelled. Set by its cancellation handler
    /// on whatever thread that runs, so it is known here before the handler's hop to the main
    /// actor arrives.
    private nonisolated final class Asker: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    weak var radio: (any PowerBaseBLERadio)?
    private let setupTimeout: Duration
    private let closeTimeout: Duration
    private var links: [UUID: Link] = [:]
    private var opening: Opening?
    private var counter = 0

    /// `setupTimeout`: from `connect` to a checked GATT service. `closeTimeout`: how long the
    /// wait for a previous connection's end may take. The wait for the permit is in neither.
    init(setupTimeout: Duration, closeTimeout: Duration) {
        self.setupTimeout = setupTimeout
        self.closeTimeout = closeTimeout
    }

    // MARK: - Opening

    /// Makes `owner` the one connection: ends the connection (or opening) there was, waits for
    /// the previous connection to `peripheral` to be over, asks `permit`, connects, and returns
    /// once `owner` reported its GATT service as checked. Throws `PowerBaseBLEOpenError`; then
    /// `owner` holds no connection and was told so. `.cancelled` when `permit` threw.
    func open(_ peripheral: UUID, for owner: any PowerBaseBLELinkOwner, permit: @escaping PowerBaseBLESendPermit) async throws {
        endAll()
        guard !Task.isCancelled else { throw PowerBaseBLEOpenError.cancelled }
        counter += 1
        let id = counter
        let asker = Asker()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Nothing is connected from here: also with no connection to wait for, the
                // permit is asked first.
                let step = links[peripheral] == nil ? askPermit(id, owner, permit) : awaitPreviousEnd(id)
                opening = Opening(
                    id: id, peripheral: peripheral, owner: owner, permit: permit, asker: asker, continuation: continuation, step: step
                )
            }
        } onCancel: {
            asker.cancel()
            Task { @MainActor [weak self] in self?.failOpening(id, .cancelled) }
        }
    }

    private func awaitPreviousEnd(_ id: Int) -> Step {
        let limit = closeTimeout
        return .previousEnd(limit: Task { [weak self] in
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            self?.previousConnectionDidNotEnd(id)
        })
    }

    /// Asks `permit` for opening `id`. The answer comes back to `permitDidAnswer`, which decides
    /// whether there is still an opening it is for.
    private func askPermit(_ id: Int, _ owner: any PowerBaseBLELinkOwner, _ permit: @escaping PowerBaseBLESendPermit) -> Step {
        .permit(Task { [weak self, weak owner] in
            let granted = (try? await permit()) != nil
            self?.permitDidAnswer(id, owner, granted: granted)
        })
    }

    /// The permit for opening `id` of `owner` answered. Only now, and only if that opening is
    /// still the one waiting for it, is the radio asked to connect.
    private func permitDidAnswer(_ id: Int, _ owner: (any PowerBaseBLELinkOwner)?, granted: Bool) {
        // Ended or replaced while the permit was asked: this answer is nobody's.
        guard let opening, opening.id == id, opening.owner === owner, case .permit = opening.step else { return }
        // The run is over or must not go on in the background, or the asking task was cancelled
        // and its handler has not got here yet.
        guard granted, !opening.asker.isCancelled else { return failOpening(id, .cancelled) }
        // Bluetooth went away and said so (`radioDidBecomeUnavailable` ends the opening); this is
        // the radio's own word at the moment of connecting.
        guard let radio, radio.availability == .poweredOn else {
            return end(opening.owner, .disconnected, opening: .bluetoothUnavailable(radio?.availability ?? .unknown))
        }
        // No opening connects onto a link whose end is outstanding.
        guard links[opening.peripheral] == nil else { return failOpening(id, .connectionFailed("previous connection still closing")) }
        links[opening.peripheral] = .connecting(opening.owner)
        let limit = setupTimeout
        self.opening?.step = .setup(limit: Task { [weak self] in
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            self?.setupDidNotFinish(id)
        })
        radio.connect(opening.peripheral)
    }

    /// `owner` has checked its GATT service (`mismatch == nil`) or found it isn't the specified one.
    func setupDidFinish(_ owner: any PowerBaseBLELinkOwner, mismatch: PowerBaseBLEOpenError?) {
        guard let opening, opening.owner === owner, case let .connected(connected)? = links[opening.peripheral], connected === owner else { return }
        if let mismatch {
            end(owner, .disconnected, opening: mismatch)
        } else {
            takeOpening()?.continuation.resume()
        }
    }

    private func failOpening(_ id: Int, _ error: PowerBaseBLEOpenError) {
        guard let opening, opening.id == id else { return }
        end(opening.owner, error == .cancelled ? .cancelled : .disconnected, opening: error)
    }

    /// The connection, or its GATT check, took too long.
    private func setupDidNotFinish(_ id: Int) {
        guard let opening, opening.id == id, case .setup = opening.step else { return }
        failOpening(id, .connectionFailed("timeout"))
    }

    /// The end of the previous connection was not reported in time: this open fails without
    /// connecting to a link that may still be there.
    private func previousConnectionDidNotEnd(_ id: Int) {
        guard let opening, opening.id == id, case .previousEnd = opening.step else { return }
        failOpening(id, .connectionFailed("previous connection still closing"))
        // Only the system's own word that nothing is left lets a later open connect.
        if case .closing? = links[opening.peripheral], radio?.isDisconnected(opening.peripheral) == true {
            links[opening.peripheral] = nil
        }
    }

    private func takeOpening() -> Opening? {
        guard let opening else { return nil }
        self.opening = nil
        opening.step.task.cancel()
        return opening
    }

    // MARK: - Ending

    /// `owner` gives its connection up (its session was closed, a request got no answer). Does
    /// nothing when `owner` holds no connection any more.
    func close(_ owner: any PowerBaseBLELinkOwner, _ error: PowerBaseBLELinkError = .disconnected) {
        guard owns(owner) else { return }
        end(owner, error, opening: error == .cancelled ? .cancelled : .connectionFailed("disconnected"))
    }

    /// Ends the connection and the opening there is. Links that are closing stay so: an open
    /// after this still waits for their end.
    func shutdown() {
        endAll()
    }

    /// Bluetooth is off, resetting or no longer allowed: every connection ended with it, and no
    /// callback will say so.
    func radioDidBecomeUnavailable(_ availability: PowerBaseBLEAvailability) {
        var lost = links.values.compactMap(Self.owner(of:))
        links = [:]
        let pending = takeOpening()
        if let pending, !lost.contains(where: { $0 === pending.owner }) { lost.append(pending.owner) }
        lost.forEach { $0.linkDidEnd(.disconnected) }
        pending?.continuation.resume(throwing: PowerBaseBLEOpenError.bluetoothUnavailable(availability))
    }

    private func endAll() {
        if let opening { end(opening.owner, .cancelled, opening: .cancelled) }
        for owner in links.values.compactMap(Self.owner(of:)) {
            end(owner, .disconnected, opening: .cancelled)
        }
    }

    /// Ends `owner`'s connection from this side. Its link, if it has one, is `closing` from here
    /// on: whatever CoreBluetooth still reports for it belongs to nobody.
    private func end(_ owner: any PowerBaseBLELinkOwner, _ error: PowerBaseBLELinkError, opening openError: PowerBaseBLEOpenError) {
        if let peripheral = peripheral(of: owner) {
            links[peripheral] = .closing
            radio?.cancelConnection(peripheral)
        }
        let pending = opening?.owner === owner ? takeOpening() : nil
        owner.linkDidEnd(error)
        pending?.continuation.resume(throwing: openError)
    }

    private func owns(_ owner: any PowerBaseBLELinkOwner) -> Bool {
        opening?.owner === owner || peripheral(of: owner) != nil
    }

    private func peripheral(of owner: any PowerBaseBLELinkOwner) -> UUID? {
        links.first { Self.owner(of: $0.value) === owner }?.key
    }

    private static func owner(of link: Link) -> (any PowerBaseBLELinkOwner)? {
        switch link {
        case let .connecting(owner), let .connected(owner): return owner
        case .closing: return nil
        }
    }

    // MARK: - CoreBluetooth's callbacks

    func didConnect(_ peripheral: UUID) {
        switch links[peripheral] {
        case let .connecting(owner)?:
            links[peripheral] = .connected(owner)
            owner.linkDidConnect()
        case .closing?:
            // The connect this side had given up got through first. It still has to end.
            radio?.cancelConnection(peripheral)
        case .connected?, nil:
            break
        }
    }

    func didFailToConnect(_ peripheral: UUID) {
        connectionEnded(peripheral)
    }

    func didDisconnect(_ peripheral: UUID) {
        connectionEnded(peripheral)
    }

    /// The one end of the one `connect` that was outstanding for `peripheral`.
    private func connectionEnded(_ peripheral: UUID) {
        guard let link = links.removeValue(forKey: peripheral) else { return }
        if let owner = Self.owner(of: link) {
            let pending = opening?.owner === owner ? takeOpening() : nil
            owner.linkDidEnd(.disconnected)
            pending?.continuation.resume(throwing: PowerBaseBLEOpenError.connectionFailed("disconnected"))
        } else if let waiting = opening, waiting.peripheral == peripheral, case let .previousEnd(limit) = waiting.step {
            // The previous connection is over. Whether the open that waited for it may connect
            // is asked now, not taken from before the wait: the app may have gone to the
            // background, or the run may have ended, meanwhile.
            limit.cancel()
            opening?.step = askPermit(waiting.id, waiting.owner, waiting.permit)
        }
    }
}

/// Asked before every new Bluetooth command while a session is being opened -- the `connect`
/// itself included, right before the radio gets it. Returns when the command may be sent (the app
/// is in the foreground); throws when it must not be sent at all (the run it belongs to is over).
/// A command that already left this device is not affected.
typealias PowerBaseBLESendPermit = @MainActor @Sendable () async throws -> Void

/// `proto-ver` and the Security 2 handshake over a connected link, as the real central runs them.
nonisolated enum PowerBaseBLESessionOpener {
    /// Reads `proto-ver` and runs the handshake once, asking `permit` before each of the three
    /// messages. On any failure the link is closed before this throws `PowerBaseBLEOpenError`.
    /// Once the session exists, what is sent over it is its caller's to decide: `permit` is not
    /// asked again.
    static func authenticate(
        over link: any PowerBaseBLELink, eui64: PowerBaseBLEEUI64, setupCode: String, permit: @escaping PowerBaseBLESendPermit
    ) async throws -> PowerBaseBLEBoardClient {
        let gate = await Gate(permit)
        let client = PowerBaseBLEBoardClient(link: PermittedLink(base: link, gate: gate))
        do {
            try await client.checkVersion()
            try await client.authenticate(eui64: eui64, setupCode: setupCode)
        } catch {
            await client.close()
            throw PowerBaseBLEOpenError.client(error as? PowerBaseBLEClientError ?? .handshakeMalformed("client"))
        }
        await gate.lift()
        return client
    }

    @MainActor
    private final class Gate {
        private var permit: PowerBaseBLESendPermit?

        init(_ permit: @escaping PowerBaseBLESendPermit) {
            self.permit = permit
        }

        func pass() async throws {
            guard let permit else { return }
            do {
                try await permit()
            } catch {
                throw PowerBaseBLELinkError.cancelled
            }
        }

        func lift() {
            permit = nil
        }
    }

    private struct PermittedLink: PowerBaseBLELink {
        let base: any PowerBaseBLELink
        let gate: Gate

        func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
            try await gate.pass()
            return try await base.exchange(endpoint: endpoint, payload: payload)
        }

        func close() async {
            await base.close()
        }
    }
}
#endif
