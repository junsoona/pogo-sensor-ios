import XCTest
@testable import PogoHome

/// What the hub says about Power Base management, all the way to "Power Base 관리": the hub's JSON
/// through the real `LiveSensorDataSource` and `PogoSnapshotMapper` into the real `AppModel`, and
/// the sheet's state read from `AppModel.snapshot` the way `PowerBaseManagementSheet` reads it.
///
/// The field defect (2026-10-07): a hub whose snapshot carried `power_base_removals` and a Base
/// with `management: supported` was shown as "연결된 허브가 … 지원하지 않습니다". Putting the user's
/// rooms and names on a snapshot rebuilt it without the hub's two management fields. The app always
/// has rooms (the default ones), so on a device that happened with every snapshot; the tests of
/// the mapper and of the presentation each passed, because none of them went through `AppModel`
/// with rooms configured.
@MainActor
final class AppModelPowerBaseManagementTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias F = ManagementHubFixtures

    private var settingsHub: FakeSettingsHub!
    private var transport: ControllableSensorAPITransport!
    private var credentials: InMemoryHubCredentialStore!
    private var removalHub: FakeRemovalHub!
    private var removals: PowerBaseRemovalController!
    private var model: AppModel!

    override func tearDown() async throws {
        model?.stop()
        model = nil
        removals = nil
        removalHub = nil
        transport = nil
        credentials = nil
        settingsHub = nil
    }

    // MARK: - The app, as it runs on a device

    private func liveSource(_ transport: ControllableSensorAPITransport) -> LiveSensorDataSource {
        LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: F.hubURL),
            transport: transport,
            sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5,
            periodicRefreshInterval: nil
        )
    }

    /// An app following a hub picked in "허브 찾기", with rooms configured (the default rooms, as on
    /// every device), connected, with the hub's first snapshot received.
    private func startApp(
        hub: FakeSettingsHub = FakeSettingsHub(),
        store: InMemoryHomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean),
        first: Data
    ) async throws {
        settingsHub = hub
        credentials = InMemoryHubCredentialStore()
        transport = ControllableSensorAPITransport { first }
        model = AppModel(
            dataSource: liveSource(transport),
            sourceIdentity: .hub(id: hub.hubID),
            sourceAddress: F.hubURL,
            configurationStore: store,
            sharedSettings: SharedSettingsController(
                transport: hub, credentials: credentials, cache: InMemorySharedSettingsCache(), language: .korean, retryInterval: .zero
            ),
            language: .korean
        )
        removalHub = FakeRemovalHub()
        removals = PowerBaseRemovalController(transport: removalHub, credentials: credentials)
        XCTAssertFalse(model.editableRooms.isEmpty, "the rooms the defect needs: every device has them")
        model.start()
        try await waitUntil { self.model.lastSyncAt != nil }
        try await waitUntil { await self.transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { self.model.connectionStatus == .connected }
    }

    /// Registers this device with the hub (the operator's one-time code). Sharing is not on yet.
    @discardableResult
    private func pair() async throws -> HubSettingsState {
        _ = settingsHub.createCode()
        return try await model.sharedSettings.pair(code: "7KQM-3XWD-PA9T", deviceName: "Test")
    }

    /// Pairs and turns settings sharing on, uploading this device's settings as the hub's first.
    private func turnOnSharing() async throws {
        let state = try await pair()
        XCTAssertFalse(state.initialized)
        _ = try await model.sharedSettings.uploadAsFirstSettings(model.sharedSettingsUploadSummary().document)
        XCTAssertTrue(model.usesSharedSettings)
    }

    /// The hub's next snapshot, as an SSE event on the open connection.
    private func receive(_ json: Data) async throws {
        let before = model.sensorSnapshot.timestamp
        await transport.setSnapshotProvider { json }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: json))
        try await waitUntil { self.model.sensorSnapshot.timestamp != before }
    }

    /// The hub's next snapshot whether or not the app puts it on screen: one the app holds back
    /// (sensors still recovering) is received all the same.
    private func deliver(_ json: Data) async throws {
        let before = model.lastSyncAt
        await transport.setSnapshotProvider { json }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: json))
        try await waitUntil { self.model.lastSyncAt != before }
    }

    /// The sheet's state, read as `PowerBaseManagementSheet.state` reads it; the target as
    /// `DevicesView` hands it to the controller.
    private func sheetState(_ identifier: String = F.base) -> P.State {
        removals.targetDidChange(PowerBaseHubTarget(appModel: model))
        return P.state(
            identifier: identifier, snapshot: model.snapshot, target: removals.target,
            removal: removals.removal(for: identifier, in: model.snapshot),
            action: removals.action(for: identifier),
            isCurrentStateVerified: model.isPowerBaseStateVerified
        )
    }

    private func supportedHub(removals: [String] = [], settings: FakeSettingsHub? = nil) -> Data {
        F.snapshot(
            bases: [F.base(F.base, moduleCount: 2, management: "supported")],
            modules: [F.module(F.gasSensor, base: F.base), F.module(F.dustSensor, base: F.base)],
            removals: removals, settings: settings
        )
    }

    // MARK: - A hub with management

    func testASupportedHubAndBaseCanBeRemovedWithRoomsConfigured() async throws {
        try await startApp(first: supportedHub())
        try await pair()

        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement, "the hub sent power_base_removals")
        XCTAssertEqual(model.snapshot.powerBases.map(\.management), [.supported])
        // The user's rooms were put on the snapshot: this is the rebuilt one, not the hub's.
        XCTAssertNotEqual(model.snapshot.rooms, model.sensorSnapshot.rooms)
        let state = sheetState()
        XCTAssertEqual(state.availability, .available)
        XCTAssertNil(PowerBaseManagementText.unavailableMessage(state.availability), "nothing says 'not supported'")
        XCTAssertEqual(state.sensorCount, 2)
        XCTAssertTrue(state.isCurrentStateVerified)
    }

    func testAnEmptyRemovalListIsStillAHubWithManagement() async throws {
        try await startApp(first: supportedHub(removals: []))
        try await pair()

        XCTAssertEqual(model.snapshot.powerBaseRemovals, [])
        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement, "no job is not the same as no management")
        XCTAssertNil(sheetState().removal)
        XCTAssertEqual(sheetState().availability, .available)
    }

    func testAPendingReleasedAndCompletedJobReachTheSheetAsTheHubReportsThem() async throws {
        // A second Base with a sensor stays throughout, so the hub's list never becomes empty.
        let other = F.base(F.otherBase, moduleCount: 1, management: "supported")
        let otherSensor = F.module(F.otherSensor, base: F.otherBase)
        let enrolled = [F.base(F.base, online: false, moduleCount: 2, management: "supported"), other]
        let sensors = [F.module(F.gasSensor, base: F.base, online: false), F.module(F.dustSensor, base: F.base, online: false), otherSensor]
        try await startApp(first: F.snapshot(bases: enrolled, modules: sensors, removals: []))
        try await pair()
        XCTAssertEqual(sheetState().availability, .available)

        // Waiting for the offline Base: shown, and the hub says it can be cancelled.
        try await receive(F.snapshot(bases: enrolled, modules: sensors, removals: [F.removal("pending")]))
        var state = sheetState()
        XCTAssertEqual(state.removal?.state, .pending)
        XCTAssertEqual(state.removal?.presentation, .waitingForPowerBase)
        XCTAssertEqual(state.availability, .removalExists)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.cancel])
        XCTAssertEqual(P.badge(for: model.snapshot.removal(forPowerBase: F.base)), .waitingForPowerBase)

        // Released: out of the hub's lists, not complete, and "삭제 확인" is offered.
        try await receive(F.snapshot(bases: [other], modules: [otherSensor], removals: [F.removal("released")]))
        state = sheetState()
        XCTAssertNil(state.base, "the hub no longer lists the Base")
        XCTAssertEqual(state.removal?.state, .released)
        XCTAssertEqual(state.removal?.presentation, .awaitingEraseConfirmation)
        XCTAssertNotEqual(state.removal?.presentation, .completed, "released is not removed")
        XCTAssertEqual(state.removal?.offersEraseConfirmation, true)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(state.availability, .removalExists)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.powerBaseIdentifier), [F.base],
                       "the device list keeps the job of a Base the hub dropped")

        // Completed: only now is it called removed, and nothing is left to do.
        try await receive(F.snapshot(bases: [other], modules: [otherSensor], removals: [F.removal("completed")]))
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .completed)
        XCTAssertEqual(state.removal?.presentation, .completed)
        XCTAssertEqual(state.removal?.offersEraseConfirmation, false)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [])
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty, "a finished removal leaves the device list")
        // The other Base is untouched by all of it.
        XCTAssertEqual(sheetState(F.otherBase).availability, .available)
    }

    func testAJobWithoutAResultOffersTheEraseConfirmationToo() async throws {
        try await startApp(first: supportedHub(removals: [F.removal("sent", resultUnknown: true)]))
        try await pair()

        let state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .resultUnknown)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(state.availability, .removalExists)
    }

    // MARK: - Every way the snapshot on screen is rebuilt

    func testTheHubsManagementSurvivesTheFirstSnapshotLaterOnesAndEveryEditOfNamesAndRooms() async throws {
        try await startApp(first: supportedHub())
        try await pair()
        XCTAssertFalse(model.usesSharedSettings, "this device's own settings")
        // First snapshot (the GET before the event stream).
        XCTAssertEqual(sheetState().availability, .available)

        // A later one (an SSE event), with a job.
        try await receive(supportedHub(removals: [F.removal("pending")]))
        XCTAssertEqual(sheetState().removal?.state, .pending)

        // Each edit puts the settings on the last snapshot again.
        let gas = ModuleIdentity.stableUUID(forRawIdentifier: F.gasSensor)
        try await model.updateHomeName(input: "작업실 집")
        assertManagement(removal: .pending, "after renaming the home")
        let study = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        assertManagement(removal: .pending, "after adding a room")
        try await model.updateModule(id: gas, customName: "서재 공기", roomID: study.id)
        assertManagement(removal: .pending, "after renaming and moving a sensor")
        XCTAssertEqual(model.module(with: gas)?.name, "서재 공기")
        XCTAssertEqual(model.module(with: gas)?.roomID, study.id)
        try await model.updateRoom(id: study.id, name: "책방", symbolName: "books.vertical.fill")
        assertManagement(removal: .pending, "after renaming a room")
        try await model.reorderRooms(orderedIDs: model.editableRooms.map(\.id).filter { $0 != ModuleCatalog.unspecifiedRoomID }.reversed())
        assertManagement(removal: .pending, "after reordering the rooms")
        try await model.deleteRoom(id: study.id)
        assertManagement(removal: .pending, "after deleting a room")
        XCTAssertEqual(model.module(with: gas)?.roomID, ModuleCatalog.unspecifiedRoomID)

        // And the next snapshot is the hub's again, not a copy of the last one.
        try await receive(supportedHub(removals: []))
        assertManagement(removal: nil, "after the job left the hub's list")
        XCTAssertEqual(sheetState().availability, .available)
        XCTAssertEqual(model.module(with: gas)?.name, "서재 공기", "the names stay")
    }

    func testTheHubsManagementSurvivesSharedSettingsAndAnotherDevicesChange() async throws {
        let hub = FakeSettingsHub()
        try await startApp(hub: hub, first: supportedHub(settings: hub))
        try await turnOnSharing()
        assertManagement(removal: nil, "after sharing was turned on")
        XCTAssertEqual(sheetState().availability, .available)

        // An edit saved through the hub.
        let hall = try await model.createRoom(name: "현관", symbolName: "door.left.hand.open")
        try await model.updateModule(id: ModuleIdentity.stableUUID(forRawIdentifier: F.dustSensor), customName: "현관 먼지", roomID: hall.id)
        try await receive(supportedHub(removals: [F.removal("pending")], settings: hub))
        assertManagement(removal: .pending, "after an edit through the hub")

        // Another device renames the room: the hub's revision moves, this device reads the new
        // settings and puts them on the snapshot it already has.
        var document = try XCTUnwrap(hub.currentDocument)
        let index = try XCTUnwrap(document.rooms.firstIndex { $0.id == hall.id })
        document.rooms[index] = HubRoomSetting(
            id: hall.id, nameKind: .custom, name: "복도", suggestionSymbol: nil, suggestionOrdinal: nil, symbol: document.rooms[index].symbol
        )
        _ = try await hub.putSettings(
            baseURL: F.hubURL, credential: try XCTUnwrap(credentials.credential(forHubID: hub.hubID)), baseRevision: hub.revision, settings: document
        )
        try await receive(supportedHub(removals: [F.removal("pending")], settings: hub))
        await waitUntil("the other device's room name arrives") { self.model.room(with: hall.id)?.name == "복도" }
        assertManagement(removal: .pending, "after another device's change")
        XCTAssertEqual(sheetState().availability, .removalExists)

        // Sharing off again: back to this device's own settings, the hub's management as it is.
        await model.sharedSettings.stopSharing()
        XCTAssertFalse(model.usesSharedSettings)
        assertManagement(removal: .pending, "after sharing was turned off")
    }

    func testEverythingButNamesAndRoomsIsTheHubsOwn() async throws {
        try await startApp(first: supportedHub(removals: [F.removal("pending")]))
        try await model.updateModule(
            id: ModuleIdentity.stableUUID(forRawIdentifier: F.gasSensor), customName: "거실 공기",
            roomID: try XCTUnwrap(model.editableRooms.first).id
        )

        // Whatever a snapshot carries besides the rooms and the modules (whose names and rooms are
        // the user's) is the hub's and reaches the screen as it is -- including what is added later.
        let shown = Dictionary(uniqueKeysWithValues: Mirror(reflecting: model.snapshot).children.map { ($0.label ?? "", $0.value) })
        let source = Mirror(reflecting: model.sensorSnapshot).children.map { ($0.label ?? "", $0.value) }
        XCTAssertGreaterThan(source.count, 2)
        for (name, value) in source where name != "rooms" && name != "modules" {
            let hubValue = try XCTUnwrap(value as? AnyHashable, name)
            XCTAssertEqual(shown[name] as? AnyHashable, hubValue, "HomeSnapshot.\(name) was not carried over from the hub's snapshot")
        }
        // The same rebuild serves a snapshot fetched for the Watch.
        XCTAssertEqual(model.applyingConfiguration(to: model.sensorSnapshot), model.snapshot)
    }

    // MARK: - What must stay "not supported"

    func testAHubWithoutManagementIsStillNotSupported() async throws {
        // An older hub: no power_base_removals, no management word on its Bases.
        let legacy = F.snapshot(
            bases: [F.base(F.base, moduleCount: 2, management: nil)],
            modules: [F.module(F.gasSensor, base: F.base), F.module(F.dustSensor, base: F.base)],
            removals: nil
        )
        try await startApp(first: legacy)
        try await pair()

        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(model.snapshot.powerBases.map(\.management), [.unknown])
        XCTAssertEqual(sheetState().availability, .hubUnsupported)
        XCTAssertNotNil(PowerBaseManagementText.unavailableMessage(sheetState().availability))

        try await model.updateHomeName(input: "작업실 집")
        try await receive(legacy)
        XCTAssertEqual(sheetState().availability, .hubUnsupported, "an edit or a new snapshot does not make it supported")
    }

    func testABaseEnrolledWithoutACredentialIsStillNotSupportedOnAHubWithManagement() async throws {
        try await startApp(first: F.snapshot(
            bases: [F.base(F.base, moduleCount: 1, management: "unsupported"), F.base(F.otherBase, moduleCount: 1, management: nil)],
            modules: [F.module(F.gasSensor, base: F.base), F.module(F.otherSensor, base: F.otherBase)],
            removals: []
        ))
        try await pair()

        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(sheetState(F.base).availability, .powerBaseUnsupported)
        XCTAssertEqual(sheetState(F.otherBase).availability, .powerBaseUnsupported, "a Base the hub says nothing about is not assumed removable")
    }

    func testADeviceThatIsNotPairedIsToldSoNotThatTheHubIsUnsupported() async throws {
        try await startApp(first: supportedHub())

        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(sheetState().availability, .hubNotEligible(.notPaired))
    }

    // MARK: - Another hub

    func testAnotherHubNeverShowsThePreviousHubsJobsOrSupport() async throws {
        try await startApp(first: supportedHub(removals: [F.removal("pending")]))
        try await pair()
        XCTAssertEqual(sheetState().removal?.state, .pending)

        // Hub B, an older one, with a Base of the same identifier.
        let hubB = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        let legacy = F.snapshot(
            bases: [F.base(F.base, moduleCount: 1, management: nil)], modules: [F.module(F.otherSensor, base: F.base)], removals: nil
        )
        let transportB = ControllableSensorAPITransport { legacy }
        model.replace(dataSource: liveSource(transportB), identity: .hub(id: hubB.hubID), address: URL(string: "http://192.168.1.11:8787"))

        // At once, before hub B has said anything.
        XCTAssertEqual(model.snapshot.powerBaseRemovals, [])
        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement)
        XCTAssertNil(sheetState().removal)
        XCTAssertNotEqual(sheetState().availability, .available)

        // And after its own snapshot.
        try await waitUntil { !self.model.snapshot.modules.isEmpty }
        XCTAssertEqual(model.snapshot.powerBaseRemovals, [], "hub A's job is not hub B's")
        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement)
        XCTAssertNil(sheetState().removal)
        XCTAssertEqual(removals.removals, [:])
        XCTAssertEqual(sheetState().availability, .hubNotEligible(.notPaired), "this device has no credential for hub B")

        // Back on hub A: what hub A says now, nothing remembered from before.
        let transportA = ControllableSensorAPITransport { [first = supportedHub(removals: [])] in first }
        model.replace(dataSource: liveSource(transportA), identity: .hub(id: settingsHub.hubID), address: F.hubURL)
        XCTAssertEqual(model.snapshot.powerBaseRemovals, [])
        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement, "nothing until hub A itself answers")
        try await waitUntil { !self.model.snapshot.modules.isEmpty }
        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement)
        XCTAssertNil(sheetState().removal)
        XCTAssertEqual(sheetState().availability, .available)
    }

    // MARK: - A Base without sensors

    func testABaseWithoutSensorsKeepsItsManagement() async throws {
        let empty = F.snapshot(bases: [F.base(F.base, moduleCount: 0, management: "supported")], modules: [], removals: [])
        try await startApp(first: empty)
        try await pair()

        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertFalse(model.snapshot.rooms.isEmpty, "the user's rooms are on the snapshot all the same")
        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement)
        var state = sheetState()
        XCTAssertEqual(state.base?.management, .supported)
        XCTAssertEqual(state.sensorCount, 0)
        XCTAssertEqual(state.availability, .available)

        try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await receive(F.snapshot(bases: [F.base(F.base, moduleCount: 0, management: "supported")], modules: [], removals: [F.removal("pending")]))
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .pending)
        XCTAssertEqual(state.affectedSensorCount, 2, "what the hub counted for the job")
        XCTAssertEqual(state.availability, .removalExists)
    }

    // MARK: - One request, then nothing to do (2026-10-08)
    //
    // A Base whose board confirms its erase to the hub itself: the hub says so
    // (`erase_confirmation`), and the user's one confirmed request is all the app ever does. Until
    // the hub says `completed` the job is "삭제 대기" or "삭제 중"; "삭제 확인" (Bluetooth) is offered
    // only when the hub stops expecting the board's own confirmation, or never did.

    private func automaticHub(online: Bool = true, removals: [String] = []) -> Data {
        F.snapshot(
            bases: [F.base(F.base, online: online, moduleCount: 2, management: "supported", eraseConfirmation: "automatic")],
            modules: [F.module(F.gasSensor, base: F.base, online: online), F.module(F.dustSensor, base: F.base, online: online)],
            removals: removals
        )
    }

    private func automaticJob(_ state: PowerBaseRemoval.State) -> PowerBaseRemoval {
        var job = RemovalFixtures.removal(state)
        job.eraseConfirmation = .automatic
        return job
    }

    func testTheLastBaseGoesFromOneRequestToRemovedWithNothingElseAsked() async throws {
        try await startApp(first: automaticHub())
        try await pair()
        var state = sheetState()
        XCTAssertEqual(state.availability, .available)
        XCTAssertEqual(state.base?.eraseConfirmation, .automatic, "the hub says this Base confirms its own removal")
        let dialog = PowerBaseManagementText.confirmMessage(
            sensorCount: state.affectedSensorCount, isOnline: true, eraseConfirmation: try XCTUnwrap(state.base).eraseConfirmation
        )
        XCTAssertTrue(dialog.contains(PowerBaseManagementText.confirmRegisterAgain), "the one confirmation only says what a removal means for later")
        XCTAssertFalse(dialog.contains(PowerBaseManagementText.confirmLater), "and does not ask for a confirmation near the Base afterwards")

        // The user's one action: "삭제", confirmed.
        removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .waitingForPowerBase)
        if AppLanguage.current == .korean {
            XCTAssertEqual(PowerBaseManagementText.removalTitle(try XCTUnwrap(state.removal).presentation), "삭제 대기")
        }

        // The hub gives the command; the board takes it.
        try await deliver(automaticHub(removals: [F.removal("accepted", age: 0, eraseConfirmation: "automatic")]))
        state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .inProgress)
        if AppLanguage.current == .korean {
            XCTAssertEqual(PowerBaseManagementText.removalTitle(.inProgress), "삭제 중")
        }
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [])

        // Released: the hub takes the last Base and its sensors out of its lists. The board is
        // erasing and will report by itself -- still "삭제 중", and nothing is asked of the user.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 0, eraseConfirmation: "automatic")]))
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .released)
        XCTAssertEqual(state.removal?.presentation, .finishing)
        XCTAssertEqual(PowerBaseManagementText.removalTitle(.finishing), PowerBaseManagementText.removalTitle(.inProgress), "one title until the hub confirms")
        XCTAssertNotEqual(PowerBaseManagementText.removalTitle(.finishing), PowerBaseManagementText.removalTitle(.completed), "released is not removed")
        XCTAssertEqual(state.removal?.offersEraseConfirmation, false)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [], "no board search, no setup code, no '삭제 확인'")
        XCTAssertNil(state.base, "the hub no longer lists the Base")
        XCTAssertTrue(model.snapshot.modules.isEmpty, "its sensors left the screen with it, as on the hub")
        XCTAssertTrue(model.snapshot.powerBases.isEmpty)
        XCTAssertFalse(model.isRegistryRecovering, "a confirmed removal is not a registry being rebuilt")
        XCTAssertEqual(model.dataWait, .noModulesYet)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.state), [.released], "the request is still listed while it is under way")
        XCTAssertEqual(P.badge(for: model.snapshot.removal(forPowerBase: F.base)), .finishing)

        // The hub verified the board's confirmation: only now "삭제 완료".
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .completed)
        if AppLanguage.current == .korean {
            XCTAssertEqual(PowerBaseManagementText.removalTitle(.completed), "삭제 완료")
        }
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [])
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty, "a finished removal is no request any more, and no row of any other list")
        XCTAssertTrue(model.snapshot.modules.isEmpty)

        // All the app ever sent: the one request. It never read or relayed a confirmation.
        XCTAssertEqual(removalHub.recorded.filter { if case .request = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(removalHub.receipts.isEmpty)
    }

    func testAnOfflineBaseWaitsAndIsRemovedWhenItComesBack() async throws {
        try await startApp(first: automaticHub(online: false))
        try await pair()
        let dialog = PowerBaseManagementText.confirmMessage(sensorCount: 2, isOnline: false, eraseConfirmation: .automatic)
        XCTAssertTrue(dialog.contains(PowerBaseManagementText.removalTitle(.waitingForPowerBase)), "the dialog names the state it will show")
        XCTAssertEqual(sheetState().availability, .available, "an offline Base can be asked to be removed")
        removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }

        // Stored on the hub; the Base is still listed (offline), its sensors with it.
        try await deliver(automaticHub(online: false, removals: [F.removal("pending", eraseConfirmation: "automatic")]))
        var state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .waitingForPowerBase)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.cancel], "a waiting request can still be cancelled")
        XCTAssertEqual(state.sensorCount, 2)

        // The Base is back: the hub carries the stored request out without the app.
        try await deliver(automaticHub(removals: [F.removal("sent", age: 0, eraseConfirmation: "automatic")]))
        XCTAssertEqual(sheetState().removal?.presentation, .inProgress)
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 0, eraseConfirmation: "automatic")]))
        XCTAssertEqual(sheetState().removal?.presentation, .finishing)
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .completed)
        XCTAssertEqual(removalHub.recorded.filter { if case .request = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(removalHub.receipts.isEmpty)
    }

    func testWhenTheBoardsOwnConfirmationDoesNotArriveTheBluetoothConfirmationIsOffered() async throws {
        try await startApp(first: automaticHub(removals: [F.removal("accepted", age: 0, eraseConfirmation: "automatic")]))
        try await pair()
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 0, eraseConfirmation: "automatic")]))
        XCTAssertEqual(sheetState().removal?.presentation, .finishing)

        // The hub stops expecting it (the board lost power, or is out of reach): the same job,
        // still released, now to be confirmed by hand -- the screen that was always there.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 300, eraseConfirmation: "manual")]))
        var state = sheetState()
        XCTAssertEqual(state.removal?.state, .released)
        XCTAssertEqual(state.removal?.presentation, .awaitingEraseConfirmation)
        XCTAssertNotEqual(state.removal?.presentation, .completed, "time completes nothing")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(PowerBaseReleaseConfirmationOrigin(try XCTUnwrap(state.removal)), .released)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.state), [.released])

        // A confirmation that arrives late all the same completes it.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .completed)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty)
    }

    func testAHubOrBoardThatDoesNotSayKeepsTheBluetoothConfirmation() async throws {
        // An earlier hub: no `erase_confirmation` anywhere. An earlier board on a current hub:
        // "manual" from the start. Both are what the app did before.
        for word in [String?.none, "manual"] {
            try await startApp(first: F.snapshot(
                bases: [F.base(F.base, moduleCount: 2, management: "supported", eraseConfirmation: word)],
                modules: [F.module(F.gasSensor, base: F.base), F.module(F.dustSensor, base: F.base)], removals: []
            ))
            try await pair()
            let base = try XCTUnwrap(sheetState().base)
            XCTAssertNotEqual(base.eraseConfirmation, .automatic)
            let dialog = PowerBaseManagementText.confirmMessage(sensorCount: 2, isOnline: true, eraseConfirmation: base.eraseConfirmation)
            XCTAssertTrue(dialog.contains(PowerBaseManagementText.confirmLater), "the dialog still says a confirmation near the Base follows")

            try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 0, eraseConfirmation: word)]))
            let state = sheetState()
            XCTAssertEqual(state.removal?.presentation, .awaitingEraseConfirmation, word ?? "absent")
            XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase], word ?? "absent")
            model.stop()
        }
    }

    func testAnotherHubShowsNothingOfTheJobUnderWay() async throws {
        try await startApp(first: automaticHub())
        try await pair()
        XCTAssertEqual(sheetState().availability, .available)
        removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        XCTAssertNotNil(sheetState().removal)

        // The app turns to another hub while the first one is still removing the Base.
        removals.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        XCTAssertNil(removals.removal(for: F.base, in: HomeSnapshot(timestamp: Date(), rooms: [], modules: [])), "the other hub's job is not shown here")
        XCTAssertNil(removals.action(for: F.base))
        XCTAssertTrue(removalHub.receipts.isEmpty)
    }

    // MARK: - The last Base with sensors, and sensors that are still recovering
    //
    // Found while looking into the defect above (2026-10-07): once the app had a complete list of
    // sensors, a snapshot without sensors -- or with a sensor that had no sample yet -- was held
    // back as a whole, the hub's removal jobs with it. Releasing the last Base that had sensors
    // empties the hub's list, so the app stayed at "삭제 진행 중" with the Base and its sensors on
    // screen and never offered "삭제 확인".

    private func id(_ sensor: String) -> UUID { ModuleIdentity.stableUUID(forRawIdentifier: sensor) }

    func testTheLastBaseWithSensorsIsReleasedConfirmedAndCompletedWithoutARelaunch() async throws {
        try await startApp(first: supportedHub())
        try await pair()
        XCTAssertEqual(model.health, .healthy)

        try await deliver(supportedHub(removals: [F.removal("accepted", age: 0)]))
        var state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .inProgress)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [], "in progress: nothing to cancel, nothing to confirm")

        // Released: the hub takes the Base and its sensors out of its lists. Nothing else is left.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .released, "the hub's latest word, without starting the app again")
        XCTAssertEqual(state.removal?.presentation, .awaitingEraseConfirmation)
        XCTAssertNotEqual(state.removal?.presentation, .completed, "released is not removed")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(PowerBaseReleaseConfirmationOrigin(try XCTUnwrap(state.removal)), .released)
        XCTAssertEqual(state.availability, .removalExists)
        XCTAssertNil(state.base, "the hub no longer lists the Base")
        XCTAssertEqual(state.sensorCount, 0)
        XCTAssertTrue(model.snapshot.modules.isEmpty, "its sensors left with it, as on the hub")
        XCTAssertTrue(model.snapshot.powerBases.isEmpty)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.state), [.released], "the device list's way into the sheet")
        XCTAssertFalse(model.isRegistryRecovering, "a confirmed removal is not a registry being rebuilt")
        XCTAssertEqual(model.health, .waitingForData, "a home without sensors is not a healthy home")
        XCTAssertEqual(model.dataWait, .noModulesYet)

        // "삭제 확인" hands the board's receipt to the hub; the hub then reports the job completed.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .completed)
        XCTAssertEqual(state.removal?.presentation, .completed)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [])
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty)
        XCTAssertTrue(model.snapshot.modules.isEmpty)
    }

    func testACompletedRemovalTheAppNeverSawReleasedStillEmptiesTheList() async throws {
        try await startApp(first: supportedHub(removals: [F.removal("accepted", age: 30)]))
        try await pair()

        // The app missed `released`. It saw the Base listed while this job had not ended, and now
        // the job has ended and the Base is not listed: that is this job's doing, whatever the
        // times on it say.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", age: 2)]))
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertTrue(model.snapshot.powerBases.isEmpty)
        XCTAssertFalse(model.isRegistryRecovering)
        let state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .completed)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [])
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty)
    }

    func testAReleasedBaseLeavesWhileAnotherBasesSensorIsStillRecovering() async throws {
        let other = F.base(F.otherBase, moduleCount: 1, management: "supported")
        try await startApp(first: F.snapshot(
            bases: [F.base(F.base, moduleCount: 2, management: "supported"), other],
            modules: [F.module(F.gasSensor, base: F.base), F.module(F.dustSensor, base: F.base), F.module(F.otherSensor, base: F.otherBase)],
            removals: [F.removal("accepted", age: 0)]
        ))
        try await pair()
        let lastReadings = try XCTUnwrap(model.module(with: id(F.otherSensor))?.readings)
        XCTAssertFalse(lastReadings.isEmpty)

        // The first Base is released while the hub lists the other Base's sensor without a sample.
        try await deliver(F.snapshot(
            bases: [other], modules: [F.module(F.otherSensor, base: F.otherBase, hasReadings: false)], removals: [F.removal("released", age: 0)]
        ))
        XCTAssertTrue(model.isRegistryRecovering, "the sensor without a sample is still held back")
        XCTAssertEqual(model.health, .recoveringRegistry)
        XCTAssertEqual(model.module(with: id(F.otherSensor))?.readings, lastReadings, "its last readings stay on screen")
        XCTAssertEqual(model.snapshot.modules.map(\.id), [id(F.otherSensor)], "the released Base's sensors do not stay with it")
        XCTAssertEqual(model.snapshot.powerBases.map(\.hardwareIdentifier), [F.otherBase])
        XCTAssertFalse(model.isPowerBaseStateVerified, "the Bases on screen are the last confirmed ones, not the hub's latest")
        var state = sheetState()
        XCTAssertNil(state.base)
        XCTAssertEqual(state.removal?.state, .released)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.powerBaseIdentifier), [F.base])
        XCTAssertEqual(sheetState(F.otherBase).availability, .available, "the other Base is as it was")

        // The sample arrives.
        try await deliver(F.snapshot(bases: [other], modules: [F.module(F.otherSensor, base: F.otherBase)], removals: [F.removal("released", age: 0)]))
        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertEqual(model.health, .healthy)
        XCTAssertTrue(model.isPowerBaseStateVerified)
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .released)
        XCTAssertNotEqual(state.removal?.presentation, .completed)
    }

    func testAnEmptyListWithoutAConfirmedRemovalKeepsTheSensorsWhileTheJobsFollowTheHub() async throws {
        // The Base was removed once before and enrolled again: that removal is still in the hub's
        // list, completed, while the hub lists the Base.
        let earlier = F.removal("completed", id: F.earlierRemovalID, age: 120)
        try await startApp(first: supportedHub(removals: [earlier, F.removal("pending", age: 0)]))
        try await pair()
        let shown = model.snapshot.modules
        XCTAssertEqual(shown.count, 2)

        func assertHeld(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(model.snapshot.modules, shown, "the sensors and their last readings stay: \(what)", file: file, line: line)
            XCTAssertEqual(model.snapshot.powerBases.map(\.hardwareIdentifier), [F.base], what, file: file, line: line)
            XCTAssertTrue(model.isRegistryRecovering, what, file: file, line: line)
            XCTAssertEqual(model.health, .recoveringRegistry, what, file: file, line: line)
            XCTAssertFalse(model.isPowerBaseStateVerified, what, file: file, line: line)
        }

        // A hub starting again: no Base and no sensor yet. Its stored jobs are there, and none of
        // them says the Base was released -- neither does a job that ended another way, or silence.
        for word in ["pending", "sent", "accepted", "cancelled", "superseded"] {
            try await deliver(F.snapshot(bases: [], modules: [], removals: [earlier, F.removal(word, age: 0)]))
            assertHeld(word)
            let removal = try XCTUnwrap(sheetState().removal, word)
            XCTAssertEqual(removal.state.rawValue, word, "the job is the hub's latest")
            XCTAssertNotEqual(removal.presentation, .completed, word)
            XCTAssertNotEqual(removal.presentation, .awaitingEraseConfirmation, word)
            XCTAssertEqual(P.removalActions(for: removal, isActing: false), word == "pending" ? [.cancel] : [], "only a waiting job can be cancelled: \(word)")
        }
        // A job without a result for a long time: the confirmation is offered, the sensors stay.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [earlier, F.removal("sent", resultUnknown: true, age: 0)]))
        assertHeld("result unknown")
        XCTAssertEqual(sheetState().removal?.presentation, .resultUnknown)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
        // No job at all.
        try await deliver(F.snapshot(bases: [], modules: [], removals: []))
        assertHeld("no job")
        XCTAssertNil(sheetState().removal)
        // Another Base was released: that does not explain where this one's sensors went.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", id: RemovalFixtures.otherRemovalID, base: F.otherBase, age: 0)]))
        assertHeld("another Base released")
        // Only the removal that had already completed when the hub listed the Base (it was enrolled
        // again since): not what emptied the list now, however recent its time.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", id: F.earlierRemovalID, age: 0)]))
        assertHeld("an earlier removal of a Base that was enrolled again")

        // The hub is back.
        try await deliver(supportedHub(removals: []))
        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertEqual(model.health, .healthy)
        XCTAssertTrue(model.isPowerBaseStateVerified)
        XCTAssertEqual(sheetState().availability, .available)
    }

    func testAnOnlineSensorWithoutASampleIsStillHeldBackWhileItsBasesJobAndSupportFollowTheHub() async throws {
        try await startApp(first: supportedHub())
        try await pair()
        let lastReadings = try XCTUnwrap(model.module(with: id(F.gasSensor))?.readings)
        let base = F.base(F.base, moduleCount: 2, management: "supported")
        let recovering = [F.module(F.gasSensor, base: F.base, hasReadings: false), F.module(F.dustSensor, base: F.base)]

        try await deliver(F.snapshot(bases: [base], modules: recovering, removals: [F.removal("pending", age: 0)]))
        XCTAssertTrue(model.isRegistryRecovering)
        XCTAssertEqual(model.health, .recoveringRegistry)
        XCTAssertEqual(model.module(with: id(F.gasSensor))?.readings, lastReadings, "the last readings stay")
        XCTAssertEqual(model.snapshot.modules.count, 2)
        var state = sheetState()
        XCTAssertEqual(state.removal?.state, .pending, "a job created while the sensors recover is shown")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.cancel])
        XCTAssertEqual(state.availability, .removalExists)

        // Cancelled on the hub: the Base is as it was and can be asked again.
        try await deliver(F.snapshot(bases: [base], modules: recovering, removals: [F.removal("cancelled", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.presentation, .cancelled)
        XCTAssertEqual(state.availability, .available)
        XCTAssertTrue(model.isRegistryRecovering)

        // Whether the hub offers management at all is the hub's word too.
        try await deliver(F.snapshot(bases: [base], modules: recovering, removals: nil))
        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(sheetState().availability, .hubUnsupported)
        try await deliver(F.snapshot(bases: [base], modules: recovering, removals: []))
        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(sheetState().availability, .available)
        XCTAssertEqual(model.module(with: id(F.gasSensor))?.readings, lastReadings)

        // The sample arrives.
        try await deliver(supportedHub())
        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertEqual(model.health, .healthy)
    }

    func testAnotherHubDuringRecoveryKeepsNothingOfWhatWasHeld() async throws {
        try await startApp(first: supportedHub())
        try await pair()
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("pending", age: 0)]))
        XCTAssertTrue(model.isRegistryRecovering)
        XCTAssertEqual(sheetState().removal?.state, .pending)

        let hubB = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        let legacy = F.snapshot(bases: [F.base(F.base, moduleCount: 1, management: nil)], modules: [F.module(F.otherSensor, base: F.base)], removals: nil)
        let transportB = ControllableSensorAPITransport { legacy }
        model.replace(dataSource: liveSource(transportB), identity: .hub(id: hubB.hubID), address: URL(string: "http://192.168.1.11:8787"))

        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertTrue(model.snapshot.modules.isEmpty, "hub A's held sensors are not hub B's")
        XCTAssertEqual(model.snapshot.powerBaseRemovals, [])
        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement)
        XCTAssertNil(sheetState().removal)
        XCTAssertFalse(model.isPowerBaseStateVerified, "hub B has not answered yet")

        try await waitUntil { !self.model.snapshot.modules.isEmpty }
        XCTAssertEqual(model.snapshot.modules.map(\.id), [id(F.otherSensor)])
        XCTAssertEqual(model.snapshot.powerBaseRemovals, [])
        XCTAssertNil(sheetState().removal)
        XCTAssertFalse(model.isRegistryRecovering)
    }

    func testEditsDuringRecoveryAndAfterTheLastBaseLeftKeepWhatTheHubSaid() async throws {
        try await startApp(first: supportedHub())
        try await pair()
        let lastReadings = try XCTUnwrap(model.module(with: id(F.gasSensor))?.readings)
        try await deliver(F.snapshot(
            bases: [F.base(F.base, moduleCount: 2, management: "supported")],
            modules: [F.module(F.gasSensor, base: F.base, hasReadings: false), F.module(F.dustSensor, base: F.base)],
            removals: [F.removal("accepted", age: 0)]
        ))
        XCTAssertTrue(model.isRegistryRecovering)

        try await model.updateHomeName(input: "작업실 집")
        let study = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await model.updateModule(id: id(F.gasSensor), customName: "서재 공기", roomID: study.id)
        XCTAssertEqual(model.module(with: id(F.gasSensor))?.name, "서재 공기")
        XCTAssertEqual(model.module(with: id(F.gasSensor))?.readings, lastReadings, "the held readings survive the edit")
        XCTAssertTrue(model.isRegistryRecovering)
        assertManagement(removal: .accepted, "after edits while the sensors recover")

        // The Base is released: its sensors, held or not, are gone with it.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", age: 0)]))
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertEqual(sheetState().removal?.state, .released)
        try await model.createRoom(name: "현관", symbolName: "door.left.hand.open")
        try await model.deleteRoom(id: study.id)
        XCTAssertEqual(sheetState().removal?.state, .released)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(model.homeName, "작업실 집")
    }

    func testTheHubsLaterAnswerAboutAJobIsShownBeforeTheNextSnapshot() async throws {
        try await startApp(first: supportedHub(removals: [F.removal("accepted", age: 30)]))
        try await pair()
        XCTAssertEqual(sheetState().removal?.state, .accepted)

        // While the sheet is shown it reads the hub's own list; no new snapshot has arrived.
        removalHub.scriptList(.success([RemovalFixtures.removal(.released, updatedAt: Date().addingTimeInterval(-10))]))
        await removals.refresh()
        XCTAssertNil(removals.refreshProblem)
        var state = sheetState()
        XCTAssertEqual(state.removal?.state, .released, "what the hub said later, not the older snapshot")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertNotEqual(state.removal?.presentation, .completed)

        // And a later snapshot is not undone by that older answer.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", age: 0)]))
        state = sheetState()
        XCTAssertEqual(state.removal?.state, .completed)
    }

    // MARK: - What makes a Base "released": what this app saw the hub do, never a time
    //
    // `1.1.1 (5)` took a `released`/`completed` job as the reason for a Base leaving the list when
    // the job's time was no more than 5 seconds before the snapshot on screen. A removal that had
    // completed just before the Base was enrolled again passed that test, and the Base's sensors
    // were dropped at the next hub restart. Now the reason is the job's own history as this app
    // saw it, from the hub it reads: a job that ended while the Base was not listed, or that was
    // seen completed while the Base was listed, is over and explains nothing later.

    private var enrolled: (bases: [String], modules: [String]) {
        ([F.base(F.base, moduleCount: 2, management: "supported")], [F.module(F.gasSensor, base: F.base), F.module(F.dustSensor, base: F.base)])
    }

    private func assertSensorsKept(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.snapshot.modules.count, 2, "the sensors stay: \(what)", file: file, line: line)
        XCTAssertEqual(model.snapshot.powerBases.map(\.hardwareIdentifier), [F.base], what, file: file, line: line)
        XCTAssertTrue(model.isRegistryRecovering, what, file: file, line: line)
    }

    private func assertBaseGone(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.snapshot.modules.isEmpty, "the sensors left with the Base: \(what)", file: file, line: line)
        XCTAssertTrue(model.snapshot.powerBases.isEmpty, what, file: file, line: line)
        XCTAssertFalse(model.isRegistryRecovering, what, file: file, line: line)
    }

    /// The last Base is released by a hub whose clock is `offset` seconds away from this device's.
    private func releaseTheLastBase(hubClockOffset offset: TimeInterval) async throws {
        let hubNow = Int64((Date().timeIntervalSince1970 + offset) * 1000)
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [], at: hubNow))
        try await pair()
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: hubNow + 1_000)], at: hubNow + 1_500))
        XCTAssertEqual(sheetState().removal?.state, .accepted)
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", at: hubNow + 2_000)], at: hubNow + 2_500))
        assertBaseGone("hub clock \(offset) s from this device's")
        XCTAssertEqual(sheetState().removal?.state, .released)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", at: hubNow + 60_000)], at: hubNow + 60_500))
        XCTAssertEqual(sheetState().removal?.presentation, .completed)
    }

    func testAHubClockThirtySecondsBehindThisDeviceChangesNothing() async throws {
        try await releaseTheLastBase(hubClockOffset: -30)
    }

    func testAHubClockThirtySecondsAheadOfThisDeviceChangesNothing() async throws {
        try await releaseTheLastBase(hubClockOffset: 30)
    }

    func testAReleaseIsTheReasonHoweverLongTheHubKeepsListingTheBase() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()

        // The job is released at 2 s on the hub's clock; the hub still lists the Base 10 and 20
        // seconds later, and takes it out after half a minute.
        let released = F.removal("released", at: F.hubClock(2))
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [released], at: F.hubClock(12)))
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [released], at: F.hubClock(22)))
        XCTAssertEqual(model.snapshot.modules.count, 2)
        XCTAssertEqual(sheetState().removal?.state, .released)

        try await deliver(F.snapshot(bases: [], modules: [], removals: [released], at: F.hubClock(32)))
        assertBaseGone("released 30 s before the Base left the list")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.state), [.released])
    }

    func testAHubClockSetBackDoesNotHideARelease() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()

        // The hub's clock is corrected an hour back (a restart without the time, a time sync);
        // then the Base is released. Every time the hub writes now is "before" the snapshot on screen.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", at: F.hubClock(-3600))], at: F.hubClock(-3599)))
        assertBaseGone("the hub's clock went back an hour")
        XCTAssertEqual(sheetState().removal?.state, .released)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
    }

    func testARemovalThatCompletedJustBeforeTheBaseWasEnrolledAgainNeverExplainsAnEmptyList() async throws {
        // What the hub says when this app first reads it: the Base and its sensors, listed one
        // second ago; a removal of that Base, completed two seconds ago.
        let earlier = F.removal("completed", at: F.hubClock(-2))
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [earlier], at: F.hubClock(-1)))
        try await pair()
        XCTAssertEqual(model.health, .healthy)

        // The hub starts again: for a moment it lists nothing.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [earlier], at: F.hubClock(0)))
        assertSensorsKept("a removal that was over before this enrollment")
        XCTAssertEqual(model.health, .recoveringRegistry)

        // And it is back.
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [earlier], at: F.hubClock(5)))
        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertEqual(model.health, .healthy)
    }

    func testAFinishedRemovalIsNotReusedAfterTheBaseIsEnrolledAgainButANewJobCounts() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()

        // Removed, confirmed...
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", at: F.hubClock(2))], at: F.hubClock(2)))
        assertBaseGone("released")
        let completed = F.removal("completed", at: F.hubClock(3))
        try await deliver(F.snapshot(bases: [], modules: [], removals: [completed], at: F.hubClock(3)))
        XCTAssertEqual(sheetState().removal?.presentation, .completed)

        // ...and enrolled again a second later; the finished job is still in the hub's list.
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [completed], at: F.hubClock(4)))
        XCTAssertEqual(model.snapshot.modules.count, 2)
        XCTAssertEqual(model.health, .healthy)

        // A hub restart: the finished job is not this enrollment's removal.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [completed], at: F.hubClock(5)))
        assertSensorsKept("the earlier, finished removal")
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [completed], at: F.hubClock(6)))
        XCTAssertEqual(model.health, .healthy)

        // A new removal of the Base -- another job -- is: also while the old one is still listed.
        let second = RemovalFixtures.otherRemovalID
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [completed, F.removal("accepted", id: second, at: F.hubClock(7))], at: F.hubClock(7)))
        XCTAssertEqual(sheetState().removal?.id, second, "the open job, not the finished one")
        try await deliver(F.snapshot(bases: [], modules: [], removals: [completed, F.removal("released", id: second, at: F.hubClock(8))], at: F.hubClock(8)))
        assertBaseGone("the new job was released")
        XCTAssertEqual(sheetState().removal?.id, second)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
    }

    func testARemovalAndANewEnrollmentThisAppDidNotSeeAreNotTakenForARemovalLater() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()

        // The app was not looking while the Base was removed and enrolled again: the next thing
        // it reads is the Base listed, with the job completed.
        let completed = F.removal("completed", at: F.hubClock(60))
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [completed], at: F.hubClock(62)))
        XCTAssertEqual(model.health, .healthy)

        try await deliver(F.snapshot(bases: [], modules: [], removals: [completed], at: F.hubClock(63)))
        assertSensorsKept("a job seen completed while its Base was listed is over")
    }

    func testAJobFirstSeenReleasedWithItsBaseStillListedIsNotEnoughToDropTheSensors() async throws {
        // Not enough to go on: the app never saw this job before it was released, so it cannot
        // tell a release under way from one that ended before the Base was enrolled again (the hub
        // keeps such a job `released` until the new enrollment is active). The sensors stay; the
        // job and its confirmation are shown all the same.
        let released = F.removal("released", at: F.hubClock(0))
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [released], at: F.hubClock(1)))
        try await pair()

        try await deliver(F.snapshot(bases: [], modules: [], removals: [released], at: F.hubClock(2)))
        assertSensorsKept("no removal is assumed")
        let state = sheetState()
        XCTAssertEqual(state.removal?.state, .released, "the job is the hub's latest all the same")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertNotEqual(state.removal?.presentation, .completed)
    }

    func testAJobThisAppCannotReadOrAHubWithoutJobsIsNoEvidence() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()

        // A state from a newer hub: the job is left out, never read as something it is not.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("erased", at: F.hubClock(2))], at: F.hubClock(3)))
        assertSensorsKept("a state this app does not know")
        XCTAssertNil(sheetState().removal)
        // A malformed job id.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", id: "not-an-id", at: F.hubClock(4))], at: F.hubClock(5)))
        assertSensorsKept("a job without a readable id")
        // No job list at all (a hub without Power Base management).
        try await deliver(F.snapshot(bases: [], modules: [], removals: nil, at: F.hubClock(6)))
        assertSensorsKept("no job list")
        XCTAssertFalse(model.snapshot.reportsPowerBaseManagement)

        // The job as this app reads it: released.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", at: F.hubClock(7))], at: F.hubClock(8)))
        assertBaseGone("released")
    }

    func testWhatWasSeenOnOneHubIsNoEvidenceOnAnother() async throws {
        // Hub A: the Base listed, with a removal that is over.
        let job = RemovalFixtures.removalID
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("completed", id: job, at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()

        // Hub B happens to use the same Base and the same job id. There the job is under way.
        let hubB = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        let onB = F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", id: job, at: F.hubClock(100))], at: F.hubClock(101))
        let transportB = ControllableSensorAPITransport { onB }
        model.replace(dataSource: liveSource(transportB), identity: .hub(id: hubB.hubID), address: URL(string: "http://192.168.1.11:8787"))
        try await waitUntil { self.model.snapshot.modules.count == 2 }
        try await waitUntil { await transportB.hasOpenEventStream }

        // Released on hub B: what hub A's list said about that id does not stand in the way.
        let before = model.lastSyncAt
        let released = F.snapshot(bases: [], modules: [], removals: [F.removal("released", id: job, at: F.hubClock(102))], at: F.hubClock(103))
        await transportB.setSnapshotProvider { released }
        await transportB.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: released))
        try await waitUntil { self.model.lastSyncAt != before }
        assertBaseGone("released on hub B")

        // Back on hub A, whose list is as it was: the Base listed, the job completed. A restart
        // of hub A is not a removal -- hub B's release of that id is not hub A's.
        let onA = F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("completed", id: job, at: F.hubClock(0))], at: F.hubClock(200))
        let transportA = ControllableSensorAPITransport { onA }
        model.replace(dataSource: liveSource(transportA), identity: .hub(id: settingsHub.hubID), address: F.hubURL)
        try await waitUntil { self.model.snapshot.modules.count == 2 }
        try await waitUntil { await transportA.hasOpenEventStream }
        let again = model.lastSyncAt
        let restarting = F.snapshot(bases: [], modules: [], removals: [F.removal("completed", id: job, at: F.hubClock(0))], at: F.hubClock(201))
        await transportA.setSnapshotProvider { restarting }
        await transportA.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: restarting))
        try await waitUntil { self.model.lastSyncAt != again }
        assertSensorsKept("hub A's own finished job")
    }

    // MARK: - Which word about a job is shown: the further along, never the later-dated

    func testAnAnswerFurtherAlongIsShownWhateverItsTimeSays() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()
        _ = sheetState()

        // The hub's clock went back an hour before it released the job; the list read by the sheet
        // carries that earlier-looking time.
        removalHub.scriptList(.success([RemovalFixtures.removal(.released, updatedAt: Date(timeIntervalSince1970: Double(F.hubClock(-3600)) / 1000))]))
        await removals.refresh()
        let state = sheetState()
        XCTAssertEqual(state.removal?.state, .released, "the same job, further along")
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
    }

    func testAnOlderAnswerNeverHidesWhatTheSnapshotSaysEvenWithALaterTime() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()
        _ = sheetState()
        // An answer read while the job was accepted, stamped by a hub clock that ran an hour ahead.
        removalHub.scriptList(.success([RemovalFixtures.removal(.accepted, updatedAt: Date(timeIntervalSince1970: Double(F.hubClock(3600)) / 1000))]))
        await removals.refresh()
        XCTAssertEqual(sheetState().removal?.state, .accepted)

        // The hub's snapshots move on; the old answer stays in memory.
        try await deliver(F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", resultUnknown: true, at: F.hubClock(0))], at: F.hubClock(400)))
        XCTAssertEqual(sheetState().removal?.presentation, .resultUnknown, "the same state, now without a result")
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("released", at: F.hubClock(401))], at: F.hubClock(402)))
        XCTAssertEqual(sheetState().removal?.state, .released)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(sheetState().removal), isActing: false), [.confirmErase])
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed", at: F.hubClock(403))], at: F.hubClock(404)))
        XCTAssertEqual(sheetState().removal?.presentation, .completed)
    }

    func testAnAnswerAboutAnotherJobNeverReplacesTheSnapshotsJob() async throws {
        try await startApp(first: F.snapshot(bases: enrolled.bases, modules: enrolled.modules, removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(1)))
        try await pair()
        _ = sheetState()
        let late = Date(timeIntervalSince1970: Double(F.hubClock(7200)) / 1000)

        // An answer about some other job of the Base, however late its time: not the Base's job.
        for state in [PowerBaseRemoval.State.cancelled, .pending, .completed] {
            removalHub.scriptList(.success([RemovalFixtures.removal(state, id: RemovalFixtures.otherRemovalID, updatedAt: late)]))
            await removals.refresh()
            XCTAssertEqual(sheetState().removal?.id, RemovalFixtures.removalID, "\(state)")
            XCTAssertEqual(sheetState().removal?.state, .accepted, "\(state)")
        }
        // It is not evidence of anything for the sensors either.
        try await deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("accepted", at: F.hubClock(0))], at: F.hubClock(2)))
        assertSensorsKept("an answer to this device is not the hub's snapshot")

        // Once the snapshot has that job, it is shown.
        try await deliver(F.snapshot(
            bases: enrolled.bases, modules: enrolled.modules,
            removals: [F.removal("cancelled", at: F.hubClock(10)), F.removal("pending", id: RemovalFixtures.otherRemovalID, at: F.hubClock(11))], at: F.hubClock(12)
        ))
        XCTAssertEqual(sheetState().removal?.id, RemovalFixtures.otherRemovalID)
        XCTAssertEqual(sheetState().removal?.state, .completed, "the same job now: what the hub answered is further along")
    }

    // MARK: - A Base without sensors: what the hub hears is not what the sensors measured

    func testABaseWithoutSensorsIsShownAsTheHubHearsItWhileTheHomeStillWaitsForSensors() async throws {
        typealias T = PowerBaseManagementText
        try await startApp(first: F.snapshot(bases: [F.base(F.base, moduleCount: 0, management: "supported")], modules: [], removals: []))
        try await pair()

        // The home: nothing measured yet, and not called healthy.
        XCTAssertEqual(model.health, .waitingForData)
        XCTAssertEqual(model.dataWait, .noModulesYet)
        XCTAssertFalse(model.health.isCurrentStateVerified)
        // The Base: the hub is connected and says it hears it.
        XCTAssertTrue(model.isPowerBaseStateVerified)
        var state = sheetState()
        XCTAssertEqual(state.base?.isOnline, true)
        XCTAssertEqual(T.connection(of: state.base, isCurrentStateVerified: state.isCurrentStateVerified), T.connection(of: state.base, isCurrentStateVerified: true))
        XCTAssertNotEqual(T.connection(of: state.base, isCurrentStateVerified: state.isCurrentStateVerified), T.connection(of: state.base, isCurrentStateVerified: false),
                          "not '상태 확인 중' for as long as no sensor is docked")

        // The hub stops hearing it: said as a fact, too.
        try await deliver(F.snapshot(bases: [F.base(F.base, online: false, moduleCount: 0, management: "supported")], modules: [], removals: []))
        state = sheetState()
        XCTAssertEqual(state.base?.isOnline, false)
        XCTAssertTrue(state.isCurrentStateVerified)

        // A sensor is docked and listed before its first sample: the Base is known, the sensor is not.
        try await deliver(F.snapshot(
            bases: [F.base(F.base, moduleCount: 1, management: "supported")], modules: [F.module(F.gasSensor, base: F.base, hasReadings: false)], removals: []
        ))
        XCTAssertEqual(model.snapshot.modules.count, 1)
        XCTAssertEqual(model.health, .waitingForData)
        XCTAssertFalse(model.health.isCurrentStateVerified, "the sensor's own state is not stated yet")
        XCTAssertTrue(model.isPowerBaseStateVerified)

        // Without a live connection nothing is stated as current.
        model.stop()
        XCTAssertFalse(model.isPowerBaseStateVerified)
        XCTAssertFalse(sheetState().isCurrentStateVerified)
    }

    // MARK: -

    private func assertManagement(removal: PowerBaseRemoval.State?, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.snapshot.reportsPowerBaseManagement, "the hub's management is gone \(when)", file: file, line: line)
        XCTAssertEqual(model.snapshot.powerBases.first { $0.hardwareIdentifier == F.base }?.management, .supported, when, file: file, line: line)
        XCTAssertEqual(model.snapshot.powerBaseRemovals, model.sensorSnapshot.powerBaseRemovals, when, file: file, line: line)
        XCTAssertEqual(sheetState().removal?.state, removal, when, file: file, line: line)
        XCTAssertNotEqual(sheetState().availability, .hubUnsupported, when, file: file, line: line)
    }
}

/// A hub's `/api/v1/snapshot` JSON with the Power Base management revision's additive fields.
private enum ManagementHubFixtures {
    static let hubURL = RemovalFixtures.url
    /// Made-up EUI-64s.
    static let base = RemovalFixtures.base
    static let otherBase = RemovalFixtures.otherBase
    static let gasSensor = "744dbdfffe65d357"
    static let dustSensor = "744dbdfffe65d07a"
    static let otherSensor = "0011223344556677"
    /// A removal of `base` that ended before the hub listed it again (it was enrolled again).
    static let earlierRemovalID = "7f0c1d2e3f405162738495a6b7c8d9e2"
    /// A hub's own clock (Unix ms), set by the test: years away from this device's clock, since
    /// nothing may depend on the two agreeing. `seconds` after an arbitrary start.
    static func hubClock(_ seconds: Double) -> Int64 { 1_600_000_000_000 + Int64(seconds * 1000) }

    nonisolated(unsafe) private static var sequence: Int64 = 0

    /// `eraseConfirmation`: what a hub that knows the field says of a Base it can remove.
    static func base(_ uuid: String, online: Bool = true, moduleCount: Int, management: String?, eraseConfirmation: String? = nil) -> String {
        // A Base the hub can remove says which registration it lists and how many removals were
        // asked of it (Linux bridge 0.5.0): what a removal request names.
        let binding = management == "supported" ? ",\"record\":\"\(RemovalFixtures.record)\",\"removal_serial\":0" : ""
        let field = (management.map { ",\"management\":\"\($0)\"" } ?? "") + (eraseConfirmation.map { ",\"erase_confirmation\":\"\($0)\"" } ?? "") + binding
        return """
        {"uuid":"\(uuid)","online":\(online),"module_count":\(moduleCount),"online_module_count":\(online ? moduleCount : 0)\(field)}
        """
    }

    /// `hasReadings: false`: listed again by the hub, its first sample not in yet.
    static func module(_ uuid: String, base: String, online: Bool = true, hasReadings: Bool = true) -> String {
        let readings = hasReadings ? #"{"kind":"temperature","raw_value":23400,"scale":1,"value":23.4,"unit":"celsius","status":"ok","sample_seq":1}"# : ""
        return """
        {"uuid":"\(uuid)","power_base_uuid":"\(base)","parent_uuid":"\(base)","online":\(online),"depth":1,"role":"leaf","sensor_bitmap":6,"generation":1,"last_seq":1,"readings":[\(readings)]}
        """
    }

    /// A job that changed just now (a completed one stays in the device list for an hour), or
    /// `age` seconds ago -- or at `hubTime` on the hub's own clock.
    static func removal(_ state: String, id: String = RemovalFixtures.removalID, base: String = base, resultUnknown: Bool = false, age: TimeInterval = 1, at hubTime: Int64? = nil, eraseConfirmation: String? = nil) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let updatedAt = hubTime ?? now - Int64(age * 1000)
        let confirmation = eraseConfirmation.map { ",\"erase_confirmation\":\"\($0)\"" } ?? ""
        return """
        {"removal_id":"\(id)","power_base_uuid":"\(base)","generation":"\(String(repeating: "7e", count: 16))","state":"\(state)","result_unknown":\(resultUnknown),"cancellable":\(state == "pending"),"created_at_unix_ms":\(updatedAt - 60_000),"updated_at_unix_ms":\(updatedAt),"affected_module_count":2\(confirmation)}
        """
    }

    /// `removals == nil`: a hub without Power Base management (the field is absent). `settings`: a
    /// hub with settings sharing, at that hub's current revision. Every call is a later snapshot,
    /// generated now -- or at `hubTime` on the hub's own clock.
    static func snapshot(bases: [String], modules: [String], removals: [String]?, settings: FakeSettingsHub? = nil, at hubTime: Int64? = nil) -> Data {
        sequence += 1
        let generatedAt = hubTime ?? Int64(Date().timeIntervalSince1970 * 1000) + sequence
        let removalsField = removals.map { ",\"power_base_removals\":[\($0.joined(separator: ","))]" } ?? ""
        let settingsField = settings.map { hub in
            hub.revision.map { ",\"settings_api\":1,\"settings_state\":\"ready\",\"settings_revision\":\"\($0)\"" }
                ?? ",\"settings_api\":1,\"settings_state\":\"uninitialized\",\"settings_revision\":null"
        } ?? ""
        return Data("""
        {"schema_version":1,"generated_at_unix_ms":\(generatedAt),"registry_generation":\(sequence),"power_bases":[\(bases.joined(separator: ","))],"modules":[\(modules.joined(separator: ","))]\(removalsField)\(settingsField)}
        """.utf8)
    }
}
