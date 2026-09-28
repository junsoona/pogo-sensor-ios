import XCTest
@testable import PogoHome

/// Settings sharing through the hub, end to end across simulated devices: migration of the first
/// device's settings, a second device showing the same, every kind of edit, conflicts, offline and
/// revoked devices, separation from other hubs and simulated data, and module identity.
@MainActor
final class SharedSettingsTests: XCTestCase {
    private typealias F = SharedSettingsFixtures

    /// Pairs `device` and turns sharing on: uploads its own settings to an empty hub, or uses the hub's.
    private func turnOnSharing(_ device: SimulatedDevice, hub: FakeSettingsHub) async throws {
        _ = hub.createCode()
        let state = try await device.controller.pair(code: "7KQM-3XWD-PA9T", deviceName: "Test")
        if state.initialized {
            try device.controller.useHubSettings(state)
        } else {
            let summary = device.model.sharedSettingsUploadSummary()
            _ = try await device.controller.uploadAsFirstSettings(summary.document)
        }
    }

    /// Starts `device`'s live connection and waits for the check it makes on starting, so a later
    /// held fetch is the one a snapshot triggers.
    private func startAndWaitForFirstCheck(_ device: SimulatedDevice) async {
        let confirmed = device.controller.lastConfirmedAt
        device.model.start()
        await waitUntil("the first check is done") { device.controller.lastConfirmedAt != confirmed }
    }

    private func roomNames(_ model: AppModel) -> [String] {
        model.snapshot.sortedRooms.filter { $0.id != ModuleCatalog.unspecifiedRoomID }.map(\.name)
    }

    // MARK: - Migration and a second device

    func testFirstDeviceUploadsItsSettingsAndASecondDeviceShowsTheSame() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await phone.model.updateHomeName(input: "바닷가 집")
        let terrace = try await phone.model.createRoom(name: "테라스", symbolName: "tree.fill")
        try await phone.model.updateModule(id: F.moduleID(F.gasSensor), customName: "공기", roomID: terrace.id)

        // Nothing reaches the hub by itself.
        XCTAssertEqual(hub.putCount, 0)
        _ = hub.createCode()
        let state = try await phone.controller.pair(code: "7kqm 3xwd pa9t", deviceName: "iPhone")
        XCTAssertFalse(state.initialized)
        XCTAssertEqual(hub.putCount, 0, "pairing alone never uploads")
        XCTAssertFalse(phone.model.usesSharedSettings)

        let summary = phone.model.sharedSettingsUploadSummary()
        XCTAssertEqual(summary.homeName, "바닷가 집")
        XCTAssertTrue(summary.rooms.map(\.name).contains("테라스"))
        XCTAssertEqual(summary.modules.map(\.name), ["공기"])
        let uploaded = try await phone.controller.uploadAsFirstSettings(summary.document)
        XCTAssertEqual(uploaded, .uploaded)
        XCTAssertEqual(phone.controller.status, .shared)
        XCTAssertEqual(hub.currentDocument?.modules.first?.uuid, F.gasSensor, "keyed by the real module UUID")

        // A second device with its own, different default settings downloads — it never uploads.
        let pad = SimulatedDevice(hub: hub, localStore: InMemoryHomeConfigurationStore(rooms: [ModuleCatalog.unspecifiedRoom(in: .korean)], language: .korean))
        _ = hub.createCode()
        let hubState = try await pad.controller.pair(code: "7KQM3XWDPA9T", deviceName: "iPad")
        XCTAssertTrue(hubState.initialized)
        try pad.controller.useHubSettings(hubState)
        XCTAssertEqual(hub.putCount, 1, "the second device did not upload anything")
        XCTAssertEqual(pad.model.homeName, "바닷가 집")
        XCTAssertEqual(roomNames(pad.model), roomNames(phone.model))
        let padModule = try XCTUnwrap(pad.model.module(with: F.moduleID(F.gasSensor)))
        XCTAssertEqual(padModule.name, "공기")
        XCTAssertEqual(padModule.roomID, terrace.id)
    }

    func testTheDevicesOwnSettingsAreKeptAndComeBackWhenSharingStops() async throws {
        let hub = FakeSettingsHub()
        let first = SimulatedDevice(hub: hub)
        try await first.model.updateHomeName(input: "허브 집")
        try await turnOnSharing(first, hub: hub)

        let localStore = InMemoryHomeConfigurationStore(language: .korean)
        try localStore.updateHomeName("내 아이패드 집")
        let second = SimulatedDevice(hub: hub, localStore: localStore)
        try await turnOnSharing(second, hub: hub)
        XCTAssertEqual(second.model.homeName, "허브 집")

        try await second.model.updateHomeName(input: "공유 이름")
        XCTAssertEqual(try localStore.load().customHomeName, "내 아이패드 집", "sharing never writes the device's own store")

        await second.controller.stopSharing()
        XCTAssertEqual(second.controller.status, .localOnly)
        XCTAssertEqual(second.model.homeName, "내 아이패드 집", "the backup comes back")
        XCTAssertNil(try second.credentials.credential(forHubID: hub.hubID), "the token is removed from the Keychain")
        XCTAssertNotNil(hub.currentDocument, "the hub's settings stay for the other devices")
    }

    func testUploadLeavesOutModulesThatAreNotOnThisHub() throws {
        let hub = FakeSettingsHub()
        let store = InMemoryHomeConfigurationStore(language: .korean)
        let device = SimulatedDevice(hub: hub, localStore: store)
        let room = try store.createRoom(name: "창고", symbolName: "shippingbox.fill")
        // A module from another hub (or simulated data) configured on this device earlier.
        try store.updateModule(id: F.moduleID(F.otherHubSensor), customName: "다른 허브 센서", roomID: room.id)
        let summary = SharedSettingsSummary.upload(local: try store.load(), snapshot: device.model.sensorSnapshot, language: .korean)
        XCTAssertEqual(summary.leftOutModuleCount, 1)
        XCTAssertFalse(summary.document.modules.contains { $0.uuid == F.otherHubSensor })
    }

    // MARK: - Edits

    func testEditsAreSavedOnTheHubAndReachTheOtherDevice() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let mac = SimulatedDevice(hub: hub)
        try await turnOnSharing(mac, hub: hub)
        mac.model.start()

        let office = try await phone.model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await phone.model.updateRoom(id: office.id, name: "작업방", symbolName: "desktopcomputer")
        let order = [office.id] + phone.model.editableRooms.map(\.id).filter { $0 != office.id && $0 != ModuleCatalog.unspecifiedRoomID }
        try await phone.model.reorderRooms(orderedIDs: order)
        try await phone.model.updateModule(id: F.moduleID(F.dustSensor), customName: "먼지", roomID: office.id)

        // The Mac notices the new revision from the snapshot it already receives.
        mac.receiveSnapshot(from: hub)
        await waitUntil("the Mac shows the phone's last change") { mac.controller.entry?.revision == hub.revision }
        XCTAssertEqual(roomNames(mac.model), roomNames(phone.model), "same rooms in the same order")
        let room = try XCTUnwrap(mac.model.room(with: office.id))
        XCTAssertEqual(room.symbolName, "desktopcomputer")
        XCTAssertEqual(mac.model.module(with: F.moduleID(F.dustSensor))?.name, "먼지")
        XCTAssertEqual(mac.model.module(with: F.moduleID(F.dustSensor))?.roomID, office.id)
        XCTAssertEqual(mac.controller.status, .shared)
    }

    func testDeletingARoomMovesItsModulesToUnspecifiedInOneChange() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let garage = try await phone.model.createRoom(name: "차고", symbolName: "car.fill")
        try await phone.model.updateModule(id: F.moduleID(F.gasSensor), customName: "가스", roomID: garage.id)
        let putsBefore = hub.putCount

        try await phone.model.deleteRoom(id: garage.id)
        XCTAssertEqual(hub.putCount, putsBefore + 1, "one atomic change")
        XCTAssertFalse(hub.currentDocument!.rooms.contains { $0.id == garage.id })
        let module = try XCTUnwrap(hub.currentDocument?.modules.first { $0.uuid == F.gasSensor })
        XCTAssertNil(module.roomID, "the module is in 미지정 공간 now")
        XCTAssertEqual(module.name, "가스", "and keeps its name")
        XCTAssertEqual(phone.model.module(with: F.moduleID(F.gasSensor))?.roomID, ModuleCatalog.unspecifiedRoomID)
    }

    func testValidationErrorsAreTheSameAsForTheDevicesOwnSettings() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        _ = try await phone.model.createRoom(name: "Studio", symbolName: "paintpalette.fill")
        let puts = hub.putCount
        await XCTAssertThrowsErrorAsync(try await phone.model.createRoom(name: "studio", symbolName: "sofa.fill")) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .duplicateRoomName)
        }
        await XCTAssertThrowsErrorAsync(try await phone.model.updateHomeName(input: String(repeating: "가", count: 31)))
        XCTAssertEqual(hub.putCount, puts, "a rejected edit never reaches the hub")
    }

    // MARK: - Conflicts

    func testConcurrentEditsConflictAndTheLaterOneIsNotLost() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let pad = SimulatedDevice(hub: hub)
        try await turnOnSharing(pad, hub: hub)
        let bedroom = HomeConfigurationDefaults.bedroomID

        // Both edit from the same revision; the iPad saves first and deletes the bedroom.
        try await pad.model.deleteRoom(id: bedroom)
        await XCTAssertThrowsErrorAsync(try await phone.model.updateRoom(id: bedroom, name: "안방", symbolName: "bed.double.fill")) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        XCTAssertFalse(hub.currentDocument!.rooms.contains { $0.id == bedroom }, "the older edit did not undelete the room")
        XCTAssertEqual(phone.controller.status, .conflict)
        XCTAssertNil(phone.model.room(with: bedroom), "the phone now shows the latest settings")
        XCTAssertTrue(phone.model.canEditConfiguration, "and the user can edit again")

        try await phone.model.updateHomeName(input: "다시 수정")
        XCTAssertEqual(phone.controller.status, .shared)
        XCTAssertEqual(hub.currentDocument?.homeName, "다시 수정")
    }

    /// Regression: an editor opened before another device's change, which then arrives by itself
    /// (SSE → automatic check), used to save its stale values on top of the newly received
    /// revision — a PUT the hub accepted, silently undoing the other device's change.
    func testAnEditorOpenedBeforeAnotherDevicesChangeArrivesAutomaticallySavesNothing() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let pad = SimulatedDevice(hub: hub)
        try await turnOnSharing(pad, hub: hub)
        phone.model.start()
        let bedroom = HomeConfigurationDefaults.bedroomID
        let gas = F.moduleID(F.gasSensor)

        // The phone opens the home, room and device editors.
        let openedWith = phone.model.configurationEditBase
        XCTAssertEqual(openedWith, .revision(hub.revision))

        // Meanwhile the iPad renames all three, and the phone receives that by itself.
        try await pad.model.updateHomeName(input: "패드 집")
        try await pad.model.updateRoom(id: bedroom, name: "패드 침실", symbolName: "bed.double.fill")
        try await pad.model.updateModule(id: gas, customName: "패드 가스", roomID: bedroom)
        phone.receiveSnapshot(from: hub)
        await waitUntil("the phone shows the iPad's change") { phone.controller.entry?.revision == hub.revision }
        XCTAssertEqual(phone.model.homeName, "패드 집")
        let puts = hub.putCount

        // Saving the editors' older values sends nothing.
        await XCTAssertThrowsErrorAsync(try await phone.model.updateHomeName(input: "폰 집", basedOn: openedWith)) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        await XCTAssertThrowsErrorAsync(try await phone.model.updateRoom(id: bedroom, nameSource: .custom("폰 침실"), symbolName: "bed.double.fill", basedOn: openedWith)) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        await XCTAssertThrowsErrorAsync(try await phone.model.updateModule(id: gas, customName: "폰 가스", roomID: bedroom, basedOn: openedWith)) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        XCTAssertEqual(hub.putCount, puts, "no stale edit reached the hub")
        XCTAssertEqual(hub.currentDocument?.homeName, "패드 집")
        XCTAssertEqual(phone.controller.status, .conflict)
        XCTAssertEqual(phone.model.homeName, "패드 집", "the latest settings are on screen")
        XCTAssertEqual(phone.model.room(with: bedroom)?.name, "패드 침실")
        XCTAssertEqual(phone.model.module(with: gas)?.name, "패드 가스")
        XCTAssertTrue(phone.model.canEditConfiguration)

        // An editor showing the latest values again saves normally.
        try await phone.model.updateHomeName(input: "폰 집", basedOn: phone.model.configurationEditBase)
        XCTAssertEqual(hub.currentDocument?.homeName, "폰 집")
        XCTAssertEqual(hub.currentDocument?.rooms.first { $0.id == bedroom }?.name, "패드 침실", "the iPad's other changes stay")
        XCTAssertEqual(phone.controller.status, .shared)
    }

    /// The same when the automatic check is still under way at the moment of saving: the save waits
    /// for it, sees the newer revision and sends nothing — here with a room order made from the
    /// older list.
    func testAReorderFromAnOlderListIsNotSavedAfterAPendingAutomaticCheck() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let pad = SimulatedDevice(hub: hub)
        try await turnOnSharing(pad, hub: hub)
        await startAndWaitForFirstCheck(phone)

        // The phone's "방 편집" list, and the order the user is about to drag it into.
        let listBase = phone.model.configurationEditBase
        let listed = phone.model.editableRooms.map(\.id).filter { $0 != ModuleCatalog.unspecifiedRoomID }
        XCTAssertGreaterThanOrEqual(listed.count, 3)
        let phoneOrder = Array(listed.dropFirst()) + [listed[0]]

        // The iPad reorders first; the phone's check for it is still waiting for the hub.
        let padOrder = Array(listed.reversed())
        try await pad.model.reorderRooms(orderedIDs: padOrder)
        let puts = hub.putCount
        hub.holdFetches()
        phone.receiveSnapshot(from: hub)
        await waitUntil("the phone's check is under way") { hub.heldFetchCount == 1 }

        let save = Task { try await phone.model.reorderRooms(orderedIDs: phoneOrder, basedOn: listBase) }
        await waitUntil("the save waits for the check") { phone.controller.isSaving }
        hub.releaseFetches()
        await XCTAssertThrowsErrorAsync(try await save.value) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        XCTAssertEqual(hub.putCount, puts, "the older order never reached the hub")
        XCTAssertEqual(hub.currentDocument?.rooms.map(\.id), padOrder)
        XCTAssertEqual(phone.model.editableRooms.map(\.id).filter { $0 != ModuleCatalog.unspecifiedRoomID }, padOrder, "the phone shows the iPad's order")

        // Reordering the list as it is now works.
        try await phone.model.reorderRooms(orderedIDs: phoneOrder, basedOn: phone.model.configurationEditBase)
        XCTAssertEqual(hub.currentDocument?.rooms.map(\.id), phoneOrder)
    }

    /// Regression: a delete confirmation opened before another device moved a sensor into the room
    /// deleted it anyway — the sensor the user never saw there went to "미지정 공간".
    func testAStaleRoomDeleteConfirmationAfterASensorMovedInDeletesNothing() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let pad = SimulatedDevice(hub: hub)
        try await turnOnSharing(pad, hub: hub)
        phone.model.start()
        let workspace = HomeConfigurationDefaults.workspace.id
        let gas = F.moduleID(F.gasSensor)
        XCTAssertNotEqual(phone.model.module(with: gas)?.roomID, workspace)

        // The phone asks "방을 삭제할까요?" for a room without that sensor…
        let pending = PendingRoomDeletion(room: try XCTUnwrap(phone.model.room(with: workspace)), base: phone.model.configurationEditBase)
        XCTAssertTrue(pending.isCurrent(in: phone.model))

        // …the iPad moves the sensor into it, and the phone receives that by itself.
        try await pad.model.updateModule(id: gas, customName: nil, roomID: workspace)
        phone.receiveSnapshot(from: hub)
        await waitUntil("the phone shows the moved sensor") { phone.controller.entry?.revision == hub.revision }
        XCTAssertFalse(pending.isCurrent(in: phone.model), "the open confirmation is closed")
        let puts = hub.putCount

        // Confirming the old dialog anyway sends nothing.
        await XCTAssertThrowsErrorAsync(try await phone.model.deleteRoom(id: workspace, basedOn: pending.base)) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        XCTAssertEqual(hub.putCount, puts, "the stale delete never reached the hub")
        XCTAssertTrue(hub.currentDocument!.rooms.contains { $0.id == workspace }, "the room is still there")
        XCTAssertEqual(hub.currentDocument?.modules.first { $0.uuid == F.gasSensor }?.roomID, workspace, "with the iPad's sensor in it")
        XCTAssertEqual(phone.model.module(with: gas)?.roomID, workspace)
        XCTAssertEqual(phone.controller.status, .conflict)

        // Confirmed again against the latest list, the delete goes through.
        let again = PendingRoomDeletion(room: try XCTUnwrap(phone.model.room(with: workspace)), base: phone.model.configurationEditBase)
        try await phone.model.deleteRoom(id: workspace, basedOn: again.base)
        XCTAssertFalse(hub.currentDocument!.rooms.contains { $0.id == workspace })
        XCTAssertEqual(phone.model.module(with: gas)?.roomID, ModuleCatalog.unspecifiedRoomID)
    }

    /// The same when the phone's automatic check for the sensor's move is still under way when the
    /// user confirms: the delete waits for it, then sends nothing.
    func testARoomDeleteConfirmedDuringAPendingAutomaticCheckDeletesNothing() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let pad = SimulatedDevice(hub: hub)
        try await turnOnSharing(pad, hub: hub)
        await startAndWaitForFirstCheck(phone)
        let workspace = HomeConfigurationDefaults.workspace.id
        let gas = F.moduleID(F.gasSensor)
        let pending = PendingRoomDeletion(room: try XCTUnwrap(phone.model.room(with: workspace)), base: phone.model.configurationEditBase)

        try await pad.model.updateModule(id: gas, customName: nil, roomID: workspace)
        let puts = hub.putCount
        hub.holdFetches()
        phone.receiveSnapshot(from: hub)
        await waitUntil("the phone's check is under way") { hub.heldFetchCount == 1 }
        XCTAssertTrue(pending.isCurrent(in: phone.model), "nothing new is on screen yet")

        let delete = Task { try await phone.model.deleteRoom(id: workspace, basedOn: pending.base) }
        await waitUntil("the delete waits for the check") { phone.controller.isSaving }
        hub.releaseFetches()
        await XCTAssertThrowsErrorAsync(try await delete.value) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .conflict)
        }
        XCTAssertEqual(hub.putCount, puts, "the stale delete never reached the hub")
        XCTAssertEqual(hub.currentDocument?.modules.first { $0.uuid == F.gasSensor }?.roomID, workspace)
        XCTAssertEqual(phone.model.module(with: gas)?.roomID, workspace, "the phone shows the sensor in the room")
    }

    func testDeviceOnlySettingsIgnoreTheEditBase() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        let base = phone.model.configurationEditBase
        XCTAssertEqual(base, .revision(nil))
        try await phone.model.updateHomeName(input: "내 집", basedOn: base)
        try await phone.model.updateHomeName(input: "내 집 2", basedOn: base)
        XCTAssertEqual(try phone.localStore.load().customHomeName, "내 집 2")
        XCTAssertEqual(hub.putCount, 0)
    }

    func testTwoDevicesUploadingFirstNeverOverwriteEachOther() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await phone.model.updateHomeName(input: "폰 집")
        let pad = SimulatedDevice(hub: hub)
        try await pad.model.updateHomeName(input: "패드 집")
        _ = hub.createCode()
        _ = try await phone.controller.pair(code: "7KQM3XWDPA9T", deviceName: "iPhone")
        _ = hub.createCode()
        _ = try await pad.controller.pair(code: "7KQM3XWDPA9T", deviceName: "iPad")
        // Both saw an empty hub and review their own settings.
        let phoneSummary = phone.model.sharedSettingsUploadSummary()
        let padSummary = pad.model.sharedSettingsUploadSummary()

        let padOutcome = try await pad.controller.uploadAsFirstSettings(padSummary.document)
        let phoneOutcome = try await phone.controller.uploadAsFirstSettings(phoneSummary.document)
        XCTAssertEqual(padOutcome, .uploaded)
        XCTAssertEqual(phoneOutcome, .hubAlreadyHadSettings)
        XCTAssertEqual(hub.currentDocument?.homeName, "패드 집")
        XCTAssertEqual(phone.model.homeName, "패드 집", "the late device uses the hub's settings")
        XCTAssertEqual(try phone.localStore.load().customHomeName, "폰 집", "and keeps its own as the backup")
    }

    // MARK: - Offline, failures, access

    func testHubOfflineKeepsTheLastSettingsAndDisablesEditingWithAReason() async throws {
        let hub = FakeSettingsHub()
        let credentials = InMemoryHubCredentialStore()
        let cache = InMemorySharedSettingsCache()
        let phone = SimulatedDevice(hub: hub, credentials: credentials, cache: cache)
        try await turnOnSharing(phone, hub: hub)
        try await phone.model.updateHomeName(input: "캐시된 집")

        // Relaunch while the hub is off.
        hub.isReachable = false
        let relaunched = SimulatedDevice(hub: hub, credentials: credentials, cache: cache)
        XCTAssertEqual(relaunched.model.homeName, "캐시된 집", "the last confirmed settings are shown")
        await waitUntil("the check fails") { relaunched.controller.status == .failed(.hubUnreachable) }
        XCTAssertFalse(relaunched.model.canEditConfiguration)
        XCTAssertNotNil(relaunched.model.configurationEditBlockedReason)
        await XCTAssertThrowsErrorAsync(try await relaunched.model.updateHomeName(input: "오프라인 수정"))
        XCTAssertEqual(hub.currentDocument?.homeName, "캐시된 집", "nothing is queued or sent later")

        // The hub comes back: the next snapshot from it restores editing.
        hub.isReachable = true
        relaunched.model.start()
        relaunched.receiveSnapshot(from: hub)
        await waitUntil("editing is back") { relaunched.controller.status == .shared }
        try await relaunched.model.updateHomeName(input: "온라인 수정")
        XCTAssertEqual(hub.currentDocument?.homeName, "온라인 수정")
    }

    func testAHubThatFailsToSaveChangesNothing() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        let revision = hub.revision
        hub.failsNextSave = true
        await XCTAssertThrowsErrorAsync(try await phone.model.updateHomeName(input: "저장 실패")) { error in
            XCTAssertEqual(error as? SharedSettingsEditError, .hubCouldNotSave)
        }
        XCTAssertEqual(hub.revision, revision)
        XCTAssertNotEqual(phone.model.homeName, "저장 실패", "the edit is not shown as done")
        try await phone.model.updateHomeName(input: "다시 저장")
        XCTAssertEqual(hub.currentDocument?.homeName, "다시 저장")
    }

    func testARevokedDeviceKeepsItsCopyButCannotEditOrPoll() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        phone.model.start()
        hub.revokeAll()

        await XCTAssertThrowsErrorAsync(try await phone.model.updateHomeName(input: "철회 후"))
        XCTAssertEqual(phone.controller.status, .failed(.unauthorized))
        XCTAssertFalse(phone.model.canEditConfiguration)

        let fetches = hub.fetchCount
        for _ in 0..<5 { phone.receiveSnapshot(from: hub) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(hub.fetchCount, fetches, "an unchanged revision does not make a revoked device poll the hub")

        // Pairing again restores access to the same shared settings.
        _ = hub.createCode()
        let state = try await phone.controller.pair(code: "7KQM3XWDPA9T", deviceName: "iPhone")
        try phone.controller.useHubSettings(state)
        XCTAssertEqual(phone.controller.status, .shared)
    }

    func testWrongAndExpiredCodesAreExplained() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        await XCTAssertThrowsErrorAsync(try await phone.controller.pair(code: "12345", deviceName: "x")) { error in
            XCTAssertEqual(error as? SharedSettingsPairingError, .malformedCode)
        }
        _ = hub.createCode()
        await XCTAssertThrowsErrorAsync(try await phone.controller.pair(code: "0000-0000-0000", deviceName: "x")) { error in
            XCTAssertEqual(error as? SharedSettingsPairingError, .wrongCode)
        }
        XCTAssertFalse(phone.controller.isPaired)
    }

    func testAHubReportingDamagedSettingsBlocksEditing() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        // A damaged settings.json: the hub answers 503 and its snapshots say "unavailable".
        hub.settingsUnavailable = true
        phone.model.start()
        phone.source.push(F.snapshot(modules: [F.gasSensor], settingsRevision: nil, settingsState: "unavailable"))
        await waitUntil("unavailable is shown") { phone.controller.status == .failed(.hubSettingsUnavailable) }
        XCTAssertFalse(phone.model.canEditConfiguration)
    }

    // MARK: - Separation and identity

    func testAnotherHubAndSimulatedDataNeverShowThisHubsSettings() async throws {
        let hub = FakeSettingsHub()
        let store = InMemoryHomeConfigurationStore(language: .korean)
        try store.updateHomeName("이 기기 집")
        let phone = SimulatedDevice(hub: hub, localStore: store)
        try await turnOnSharing(phone, hub: hub)
        try await phone.model.updateHomeName(input: "허브 A 집")

        let otherHub = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        phone.model.replace(dataSource: PushedSnapshotSource(), identity: .hub(id: otherHub.hubID), address: URL(string: "http://192.168.50.130:8787"))
        XCTAssertEqual(phone.controller.status, .localOnly)
        XCTAssertEqual(phone.model.homeName, "이 기기 집", "hub B shows the device's own settings, never hub A's")

        phone.model.replace(dataSource: MockSensorDataSource(), identity: .simulated)
        XCTAssertEqual(phone.model.homeName, "이 기기 집", "simulated data never uses shared settings")

        phone.model.replace(dataSource: PushedSnapshotSource(), identity: .hub(id: hub.hubID), address: F.hubURL)
        XCTAssertEqual(phone.model.homeName, "허브 A 집", "back on hub A, its cached copy is shown at once")
    }

    func testNamesAndRoomsFollowTheModuleAcrossDetachAndRedock() async throws {
        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        try await turnOnSharing(phone, hub: hub)
        phone.model.start()
        let hall = try await phone.model.createRoom(name: "현관", symbolName: "door.left.hand.open")
        try await phone.model.updateModule(id: F.moduleID(F.dustSensor), customName: "현관 먼지", roomID: hall.id)

        phone.receiveSnapshot(from: hub, modules: [F.gasSensor])
        await waitUntil("the detached module disappears") { phone.model.module(with: F.moduleID(F.dustSensor)) == nil }
        XCTAssertTrue(hub.currentDocument!.modules.contains { $0.uuid == F.dustSensor }, "its settings stay on the hub")

        // Re-docked, possibly on another Power Base: same module UUID, same name and room.
        phone.receiveSnapshot(from: hub, modules: [F.gasSensor, F.dustSensor])
        await waitUntil("the module is back") { phone.model.module(with: F.moduleID(F.dustSensor)) != nil }
        XCTAssertEqual(phone.model.module(with: F.moduleID(F.dustSensor))?.name, "현관 먼지")
        XCTAssertEqual(phone.model.module(with: F.moduleID(F.dustSensor))?.roomID, hall.id)
    }

    func testSuggestedRoomNamesFollowEachDevicesLanguage() {
        let document = HubSettingsDocument(homeName: nil, rooms: [
            HubRoomSetting(id: HomeConfigurationDefaults.livingRoomID, nameKind: .suggestion, name: nil, suggestionSymbol: "sofa.fill", suggestionOrdinal: 1, symbol: "sofa.fill"),
            HubRoomSetting(id: UUID(), nameKind: .custom, name: "Jun's Room", suggestionSymbol: nil, suggestionOrdinal: nil, symbol: "bed.double.fill"),
        ], modules: [])
        let korean = HubSettingsMapping.configuration(from: document, language: .korean)
        let english = HubSettingsMapping.configuration(from: document, language: .english)
        XCTAssertEqual(korean.rooms.first?.name, "거실")
        XCTAssertEqual(english.rooms.first?.name, "Living Room")
        XCTAssertEqual(english.rooms[1].name, "Jun's Room", "a typed name is the same everywhere")
        XCTAssertEqual(korean.rooms.last?.id, ModuleCatalog.unspecifiedRoomID, "미지정 공간 is implicit and last")
        XCTAssertEqual(HubSettingsMapping.document(from: korean, rawIdentifiers: [:]).rooms, document.rooms, "round trip keeps the name sources")
    }

    func testSnapshotDecodingReadsTheSettingsSignalAndOlderHubsHaveNone() throws {
        let shared = F.snapshot(modules: [F.gasSensor], settingsRevision: "0123456789abcdef-3")
        XCTAssertEqual(shared.hubSettings, HubSettingsSignal(state: .ready, revision: "0123456789abcdef-3"))
        let json = #"{"schema_version":1,"generated_at_unix_ms":1,"registry_generation":1,"modules":[]}"#
        XCTAssertNil(try PogoSnapshotMapper.decodeSnapshot(from: Data(json.utf8)).hubSettings)
    }
}

/// The pairing proofs must match the hub's `device_auth.cpp` bit for bit: these are the same
/// vectors its `test_device_auth.cpp` checks.
final class HubPairingProofTests: XCTestCase {
    private let hubID = "3f0c9a4e8b1d4c2a9e7f6b5a4d3c2b1a"
    private let nonce = "000102030405060708090a0b0c0d0e0f"

    func testProofsMatchTheHubsTestVectors() {
        let certificate = HubPairingProof.sha256Hex(Data("test-cert".utf8))
        XCTAssertEqual(certificate, "ac978e63f273ba9ee1132bfecc103c767c52512fd5b065cc0ee224f9ec49d6a2")
        XCTAssertEqual(
            HubPairingProof.client(code: "7KQM3XWDPA9T", hubID: hubID, certificateSHA256: certificate, clientNonce: nonce, deviceName: "Jun의 iPhone"),
            "096c8f9cdd9997de40cb91226f7e34a89a8f06e4b8798878eeb49a178b3f3c99"
        )
        XCTAssertEqual(
            HubPairingProof.server(code: "7KQM3XWDPA9T", hubID: hubID, certificateSHA256: certificate, clientNonce: nonce, deviceID: "0123456789abcdef", token: String(repeating: "A", count: 43)),
            "4d9e5bc4d035fbc41252d190a746e3dd14dae31ca3d713531967e20fd23994a0"
        )
    }

    /// The hub lists a device by the name typed at pairing; an empty field falls back to the app's
    /// current name (조각보 홈 / Jogakbo Home), never the old one.
    @MainActor
    func testAnEmptyDeviceNameFallsBackToTheAppName() {
        XCTAssertEqual(SharedSettingsController.deviceName("  \n"), Brand.appName)
        XCTAssertNotEqual(SharedSettingsController.deviceName(""), "PogoHome")
        XCTAssertEqual(SharedSettingsController.deviceName(" Jun의 iPad "), "Jun의 iPad")
    }

    func testCodesAreNormalizedLikeTheHubDoes() {
        XCTAssertEqual(HubPairingCode.normalized("7kqm-3xwd-pa9t"), "7KQM3XWDPA9T")
        XCTAssertEqual(HubPairingCode.normalized("OIL1 0000 0000"), "011100000000")
        XCTAssertNil(HubPairingCode.normalized("7KQM-3XWD-PA9U"))
        XCTAssertNil(HubPairingCode.normalized("7KQM-3XWD-PA9"))
        XCTAssertNil(HubPairingCode.normalized("7KQM-3XWD-PA9TT"))
        XCTAssertEqual(HubPairingProof.makeNonce().count, 32)
        XCTAssertNotEqual(HubPairingProof.makeNonce(), HubPairingProof.makeNonce())
    }

    func testHTTPErrorsMapToTheirMeaning() {
        func error(_ status: Int, _ body: String) -> HubSettingsError {
            URLSessionHubSettingsTransport.error(status: status, data: Data(body.utf8))
        }
        XCTAssertEqual(error(401, #"{"error":"unauthorized"}"#), .unauthorized)
        XCTAssertEqual(error(403, #"{"error":"pairing_rejected","reason":"expired"}"#), .pairingRejected(reason: "expired"))
        XCTAssertEqual(error(404, #"{"error":"not_found"}"#), .notSupported)
        XCTAssertEqual(error(409, #"{"error":"too_many_devices"}"#), .tooManyDevices)
        XCTAssertEqual(error(422, #"{"error":"invalid_settings","detail":"unknown_room_id"}"#), .invalid(detail: "unknown_room_id"))
        XCTAssertEqual(error(500, #"{"error":"settings_save_failed"}"#), .saveFailed)
        XCTAssertEqual(error(503, #"{"error":"settings_unavailable","reason":"corrupt"}"#), .unavailable(reason: "corrupt"))
        let conflict = #"{"error":"revision_conflict","current":{"schema_version":1,"hub_id":"aa","initialized":true,"revision":"x-2","updated_at_unix_ms":5,"settings":{"home_name":null,"rooms":[],"modules":[]}}}"#
        guard case let .conflict(current) = error(409, conflict) else { return XCTFail("expected a conflict") }
        XCTAssertEqual(current.revision, "x-2")
    }

    func testCredentialsAreKeptPerHubInTheKeychain() throws {
        let store = KeychainHubCredentialStore(service: "com.junsoona.PogoHome.tests.\(UUID().uuidString)")
        let a = HubCredential(hubID: String(repeating: "a", count: 32), deviceID: "d1", token: "t1", certificateSHA256: "c1", pairedAt: Date(timeIntervalSince1970: 1))
        let b = HubCredential(hubID: String(repeating: "b", count: 32), deviceID: "d2", token: "t2", certificateSHA256: "c2", pairedAt: Date(timeIntervalSince1970: 2))
        do {
            try store.save(a)
        } catch HubCredentialStoreError.keychain(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("no Keychain entitlement in this test host")
        }
        defer {
            try? store.deleteCredential(forHubID: a.hubID)
            try? store.deleteCredential(forHubID: b.hubID)
        }
        try store.save(b)
        XCTAssertEqual(try store.credential(forHubID: a.hubID), a)
        XCTAssertEqual(try store.credential(forHubID: b.hubID), b)
        try store.deleteCredential(forHubID: a.hubID)
        XCTAssertNil(try store.credential(forHubID: a.hubID))
        XCTAssertEqual(try store.credential(forHubID: b.hubID), b)
    }
}
