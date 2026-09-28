import XCTest
@testable import PogoHome

/// Automatic Apple Home reads (`AppleHomeAutoReader`): a transient failure of the first read is
/// retried without a tap, a lasting one ends as a failure after a bounded number of attempts,
/// and a large home is read a few accessories at a time.
@MainActor
final class AppleHomeAutoReaderTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    private let policy = AppleHomeAutoReader.Policy(maxConcurrentReads: 4, retryDelays: [.seconds(3), .seconds(10)])
    private let timedOut = AppleHomeReadFailure(error: .timedOut, diagnosticCode: "deadline")

    private func makeReader(_ reads: ScriptedReads, sleeper: ManualSleeper? = nil) -> AppleHomeAutoReader {
        let sleep: AppleHomeAutoReader.Sleep
        if let sleeper {
            sleep = { try await sleeper.sleep($0) }
        } else {
            sleep = { _ in await Task.yield() }
        }
        return AppleHomeAutoReader(policy: policy, sleep: sleep) { await reads.read($0) }
    }

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: - Recovery

    func testATimedOutFirstReadIsRetriedAndRecoversWithoutATap() async {
        let reads = ScriptedReads()
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)
        var changes = 0
        reader.onChange = { changes += 1 }
        let id = UUID()

        reader.sync(readableIDs: [id])
        XCTAssertEqual(reader.states[id], .reading(attempt: 1, maxAttempts: 3))
        let started = await waitUntil { reads.pending.count == 1 }
        XCTAssertTrue(started)
        reads.resolve(id, with: timedOut)

        let waitingToRetry = await waitUntil { sleeper.requested.count == 1 }
        XCTAssertTrue(waitingToRetry)
        XCTAssertEqual(reader.states[id], .waiting(nextAttempt: 2, maxAttempts: 3), "retrying, not settled as failed")
        XCTAssertEqual(sleeper.requested, [.seconds(3)])

        sleeper.fireAll()
        let retried = await waitUntil { reads.pending.count == 1 }
        XCTAssertTrue(retried)
        XCTAssertEqual(reader.states[id], .reading(attempt: 2, maxAttempts: 3))
        reads.resolve(id, with: nil)

        let settled = await waitUntil { reader.states.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(reads.calls, [id, id])
        XCTAssertGreaterThan(changes, 0, "the provider republishes on every step")

        reader.sync(readableIDs: [id])
        XCTAssertEqual(reads.calls.count, 2, "a settled accessory isn't read again on the next HomeKit update")
    }

    func testAnEarlyHomeKitAccessReadErrorRecoversWithoutOpeningTheAccessory() async {
        let reads = ScriptedReads()
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)
        let id = UUID()

        reader.sync(readableIDs: [id])
        _ = await waitUntil { reads.pending.count == 1 }
        reads.resolve(id, with: AppleHomeReadFailure(error: .accessNotReady, diagnosticCode: "HMErrorDomain:access"))

        let waiting = await waitUntil { sleeper.hasWaiting }
        XCTAssertTrue(waiting)
        XCTAssertEqual(reader.states[id], .waiting(nextAttempt: 2, maxAttempts: 3))
        sleeper.fireAll()
        _ = await waitUntil { reads.pending.count == 1 }
        reads.resolve(id, with: nil)

        let settled = await waitUntil { reader.states.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(reads.calls, [id, id])
    }

    func testALastingFailureStopsAfterTheLastAttemptAndIsNotRetriedForever() async {
        let reads = ScriptedReads()
        reads.answer = { _, _ in AppleHomeReadFailure(error: .timedOut, diagnosticCode: "deadline") }
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)
        let id = UUID()

        reader.sync(readableIDs: [id])
        for expectedSleeps in 1...2 {
            let waiting = await waitUntil { sleeper.requested.count == expectedSleeps && sleeper.hasWaiting }
            XCTAssertTrue(waiting)
            sleeper.fireAll()
        }
        let done = await waitUntil { reader.states.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(reads.calls.count, 3, "three attempts in all")
        XCTAssertEqual(sleeper.requested, [.seconds(3), .seconds(10)])

        reader.sync(readableIDs: [id])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads.calls.count, 3, "given up until it drops out and comes back, or the user reads it")
        XCTAssertFalse(sleeper.hasWaiting)
    }

    func testAFailureThatARetryWontFixIsNotRetried() async {
        let reads = ScriptedReads()
        reads.answer = { _, _ in AppleHomeReadFailure(error: .characteristicNotFound, diagnosticCode: "x") }
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)

        reader.sync(readableIDs: [UUID()])
        let done = await waitUntil { reader.states.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(reads.calls.count, 1)
        XCTAssertTrue(sleeper.requested.isEmpty)
    }

    func testASuccessfulReadByTheUserMakesAPendingRetryUnnecessary() async {
        let reads = ScriptedReads()
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)
        let id = UUID()
        reader.sync(readableIDs: [id])
        _ = await waitUntil { reads.pending.count == 1 }
        reads.resolve(id, with: timedOut)
        _ = await waitUntil { sleeper.hasWaiting }

        reader.noteRead(id, succeeded: false)
        XCTAssertEqual(reader.states[id], .waiting(nextAttempt: 2, maxAttempts: 3), "a failed tap leaves the retry in place")
        reader.noteRead(id, succeeded: true)
        XCTAssertNil(reader.states[id])

        sleeper.fireAll()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads.calls.count, 1)
    }

    // MARK: - Many accessories

    func testFortyTwoAccessoriesAreReadAFewAtATimeAndEachOnce() async {
        let reads = ScriptedReads()
        let reader = makeReader(reads)
        let all = ids(42)

        reader.sync(readableIDs: all)
        let firstBatch = await waitUntil { reads.pending.count == 4 }
        XCTAssertTrue(firstBatch)
        XCTAssertEqual(reads.calls, Array(all.prefix(4)), "in the given order, four at a time")
        XCTAssertEqual(all.dropFirst(4).map { reader.states[$0] }, Array(repeating: .waiting(nextAttempt: 1, maxAttempts: 3), count: 38))

        while let next = reads.pending.first {
            reads.resolve(next, with: nil)
            _ = await waitUntil { reads.pending.count == min(4, 42 - reads.finished) }
        }
        let done = await waitUntil { reader.states.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(reads.calls.count, 42)
        XCTAssertEqual(Set(reads.calls), Set(all))
        XCTAssertEqual(reads.peakInFlight, 4)
    }

    func testFortyTwoTimedOutFirstReadsAllRecoverWithoutExceedingTheLimit() async {
        let reads = ScriptedReads()
        // Like the Mac's home hub answering the first, crowded round too late.
        reads.answer = { _, attempt in attempt == 1 ? AppleHomeReadFailure(error: .timedOut, diagnosticCode: "deadline") : nil }
        let reader = makeReader(reads)
        let all = ids(42)

        reader.sync(readableIDs: all)
        let done = await waitUntil { reader.states.isEmpty && reads.calls.count == 84 }
        XCTAssertTrue(done, "calls \(reads.calls.count), still pending \(reader.states.count)")
        XCTAssertLessThanOrEqual(reads.peakInFlight, 4)
        XCTAssertEqual(Set(reads.calls), Set(all))
    }

    // MARK: - Accessories coming and going

    func testAnAccessoryThatStopsRespondingIsReadAgainWhenItIsBack() async {
        let reads = ScriptedReads()
        reads.answer = { _, _ in nil }
        let reader = makeReader(reads)
        let id = UUID()
        reader.sync(readableIDs: [id])
        _ = await waitUntil { reader.states.isEmpty }

        reader.sync(readableIDs: [])
        reader.sync(readableIDs: [id])
        let reread = await waitUntil { reads.calls.count == 2 && reader.states.isEmpty }
        XCTAssertTrue(reread)

        reader.markStale(id)
        reader.sync(readableIDs: [id])
        let staleReread = await waitUntil { reads.calls.count == 3 && reader.states.isEmpty }
        XCTAssertTrue(staleReread)
    }

    func testAnAccessoryThatDropsOutWhileWaitingToRetryIsNotRetried() async {
        let reads = ScriptedReads()
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)
        let id = UUID()
        reader.sync(readableIDs: [id])
        _ = await waitUntil { reads.pending.count == 1 }
        reads.resolve(id, with: timedOut)
        _ = await waitUntil { sleeper.hasWaiting }

        reader.sync(readableIDs: [])
        XCTAssertNil(reader.states[id])
        sleeper.fireAll()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads.calls.count, 1)
    }

    func testResetDiscardsReadsStillRunning() async {
        let reads = ScriptedReads()
        let sleeper = ManualSleeper()
        let reader = makeReader(reads, sleeper: sleeper)
        let all = ids(6)
        reader.sync(readableIDs: all)
        _ = await waitUntil { reads.pending.count == 4 }

        reader.reset()
        XCTAssertTrue(reader.states.isEmpty)
        for id in reads.pending { reads.resolve(id, with: timedOut) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(reader.states.isEmpty)
        XCTAssertEqual(reads.calls.count, 4, "nothing queued before the reset starts afterwards")
        XCTAssertTrue(sleeper.requested.isEmpty, "no retry for a read that ended after the reset")
    }

    // MARK: - What the tiles and the Dashboard say

    private func light(
        id: UUID = F.lightID,
        error: String? = nil,
        autoRead: AppleHomeAutoReadState? = nil,
        read: Bool = true,
        reachable: Bool = true
    ) -> AppleHomeAccessory {
        let base = F.light(power: read ? .bool(true) : nil, brightness: read ? .int(40) : nil, reachable: reachable)
        return AppleHomeAccessory(
            id: id, homeID: base.homeID, name: base.name, roomID: base.roomID, roomName: base.roomName,
            isReachable: base.isReachable, isMatter: true, services: base.services,
            lastReadError: error, autoRead: autoRead
        )
    }

    private var nothingToRead: AppleHomeAccessory {
        AppleHomeAccessory(
            id: UUID(), homeID: F.homeID, name: "Button", isReachable: true,
            services: [AppleHomeService(id: UUID(), kind: .other, name: "", characteristics: [], unsupportedCharacteristicCount: 2)]
        )
    }

    func testValueStatusKeepsNothingToReadPendingRetryingAndFailedApart() {
        XCTAssertEqual(AppleHomeValueStatus.resolve(nothingToRead), .nothingToRead)
        XCTAssertEqual(AppleHomeValueStatus.resolve(light(autoRead: .waiting(nextAttempt: 1, maxAttempts: 3), read: false)), .checking)
        XCTAssertEqual(AppleHomeValueStatus.resolve(light(autoRead: .reading(attempt: 1, maxAttempts: 3), read: false)), .checking)
        XCTAssertEqual(
            AppleHomeValueStatus.resolve(light(error: "late", autoRead: .waiting(nextAttempt: 2, maxAttempts: 3), read: false)),
            .retrying(attempt: 2, maxAttempts: 3)
        )
        XCTAssertEqual(AppleHomeValueStatus.resolve(light(error: "late", read: false)), .failed("late"))
        XCTAssertEqual(AppleHomeValueStatus.resolve(light()), .checked(F.readAt))
        XCTAssertEqual(AppleHomeValueStatus.resolve(light(read: false)), .notChecked)
    }

    func testANeverReadValueIsNotShownAsCurrent() {
        let pending = light(autoRead: .reading(attempt: 1, maxAttempts: 3), read: false)
        let model = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: F.ready([pending])), defaults: makeIsolatedDefaults())
        model.enable()
        let quick = model.quickControl(for: pending)
        guard case .needsStateCheck = quick else { return XCTFail("\(quick)") }
        XCTAssertEqual(
            AppleHomeTileText.state(of: pending, quick: quick, pending: nil, isReading: true),
            String(localized: "상태 확인 중…", comment: "Apple Home tile: reading the device's state")
        )
    }

    func testTheTileShowsARetryAsProgressAndOnlyTheFinalFailureAsAProblem() {
        let retrying = light(error: "late", autoRead: .waiting(nextAttempt: 2, maxAttempts: 3), read: false)
        let quick = AppleHomeQuickControl.resolve(retrying, isAccessReady: true) { $0.confirmedValue }
        XCTAssertNil(AppleHomeTileText.problem(of: retrying, quick: quick, messages: [:]))
        XCTAssertEqual(AppleHomeTileText.readProgress(of: retrying), AppleHomeText.retrying(attempt: 2, maxAttempts: 3))

        let failed = light(error: "late", read: false)
        XCTAssertNotNil(AppleHomeTileText.problem(of: failed, quick: quick, messages: [:]), "a lasting failure stays visible")
        XCTAssertNil(AppleHomeTileText.readProgress(of: failed))

        XCTAssertNotEqual(AppleHomeText.valueCheckLine(of: nothingToRead), AppleHomeText.lastChecked(nil), "no value to read isn't 'not read yet'")
    }

    func testRespondingAndValueReadsAreCountedSeparately() {
        let accessories = [
            light(id: UUID(), error: "late", read: false),
            AppleHomeFixtures.sensor(),
            light(id: UUID(), autoRead: .waiting(nextAttempt: 1, maxAttempts: 3), read: false),
            light(id: UUID(), error: "late", read: false, reachable: false),
        ]
        XCTAssertEqual(
            AppleHomeValueCheckSummary.evaluate(accessories),
            AppleHomeValueCheckSummary(checking: 1, failed: 1),
            "an accessory that doesn't respond is counted as not responding, not as a read failure"
        )
        let model = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: F.ready(Array(accessories.prefix(3)))), defaults: makeIsolatedDefaults())
        model.enable()
        let layout = model.layout(pogo: HomeSnapshot(timestamp: .now, rooms: [], modules: []))
        XCTAssertEqual(layout.visibleAccessories.count, 3)
        XCTAssertEqual(
            AppleHomeStatusSummary.evaluate(state: .ready, layout: layout),
            .allResponding(total: layout.visibleAccessories.count),
            "a timed-out value read doesn't make HomeKit's reachability 'not responding'"
        )
    }

    func testAReadTimeOutIsWordedAsAValueReadNotAsTheDeviceNotResponding() {
        XCTAssertNotEqual(AppleHomeModel.readMessage(for: AppleHomeProviderError.timedOut), AppleHomeModel.message(for: AppleHomeProviderError.timedOut))
        XCTAssertEqual(AppleHomeModel.readMessage(for: AppleHomeProviderError.notReachable), AppleHomeModel.message(for: AppleHomeProviderError.notReachable))
    }
}

/// Reads whose outcome the test decides: answered at once by `answer`, or held until `resolve`.
@MainActor
final class ScriptedReads {
    /// `(accessory, attempt number for it)` → failure or `nil` for success.
    var answer: ((UUID, Int) -> AppleHomeReadFailure?)?
    private(set) var calls: [UUID] = []
    private(set) var peakInFlight = 0
    private(set) var finished = 0
    private var inFlight = 0
    private var held: [(id: UUID, continuation: CheckedContinuation<AppleHomeReadFailure?, Never>)] = []

    var pending: [UUID] { held.map(\.id) }

    func read(_ id: UUID) async -> AppleHomeReadFailure? {
        calls.append(id)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer {
            inFlight -= 1
            finished += 1
        }
        if let answer {
            await Task.yield()
            return answer(id, calls.filter { $0 == id }.count)
        }
        return await withCheckedContinuation { held.append((id, $0)) }
    }

    func resolve(_ id: UUID, with failure: AppleHomeReadFailure?) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        held.remove(at: index).continuation.resume(returning: failure)
    }
}

/// A retry pause that ends only when the test says so.
@MainActor
final class ManualSleeper {
    private(set) var requested: [Duration] = []
    private var gates: [CheckedContinuation<Void, Never>] = []

    var hasWaiting: Bool { !gates.isEmpty }

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        await withCheckedContinuation { gates.append($0) }
    }

    func fireAll() {
        let fired = gates
        gates = []
        fired.forEach { $0.resume() }
    }
}
