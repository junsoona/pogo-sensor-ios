import CoreBluetooth
import Foundation
import PowerBaseBLEKit

/// The Bluetooth side of the DEBUG "BLE 등록 시험": scans for boards that advertise the enrollment
/// service, and opens one connection at a time to the board the tester picked.
///
/// - Scan results are hints. A name and the EUI-64 in it prove nothing; identity comes only from
///   the Security 2 session (`PowerBaseBLEBoardClient`).
/// - Endpoints are found by the 0x2901 User Description of each characteristic, never by position
///   or discovery order. The service must hold exactly the five endpoints of the specification,
///   each once, each readable and writable, each under its documented UUID; anything else is
///   refused before a single byte is written.
/// - There is no notify. A request is one `writeValue(.withResponse)` of the whole message and
///   the answer is one read of the same characteristic (`PowerBaseEnrollmentBLEExchanger`). A
///   message is never split over several writes (the board would take each as a request of its
///   own); one that doesn't fit a characteristic value is refused with `.messageTooLong`.
///   CoreBluetooth turns a value longer than the ATT MTU into a long write / long read by itself.
/// - Everything runs on the main queue. Each connection is its own object. Which connection a
///   CoreBluetooth connection callback belongs to, and when the next connection to the same board
///   may start, is decided by `PowerBaseEnrollmentBLELifecycle`: a connection that was closed or
///   replaced gets no callback, and its late `close` can't end the connection that followed it.
final class PowerBaseEnrollmentBLECentral: NSObject, PowerBaseBLEBoardProviding, CBCentralManagerDelegate, PowerBaseBLERadio {
    private static let serviceUUID = CBUUID(string: PowerBaseBLEProtocol.serviceUUID)

    private(set) var availability: PowerBaseBLEAvailability = .unknown
    private(set) var boards: [PowerBaseBLEDiscoveredBoard] = []
    var onChange: (() -> Void)?

    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var wantsScan = false
    private let lifecycle: PowerBaseEnrollmentBLELifecycle
    private let exchangeTimeout: Duration
    private let handshakeTimeout: Duration

    /// `setupTimeout`: from the connect to a checked GATT service. `handshakeTimeout`: the board
    /// computes SRP in its BLE task before it answers the write, and ATT allows a transaction 30
    /// seconds. `closeTimeout`: how long a new connection waits for CoreBluetooth to report the
    /// end of the previous one to the same board.
    init(
        setupTimeout: Duration = .seconds(20), exchangeTimeout: Duration = .seconds(10), handshakeTimeout: Duration = .seconds(30),
        closeTimeout: Duration = .seconds(5)
    ) {
        lifecycle = PowerBaseEnrollmentBLELifecycle(setupTimeout: setupTimeout, closeTimeout: closeTimeout)
        self.exchangeTimeout = exchangeTimeout
        self.handshakeTimeout = handshakeTimeout
        super.init()
        lifecycle.radio = self
    }

    // MARK: - PowerBaseBLEBoardProviding

    func activate() {
        guard manager == nil else { return }
        // No system "turn on Bluetooth" alert: the screen says it in its own words.
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScanning() {
        wantsScan = true
        boards = []
        // A board picked earlier stays connectable by its identifier.
        scanIfPossible()
        onChange?()
    }

    func resumeScanning() {
        wantsScan = true
        scanIfPossible()
        onChange?()
    }

    func stopScanning() {
        wantsScan = false
        if let manager, manager.state == .poweredOn, manager.isScanning {
            manager.stopScan()
        }
    }

    func openSession(
        boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String, permit: @escaping PowerBaseBLESendPermit
    ) async throws -> any PowerBaseBLEBoardSession {
        // Nothing of an older connection is touched for a run that is over or away. This is not
        // the check for the connect itself: that one is the lifecycle's, right before the radio
        // connects, because the wait for an older connection's end comes in between.
        do {
            try await permit()
        } catch {
            throw PowerBaseBLEOpenError.cancelled
        }
        guard let manager, availability == .poweredOn else { throw PowerBaseBLEOpenError.bluetoothUnavailable(availability) }
        guard let peripheral = peripherals[boardID] ?? manager.retrievePeripherals(withIdentifiers: [boardID]).first else {
            throw PowerBaseBLEOpenError.boardNotFound
        }
        peripherals[boardID] = peripheral
        // One connection at a time: the lifecycle ends an older one, waits for the end of the
        // previous connection to this board, and asks `permit` again before it connects.
        let connection = PowerBaseEnrollmentBLEConnection(
            peripheral: peripheral, lifecycle: lifecycle, exchangeTimeout: exchangeTimeout, handshakeTimeout: handshakeTimeout
        )
        try await connection.open(permit: permit)
        return try await PowerBaseBLESessionOpener.authenticate(
            over: PowerBaseEnrollmentBLELink(connection: connection), eui64: eui64, setupCode: setupCode, permit: permit
        )
    }

    func shutdown() {
        stopScanning()
        lifecycle.shutdown()
    }

    // MARK: - PowerBaseBLERadio

    func connect(_ peripheral: UUID) {
        guard let manager, manager.state == .poweredOn, let peripheral = peripherals[peripheral] else { return }
        manager.connect(peripheral)
    }

    func cancelConnection(_ peripheral: UUID) {
        guard let manager, manager.state == .poweredOn, let peripheral = peripherals[peripheral] else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    func isDisconnected(_ peripheral: UUID) -> Bool {
        peripherals[peripheral].map { $0.state == .disconnected } ?? true
    }

    private func scanIfPossible() {
        guard wantsScan, let manager, manager.state == .poweredOn else { return }
        // Only this service; one report per board (plus the one that brings its name).
        manager.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: PowerBaseBLEAvailability
        switch central.state {
        case .poweredOn: state = .poweredOn
        case .poweredOff: state = .poweredOff
        case .unsupported: state = .unsupported
        case .unauthorized: state = CBCentralManager.authorization == .restricted ? .restricted : .denied
        case .resetting: state = .resetting
        case .unknown: state = .unknown
        @unknown default: state = .unknown
        }
        availability = state
        if state == .poweredOn {
            scanIfPossible()
        } else {
            // Peripherals and connections don't survive Bluetooth going away.
            lifecycle.radioDidBecomeUnavailable(state)
            boards = []
            peripherals = [:]
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let hint = name.flatMap { PowerBaseBLEProtocol.advertisedEUI64(inName: $0)?.hex }
        peripherals[peripheral.identifier] = peripheral
        if let index = boards.firstIndex(where: { $0.id == peripheral.identifier }) {
            // A later report may bring the name (it travels in the scan response).
            if let name { boards[index].name = name }
            if let hint { boards[index].advertisedEUI64 = hint }
            boards[index].rssi = RSSI.intValue
        } else {
            boards.append(PowerBaseBLEDiscoveredBoard(id: peripheral.identifier, name: name, advertisedEUI64: hint, rssi: RSSI.intValue))
        }
        onChange?()
    }

    // These three name a peripheral, not a connection: the lifecycle knows whose they are.

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lifecycle.didConnect(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lifecycle.didFailToConnect(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lifecycle.didDisconnect(peripheral.identifier)
    }
}

/// One connection to one board, from `connect` to the end. Single use. When it connects and when
/// it is over is the lifecycle's to say (`PowerBaseBLELinkOwner`); this is the GATT side.
final class PowerBaseEnrollmentBLEConnection: NSObject, CBPeripheralDelegate, PowerBaseBLEEndpointIO, PowerBaseBLELinkOwner {
    private static let userDescriptionUUID = CBUUID(string: CBUUIDCharacteristicUserDescriptionString)

    let peripheral: CBPeripheral
    private weak var lifecycle: PowerBaseEnrollmentBLELifecycle?
    private let exchangeTimeout: Duration
    private let handshakeTimeout: Duration

    private enum State { case idle, opening, ready, closed }
    private var state = State.idle

    private var service: CBService?
    private var pendingDescriptorDiscoveries = Set<CBUUID>()
    private var pendingDescriptorReads = Set<CBUUID>()
    private var descriptions: [(characteristic: CBCharacteristic, text: String?)] = []
    private var endpoints: [PowerBaseBLEProtocol.Endpoint: CBCharacteristic] = [:]

    /// The request/answer logic, once the connection is ready.
    private var exchanger: PowerBaseEnrollmentBLEExchanger?

    init(peripheral: CBPeripheral, lifecycle: PowerBaseEnrollmentBLELifecycle, exchangeTimeout: Duration, handshakeTimeout: Duration) {
        self.peripheral = peripheral
        self.lifecycle = lifecycle
        self.exchangeTimeout = exchangeTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: - Opening

    /// Connects, once `permit` allows it, and checks the GATT service. Throws
    /// `PowerBaseBLEOpenError`; on a throw the connection is already closed.
    func open(permit: @escaping PowerBaseBLESendPermit) async throws {
        guard state == .idle, let lifecycle else { throw PowerBaseBLEOpenError.connectionFailed("state") }
        state = .opening
        try await lifecycle.open(peripheral.identifier, for: self, permit: permit)
    }

    func linkDidConnect() {
        guard state == .opening else { return }
        // Only now: until the previous connection to this board had ended, the peripheral was its.
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: PowerBaseBLEProtocol.serviceUUID)])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard state == .opening else { return }
        let wanted = CBUUID(string: PowerBaseBLEProtocol.serviceUUID)
        let matches = (peripheral.services ?? []).filter { $0.uuid == wanted }
        guard error == nil, matches.count == 1 else { return failOpening(.gattMismatch("service")) }
        service = matches[0]
        peripheral.discoverCharacteristics(nil, for: matches[0])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard state == .opening, service === self.service else { return }
        let characteristics = service.characteristics ?? []
        guard error == nil, characteristics.count == PowerBaseBLEProtocol.Endpoint.allCases.count else {
            return failOpening(.gattMismatch("characteristics"))
        }
        guard Set(characteristics.map(\.uuid)).count == characteristics.count else { return failOpening(.gattMismatch("duplicate characteristic")) }
        pendingDescriptorDiscoveries = Set(characteristics.map(\.uuid))
        for characteristic in characteristics {
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard state == .opening, pendingDescriptorDiscoveries.remove(characteristic.uuid) != nil else { return }
        let userDescriptions = (characteristic.descriptors ?? []).filter { $0.uuid == Self.userDescriptionUUID }
        guard error == nil, userDescriptions.count == 1 else { return failOpening(.gattMismatch("descriptor")) }
        pendingDescriptorReads.insert(characteristic.uuid)
        peripheral.readValue(for: userDescriptions[0])
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard state == .opening, descriptor.uuid == Self.userDescriptionUUID, let characteristic = descriptor.characteristic,
              pendingDescriptorReads.remove(characteristic.uuid) != nil else { return }
        guard error == nil else { return failOpening(.gattMismatch("descriptor")) }
        descriptions.append((characteristic, descriptor.value as? String))
        if pendingDescriptorDiscoveries.isEmpty && pendingDescriptorReads.isEmpty {
            finishOpening()
        }
    }

    private func finishOpening() {
        switch Self.endpoints(from: descriptions.map { ($0.characteristic.uuid.uuidString, $0.text, $0.characteristic.properties) }) {
        case let .failure(mismatch):
            failOpening(mismatch)
        case let .success(indexes):
            endpoints = indexes.mapValues { descriptions[$0].characteristic }
            exchanger = PowerBaseEnrollmentBLEExchanger(io: self, exchangeTimeout: exchangeTimeout, handshakeTimeout: handshakeTimeout) { [weak self] in
                self?.invalidate(.disconnected)
            }
            state = .ready
            lifecycle?.setupDidFinish(self, mismatch: nil)
        }
    }

    /// The endpoint each characteristic is, from what was read off the board — or why the service
    /// isn't the specified one. `characteristics`: UUID, 0x2901 text, properties, in any order;
    /// the result maps each endpoint to its index.
    nonisolated static func endpoints(
        from characteristics: [(uuid: String, description: String?, properties: CBCharacteristicProperties)]
    ) -> Result<[PowerBaseBLEProtocol.Endpoint: Int], PowerBaseBLEOpenError> {
        var result: [PowerBaseBLEProtocol.Endpoint: Int] = [:]
        for (index, characteristic) in characteristics.enumerated() {
            guard let text = characteristic.description, let endpoint = PowerBaseBLEProtocol.Endpoint(rawValue: text) else {
                return .failure(.gattMismatch("unknown endpoint"))
            }
            guard result[endpoint] == nil else { return .failure(.gattMismatch("duplicate endpoint")) }
            guard characteristic.uuid.uppercased() == endpoint.characteristicUUID else { return .failure(.gattMismatch("endpoint UUID")) }
            guard characteristic.properties.contains(.read), characteristic.properties.contains(.write) else {
                return .failure(.gattMismatch("endpoint properties"))
            }
            result[endpoint] = index
        }
        guard result.count == PowerBaseBLEProtocol.Endpoint.allCases.count else { return .failure(.gattMismatch("missing endpoint")) }
        return .success(result)
    }

    private func failOpening(_ mismatch: PowerBaseBLEOpenError) {
        guard state == .opening else { return }
        lifecycle?.setupDidFinish(self, mismatch: mismatch)
    }

    // MARK: - One request, one answer

    /// Writes the whole of `payload` to the endpoint's characteristic and returns what a read of
    /// it gives afterwards. Throws `PowerBaseBLELinkError`. See `PowerBaseEnrollmentBLEExchanger`.
    func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
        guard state == .ready, let exchanger else { throw PowerBaseBLELinkError.disconnected }
        return try await exchanger.exchange(endpoint: endpoint, payload: payload)
    }

    private func endpoint(of characteristic: CBCharacteristic) -> PowerBaseBLEProtocol.Endpoint? {
        endpoints.first { $0.value === characteristic }?.key
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard state == .ready, let endpoint = endpoint(of: characteristic) else { return }
        // An ATT error is the board's own "no" to this request; anything else is the transport.
        exchanger?.didWrite(endpoint, error == nil ? .written : (error is CBATTError ? .rejected : .failed))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard state == .ready, let endpoint = endpoint(of: characteristic) else { return }
        exchanger?.didRead(endpoint, value: error == nil ? characteristic.value : nil)
    }

    // MARK: PowerBaseBLEEndpointIO

    var maximumWriteLength: Int { peripheral.maximumWriteValueLength(for: .withResponse) }

    func write(_ payload: Data, to endpoint: PowerBaseBLEProtocol.Endpoint) {
        guard state == .ready, let characteristic = endpoints[endpoint] else { return }
        // One write with response of the whole value; CoreBluetooth makes it a long write if needed.
        peripheral.writeValue(payload, for: characteristic, type: .withResponse)
    }

    func read(_ endpoint: PowerBaseBLEProtocol.Endpoint) {
        guard state == .ready, let characteristic = endpoints[endpoint] else { return }
        peripheral.readValue(for: characteristic)
    }

    // MARK: - Ending

    /// Ends the connection. A request under way fails with `error`; an opening under way fails as
    /// a lost connection. Safe to call again, and without effect once the connection is over: a
    /// late call can't touch the connection that came after this one.
    func invalidate(_ error: PowerBaseBLELinkError) {
        guard state == .opening || state == .ready else { return }
        if let lifecycle {
            lifecycle.close(self, error)
        } else {
            linkDidEnd(error)
        }
    }

    func linkDidEnd(_ error: PowerBaseBLELinkError) {
        guard state != .closed else { return }
        state = .closed
        endpoints = [:]
        descriptions = []
        service = nil
        // The peripheral object is shared with the next connection to this board: only this
        // connection's own delegate registration is removed.
        if peripheral.delegate === self { peripheral.delegate = nil }
        // Fails the request under way. Its `onClose` finds this connection closed already.
        exchanger?.close(error)
    }
}

/// What the request/answer logic needs from a connected peripheral.
@MainActor
protocol PowerBaseBLEEndpointIO: AnyObject {
    /// The longest value one write with response may carry on this connection.
    var maximumWriteLength: Int { get }
    /// Starts a write with response of the whole of `payload`. `didWrite` reports its result.
    func write(_ payload: Data, to endpoint: PowerBaseBLEProtocol.Endpoint)
    /// Starts a read of the endpoint's characteristic. `didRead` reports its result.
    func read(_ endpoint: PowerBaseBLEProtocol.Endpoint)
}

/// How a write with response ended.
nonisolated enum PowerBaseBLEWriteOutcome: Sendable {
    case written
    /// The board answered with an ATT error: its handler refused the request.
    case rejected
    case failed
}

/// One request and its answer at a time on one connection: write the whole request to the
/// endpoint's characteristic, then read the same characteristic. Separate from CoreBluetooth so
/// the rules below can be tested without a radio.
///
/// - A request longer than one characteristic value is refused before anything is written. It is
///   never split.
/// - Every request has a time limit. A request without an answer in time, a failed read or write,
///   or a lost connection **closes** the exchanger: nothing more is sent, and an answer that
///   arrives afterwards finds nothing to complete. Only the board's own refusal of a write (an
///   ATT error) leaves it open.
/// - A report for another endpoint than the one waited for, or for a step that already happened,
///   changes nothing. The caller is resumed exactly once.
/// - Not cancellable: a request that left this device is waited for until its answer or its time
///   limit. Cutting it off would leave the session's counters -- and what the board did -- unknown,
///   exactly when a clean-up needs the session.
final class PowerBaseEnrollmentBLEExchanger {
    private weak var io: PowerBaseBLEEndpointIO?
    private let exchangeTimeout: Duration
    private let handshakeTimeout: Duration
    private let onClose: () -> Void

    private(set) var isOpen = true

    private struct Pending {
        let id: Int
        let endpoint: PowerBaseBLEProtocol.Endpoint
        var isReading: Bool
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pending: Pending?
    private var counter = 0
    private var timeoutTask: Task<Void, Never>?

    /// `onClose` is called once, when the exchanger closes: the owner ends the connection.
    init(io: PowerBaseBLEEndpointIO, exchangeTimeout: Duration, handshakeTimeout: Duration, onClose: @escaping () -> Void) {
        self.io = io
        self.exchangeTimeout = exchangeTimeout
        self.handshakeTimeout = handshakeTimeout
        self.onClose = onClose
    }

    func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
        guard isOpen, let io else { throw PowerBaseBLELinkError.disconnected }
        guard pending == nil else { throw PowerBaseBLELinkError.failed("busy") }
        let limit = min(PowerBaseBLEProtocol.maximumAttributeLength, io.maximumWriteLength)
        guard !payload.isEmpty, payload.count <= limit else {
            throw PowerBaseBLELinkError.messageTooLong(length: payload.count, limit: limit)
        }
        counter += 1
        let id = counter
        // The board computes SRP before it answers a handshake write; ATT allows 30 seconds.
        let timeout = endpoint == .session ? handshakeTimeout : exchangeTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pending = Pending(id: id, endpoint: endpoint, isReading: false, continuation: continuation)
            timeoutTask = Task { [weak self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                guard let self, self.pending?.id == id else { return }
                self.close(.timeout)
            }
            io.write(payload, to: endpoint)
        }
    }

    /// The write to `endpoint` ended.
    func didWrite(_ endpoint: PowerBaseBLEProtocol.Endpoint, _ outcome: PowerBaseBLEWriteOutcome) {
        guard isOpen, var current = pending, current.endpoint == endpoint, !current.isReading else { return }
        switch outcome {
        case .written:
            current.isReading = true
            pending = current
            io?.read(endpoint)
        case .rejected:
            complete(.failure(PowerBaseBLELinkError.rejected))
        case .failed:
            close(.failed("write"))
        }
    }

    /// The read of `endpoint` ended; `value` is `nil` when it failed.
    func didRead(_ endpoint: PowerBaseBLEProtocol.Endpoint, value: Data?) {
        guard isOpen, let current = pending, current.endpoint == endpoint, current.isReading else { return }
        guard let value, value.count <= PowerBaseBLEProtocol.maximumAttributeLength else {
            close(.failed("read"))
            return
        }
        complete(.success(value))
    }

    /// Ends everything: the request under way fails with `error`. Safe to call again.
    func close(_ error: PowerBaseBLELinkError) {
        guard isOpen else { return }
        isOpen = false
        let current = pending
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        onClose()
        current?.continuation.resume(throwing: error)
    }

    private func complete(_ result: Result<Data, Error>) {
        guard let current = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        current.continuation.resume(with: result)
    }
}

/// The connection as the package's `PowerBaseBLELink`: a `Sendable` handle that hops to the main
/// actor, where CoreBluetooth and the connection live.
nonisolated struct PowerBaseEnrollmentBLELink: PowerBaseBLELink {
    let connection: PowerBaseEnrollmentBLEConnection

    func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
        try await connection.exchange(endpoint: endpoint, payload: payload)
    }

    func close() async {
        await connection.invalidate(.disconnected)
    }
}
