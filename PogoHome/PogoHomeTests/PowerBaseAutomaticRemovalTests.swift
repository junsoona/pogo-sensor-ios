import XCTest
@testable import PogoHome

/// "Delete once, then nothing to do" (2026-10-08): what the hub's `erase_confirmation` does to
/// what the app shows and offers for a removal -- and what it never does.
///
/// A Power Base whose board confirms its erase to the hub itself needs nothing from this app after
/// the request: no board search, no setup code, no "삭제 확인". The hub says which Bases those are and
/// which jobs still expect it. Whatever it says, a job is "삭제 완료" only when the hub's state is
/// `completed`.
///
/// The whole way through the real `AppModel` is in `AppModelPowerBaseManagementTests`.
final class PowerBaseAutomaticRemovalTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias T = PowerBaseManagementText
    private typealias Transport = URLSessionPowerBaseRemovalTransport

    private func removal(
        _ state: PowerBaseRemoval.State, _ confirmation: PowerBaseEraseConfirmation, resultUnknown: Bool = false,
        id: String = RemovalFixtures.removalID, updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_100)
    ) -> PowerBaseRemoval {
        var removal = RemovalFixtures.removal(state, id: id, resultUnknown: resultUnknown, updatedAt: updatedAt)
        removal.eraseConfirmation = confirmation
        return removal
    }

    // MARK: - What the hub says

    func testTheHubsWordOnAJobIsReadAndNothingElseIsGuessed() throws {
        func decoded(_ state: String, _ extra: String) throws -> PowerBaseRemoval {
            try Transport.decodeRemoval(Data(RemovalFixtures.json(state, extra: extra).utf8))
        }
        XCTAssertEqual(try decoded("released", #","erase_confirmation":"automatic""#).eraseConfirmation, .automatic)
        XCTAssertEqual(try decoded("released", #","erase_confirmation":"manual""#).eraseConfirmation, .manual)
        XCTAssertEqual(try decoded("pending", #","erase_confirmation":"automatic""#).eraseConfirmation, .automatic)
        // An earlier hub does not say; a later hub's word this app does not know is not taken
        // for "automatic".
        XCTAssertEqual(try decoded("released", "").eraseConfirmation, .unspecified)
        XCTAssertEqual(try decoded("released", #","erase_confirmation":"scheduled""#).eraseConfirmation, .unspecified)
        XCTAssertEqual(try decoded("released", #","erase_confirmation":"""#).eraseConfirmation, .unspecified)
        // The word changes nothing else about the job.
        let job = try decoded("released", #","erase_confirmation":"automatic""#)
        XCTAssertEqual(job.state, .released)
        XCTAssertFalse(job.state.isFinal)
        XCTAssertFalse(job.cancellable)
        // Nothing is expected of a job that has ended.
        for state in ["completed", "cancelled", "superseded"] {
            XCTAssertEqual(try decoded(state, #","erase_confirmation":"automatic""#).eraseConfirmation, .unspecified, state)
        }
    }

    func testTheHubsWordOnAPowerBaseIsReadFromTheSnapshot() throws {
        func base(_ extra: String) -> String {
            #"{"uuid":"\#(RemovalFixtures.base)","online":true,"module_count":0,"online_module_count":0\#(extra)}"#
        }
        func mapped(_ extra: String) throws -> PowerBase {
            let dto = try JSONDecoder().decode(PogoSnapshotDTO.self, from: RemovalFixtures.snapshotJSON(bases: [base(extra)], removals: ""))
            return try XCTUnwrap(try PogoSnapshotMapper.map(dto, generatedAt: Date(timeIntervalSince1970: 1_790_000_200)).powerBases.first)
        }
        XCTAssertEqual(try mapped(#","management":"supported","erase_confirmation":"automatic""#).eraseConfirmation, .automatic)
        XCTAssertEqual(try mapped(#","management":"supported","erase_confirmation":"manual""#).eraseConfirmation, .manual)
        XCTAssertEqual(try mapped(#","management":"supported""#).eraseConfirmation, .unspecified, "an earlier hub")
        XCTAssertEqual(try mapped("").eraseConfirmation, .unspecified, "a hub without management")
        // Only a Base the hub can remove has a way its removal is confirmed.
        XCTAssertEqual(try mapped(#","management":"unsupported","erase_confirmation":"automatic""#).eraseConfirmation, .unspecified)
        XCTAssertEqual(try mapped(#","management":"supported","erase_confirmation":"automatic""#).management, .supported)
    }

    // MARK: - What is shown

    func testUntilTheHubConfirmsAJobIsWaitingOrBeingRemovedNeverRemoved() {
        let removed = T.removalTitle(.completed)
        // Every state before `completed`, with everything the hub can say about it.
        for confirmation in [PowerBaseEraseConfirmation.unspecified, .automatic, .manual] {
            for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .released] {
                for unknown in [false, true] where !unknown || state == .sent || state == .accepted {
                    let job = removal(state, confirmation, resultUnknown: unknown)
                    XCTAssertNotEqual(job.presentation, .completed, "\(state) \(confirmation)")
                    XCTAssertNotEqual(T.removalTitle(job.presentation), removed, "\(state) \(confirmation)")
                    XCTAssertNotEqual(T.removalMessage(job.presentation), T.removalMessage(.completed), "\(state) \(confirmation)")
                }
            }
        }
        XCTAssertEqual(removal(.completed, .unspecified).presentation, .completed)

        // The two titles of a job that needs nothing from the user: waiting, then one title for
        // the whole time between the command and the hub's confirmation.
        let waiting = T.removalTitle(removal(.pending, .automatic).presentation)
        let removing = T.removalTitle(removal(.sent, .automatic).presentation)
        XCTAssertNotEqual(waiting, removing)
        XCTAssertEqual(T.removalTitle(removal(.accepted, .automatic).presentation), removing)
        XCTAssertEqual(T.removalTitle(removal(.released, .automatic).presentation), removing)
        XCTAssertEqual(removal(.released, .automatic).presentation, .finishing)
        if AppLanguage.current == .korean {
            XCTAssertEqual(waiting, "삭제 대기")
            XCTAssertEqual(removing, "삭제 중")
            XCTAssertEqual(removed, "삭제 완료")
        }
        // Released and to be confirmed by hand has a state of its own, as before.
        XCTAssertEqual(removal(.released, .manual).presentation, .awaitingEraseConfirmation)
        XCTAssertEqual(removal(.released, .unspecified).presentation, .awaitingEraseConfirmation)
        XCTAssertNotEqual(T.removalTitle(.awaitingEraseConfirmation), T.removalTitle(.finishing))
        XCTAssertNotEqual(T.removalMessage(.finishing), T.removalMessage(.inProgress), "what is happening is said for each")
        XCTAssertNotEqual(T.removalMessage(.finishing), T.removalMessage(.awaitingEraseConfirmation))
    }

    func testTheBluetoothConfirmationIsOfferedExactlyWhenSomeoneHasToAct() {
        // Automatic: nothing to do at any point.
        for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .released] {
            XCTAssertFalse(removal(state, .automatic).offersEraseConfirmation, "\(state)")
        }
        XCTAssertEqual(P.removalActions(for: removal(.released, .automatic), isActing: false), [])
        XCTAssertEqual(P.removalActions(for: removal(.pending, .automatic), isActing: false), [.cancel], "a waiting job can be cancelled, as before")
        // The hub stopped expecting it, or never did: the screen that was always there.
        XCTAssertEqual(P.removalActions(for: removal(.released, .manual), isActing: false), [.confirmErase])
        XCTAssertEqual(P.removalActions(for: removal(.released, .unspecified), isActing: false), [.confirmErase])
        // A command without any sign of life: offered whatever was expected (the hub itself
        // reports "manual" then; a hub that still said "automatic" is not obeyed over that).
        for confirmation in [PowerBaseEraseConfirmation.unspecified, .automatic, .manual] {
            XCTAssertEqual(P.removalActions(for: removal(.sent, confirmation, resultUnknown: true), isActing: false), [.confirmErase], "\(confirmation)")
            XCTAssertEqual(removal(.accepted, confirmation, resultUnknown: true).presentation, .resultUnknown)
        }
        // A job that ended offers nothing.
        for state in [PowerBaseRemoval.State.completed, .cancelled, .superseded] {
            XCTAssertEqual(P.removalActions(for: removal(state, .manual), isActing: false), [], "\(state)")
        }
    }

    func testAJobUnderWayLeavesNothingToRequestAndShowsItsBadge() {
        let supported = PowerBase(hardwareIdentifier: RemovalFixtures.base, isOnline: true, moduleCount: 0, onlineModuleCount: 0, management: .supported, eraseConfirmation: .automatic, record: RemovalFixtures.record, removalSerial: 0)
        let snapshot = HomeSnapshot(timestamp: Date(timeIntervalSince1970: 1_790_000_200), rooms: [], modules: [], powerBases: [supported], reportsPowerBases: true, powerBaseRemovals: [], reportsPowerBaseManagement: true)
        XCTAssertEqual(P.availability(base: supported, snapshot: snapshot, target: RemovalFixtures.target(), removal: nil), .available)
        XCTAssertEqual(P.availability(base: nil, snapshot: snapshot, target: RemovalFixtures.target(), removal: removal(.released, .automatic)), .removalExists,
                       "the same Base cannot be asked twice while the first request is under way")
        XCTAssertEqual(P.badge(for: removal(.released, .automatic)), .finishing)
        XCTAssertEqual(PowerBaseManagementContent.symbol(.finishing), PowerBaseManagementContent.symbol(.inProgress), "one look for 'being removed'")
    }

    func testAFinishedRemovalLeavesTheDeviceList() {
        let now = Date(timeIntervalSince1970: 1_790_010_000)
        func snapshot(_ removals: [PowerBaseRemoval], bases: [PowerBase] = []) -> HomeSnapshot {
            HomeSnapshot(timestamp: now, rooms: [], modules: [], powerBases: bases, reportsPowerBases: true, powerBaseRemovals: removals, reportsPowerBaseManagement: true)
        }
        let recent = now.addingTimeInterval(-60)
        // Under way: a request, whatever the hub expects of it and however long it takes.
        for job in [removal(.pending, .automatic), removal(.sent, .automatic), removal(.accepted, .manual, resultUnknown: true),
                    removal(.released, .automatic), removal(.released, .manual, updatedAt: now.addingTimeInterval(-90 * 86_400))] {
            XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: snapshot([job])).map(\.id), [job.id], "\(job.state)")
        }
        // Completed: no request any more, and no row of any other list -- however recent.
        let done = removal(.completed, .unspecified, updatedAt: recent)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([done])).isEmpty)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([removal(.completed, .unspecified, updatedAt: now)])).isEmpty)
        // A request under way of another Base stays, next to a finished one.
        let underWay = PowerBaseRemoval(
            id: RemovalFixtures.otherRemovalID, powerBaseIdentifier: RemovalFixtures.otherBase, state: .released, resultUnknown: false, cancellable: false,
            affectedModuleCount: 1, createdAt: recent, updatedAt: recent, eraseConfirmation: .automatic
        )
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: snapshot([done, underWay])).map(\.id), [underWay.id])
        // Ended without changing anything: not listed either.
        for state in [PowerBaseRemoval.State.cancelled, .superseded] {
            XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([removal(state, .unspecified, updatedAt: recent)])).isEmpty, "\(state)")
        }
        // A Base that is listed shows its job in its own row instead.
        let listed = PowerBase(hardwareIdentifier: RemovalFixtures.base, isOnline: false, moduleCount: 0, onlineModuleCount: 0, management: .supported, record: RemovalFixtures.record, removalSerial: 0)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([removal(.pending, .automatic)], bases: [listed])).isEmpty)
    }

    // MARK: - The one confirmation

    func testTheConfirmationPromisesOnlyWhatTheHubSaysOfTheBase() {
        let automatic = T.confirmMessage(sensorCount: 2, isOnline: true, eraseConfirmation: .automatic)
        XCTAssertFalse(automatic.contains(T.confirmLater), "nothing more is asked of the user")
        XCTAssertTrue(automatic.contains(T.confirmRegisterAgain), "what a removal means for later is still said")
        for confirmation in [PowerBaseEraseConfirmation.manual, .unspecified] {
            let message = T.confirmMessage(sensorCount: 2, isOnline: true, eraseConfirmation: confirmation)
            XCTAssertTrue(message.contains(T.confirmLater), "\(confirmation)")
            XCTAssertTrue(T.confirmLater.contains(T.confirmErase), "names the screen that confirms it")
        }
        XCTAssertEqual(T.confirmMessage(sensorCount: 2, isOnline: true), T.confirmMessage(sensorCount: 2, isOnline: true, eraseConfirmation: .unspecified),
                       "a caller that does not know says what was always said")
        // An offline Base: the request waits, whoever confirms later.
        for confirmation in [PowerBaseEraseConfirmation.automatic, .manual, .unspecified] {
            let offline = T.confirmMessage(sensorCount: 0, isOnline: false, eraseConfirmation: confirmation)
            XCTAssertTrue(offline.contains(T.removalTitle(.waitingForPowerBase)), "names the state it will show: \(confirmation)")
            XCTAssertEqual(offline.contains(T.confirmLater), confirmation != .automatic, "\(confirmation)")
        }
    }

    /// The field feedback of `1.2.0 (8)`: the dialog is narrow, and three paragraphs in it were
    /// hard to read. Every branch is one paragraph of two or three short sentences.
    func testTheConfirmationIsOneShortParagraphInEveryBranch() {
        var longest = 0
        for sensors in [0, 1, 2, 12] {
            for online in [true, false] {
                for confirmation in [PowerBaseEraseConfirmation.automatic, .manual, .unspecified] {
                    let message = T.confirmMessage(sensorCount: sensors, isOnline: online, eraseConfirmation: confirmation)
                    let what = "\(sensors) sensors, online \(online), \(confirmation): \(message)"
                    XCTAssertFalse(message.contains("\n"), "one paragraph: \(what)")
                    let sentences = message.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    XCTAssertTrue((2...3).contains(sentences.count), "two or three sentences: \(what)")
                    longest = max(longest, message.count)
                }
            }
        }
        // The longest branch (offline, to be confirmed near the Base) is 147 characters in Korean,
        // 307 in English and 331 in Spanish with two sensors. In 1.2.0 (8) the four branches were
        // 243-355, 467-689 and 501-720 characters, in three paragraphs.
        XCTAssertLessThan(longest, AppLanguage.current == .korean ? 160 : 350, "the longest branch")
    }

    func testNoWordingOfTheFlowNamesHowItWorksInside() {
        var texts = [T.confirmRegisterAgain, T.confirmOffline, T.confirmLater, T.listHeader, T.deleteFooter, T.confirmEraseWhenUnknown, T.cleanupPending, T.completionNotice(label: "Power Base ··b3c4")]
        let presentations: [PowerBaseRemoval.Presentation] = [.waitingForPowerBase, .inProgress, .resultUnknown, .finishing, .awaitingEraseConfirmation, .completed, .cancelled, .superseded]
        texts += presentations.map(T.removalTitle) + presentations.map(T.removalMessage)
        texts += [T.confirmMessage(sensorCount: 3, isOnline: true, eraseConfirmation: .automatic), T.confirmMessage(sensorCount: 0, isOnline: false, eraseConfirmation: .manual)]
        // Names of the parts, in any case; and abbreviations, as written. Nor the hub's own words
        // for the steps of a removal ("released", "등록 해제", the stored join information).
        let names = ["Thread", "CoAP", "HELLO", "Dataset", "데이터셋", "영수증", "receipt", "recibo", "capability", "erase_confirmation", "nonce", "세대",
                     "등록 해제", "등록을 해제", "가입 정보", "released", "join information", "dada de baja", "dio de baja", "información de acceso"]
        let abbreviations = ["MAC", "RAM", "NVS", "PSA", "EUI"]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            for word in names {
                XCTAssertNil(text.range(of: word, options: .caseInsensitive), "'\(word)' in: \(text)")
            }
            for word in abbreviations {
                XCTAssertNil(text.range(of: word), "'\(word)' in: \(text)")
            }
        }
    }

    // MARK: - The hub's later word

    func testByHandIsALaterWordThanAutomaticForTheSameReleasedJob() {
        typealias C = PowerBaseRemovalController
        XCTAssertTrue(C.isFurtherAlong(removal(.released, .manual), than: removal(.released, .automatic)), "the hub stopped expecting it")
        XCTAssertFalse(C.isFurtherAlong(removal(.released, .automatic), than: removal(.released, .manual)), "an older answer never undoes that")
        XCTAssertFalse(C.isFurtherAlong(removal(.released, .manual), than: removal(.released, .manual)))
        XCTAssertFalse(C.isFurtherAlong(removal(.released, .unspecified), than: removal(.released, .automatic)), "a hub that did not say is not a later word")
        // The order of the states is what it was.
        XCTAssertTrue(C.isFurtherAlong(removal(.completed, .unspecified), than: removal(.released, .manual)))
        XCTAssertTrue(C.isFurtherAlong(removal(.released, .automatic), than: removal(.accepted, .manual, resultUnknown: true)))
        XCTAssertTrue(C.isFurtherAlong(removal(.sent, .manual, resultUnknown: true), than: removal(.sent, .automatic)))
        XCTAssertFalse(C.isFurtherAlong(removal(.sent, .automatic), than: removal(.sent, .manual, resultUnknown: true)))
        XCTAssertFalse(C.isFurtherAlong(removal(.pending, .manual), than: removal(.pending, .automatic)), "before the release only the snapshot's word counts")
    }

    @MainActor
    func testTheSheetShowsTheHubsLaterWordAndOneRequestIsOneJob() async throws {
        let hub = FakeRemovalHub()
        let credentials = InMemoryHubCredentialStore()
        try credentials.save(RemovalFixtures.credential())
        let controller = PowerBaseRemovalController(transport: hub, credentials: credentials)
        controller.targetDidChange(RemovalFixtures.target())
        func snapshot(_ removals: [PowerBaseRemoval]) -> HomeSnapshot {
            HomeSnapshot(timestamp: Date(timeIntervalSince1970: 1_790_000_200), rooms: [], modules: [], powerBaseRemovals: removals, reportsPowerBaseManagement: true)
        }

        // "삭제" twice in a row is one request; the hub answers both devices with the same job.
        hub.hold()
        hub.scriptRequest(.success(removal(.pending, .automatic)))
        controller.requestRemoval(of: RemovalFixtures.base)
        controller.requestRemoval(of: RemovalFixtures.base)
        try await waitUntil { hub.heldCount == 1 }
        XCTAssertEqual(controller.action(for: RemovalFixtures.base), .requesting)
        hub.release()
        try await waitUntil { controller.action(for: RemovalFixtures.base) == nil }
        XCTAssertEqual(hub.recorded.filter { if case .request = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(controller.removal(for: RemovalFixtures.base, in: snapshot([]))?.presentation, .waitingForPowerBase)

        // The snapshot still says the board will confirm by itself; the hub's list, read while
        // the sheet is shown, already says by hand: the later word is shown.
        hub.scriptList(.success([removal(.released, .manual)]))
        await controller.refresh()
        XCTAssertEqual(controller.removal(for: RemovalFixtures.base, in: snapshot([removal(.released, .automatic)]))?.presentation, .awaitingEraseConfirmation)
        // And an older list never undoes what a later snapshot says.
        hub.scriptList(.success([removal(.released, .automatic)]))
        await controller.refresh()
        XCTAssertEqual(controller.removal(for: RemovalFixtures.base, in: snapshot([removal(.released, .manual)]))?.presentation, .awaitingEraseConfirmation)
        XCTAssertEqual(controller.removal(for: RemovalFixtures.base, in: snapshot([removal(.completed, .unspecified)]))?.presentation, .completed)

        // A request whose answer is lost is not a "no": it is kept, and sent again as it is.
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.dismissFailure(for: RemovalFixtures.base)
        controller.requestRemoval(of: RemovalFixtures.otherBase)
        try await waitUntil { controller.action(for: RemovalFixtures.otherBase) != .requesting }
        XCTAssertEqual(controller.action(for: RemovalFixtures.otherBase), .resultUnknown)
        XCTAssertFalse(T.removalResultUnknown.isEmpty)
        XCTAssertTrue(hub.receipts.isEmpty, "nothing in any of this relayed a confirmation from the app")
    }
}
