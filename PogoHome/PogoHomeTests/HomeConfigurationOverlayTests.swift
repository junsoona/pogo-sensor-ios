import XCTest
@testable import PogoHome

@MainActor
final class HomeConfigurationOverlayTests: XCTestCase {
    func testRenameAndRoomAssignmentApplyImmediatelyWithoutChangingSensorState() async throws {
        let sourceSnapshot = makeSnapshot(value: 21)
        let source = ConfigurationTestDataSource(initial: sourceSnapshot)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(
            dataSource: source,
            initialSnapshot: sourceSnapshot,
            configurationStore: store
        )
        let moduleID = try XCTUnwrap(sourceSnapshot.modules.first?.id)

        try await model.updateModule(
            id: moduleID,
            customName: "창가 공기 센서",
            roomID: HomeConfigurationDefaults.bedroom.id
        )

        let module = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertEqual(module.name, "창가 공기 센서")
        XCTAssertEqual(module.hardwareName, "시험 센서")
        XCTAssertEqual(module.hardwareIdentifier, "0011223344556677")
        XCTAssertEqual(module.roomID, HomeConfigurationDefaults.bedroom.id)
        XCTAssertEqual(module.readings.first?.value, 21)
        XCTAssertTrue(module.isOnline)
    }

    func testIncomingSensorUpdatesPreserveUserNameAndRoom() async throws {
        let initial = makeSnapshot(value: 21)
        let source = ConfigurationTestDataSource(initial: initial)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: source, initialSnapshot: initial, configurationStore: store)
        let moduleID = try XCTUnwrap(initial.modules.first?.id)
        try await model.updateModule(
            id: moduleID,
            customName: "내 센서",
            roomID: HomeConfigurationDefaults.workspace.id
        )
        model.start()
        defer { model.stop() }

        source.yield(makeSnapshot(value: 35))
        try await waitUntil { model.module(with: moduleID)?.readings.first?.value == 35 }

        let updated = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertEqual(updated.name, "내 센서")
        XCTAssertEqual(updated.roomID, HomeConfigurationDefaults.workspace.id)
    }

    func testPartialRecoveryDoesNotEraseDisplayStateOrConfiguration() async throws {
        let complete = makeSnapshot(value: 21)
        let source = ConfigurationTestDataSource(initial: complete)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: source, initialSnapshot: complete, configurationStore: store)
        let moduleID = try XCTUnwrap(complete.modules.first?.id)
        try await model.updateModule(
            id: moduleID,
            customName: "보존할 이름",
            roomID: HomeConfigurationDefaults.livingRoom.id
        )
        model.start()
        defer { model.stop() }

        source.yield(HomeSnapshot(timestamp: Date(), rooms: [], modules: []))
        try await waitUntil { model.isRegistryRecovering }

        let preserved = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertEqual(preserved.name, "보존할 이름")
        XCTAssertEqual(preserved.roomID, HomeConfigurationDefaults.livingRoom.id)
        XCTAssertEqual(preserved.readings.first?.value, 21)
    }

    func testDeletingAssignedRoomUpdatesVisibleModuleToFallback() async throws {
        let initial = makeSnapshot(value: 21)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(
            dataSource: ConfigurationTestDataSource(initial: initial),
            initialSnapshot: initial,
            configurationStore: store
        )
        let moduleID = try XCTUnwrap(initial.modules.first?.id)
        let room = try await model.createRoom(name: "삭제할 방", symbolName: "square.fill")
        try await model.updateModule(id: moduleID, customName: "이름 유지", roomID: room.id)

        try await model.deleteRoom(id: room.id)

        let module = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertEqual(module.name, "이름 유지")
        XCTAssertEqual(module.roomID, ModuleCatalog.unspecifiedRoom.id)
    }

    func testClearingCustomNameRestoresHardwareName() async throws {
        let initial = makeSnapshot(value: 21)
        let model = AppModel(
            dataSource: ConfigurationTestDataSource(initial: initial),
            initialSnapshot: initial,
            configurationStore: InMemoryHomeConfigurationStore()
        )
        let moduleID = try XCTUnwrap(initial.modules.first?.id)

        try await model.updateModule(id: moduleID, customName: "별명", roomID: HomeConfigurationDefaults.livingRoom.id)
        try await model.updateModule(id: moduleID, customName: nil, roomID: HomeConfigurationDefaults.livingRoom.id)

        XCTAssertEqual(model.module(with: moduleID)?.name, "시험 센서")
    }

    /// Milestone: "timeout/일시적 통신 단절/재부팅 -> offline, not removed". A module merely
    /// reported `online: false` (still present in the snapshot) must never lose its saved
    /// name/room, and must never disappear from `AppModel.snapshot` the way an actually
    /// absent (removed) module does.
    func testOfflineModuleKeepsItsConfigurationAndStaysInTheSnapshot() async throws {
        let initial = makeSnapshot(value: 21)
        let source = ConfigurationTestDataSource(initial: initial)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: source, initialSnapshot: initial, configurationStore: store)
        let moduleID = try XCTUnwrap(initial.modules.first?.id)
        try await model.updateModule(id: moduleID, customName: "보존할 이름", roomID: HomeConfigurationDefaults.bedroom.id)
        model.start()
        defer { model.stop() }

        var offlineModule = initial.modules[0]
        offlineModule = SensorModule(
            id: offlineModule.id,
            name: offlineModule.hardwareName,
            hardwareName: offlineModule.hardwareName,
            hardwareIdentifier: offlineModule.hardwareIdentifier,
            roomID: offlineModule.roomID,
            readings: offlineModule.readings,
            isOnline: false,
            lastSeen: Date(),
            roleDescription: offlineModule.roleDescription
        )
        source.yield(HomeSnapshot(timestamp: Date(), rooms: initial.rooms, modules: [offlineModule]))
        try await waitUntil { model.module(with: moduleID)?.isOnline == false }

        let module = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertEqual(module.name, "보존할 이름")
        XCTAssertEqual(module.roomID, HomeConfigurationDefaults.bedroom.id)
    }

    /// Milestone: "재등록 시 기존 사용자 이름과 방 배치를 복원". A module absent from the
    /// snapshot for a while (removed) and then reappearing under the same UUID must come
    /// back with its previously-saved name/room, not as a fresh nameless/unassigned device —
    /// `updateModule`'s persisted configuration is keyed by UUID and is never deleted just
    /// because the module briefly left the live snapshot.
    func testModuleReappearingAfterAbsenceRestoresItsPreviouslySavedNameAndRoom() async throws {
        // A second, always-present module with its own reading keeps every intermediate
        // snapshot below "complete" (per `onlineModulesHaveReadings`, a fully empty registry
        // is deliberately never treated as trustworthy — see `AppModel.applyIncoming`), so
        // the target module's removal-then-reappearance is exercised without depending on
        // that separate empty-registry guard at all.
        let controlID = UUID()
        let control = SensorModule(
            id: controlID,
            name: "고정 센서",
            roomID: ModuleCatalog.unspecifiedRoom.id,
            readings: [SensorReading(kind: .temperature, value: 20, timestamp: Date(), status: .normal)],
            isOnline: true,
            lastSeen: Date()
        )
        let initial = makeSnapshot(value: 21)
        let targetID = try XCTUnwrap(initial.modules.first?.id)
        let withControl = HomeSnapshot(timestamp: Date(), rooms: initial.rooms, modules: initial.modules + [control])
        let source = ConfigurationTestDataSource(initial: withControl)
        let store = InMemoryHomeConfigurationStore()
        let model = AppModel(dataSource: source, initialSnapshot: withControl, configurationStore: store)
        try await model.updateModule(id: targetID, customName: "복원될 이름", roomID: HomeConfigurationDefaults.workspace.id)
        model.start()
        defer { model.stop() }

        // The target module is gone entirely (a real removal); the control module remains,
        // with a reading, so this snapshot is complete and applies immediately.
        source.yield(HomeSnapshot(timestamp: Date(), rooms: initial.rooms, modules: [control]))
        try await waitUntil { model.module(with: targetID) == nil }

        // It reappears under the same UUID (re-approved after re-docking to POGO), reported
        // by the hardware exactly as any newly-seen module would be — no name, no room.
        let reregistered = SensorModule(
            id: targetID,
            name: "시험 센서",
            hardwareName: "시험 센서",
            hardwareIdentifier: "0011223344556677",
            roomID: ModuleCatalog.unspecifiedRoom.id,
            readings: [SensorReading(kind: .temperature, value: 30, timestamp: Date(), status: .normal)],
            isOnline: true,
            lastSeen: Date()
        )
        source.yield(HomeSnapshot(timestamp: Date(), rooms: initial.rooms, modules: [control, reregistered]))
        try await waitUntil { model.module(with: targetID) != nil }

        let restored = try XCTUnwrap(model.module(with: targetID))
        XCTAssertEqual(restored.name, "복원될 이름")
        XCTAssertEqual(restored.roomID, HomeConfigurationDefaults.workspace.id)
    }

    private func makeSnapshot(value: Double) -> HomeSnapshot {
        let moduleID = UUID(uuidString: "00112233-4455-4677-8899-AABBCCDDEEFF")!
        let module = SensorModule(
            id: moduleID,
            name: "시험 센서",
            hardwareName: "시험 센서",
            hardwareIdentifier: "0011223344556677",
            roomID: ModuleCatalog.unspecifiedRoom.id,
            readings: [
                SensorReading(kind: .temperature, value: value, timestamp: Date(), status: .normal),
            ],
            isOnline: true,
            lastSeen: Date(),
            roleDescription: "시험 모듈"
        )
        return HomeSnapshot(
            timestamp: Date(),
            rooms: ModuleCatalog.allRooms,
            modules: [module]
        )
    }
}

@MainActor
private final class ConfigurationTestDataSource: SensorDataSource {
    private let initial: HomeSnapshot
    private let stream: AsyncStream<HomeSnapshot>
    private let continuation: AsyncStream<HomeSnapshot>.Continuation

    init(initial: HomeSnapshot) {
        self.initial = initial
        let pair = AsyncStream.makeStream(of: HomeSnapshot.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.continuation.yield(initial)
    }

    func currentSnapshot() async throws -> HomeSnapshot { initial }

    func updates() -> AsyncStream<HomeSnapshot> {
        stream
    }

    func yield(_ snapshot: HomeSnapshot) {
        continuation.yield(snapshot)
    }
}
