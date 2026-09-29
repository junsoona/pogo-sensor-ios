import XCTest
@testable import PogoHome

/// The Dashboard's tiles and cards open lists; every number shown must be the length of the list
/// it opens, filtered by the same rule, and each source (조각보 sensors, Apple Home) counts only
/// its own devices.
final class DashboardMetricsTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let baseID = "b0b0b0fffe000002"

    /// Online and fine, online with a stale and an error reading, offline on its own, offline
    /// with its whole Power Base, and online without readings yet.
    private func snapshot() -> HomeSnapshot {
        let room = HomeConfigurationDefaults.livingRoom
        func module(_ n: Int, name: String, online: Bool, readings: [SensorReading], base: String? = nil) -> SensorModule {
            SensorModule(
                id: UUID(uuidString: "8A3B1C10-00\(n)0-4000-8000-0000000000\(n)0")!,
                name: name,
                roomID: room.id,
                readings: readings,
                isOnline: online,
                lastSeen: now,
                powerBaseIdentifier: base
            )
        }
        let modules = [
            module(1, name: "거실 환경", online: true, readings: [
                SensorReading(kind: .temperature, value: 23.4, timestamp: now, status: .normal),
                SensorReading(kind: .humidity, value: 45, timestamp: now, status: .normal),
            ]),
            module(2, name: "거실 공기", online: true, readings: [
                SensorReading(kind: .pm2_5, value: 7, timestamp: now, status: .stale),
                SensorReading(kind: .vocIndex, value: 100, timestamp: now, status: .error),
                SensorReading(kind: .pm10, value: 9, timestamp: now, status: .conditioning),
            ]),
            module(3, name: "침실 센서", online: false, readings: [
                SensorReading(kind: .temperature, value: 20, timestamp: now, status: .stale),
            ]),
            module(4, name: "서재 센서", online: false, readings: [
                SensorReading(kind: .humidity, value: 50, timestamp: now, status: .normal),
            ], base: baseID),
            module(5, name: "새 모듈", online: true, readings: []),
        ]
        return HomeSnapshot(
            timestamp: now,
            rooms: [room],
            modules: modules,
            powerBases: [PowerBase(hardwareIdentifier: baseID, isOnline: false, moduleCount: 1, onlineModuleCount: 0)],
            reportsPowerBases: true
        )
    }

    // MARK: - 조각보 sensor tiles

    func testEachTileCountsExactlyTheListItOpens() throws {
        let snapshot = snapshot()
        for health in [HomeHealthState.healthy, .attentionNeeded] {
            let online = try XCTUnwrap(DashboardMetrics.onlineModules(snapshot, health: health))
            XCTAssertEqual(Set(online.map(\.id)), Set(snapshot.modules.filter(\.isOnline).map(\.id)))
            XCTAssertTrue(online.allSatisfy(\.isOnline), "the online list shows only online modules")

            let attention = try XCTUnwrap(DashboardMetrics.attentionItems(snapshot, health: health))
            XCTAssertEqual(Set(attention.map(\.id)), Set(snapshot.modulesNeedingAttention.map(\.id)))
            XCTAssertTrue(attention.allSatisfy { !$0.reasons.isEmpty }, "every listed module says why")
        }

        let groups = DashboardMetrics.readingGroups(snapshot)
        XCTAssertEqual(DashboardMetrics.readingCount(groups), snapshot.allReadings.count, "the 센서 tile counts every reading on screen")
        XCTAssertEqual(Set(groups.flatMap(\.readings).map(\.id)), Set(snapshot.allReadings.map(\.id)))
        for group in groups {
            XCTAssertEqual(group.readings.map(\.id), group.module.sortedReadings.map(\.id), "readings stay under their own module")
        }
        XCTAssertFalse(groups.contains { $0.module.readings.isEmpty }, "a module without readings has no section")
    }

    func testWithoutAVerifiedConnectionTheTilesShowNoCountAndTheListsNoGuess() {
        let snapshot = snapshot()
        for health in [HomeHealthState.reconnecting, .recoveringRegistry, .waitingForData] {
            XCTAssertNil(DashboardMetrics.onlineModules(snapshot, health: health), "\(health)")
            XCTAssertNil(DashboardMetrics.attentionItems(snapshot, health: health), "\(health)")
        }
        // Readings are shown (as last received) whatever the connection, and so are counted.
        XCTAssertEqual(DashboardMetrics.readingCount(DashboardMetrics.readingGroups(snapshot)), 7)
    }

    func testAttentionReasonsNameTheProblem() throws {
        let snapshot = snapshot()
        let items = try XCTUnwrap(DashboardMetrics.attentionItems(snapshot, health: .attentionNeeded))
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.module.name, $0.reasons) })
        XCTAssertEqual(byName["거실 공기"], [.reading(.pm2_5, .stale), .reading(.vocIndex, .error)], "a calibrating reading isn't a problem")
        XCTAssertEqual(byName["침실 센서"], [.offline(isPowerBaseOffline: false)])
        XCTAssertEqual(byName["서재 센서"], [.offline(isPowerBaseOffline: true)])
        XCTAssertNil(byName["거실 환경"])
        XCTAssertNil(byName["새 모듈"], "no readings yet isn't an attention reason")
    }

    func testEmptyHomesGiveEmptyListsNotMissingOnes() throws {
        let empty = HomeSnapshot(timestamp: now, rooms: [], modules: [])
        XCTAssertEqual(try XCTUnwrap(DashboardMetrics.onlineModules(empty, health: .healthy)), [])
        XCTAssertEqual(try XCTUnwrap(DashboardMetrics.attentionItems(empty, health: .healthy)), [])
        XCTAssertEqual(DashboardMetrics.readingGroups(empty), [])
    }

    // MARK: - Apple Home card

    private func accessory(
        _ name: String,
        reachable: Bool = true,
        blocked: Bool = false,
        error: String? = nil,
        autoRead: AppleHomeAutoReadState? = nil,
        read: Bool = true
    ) -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: UUID(),
            homeID: F.homeID,
            name: name,
            roomID: F.livingRoomID,
            roomName: "거실",
            isReachable: reachable,
            isBlocked: blocked,
            services: [
                AppleHomeService(id: UUID(), kind: .temperatureSensor, name: name, characteristics: [
                    AppleHomeCharacteristic(id: UUID(), kind: .currentTemperature, value: read ? .double(21) : nil, confirmedAt: read ? now : nil),
                ]),
            ],
            lastReadError: error,
            autoRead: autoRead
        )
    }

    func testIssuesSeparateNotRespondingFromReadFailuresAndRetries() {
        let fine = accessory("정상")
        let unreachable = accessory("응답 없음", reachable: false, error: "late")
        let blocked = accessory("차단", blocked: true)
        let failed = accessory("실패", error: "late", read: false)
        let retrying = accessory("재시도", autoRead: .waiting(nextAttempt: 2, maxAttempts: 3), read: false)
        let checking = accessory("확인 중", autoRead: .waiting(nextAttempt: 1, maxAttempts: 3), read: false)
        let issues = AppleHomeIssueList.evaluate([fine, unreachable, blocked, failed, retrying, checking])

        XCTAssertEqual(issues.issues.map(\.accessory.id), [unreachable, blocked, failed, retrying, checking].map(\.id), "in the given (layout) order")
        XCTAssertEqual(AppleHomeIssueReason.resolve(fine), nil)
        XCTAssertEqual(AppleHomeIssueReason.resolve(unreachable), .notResponding(isBlocked: false), "a device that doesn't respond isn't also a read failure")
        XCTAssertEqual(AppleHomeIssueReason.resolve(blocked), .notResponding(isBlocked: true))
        XCTAssertEqual(AppleHomeIssueReason.resolve(failed), .readFailed("late"))
        XCTAssertEqual(AppleHomeIssueReason.resolve(retrying), .retrying(attempt: 2, maxAttempts: 3))
        XCTAssertEqual(AppleHomeIssueReason.resolve(checking), .checking)

        // Each filter returns only its own kind, and together they are the whole list.
        for category in AppleHomeIssueReason.Category.allCases {
            XCTAssertTrue(issues.issues(in: category).allSatisfy { $0.reason.category == category })
        }
        XCTAssertEqual(AppleHomeIssueReason.Category.allCases.map(issues.count).reduce(0, +), issues.issues.count)
        XCTAssertEqual(issues.count(.notResponding), 2)
        XCTAssertEqual(issues.count(.readFailed), 1)
        XCTAssertEqual(issues.count(.retrying), 1)
        XCTAssertEqual(issues.count(.checking), 1)
    }

    @MainActor
    func testTheAppleHomeCardCountsTheSameDevicesItsListShows() {
        let accessories = [
            accessory("정상"),
            accessory("응답 없음", reachable: false),
            accessory("실패", error: "late", read: false),
            accessory("재시도", autoRead: .waiting(nextAttempt: 3, maxAttempts: 3), read: false),
        ]
        let model = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: F.ready(accessories)), defaults: makeIsolatedDefaults())
        model.enable()
        let layout = model.layout(pogo: HomeSnapshot(timestamp: now, rooms: [], modules: []))
        let issues = AppleHomeIssueList.evaluate(layout.visibleAccessories)

        XCTAssertEqual(
            AppleHomeStatusSummary.evaluate(state: .ready, layout: layout),
            .someNotResponding(notResponding: issues.count(.notResponding), total: 4)
        )
        XCTAssertEqual(
            AppleHomeValueCheckSummary.evaluate(layout.visibleAccessories),
            AppleHomeValueCheckSummary(checking: issues.count(.checking), retrying: issues.count(.retrying), failed: issues.count(.readFailed))
        )
        XCTAssertEqual(AppleHomeValueCheckSummary.evaluate(issues), AppleHomeValueCheckSummary(checking: 0, retrying: 1, failed: 1))
    }

    /// A hidden duplicate of a 조각보 sensor isn't on the Apple Home card, so it isn't in the list
    /// either; and 조각보 modules never appear in the Apple Home list, nor Apple Home devices in
    /// the 조각보 lists — even with the same name.
    @MainActor
    func testSourcesStaySeparateAndHiddenDuplicatesAreNotCounted() throws {
        let pogo = snapshot()
        let pogoModule = try XCTUnwrap(pogo.modules.first)
        let sameName = accessory(pogoModule.name, reachable: false)
        let linked = accessory("브리지 센서", reachable: false)
        let model = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: F.ready([sameName, linked])), defaults: makeIsolatedDefaults())
        model.enable()
        model.link(accessoryID: linked.id, toPogoModule: pogoModule.id)

        let layout = model.layout(pogo: pogo)
        let issues = AppleHomeIssueList.evaluate(layout.visibleAccessories)
        XCTAssertEqual(issues.issues.map(\.accessory.id), [sameName.id], "a same name alone never links; the linked one is hidden")
        XCTAssertEqual(layout.hiddenDuplicates.map(\.id), [linked.id])
        XCTAssertEqual(
            AppleHomeStatusSummary.evaluate(state: .ready, layout: layout),
            .someNotResponding(notResponding: 1, total: 1)
        )

        let pogoIDs = Set(pogo.modules.map(\.id))
        XCTAssertTrue(issues.issues.allSatisfy { !pogoIDs.contains($0.accessory.id) })
        let online = try XCTUnwrap(DashboardMetrics.onlineModules(pogo, health: .attentionNeeded))
        XCTAssertTrue(online.allSatisfy { pogoIDs.contains($0.id) })
    }

    // MARK: - Apple Home card verdict

    private typealias Verdict = AppleHomeCardVerdict

    private func verdict(_ summary: AppleHomeStatusSummary, checking: Int = 0, retrying: Int = 0, failed: Int = 0) -> Verdict {
        Verdict.evaluate(summary: summary, valueCheck: AppleHomeValueCheckSummary(checking: checking, retrying: retrying, failed: failed))
    }

    private func counts(total: Int, notResponding: Int = 0, readFailed: Int = 0, retrying: Int = 0, checking: Int = 0) -> Verdict.Counts {
        Verdict.Counts(total: total, notResponding: notResponding, readFailed: readFailed, retrying: retrying, checking: checking)
    }

    /// Green only when every device responds and no read is pending or failed.
    func testTheAppleHomeCardIsFineOnlyWithNothingPendingOrFailed() {
        XCTAssertEqual(verdict(.allResponding(total: 42)), .fine(total: 42))
        XCTAssertEqual(Verdict.evaluate(summary: .allResponding(total: 42), valueCheck: nil), .fine(total: 42))
    }

    /// The Mac case: HomeKit reports all 42 as responding while 5 value reads failed for good.
    func testAFailedValueReadNeedsAttentionEvenWhenHomeKitReportsEveryDeviceResponding() {
        let result = verdict(.allResponding(total: 42), failed: 5)
        XCTAssertEqual(result, .needsAttention(counts(total: 42, readFailed: 5)))
        guard case let .needsAttention(counts) = result else { return XCTFail() }
        XCTAssertEqual(counts.responding, 42, "HomeKit's responding count is shown as reported, not flipped")
    }

    func testNotRespondingNeedsAttention() {
        XCTAssertEqual(verdict(.someNotResponding(notResponding: 2, total: 42)), .needsAttention(counts(total: 42, notResponding: 2)))
    }

    /// Reads still under way are shown as such — never as a failure, and never as fine.
    func testReadsInProgressAreNeitherFineNorFailures() {
        XCTAssertEqual(verdict(.allResponding(total: 42), retrying: 5), .retrying(counts(total: 42, retrying: 5)))
        XCTAssertEqual(verdict(.allResponding(total: 42), checking: 3), .checking(counts(total: 42, checking: 3)))
        XCTAssertEqual(
            verdict(.allResponding(total: 42), checking: 3, retrying: 5),
            .retrying(counts(total: 42, retrying: 5, checking: 3)),
            "a retry is the more telling of the two"
        )
    }

    /// Attention wins over reads in progress, and every count stays on the card.
    func testEveryCountStaysSeparateWhenSeveralApply() {
        XCTAssertEqual(
            verdict(.someNotResponding(notResponding: 2, total: 42), checking: 1, retrying: 3, failed: 5),
            .needsAttention(counts(total: 42, notResponding: 2, readFailed: 5, retrying: 3, checking: 1))
        )
        XCTAssertEqual(
            verdict(.allResponding(total: 42), checking: 1, retrying: 3, failed: 5),
            .needsAttention(counts(total: 42, readFailed: 5, retrying: 3, checking: 1))
        )
    }

    /// Unavailable, no access, no home and no devices keep their own states, whatever reads say.
    func testStatesWithoutReadableDevicesAreKept() {
        for state in [AppleHomeAccessState.off, .loading, .denied, .restricted, .unsupported] {
            XCTAssertEqual(verdict(.unavailable(state), failed: 5), .unavailable(state), "\(state)")
        }
        XCTAssertEqual(verdict(.noHome, retrying: 1), .noHome)
        XCTAssertEqual(verdict(.noDevices, checking: 1), .noDevices)
    }

    /// From real accessories: a device that doesn't respond is counted once, as not responding,
    /// even with a read error left over; a responding one whose read failed counts as responding.
    @MainActor
    func testTheCardVerdictCountsEachDeviceOnce() {
        let accessories = [
            accessory("정상"),
            accessory("응답 없음, 이전 오류", reachable: false, error: "late", read: false),
            accessory("실패", error: "late", read: false),
            accessory("실패 2", error: "late", read: false),
            accessory("재시도", autoRead: .waiting(nextAttempt: 2, maxAttempts: 3), read: false),
            accessory("첫 읽기", autoRead: .reading(attempt: 1, maxAttempts: 3), read: false),
        ]
        let model = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: F.ready(accessories)), defaults: makeIsolatedDefaults())
        model.enable()
        let layout = model.layout(pogo: HomeSnapshot(timestamp: now, rooms: [], modules: []))
        let issues = AppleHomeIssueList.evaluate(layout.visibleAccessories)

        XCTAssertEqual(
            Verdict.evaluate(summary: AppleHomeStatusSummary.evaluate(state: .ready, layout: layout), valueCheck: AppleHomeValueCheckSummary.evaluate(issues)),
            .needsAttention(counts(total: 6, notResponding: 1, readFailed: 2, retrying: 1, checking: 1))
        )
        XCTAssertEqual(issues.issues.count, 5, "the card's counts add up to the list it opens")
    }

    // MARK: - Detail navigation

    /// The lists open the existing detail screens through the existing routes, with the row's
    /// own id — never an id from the other source.
    @MainActor
    func testRowsOpenTheExistingDetailScreens() throws {
        let pogo = snapshot()
        let item = try XCTUnwrap(DashboardMetrics.attentionItems(pogo, health: .attentionNeeded)?.first)
        XCTAssertEqual(item.detailRoute, AppRoute.module(item.module.id))
        let group = try XCTUnwrap(DashboardMetrics.readingGroups(pogo).first)
        XCTAssertEqual(group.detailRoute, AppRoute.module(group.module.id))

        let failed = accessory("실패", error: "late", read: false)
        let issue = try XCTUnwrap(AppleHomeIssueList.evaluate([failed]).issues.first)
        XCTAssertEqual(issue.detailRoute, AppleHomeRoute.accessory(failed.id))
    }
}
