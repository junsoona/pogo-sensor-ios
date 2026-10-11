#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import XCTest
@testable import PogoHome

/// Made-up boards and codes for the QR tests: two of the public vectors of the firmware
/// repository's `tools/power_base_setup_qr_vectors.json`. None belongs to a board.
enum SetupQRFixtures {
    /// The board the other fakes use (`EnrollmentFixtures.eui64`) and its made-up code.
    static let eui64 = EnrollmentFixtures.eui64
    static let setupCode = EnrollmentFixtures.setupCode
    static let text = "POGO-PB:1:" + eui64 + ":" + setupCode
    /// Another board, with another code.
    static let otherEUI64 = "00124b0001a2b3d9"
    static let otherSetupCode = "LJNFUWS2LJNFUWS2LJNFUWS2A4"
    static let otherText = "POGO-PB:1:" + otherEUI64 + ":" + otherSetupCode

    /// `FakeBLEBoardProvider.boardID`.
    static let boardID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let otherBoardID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    static let target = PowerBaseSetupQRIntake.Target(boardID: boardID, boardEUI64: eui64)
    static let otherTarget = PowerBaseSetupQRIntake.Target(boardID: otherBoardID, boardEUI64: otherEUI64)

    static var payload: PowerBaseSetupQRPayload { try! PowerBaseSetupQRPayload(parsing: text) }
    static var otherPayload: PowerBaseSetupQRPayload { try! PowerBaseSetupQRPayload(parsing: otherText) }
}

/// A camera whose every step the test decides: whether there is one, what the permission is and
/// when the question is answered, when a start finishes, and what a frame shows.
@MainActor
final class FakeQRCameraProvider: PowerBaseSetupQRCameraProviding {
    var hasCamera = true
    var access = PowerBaseSetupQRCameraAccess.authorized
    /// What the user answers to the permission question.
    var grantsAccess = true
    var startSucceeds = true
    /// The permission question stays open until `answerAccess()`.
    var holdsAccess = false
    /// A start does not finish until `finishStarts()`.
    var holdsStart = false

    private(set) var accessRequests = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var isRunning = false
    private var handler: (@Sendable ([String?]) -> Void)?
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var pendingAccessRequests: Int { accessWaiters.count }
    var pendingStarts: Int { startWaiters.count }

    func requestAccess() async -> Bool {
        accessRequests += 1
        if holdsAccess { await withCheckedContinuation { accessWaiters.append($0) } }
        access = grantsAccess ? .authorized : .denied
        return grantsAccess
    }

    func answerAccess() {
        holdsAccess = false
        let waiting = accessWaiters
        accessWaiters = []
        waiting.forEach { $0.resume() }
    }

    func start(onSymbols: @escaping @Sendable ([String?]) -> Void) async -> Bool {
        starts += 1
        let stopsBefore = stops
        if holdsStart { await withCheckedContinuation { startWaiters.append($0) } }
        // Like the capture engine: a start that was overtaken by a stop leaves the camera off.
        guard stops == stopsBefore, startSucceeds else { return false }
        handler = onSymbols
        isRunning = true
        return true
    }

    func finishStarts() {
        holdsStart = false
        let waiting = startWaiters
        startWaiters = []
        waiting.forEach { $0.resume() }
    }

    func stop() {
        stops += 1
        isRunning = false
        handler = nil
    }

    let previewSource: AnyObject? = nil

    /// What the camera that runs now reports to. A test keeps it to report "late", after that
    /// camera was stopped.
    var currentHandler: (@Sendable ([String?]) -> Void)? { handler }

    /// One frame with these QR codes in view. Nothing happens while the camera is off.
    func show(_ symbols: String?...) {
        show(symbols)
    }

    func show(_ symbols: [String?]) {
        handler?(symbols)
    }
}

extension PowerBaseSetupQRIntake {
    /// A picture's scan at the point where the chosen picture is being read: the row was tapped
    /// (the scan begins there), its picker returned a choice and closed.
    func beginReadingImage(_ picker: ImagePicker = .photos, for target: Target?, apply: @escaping (PowerBaseSetupQRPayload) -> Bool) -> Ticket? {
        guard let ticket = begin(.image(picker), for: target, apply: apply) else { return nil }
        guard imagePickerDidChoose(ticket) else { return nil }
        imagePickerDidClose(ticket)
        return ticket
    }
}

extension PowerBaseSetupQRRows {
    /// The same through the row's own tap, into a screen's field.
    @MainActor
    static func beginReadingImage(
        intake: PowerBaseSetupQRIntake, target: PowerBaseSetupQRIntake.Target?, field: Binding<PowerBaseSetupCodeField>
    ) -> PowerBaseSetupQRIntake.Ticket? {
        guard let ticket = begin(.image(imagePicker), intake: intake, target: target, field: field), intake.imagePickerDidChoose(ticket) else { return nil }
        intake.imagePickerDidClose(ticket)
        return ticket
    }
}

/// A picture that is loaded when the test says so.
final class FakeImageLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var waiting: [CheckedContinuation<PowerBaseSetupQRReading, Never>] = []

    /// How often loading was started at all.
    var starts: Int { lock.withLock { startCount } }
    var pending: Int { lock.withLock { waiting.count } }

    func load() async -> PowerBaseSetupQRReading {
        await withCheckedContinuation { continuation in
            lock.withLock {
                startCount += 1
                waiting.append(continuation)
            }
        }
    }

    /// Every load that waits gets `reading`.
    func finish(_ reading: PowerBaseSetupQRReading) {
        let continuations = lock.withLock {
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume(returning: reading) }
    }
}

/// Where the tests' scans put a code: a field like a screen's, and how often it was written.
@MainActor
final class QRFieldBox {
    var field = PowerBaseSetupCodeField()
    private(set) var fills = 0
    private(set) var offers = 0

    func apply(_ payload: PowerBaseSetupQRPayload) -> Bool {
        offers += 1
        guard field.fill(from: payload) else { return false }
        fills += 1
        return true
    }

    /// The field as a screen hands it to the rows. A scan's code arrives through it: every
    /// arrival is counted as an offer, and one that changed the field as a fill.
    var binding: Binding<PowerBaseSetupCodeField> {
        Binding(get: { self.field }, set: { newValue in
            self.offers += 1
            if newValue != self.field { self.fills += 1 }
            self.field = newValue
        })
    }
}

// MARK: - The field: a code and the board it belongs to

@MainActor
final class PowerBaseSetupCodeFieldTests: XCTestCase {
    private typealias F = SetupQRFixtures

    func testATypedCodeBelongsToWhicheverBoardIsSelected() {
        var field = PowerBaseSetupCodeField(typed: F.setupCode)
        XCTAssertNil(field.codeBoardEUI64)
        XCTAssertEqual(field.codeForSelectedBoard, F.setupCode, "as before: a typed code is there before a board is")
        field.select(boardEUI64: F.eui64)
        field.select(boardEUI64: F.otherEUI64)
        field.select(boardEUI64: nil)
        XCTAssertEqual(field.text, F.setupCode, "a typed code is the user's to keep across selections, as before")
        XCTAssertEqual(field.codeForSelectedBoard, F.setupCode)
    }

    func testAQRCodeIsTakenOnlyForTheBoardSelectedAtThatMoment() {
        var field = PowerBaseSetupCodeField(typed: "MFRG")
        XCTAssertFalse(field.fill(from: F.payload), "no board is selected")
        XCTAssertEqual(field.text, "MFRG")
        field.select(boardEUI64: F.otherEUI64)
        XCTAssertFalse(field.fill(from: F.payload), "another board is selected")
        XCTAssertEqual(field.text, "MFRG", "what was typed is kept")
        XCTAssertEqual(field.selectedBoardEUI64, F.otherEUI64, "and the selection is not moved to the code's board")
        XCTAssertNil(field.codeBoardEUI64)

        field.select(boardEUI64: F.eui64)
        XCTAssertTrue(field.fill(from: F.payload))
        XCTAssertEqual(field.text, F.setupCode)
        XCTAssertEqual(field.codeBoardEUI64, F.eui64)
        XCTAssertEqual(field.codeForSelectedBoard, F.setupCode)
    }

    func testACodeFromAQRCodeDoesNotFollowTheSelectionToAnotherBoard() {
        var field = PowerBaseSetupCodeField()
        field.select(boardEUI64: F.eui64)
        XCTAssertTrue(field.fill(from: F.payload))
        // Looking again, or the same board picked again: the code is still that board's.
        field.select(boardEUI64: nil)
        XCTAssertEqual(field.text, F.setupCode)
        XCTAssertNil(field.codeForSelectedBoard, "with nothing selected there is no board to send it to")
        field.select(boardEUI64: F.eui64)
        XCTAssertEqual(field.codeForSelectedBoard, F.setupCode)
        // Another board: dropped, not carried over.
        field.select(boardEUI64: F.otherEUI64)
        XCTAssertEqual(field.text, "")
        XCTAssertNil(field.codeBoardEUI64)
        XCTAssertEqual(field.codeForSelectedBoard, "")
        // And it does not come back with the first board.
        field.select(boardEUI64: F.eui64)
        XCTAssertEqual(field.text, "")
    }

    func testEditingACodeFromAQRCodeMakesItATypedCode() {
        var field = PowerBaseSetupCodeField()
        field.select(boardEUI64: F.eui64)
        XCTAssertTrue(field.fill(from: F.payload))
        // The text field writes the same text back (focus, layout): nothing changes.
        field.edit(F.setupCode)
        XCTAssertEqual(field.codeBoardEUI64, F.eui64)
        // One character changed: it is what the user typed now, and no board is remembered.
        field.edit(String(F.setupCode.dropLast()) + "E")
        XCTAssertNil(field.codeBoardEUI64)
        field.select(boardEUI64: F.otherEUI64)
        XCTAssertEqual(field.text, String(F.setupCode.dropLast()) + "E", "a typed code stays with the user")
        // Cleared (the hub confirmed): nothing is left of the board either.
        field.select(boardEUI64: F.eui64)
        XCTAssertTrue(field.fill(from: F.payload))
        field.edit("")
        XCTAssertEqual(field, { var empty = PowerBaseSetupCodeField(); empty.select(boardEUI64: F.eui64); return empty }())
    }

    /// Swift calls "K" and U+212A KELVIN SIGN equal. A field that compared characters would keep
    /// the board for a text that is no longer the QR code's.
    func testAnEditThatOnlyLooksTheSameIsStillAnEdit() {
        var field = PowerBaseSetupCodeField()
        field.select(boardEUI64: F.eui64)
        XCTAssertTrue(field.fill(from: F.payload))
        let lookAlike = F.setupCode.replacingOccurrences(of: "K", with: "\u{212A}")
        XCTAssertEqual(lookAlike, F.setupCode)
        field.edit(lookAlike)
        XCTAssertNil(field.codeBoardEUI64)
        XCTAssertEqual(Array(field.text.utf8), Array(lookAlike.utf8))
    }

    func testNothingThatPrintsAFieldOrAHandoffShowsTheCode() throws {
        var field = PowerBaseSetupCodeField()
        field.select(boardEUI64: F.eui64)
        XCTAssertTrue(field.fill(from: F.payload))
        let handoff = try XCTUnwrap(PowerBaseSetupCodeHandoff(code: F.setupCode, boardEUI64: F.eui64))
        let form = PowerBaseSetupForm.starting(with: handoff)
        let reading = PowerBaseSetupQRReading.symbols([F.text, nil])
        var dumped = ""
        dump(field, to: &dumped)
        dump(handoff, to: &dumped)
        dump(form, to: &dumped)
        dump(reading, to: &dumped)
        let shown = ["\(field)", String(reflecting: field), "\(handoff)", String(reflecting: handoff), "\(form)", String(reflecting: form), "\(reading)",
                     String(reflecting: reading), "\(PowerBaseSetupQRIntake.Completion.refused(.differentBoard))", dumped]
        for text in shown {
            XCTAssertFalse(text.contains(F.setupCode), text)
            XCTAssertFalse(text.contains("POGO-PB:1"), text)
            XCTAssertFalse(text.contains(F.eui64), text)
        }
    }
}

// MARK: - The hand-over from "다른 허브에 연결하기" to the registration

@MainActor
final class PowerBaseSetupCodeHandoffTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias P = PowerBaseReenrollPresentation

    func testTheCodeIsHandedOverForTheAuthenticatedBoardOnly() throws {
        // Typed there.
        let typed = PowerBaseSetupCodeField(typed: F.setupCode)
        let fromTyped = try XCTUnwrap(P.handoff(code: typed, authenticatedBoard: F.eui64))
        XCTAssertEqual(fromTyped.code, F.setupCode)
        XCTAssertEqual(fromTyped.boardEUI64, F.eui64)
        // Read from the board's QR code there.
        var scanned = PowerBaseSetupCodeField()
        scanned.select(boardEUI64: F.eui64)
        XCTAssertTrue(scanned.fill(from: F.payload))
        XCTAssertEqual(P.handoff(code: scanned, authenticatedBoard: F.eui64), fromTyped)

        // Nothing is handed over without a board that was authenticated,
        XCTAssertNil(P.handoff(code: typed, authenticatedBoard: nil))
        XCTAssertNil(P.handoff(code: typed, authenticatedBoard: ""))
        XCTAssertNil(P.handoff(code: typed, authenticatedBoard: F.eui64.uppercased()), "not the form boards advertise")
        XCTAssertNil(P.handoff(code: typed, authenticatedBoard: String(repeating: "0", count: 16)))
        // for a code that is another board's,
        XCTAssertNil(P.handoff(code: scanned, authenticatedBoard: F.otherEUI64))
        // or for a field that holds no setup code any more.
        XCTAssertNil(P.handoff(code: PowerBaseSetupCodeField(), authenticatedBoard: F.eui64))
        XCTAssertNil(P.handoff(code: PowerBaseSetupCodeField(typed: "MFRGGZDF"), authenticatedBoard: F.eui64))
    }

    func testTheRegistrationScreenShowsAHandedOverCodeOnlyForThatBoard() throws {
        let handoff = try XCTUnwrap(PowerBaseSetupCodeHandoff(code: F.setupCode, boardEUI64: F.eui64))
        let board = PowerBaseBLEDiscoveredBoard(id: F.boardID, name: nil, advertisedEUI64: F.eui64, rssi: -50)
        let other = PowerBaseBLEDiscoveredBoard(id: F.otherBoardID, name: nil, advertisedEUI64: F.otherEUI64, rssi: -40)

        // The same board is picked: the code is there, ready, and still the user's to change.
        var same = PowerBaseSetupForm.starting(with: handoff)
        XCTAssertFalse(same.didStartFinding, "nothing is looked for or selected by the hand-over")
        XCTAssertNil(same.selectedBoardID)
        XCTAssertNil(same.code.codeForSelectedBoard, "before a board is picked there is nothing to send")
        same.select(board)
        XCTAssertEqual(same.setupCode, F.setupCode)
        XCTAssertEqual(same.code.codeForSelectedBoard, F.setupCode)

        // Another board is picked -- the stronger signal, a slip of the finger: the code is gone.
        var different = PowerBaseSetupForm.starting(with: handoff)
        different.select(other)
        XCTAssertEqual(different.setupCode, "")
        XCTAssertEqual(different.code.codeForSelectedBoard, "")
        different.select(board)
        XCTAssertEqual(different.setupCode, "", "and it is not put back")

        // A selection made around `select` (state restored, a test) is no way in either.
        var forced = PowerBaseSetupForm.starting(with: handoff)
        forced.selectedBoardID = F.otherBoardID
        XCTAssertNil(forced.code.codeForSelectedBoard)

        // Nothing handed over: empty, as before.
        XCTAssertEqual(PowerBaseSetupForm.starting(with: nil), PowerBaseSetupForm())
    }
}

// MARK: - One look: what it says about the selected board

@MainActor
final class PowerBaseSetupQREvaluationTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private func problem(_ symbols: [String?], for target: Intake.Target = F.target) -> Intake.Problem? {
        guard case let .failure(problem)? = Intake.evaluate(.symbols(symbols), for: target) else { return nil }
        return problem
    }

    private func code(_ symbols: [String?], for target: Intake.Target = F.target) -> String? {
        guard case let .success(payload)? = Intake.evaluate(.symbols(symbols), for: target) else { return nil }
        return payload.setupCode
    }

    func testOnlyTheSelectedBoardsOwnCodeIsTaken() {
        XCTAssertEqual(code([F.text]), F.setupCode)
        XCTAssertEqual(problem([F.otherText]), .differentBoard)
        XCTAssertEqual(code([F.otherText], for: F.otherTarget), F.otherSetupCode)
        XCTAssertNil(Intake.evaluate(.symbols([]), for: F.target), "nothing in view is not a problem by itself")
    }

    func testOtherKindsOfCodesAreNotTaken() {
        for other in [F.setupCode, F.eui64, "https://example.com/" + F.text, "MT:Y.K9042C00KA0648G00", "X-HM://0024Y2S8X1ABC", "ABCD-EFGH-JKLM",
                      "pogohome://powerbase/" + F.eui64, " " + F.text, ""] {
            XCTAssertEqual(problem([other]), .notPowerBaseCode, other)
        }
        XCTAssertEqual(problem([nil]), .notPowerBaseCode, "a QR code without text")
        XCTAssertEqual(problem(["POGO-PB:2:" + F.eui64 + ":" + F.setupCode]), .unsupportedVersion)
        XCTAssertEqual(problem([F.text.lowercased()]), .notPowerBaseCode)
        for damaged in [F.text + "\n", F.text + ":1", "POGO-PB:1:" + F.eui64 + ":" + F.setupCode.lowercased(), "POGO-PB:1:" + F.eui64.uppercased() + ":" + F.setupCode,
                        String(F.text.dropLast()) + "B", String(F.text.dropLast())] {
            XCTAssertEqual(problem([damaged]), .damagedCode, damaged)
        }
        XCTAssertEqual(Intake.evaluate(.unreadableImage, for: F.target).flatMap { try? $0.get() }, nil)
        guard case .failure(.unreadableImage)? = Intake.evaluate(.unreadableImage, for: F.target),
              case .failure(.imageTooLarge)? = Intake.evaluate(.imageTooLarge, for: F.target) else { return XCTFail("image failures") }
    }

    func testSeveralDifferentCodesInViewAreNeverChosenBetween() {
        // The right one next to anything else: not taken, whichever comes first.
        XCTAssertEqual(problem([F.text, F.otherText]), .severalCodes)
        XCTAssertEqual(problem([F.otherText, F.text]), .severalCodes)
        XCTAssertEqual(problem([F.text, "https://example.com"]), .severalCodes)
        XCTAssertEqual(problem([F.text, nil]), .severalCodes)
        XCTAssertEqual(problem([F.text, F.text + "\n"]), .severalCodes)
        // The same code detected more than once is one code.
        XCTAssertEqual(code([F.text, F.text, F.text]), F.setupCode)
        XCTAssertEqual(problem([F.otherText, F.otherText]), .differentBoard)
        XCTAssertEqual(problem([nil, nil]), .notPowerBaseCode)
        // A string that Swift calls equal but is other bytes is another code.
        let lookAlike = F.text.replacingOccurrences(of: "K", with: "\u{212A}")
        XCTAssertEqual(lookAlike, F.text)
        XCTAssertEqual(problem([F.text, lookAlike]), .severalCodes)
        XCTAssertEqual(problem([lookAlike, F.text]), .severalCodes)
        XCTAssertEqual(problem([lookAlike]), .damagedCode)
    }

    /// The EUI-64 of one code is never put together with the setup code of another: the other
    /// board's code next to a broken code of the selected board gives nothing.
    func testNothingIsCombinedFromTwoCodes() {
        let eui64OfSelectedBoardOnly = "POGO-PB:1:" + F.eui64 + ":"
        XCTAssertEqual(problem([eui64OfSelectedBoardOnly, F.otherText]), .severalCodes)
        XCTAssertEqual(problem([eui64OfSelectedBoardOnly, F.otherSetupCode]), .severalCodes)
        XCTAssertNil(code([eui64OfSelectedBoardOnly, F.otherText]))
    }

    func testARemovalTakesOnlyTheRemovedBoardsCode() {
        let removed = Intake.Target(boardID: F.boardID, boardEUI64: F.eui64, requiredEUI64: F.eui64)
        XCTAssertTrue(removed.isUsable)
        XCTAssertEqual(code([F.text], for: removed), F.setupCode)
        XCTAssertEqual(problem([F.otherText], for: removed), .differentBoard)
        // A selected board that is not the removal's board is no target at all.
        let wrong = Intake.Target(boardID: F.otherBoardID, boardEUI64: F.otherEUI64, requiredEUI64: F.eui64)
        XCTAssertFalse(wrong.isUsable)
        XCTAssertEqual(problem([F.otherText], for: wrong), .differentBoard)
        XCTAssertEqual(problem([F.text], for: wrong), .differentBoard)
    }

    func testABoardWithoutAWellFormedIdentityIsNoTarget() {
        for eui64 in ["", "00124b0001a2b3c", F.eui64.uppercased(), String(repeating: "0", count: 16), "00124b0001a2b3cg", F.eui64 + "0"] {
            XCTAssertFalse(Intake.Target(boardID: F.boardID, boardEUI64: eui64).isUsable, eui64)
        }
        XCTAssertTrue(F.target.isUsable)
    }
}

// MARK: - A scan, and everything that can happen before its result arrives

@MainActor
final class PowerBaseSetupQRIntakeTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private var box: QRFieldBox!
    private var intake: Intake!

    override func setUp() async throws {
        box = QRFieldBox()
        box.field = PowerBaseSetupCodeField(typed: "TYPED")
        box.field.select(boardEUI64: F.eui64)
        intake = Intake(camera: nil)
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        intake.targetDidChange(F.target)
    }

    private func beginImage(for target: Intake.Target? = F.target) -> Intake.Ticket? {
        intake.beginReadingImage(for: target) { [box] in box!.apply($0) }
    }

    private func assertNothingEntered(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.field.text, "TYPED", message, file: file, line: line)
        XCTAssertEqual(box.fills, 0, message, file: file, line: line)
        XCTAssertNil(box.field.codeBoardEUI64, message, file: file, line: line)
    }

    func testTheSelectedBoardsCodeIsEnteredOnce() throws {
        let ticket = try XCTUnwrap(beginImage())
        XCTAssertEqual(intake.scan, ticket)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .applied)
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.field.codeBoardEUI64, F.eui64)
        XCTAssertNil(intake.scan)
        XCTAssertNil(intake.problem)
        XCTAssertTrue(intake.didFill)
        // The same result again, and again: the scan is over.
        box.field.edit("EDITED AFTERWARDS")
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(box.field.text, "EDITED AFTERWARDS", "a repeated callback does not write the field again")
        XCTAssertEqual(box.offers, 1)
    }

    func testEveryRefusalKeepsTheFieldAndSaysWhy() throws {
        let cases: [(PowerBaseSetupQRReading, Intake.Problem)] = [
            (.symbols([F.otherText]), .differentBoard), (.symbols([F.text, F.otherText]), .severalCodes), (.symbols(["https://example.com"]), .notPowerBaseCode),
            (.symbols([F.text + "\n"]), .damagedCode), (.symbols(["POGO-PB:9:" + F.eui64 + ":" + F.setupCode]), .unsupportedVersion),
            (.symbols([]), .noCodeInImage), (.unreadableImage, .unreadableImage), (.imageTooLarge, .imageTooLarge),
        ]
        for (reading, problem) in cases {
            let ticket = try XCTUnwrap(beginImage())
            XCTAssertNil(intake.problem, "a new scan starts without the last one's message")
            XCTAssertEqual(intake.complete(ticket, with: reading), .refused(problem))
            XCTAssertEqual(intake.problem, problem)
            XCTAssertNil(intake.scan, "an image is looked at once")
            XCTAssertFalse(intake.didFill)
            assertNothingEntered("\(problem)")
            XCTAssertEqual(box.field.selectedBoardEUI64, F.eui64, "the selection is never moved to a code's board")
            // The same image's result once more changes nothing either.
            XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        }
        assertNothingEntered()
        XCTAssertEqual(box.offers, 0)
        // Typing clears what was said about the last look.
        intake.fieldWasEdited()
        XCTAssertNil(intake.problem)
    }

    func testNoScanBeginsWithoutABoardToReadACodeFor() {
        XCTAssertNil(beginImage(for: nil), "no board is selected")
        XCTAssertNil(beginImage(for: Intake.Target(boardID: F.boardID, boardEUI64: "")), "a row without an EUI-64")
        XCTAssertNil(beginImage(for: Intake.Target(boardID: F.boardID, boardEUI64: String(repeating: "0", count: 16))))
        XCTAssertNil(beginImage(for: F.otherTarget), "not the board the code entry is shown for")
        XCTAssertNil(beginImage(for: Intake.Target(boardID: F.otherBoardID, boardEUI64: F.otherEUI64, requiredEUI64: F.eui64)))
        XCTAssertNil(intake.scan)

        intake.targetDidChange(nil)
        XCTAssertNil(beginImage(), "the code entry is not shown (a run is under way, a result is shown)")
        intake.targetDidChange(F.target)
        intake.sceneDidEnterBackground()
        XCTAssertNil(beginImage(), "in the background")
        intake.sceneDidBecomeActive()
        intake.screenDidDisappear()
        XCTAssertNil(beginImage(), "the screen is gone")
        XCTAssertNil(intake.scan)
        XCTAssertNil(intake.begin(.camera, for: F.target) { [box] in box!.apply($0) }, "there is no camera scan here (Mac)")

        let never = Intake(camera: nil)
        never.targetDidChange(F.target)
        XCTAssertNil(never.beginReadingImage(for: F.target) { _ in true }, "a screen that never appeared")
        assertNothingEntered()
    }

    // MARK: Late results

    func testAResultThatArrivesAfterTheScreenWasLeftChangesNothing() throws {
        let ticket = try XCTUnwrap(beginImage())
        intake.screenDidDisappear()
        XCTAssertNil(intake.scan)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        // Not even when the screen is shown again: that scan is over.
        intake.screenDidAppear()
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
        XCTAssertNil(intake.problem, "and nothing is said about a scan of a screen that was left")
        XCTAssertEqual(box.offers, 0)
    }

    func testAResultThatArrivesAfterTheUserCancelledChangesNothing() throws {
        let ticket = try XCTUnwrap(beginImage())
        intake.cancel()
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.otherText])), .ignored)
        assertNothingEntered()
        XCTAssertNil(intake.problem)
    }

    func testAResultThatArrivesAfterTheHubChangedChangesNothing() throws {
        let ticket = try XCTUnwrap(beginImage())
        intake.hubDidChange(EnrollmentFixtures.hubA)
        XCTAssertEqual(intake.scan, ticket, "the same hub told again is no change")
        intake.hubDidChange(EnrollmentFixtures.hubB)
        XCTAssertNil(intake.scan)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        intake.hubDidChange(EnrollmentFixtures.hubA)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored, "back on the first hub: still over")
        assertNothingEntered()
        // No hub any more (a typed address, simulated data): the same.
        let second = try XCTUnwrap(beginImage())
        intake.hubDidChange(nil)
        XCTAssertEqual(intake.complete(second, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
    }

    func testAResultThatArrivesAfterAnotherBoardWasSelectedChangesNothing() throws {
        // The screen tells the intake.
        var ticket = try XCTUnwrap(beginImage())
        box.field.select(boardEUI64: F.otherEUI64)
        intake.targetDidChange(F.otherTarget)
        XCTAssertNil(intake.scan)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.otherText])), .ignored, "nor the new board's code through the old scan")
        assertNothingEntered()

        // The screen has not told the intake yet (the tap and the result in the same moment):
        // the field knows the selection and has the last word.
        box.field.select(boardEUI64: F.eui64)
        intake.targetDidChange(F.target)
        ticket = try XCTUnwrap(beginImage())
        box.field.select(boardEUI64: F.otherEUI64)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(box.offers, 1, "offered, and refused by the field")
        assertNothingEntered()
        XCTAssertNil(intake.scan)
        XCTAssertFalse(intake.didFill)

        // Deselected ("다시 찾기") and the same board selected again: the old scan stays over.
        box.field.select(boardEUI64: F.eui64)
        intake.targetDidChange(F.target)
        ticket = try XCTUnwrap(beginImage())
        intake.targetDidChange(nil)
        intake.targetDidChange(F.target)
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
    }

    func testAResultOfAnEarlierScanDoesNotCountForALaterOne() throws {
        let first = try XCTUnwrap(beginImage())
        let second = try XCTUnwrap(beginImage())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(intake.complete(first, with: .symbols([F.text])), .ignored)
        XCTAssertEqual(intake.scan, second)
        assertNothingEntered()
        XCTAssertEqual(intake.complete(second, with: .symbols([F.otherText])), .refused(.differentBoard))
        XCTAssertEqual(intake.complete(first, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
    }

    func testAnImageResultThatArrivesInTheBackgroundIsNotEntered() throws {
        let ticket = try XCTUnwrap(beginImage())
        intake.sceneDidEnterBackground()
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
        XCTAssertNil(intake.scan, "the image was looked at once: that scan is over")
        XCTAssertEqual(intake.problem, .interrupted, "and the user is told to try again")
        // Back in the foreground the dropped result is not picked up.
        intake.sceneDidBecomeActive()
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
        XCTAssertEqual(box.offers, 0)
        // A new scan works as ever.
        let again = try XCTUnwrap(beginImage())
        XCTAssertEqual(intake.complete(again, with: .symbols([F.text])), .applied)
        XCTAssertEqual(box.field.text, F.setupCode)
    }

    func testARemovalsScanEndsWhenTheSelectionIsNoLongerTheRemovedBoard() throws {
        let removed = Intake.Target(boardID: F.boardID, boardEUI64: F.eui64, requiredEUI64: F.eui64)
        intake.targetDidChange(removed)
        let ticket = try XCTUnwrap(intake.beginReadingImage(for: removed) { [box] in box!.apply($0) })
        // The same row, but for another removal: another target.
        intake.targetDidChange(Intake.Target(boardID: F.boardID, boardEUI64: F.eui64, requiredEUI64: F.otherEUI64))
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        assertNothingEntered()
    }
}

// MARK: - The camera

@MainActor
final class PowerBaseSetupQRCameraTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private var provider: FakeQRCameraProvider!
    private var camera: PowerBaseSetupQRCamera!
    private var box: QRFieldBox!
    private var intake: Intake!

    override func setUp() async throws {
        provider = FakeQRCameraProvider()
        camera = PowerBaseSetupQRCamera(provider: provider)
        box = QRFieldBox()
        box.field = PowerBaseSetupCodeField(typed: "TYPED")
        box.field.select(boardEUI64: F.eui64)
        intake = Intake(camera: camera)
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        intake.targetDidChange(F.target)
    }

    @discardableResult
    private func openScanner() -> Intake.Ticket? {
        intake.begin(.camera, for: F.target) { [box] in box!.apply($0) }
    }

    private func settled() async throws {
        try await eventually { self.camera.unfinishedStarts == 0 }
    }

    /// A frame's result reaches the main actor a moment later.
    private func frame(_ symbols: String?...) async throws {
        provider.show(symbols)
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
    }

    func testThePermissionIsAskedOnlyWhenTheUserOpensTheScanner() async throws {
        provider.access = .notDetermined
        // The screen is there, a board is selected, the field is used: no question, no camera.
        box.field.edit("TYPED MORE")
        intake.fieldWasEdited()
        let imageScan = intake.beginReadingImage(for: F.target) { _ in false }
        XCTAssertNotNil(imageScan, "reading a picture needs no camera either")
        intake.cancel()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.accessRequests, 0)
        XCTAssertEqual(provider.starts, 0)
        XCTAssertEqual(camera.state, .idle)

        XCTAssertNotNil(openScanner())
        try await eventually { self.camera.state == .running }
        XCTAssertEqual(provider.accessRequests, 1)
        XCTAssertEqual(provider.starts, 1)
        XCTAssertTrue(provider.isRunning)
    }

    func testTheSelectedBoardsCodeIsEnteredAndTheScannerClosesItself() async throws {
        openScanner()
        try await eventually { self.camera.state == .running }
        // Not this board's, several at once, something else: the scanner stays open and says why.
        try await frame(F.otherText)
        XCTAssertEqual(intake.problem, .differentBoard)
        try await frame(F.text, F.otherText)
        XCTAssertEqual(intake.problem, .severalCodes)
        try await frame("https://example.com")
        XCTAssertEqual(intake.problem, .notPowerBaseCode)
        XCTAssertNotNil(intake.scan)
        XCTAssertEqual(box.field.text, "TYPED")
        XCTAssertTrue(provider.isRunning)

        // The frame's detections of the right code, twice in one frame and in frames that were
        // already on their way: entered once.
        provider.show(F.text, F.text)
        provider.show(F.text)
        provider.show(F.text)
        try await eventually { self.intake.scan == nil }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(box.fills, 1)
        XCTAssertEqual(box.offers, 1)
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertNil(intake.problem)
        XCTAssertTrue(intake.didFill)
        XCTAssertFalse(provider.isRunning, "the camera is off as soon as the code was read")
        XCTAssertEqual(camera.state, .idle)
        // A frame the camera still had: nobody is listening.
        box.field.edit("EDITED")
        try await frame(F.text)
        XCTAssertEqual(box.field.text, "EDITED")
        XCTAssertEqual(box.offers, 1)
    }

    func testWithoutACameraNothingIsAskedAndNothingIsStarted() async throws {
        provider.hasCamera = false
        provider.access = .notDetermined
        openScanner()
        try await settled()
        XCTAssertEqual(camera.state, .unavailable)
        XCTAssertEqual(provider.accessRequests, 0, "a device without a camera is not asked for the camera")
        XCTAssertEqual(provider.starts, 0)
        XCTAssertNotNil(intake.scan, "the scanner stays open to say so, until the user closes it")
        intake.cancel()
        XCTAssertEqual(camera.state, .idle)
    }

    func testADeniedOrRestrictedCameraIsNotStarted() async throws {
        for (access, state) in [(PowerBaseSetupQRCameraAccess.denied, PowerBaseSetupQRCamera.State.denied), (.restricted, .restricted)] {
            provider.access = access
            openScanner()
            try await settled()
            XCTAssertEqual(camera.state, state)
            XCTAssertEqual(provider.accessRequests, 0, "the system asks once; the app does not ask again")
            XCTAssertEqual(provider.starts, 0)
            intake.cancel()
        }
        // Asked now, and refused.
        provider.access = .notDetermined
        provider.grantsAccess = false
        openScanner()
        try await settled()
        XCTAssertEqual(camera.state, .denied)
        XCTAssertEqual(provider.starts, 0)
        XCTAssertEqual(box.field.text, "TYPED")
    }

    func testAPermissionAnsweredAfterTheScannerWasClosedDoesNotTurnTheCameraOn() async throws {
        provider.access = .notDetermined
        provider.holdsAccess = true
        openScanner()
        try await eventually { self.provider.pendingAccessRequests == 1 }
        XCTAssertEqual(camera.state, .askingPermission)
        intake.cancel()
        XCTAssertEqual(camera.state, .idle, "closing does not wait for the answer")
        provider.answerAccess()
        try await settled()
        XCTAssertEqual(provider.starts, 0)
        XCTAssertFalse(provider.isRunning)
        XCTAssertEqual(camera.state, .idle)
    }

    func testAPermissionAnsweredAfterTheScreenWasLeftDoesNotTurnTheCameraOn() async throws {
        provider.access = .notDetermined
        provider.holdsAccess = true
        openScanner()
        try await eventually { self.provider.pendingAccessRequests == 1 }
        intake.screenDidDisappear()
        provider.answerAccess()
        try await settled()
        XCTAssertEqual(provider.starts, 0)
        XCTAssertFalse(provider.isRunning)
        // Neither does another board or another hub while the question is open.
        for change in [{ self.intake.targetDidChange(F.otherTarget) }, { self.intake.hubDidChange(EnrollmentFixtures.hubB) }] {
            intake.screenDidAppear()
            intake.targetDidChange(F.target)
            provider.access = .notDetermined
            provider.holdsAccess = true
            openScanner()
            try await eventually { self.provider.pendingAccessRequests == 1 }
            change()
            provider.answerAccess()
            try await settled()
            XCTAssertEqual(provider.starts, 0)
            XCTAssertFalse(provider.isRunning)
        }
    }

    func testClosingWhileTheCameraStartsLeavesItOff() async throws {
        provider.holdsStart = true
        openScanner()
        try await eventually { self.provider.pendingStarts == 1 }
        XCTAssertEqual(camera.state, .starting)
        intake.cancel()
        XCTAssertEqual(camera.state, .idle)
        provider.finishStarts()
        try await settled()
        XCTAssertFalse(provider.isRunning, "a start that finishes after the scanner was closed does not leave the camera on")
        XCTAssertEqual(camera.state, .idle)
        try await frame(F.text)
        XCTAssertEqual(box.field.text, "TYPED")
    }

    func testTheCameraIsOffInTheBackgroundAndNothingIsEnteredThere() async throws {
        openScanner()
        try await eventually { self.camera.state == .running }
        intake.sceneDidEnterBackground()
        XCTAssertEqual(camera.state, .paused)
        XCTAssertFalse(provider.isRunning, "stopped at once")
        try await frame(F.text)
        XCTAssertEqual(box.field.text, "TYPED")
        XCTAssertNotNil(intake.scan, "the scan is still the user's: it goes on when the app is back")

        intake.sceneDidBecomeActive()
        try await eventually { self.camera.state == .running }
        XCTAssertEqual(provider.starts, 2)
        try await frame(F.text)
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertFalse(provider.isRunning)
    }

    func testAScannerClosedInTheBackgroundStaysClosedWhenTheAppIsBack() async throws {
        openScanner()
        try await eventually { self.camera.state == .running }
        intake.sceneDidEnterBackground()
        // Closed, left, another hub -- none of it waits for the foreground.
        intake.screenDidDisappear()
        XCTAssertEqual(camera.state, .idle)
        XCTAssertNil(intake.scan)
        intake.sceneDidBecomeActive()
        try await settled()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.starts, 1, "the camera of a scanner that is gone does not come back on")
        XCTAssertFalse(provider.isRunning)
        XCTAssertEqual(camera.state, .idle)
    }

    func testAStartThatFinishesInTheBackgroundLeavesTheCameraOff() async throws {
        provider.holdsStart = true
        openScanner()
        try await eventually { self.provider.pendingStarts == 1 }
        intake.sceneDidEnterBackground()
        XCTAssertEqual(camera.state, .paused)
        provider.finishStarts()
        try await settled()
        XCTAssertFalse(provider.isRunning)
        XCTAssertEqual(camera.state, .paused)
        // Back: started afresh, because the scanner is still open.
        intake.sceneDidBecomeActive()
        try await eventually { self.camera.state == .running }
        XCTAssertTrue(provider.isRunning)
    }

    func testAPermissionAnsweredInTheBackgroundStartsTheCameraOnlyWhenTheAppIsBack() async throws {
        provider.access = .notDetermined
        provider.holdsAccess = true
        openScanner()
        try await eventually { self.provider.pendingAccessRequests == 1 }
        intake.sceneDidEnterBackground()
        provider.answerAccess()
        try await settled()
        XCTAssertEqual(provider.starts, 0)
        XCTAssertFalse(provider.isRunning)
        intake.sceneDidBecomeActive()
        try await eventually { self.camera.state == .running }
        XCTAssertEqual(provider.starts, 1)
        XCTAssertEqual(provider.accessRequests, 1, "the answer is known by then: not asked twice")
    }

    func testACameraThatDoesNotStartSaysSoAndEntersNothing() async throws {
        provider.startSucceeds = false
        openScanner()
        try await settled()
        XCTAssertEqual(camera.state, .failed)
        XCTAssertFalse(provider.isRunning)
        XCTAssertEqual(box.field.text, "TYPED")
    }

    func testOpeningTheScannerNeedsABoardLikeAnyScan() async throws {
        intake.targetDidChange(nil)
        XCTAssertNil(openScanner())
        intake.targetDidChange(F.target)
        intake.screenDidDisappear()
        XCTAssertNil(openScanner())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.accessRequests, 0)
        XCTAssertEqual(provider.starts, 0, "no scan, no camera")
    }
}
#endif
