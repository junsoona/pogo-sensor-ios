#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Three defects found in review (2026-10-06), and what holds instead since:
///
/// 1. A picture that was still being read when the user typed or pasted was entered over what
///    the user wrote. Now the user's edit ends the scan.
/// 2. A picture's scan that was under way when the app went to the background was entered after
///    the return. Now the background ends it; only a picture chosen anew is entered.
/// 3. The scan was made when the picker *returned*, so a choice made in a picker that had been
///    open across a change of hub, board or screen counted as a new scan. Now the scan is made
///    by the tap that opens the picker, and the picker's answer belongs to that scan or to none.
///
/// The picker and the loader are scripted; everything between the row's tap and the field --
/// `PowerBaseSetupQRRows.begin`, the intake's picker entry points, `PowerBaseSetupQRPickedImage`
/// -- is the code the app runs.
@MainActor
final class PowerBaseSetupQRFollowUpTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Intake = PowerBaseSetupQRIntake

    private var box: QRFieldBox!
    private var intake: Intake!
    private var field: Binding<PowerBaseSetupCodeField>!

    override func setUp() async throws {
        box = QRFieldBox()
        box.field = PowerBaseSetupCodeField(typed: "TYPED")
        box.field.select(boardEUI64: F.eui64)
        field = box.binding
        intake = Intake(camera: nil)
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        intake.targetDidChange(F.target)
    }

    /// The row's tap, as the button does it. The scan and its picker exist from here.
    private func tapImageRow(_ picker: Intake.ImagePicker = .photos, for target: Intake.Target? = F.target) -> Intake.Ticket? {
        PowerBaseSetupQRRows.begin(.image(picker), intake: intake, target: target, field: field)
    }

    /// The picker opened for `ticket` returns a choice and closes, as a system picker does.
    @discardableResult
    private func pickerReturns(_ loader: FakeImageLoader, for ticket: Intake.Ticket) -> Bool {
        let taken = intake.imagePickerDidChoose(ticket) { await loader.load() }
        intake.imagePickerDidClose(ticket)
        return taken
    }

    private func settled() async throws {
        try await eventually { self.intake.unfinishedImageLoads == 0 }
    }

    private func assertUntouched(_ text: String = "TYPED", _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.field.text, text, message, file: file, line: line)
        XCTAssertNil(box.field.codeBoardEUI64, message, file: file, line: line)
        XCTAssertFalse(intake.didFill, message, file: file, line: line)
    }

    // MARK: - When the scan is made

    func testTheScanAndItsPickerExistFromTheTapNotFromThePickersAnswer() async throws {
        XCTAssertNil(intake.scan)
        XCTAssertNil(intake.openImagePicker, "no picker without a tap")
        let ticket = try XCTUnwrap(tapImageRow(.photos))
        // Before anything was chosen: the scan is there, and the picker is shown for it.
        XCTAssertEqual(intake.scan, ticket)
        XCTAssertEqual(intake.openImagePicker?.ticket, ticket)
        XCTAssertEqual(intake.openImagePicker?.picker, .photos)
        XCTAssertEqual(intake.choosingImageTicket, ticket)
        XCTAssertEqual(intake.imageStage, .choosing(isPickerOpen: true))
        XCTAssertEqual(ticket.target, F.target, "the scan knows the board it was begun for")
        XCTAssertEqual(box.offers, 0)

        // The answer is handed to that scan: no other scan is made on the way to the field.
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: ticket))
        XCTAssertEqual(intake.scan, ticket, "the same scan, now reading")
        XCTAssertEqual(intake.imageStage, .reading)
        XCTAssertNil(intake.openImagePicker)
        XCTAssertNil(intake.choosingImageTicket)
        try await eventually { loader.pending == 1 }
        loader.finish(.symbols([F.text]))
        try await settled()
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.fills, 1)
        XCTAssertNil(intake.scan)
        XCTAssertTrue(intake.didFill)

        // Every tap is another scan; no serial is used twice.
        let second = try XCTUnwrap(tapImageRow(.file))
        XCTAssertGreaterThan(second.serial, ticket.serial)
        XCTAssertEqual(intake.openImagePicker?.picker, .file)
    }

    func testNoPickerOpensWithoutABoardToReadACodeFor() {
        XCTAssertNil(tapImageRow(for: nil))
        XCTAssertNil(tapImageRow(for: F.otherTarget), "not the board the code entry is shown for")
        intake.sceneDidEnterBackground()
        XCTAssertNil(tapImageRow())
        intake.sceneDidBecomeActive()
        intake.screenDidDisappear()
        XCTAssertNil(tapImageRow())
        XCTAssertNil(intake.openImagePicker)
        XCTAssertNil(intake.scan)
    }

    /// A result cannot be handed to a scan whose picker has not answered: nothing reads a
    /// picture "for" a scan by naming the scan alone.
    func testAResultIsNotTakenForAScanWhosePickerHasNotAnswered() throws {
        let ticket = try XCTUnwrap(tapImageRow())
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        assertUntouched()
        XCTAssertEqual(intake.scan, ticket, "and the scan is still waiting for its picker")
        XCTAssertEqual(box.offers, 0)
    }

    func testAPictureIsEnteredOnceHoweverOftenItsResultArrives() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: ticket))
        // The picker answering twice for one scan (a double callback): the second is not loaded.
        let again = FakeImageLoader()
        XCTAssertFalse(pickerReturns(again, for: ticket))
        try await eventually { loader.pending == 1 }
        loader.finish(.symbols([F.text, F.text]))
        try await settled()
        XCTAssertEqual(box.fills, 1)
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(again.starts, 0)
        // The result once more, by any way: nothing.
        box.field.edit("EDITED AFTERWARDS")
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertFalse(intake.imagePickerDidChoose(ticket))
        XCTAssertEqual(box.field.text, "EDITED AFTERWARDS")
        XCTAssertEqual(box.offers, 1)
    }

    /// A picker may say that it closed before its choice arrives. The choice still belongs to
    /// the scan the picker was opened for.
    func testAChoiceThatArrivesAfterThePickerSaidItClosedIsStillThatScans() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        intake.imagePickerDidClose(ticket)
        XCTAssertNil(intake.openImagePicker, "the picker is not shown again")
        XCTAssertEqual(intake.choosingImageTicket, ticket, "but its answer is still listened to")
        XCTAssertEqual(intake.scan, ticket)
        let loader = FakeImageLoader()
        XCTAssertTrue(intake.imagePickerDidChoose(ticket) { await loader.load() })
        try await eventually { loader.pending == 1 }
        loader.finish(.symbols([F.text]))
        try await settled()
        XCTAssertEqual(box.field.text, F.setupCode)
    }

    // MARK: - 1. The user typed or pasted

    func testAPictureThatWasBeingReadWhenTheUserTypedIsNotEnteredOverWhatWasTyped() async throws {
        for late in [PowerBaseSetupQRReading.symbols([F.text]), .symbols([F.otherText]), .symbols([]), .unreadableImage] {
            box.field = PowerBaseSetupCodeField(typed: "TYPED")
            box.field.select(boardEUI64: F.eui64)
            let ticket = try XCTUnwrap(tapImageRow())
            let loader = FakeImageLoader()
            XCTAssertTrue(pickerReturns(loader, for: ticket))
            try await eventually { loader.pending == 1 }

            intake.userTyped("TYPED BY HAND", into: &box.field)
            XCTAssertNil(intake.scan, "the user's edit ends the scan")
            XCTAssertNil(intake.imageStage)

            loader.finish(late)
            try await settled()
            assertUntouched("TYPED BY HAND", "\(late)")
            XCTAssertNil(intake.problem, "\(late): the result of a scan the user typed over says nothing")
            XCTAssertEqual(intake.complete(ticket, with: late), .ignored)
            XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
            assertUntouched("TYPED BY HAND", "\(late)")
        }
        XCTAssertEqual(box.offers, 0, "the scan's way into the field is gone with the scan")
    }

    func testAPictureThatWasBeingReadWhenTheUserPastedIsNotEnteredOverWhatWasPasted() async throws {
        // Pasted: another code, and -- the user's act all the same -- the very text that is there.
        for pasted in [F.otherSetupCode, "TYPED"] {
            box.field = PowerBaseSetupCodeField(typed: "TYPED")
            box.field.select(boardEUI64: F.eui64)
            let ticket = try XCTUnwrap(tapImageRow())
            let loader = FakeImageLoader()
            XCTAssertTrue(pickerReturns(loader, for: ticket))
            try await eventually { loader.pending == 1 }

            intake.userPasted(pasted, into: &box.field)
            XCTAssertNil(intake.scan)
            loader.finish(.symbols([F.text]))
            try await settled()
            assertUntouched(pasted)
            XCTAssertNil(intake.problem)
        }
        XCTAssertEqual(box.offers, 0)
    }

    func testTheUsersEditAlsoEndsAScanWhosePickerIsStillOpenOrJustClosed() async throws {
        // Closed without a choice yet (the user gave up, or the choice is on its way): typing ends it.
        let closed = try XCTUnwrap(tapImageRow())
        intake.imagePickerDidClose(closed)
        intake.userTyped("TYPED MORE", into: &box.field)
        XCTAssertNil(intake.scan)
        let loader = FakeImageLoader()
        XCTAssertFalse(intake.imagePickerDidChoose(closed) { await loader.load() })
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(loader.starts, 0, "a choice for a scan that is over is not even loaded")
        assertUntouched("TYPED MORE")
    }

    /// A text field writes back what it already shows -- on focus, on layout, on a Return that
    /// adds nothing. That is not the user editing: the scan goes on and its code is entered.
    func testTheTextFieldWritingBackTheSameTextIsNotAnEdit() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: ticket))
        try await eventually { loader.pending == 1 }
        intake.userTyped("TYPED", into: &box.field)
        intake.userTyped("TYPED", into: &box.field)
        XCTAssertEqual(intake.scan, ticket, "still the current scan")
        loader.finish(.symbols([F.text]))
        try await settled()
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.fills, 1)
    }

    /// The code a scan entered is not the user's edit: the notice stays, the board is still
    /// known, and the text field showing (and writing back) the new code changes neither.
    func testEnteringACodeIsNotMistakenForTheUserEditing() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: ticket))
        try await eventually { loader.pending == 1 }
        loader.finish(.symbols([F.text]))
        try await settled()
        XCTAssertTrue(intake.didFill)
        intake.userTyped(F.setupCode, into: &box.field)
        XCTAssertTrue(intake.didFill, "the field showing what was just entered is no edit")
        XCTAssertEqual(box.field.codeBoardEUI64, F.eui64)
        // One character changed by hand: now it is.
        intake.userTyped(String(F.setupCode.dropLast()) + "E", into: &box.field)
        XCTAssertFalse(intake.didFill)
        XCTAssertNil(box.field.codeBoardEUI64)
        // A refusal's words go with an edit as well.
        let refused = try XCTUnwrap(tapImageRow())
        XCTAssertTrue(intake.imagePickerDidChoose(refused))
        XCTAssertEqual(intake.complete(refused, with: .symbols([F.otherText])), .refused(.differentBoard))
        intake.userTyped("X", into: &box.field)
        XCTAssertNil(intake.problem)
    }

    /// The three screens share one entry: the same holds for each screen's own form.
    func testTypingEndsAScanOnEachOfTheThreeScreensForms() async throws {
        let board = PowerBaseBLEDiscoveredBoard(id: F.boardID, name: nil, advertisedEUI64: F.eui64, rssi: -50)
        var setup = PowerBaseSetupForm(didStartFinding: true, setupCode: "TYPED")
        setup.select(board)
        var reenroll = PowerBaseReenrollForm(didStartFinding: true, setupCode: "TYPED")
        reenroll.select(board)
        var confirmation = PowerBaseReleaseConfirmationForm(didStartFinding: true, setupCode: "TYPED")
        confirmation.select(board)
        let fields: [(String, Binding<PowerBaseSetupCodeField>)] = [
            ("registration", Binding(get: { setup.code }, set: { setup.code = $0 })),
            ("re-enrollment", Binding(get: { reenroll.code }, set: { reenroll.code = $0 })),
            ("confirm removal", Binding(get: { confirmation.code }, set: { confirmation.code = $0 })),
        ]
        for (screen, field) in fields {
            let ticket = try XCTUnwrap(PowerBaseSetupQRRows.begin(.image(.photos), intake: intake, target: F.target, field: field), screen)
            let loader = FakeImageLoader()
            XCTAssertTrue(pickerReturns(loader, for: ticket), screen)
            try await eventually { loader.pending == 1 }
            // What `PowerBaseSetupCodeEntry` does when its text field writes.
            intake.userTyped("TYPED BY HAND", into: &field.wrappedValue)
            loader.finish(.symbols([F.text]))
            try await settled()
            XCTAssertEqual(field.wrappedValue.text, "TYPED BY HAND", screen)
            XCTAssertNil(field.wrappedValue.codeBoardEUI64, screen)
            XCTAssertNil(intake.problem, screen)
        }
        XCTAssertEqual([setup.setupCode, reenroll.setupCode, confirmation.setupCode], Array(repeating: "TYPED BY HAND", count: 3))
    }

    // MARK: - 2. The background

    func testAPictureBeingReadAcrossTheBackgroundIsNotEnteredAfterTheReturn() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: ticket))
        try await eventually { loader.pending == 1 }

        intake.sceneDidEnterBackground()
        XCTAssertNil(intake.scan, "over at once, not when the result arrives")
        XCTAssertEqual(intake.problem, .interrupted)
        intake.sceneDidBecomeActive()
        XCTAssertNil(intake.scan)

        // Back in the foreground the old picture arrives: it is not entered, now or later.
        loader.finish(.symbols([F.text]))
        try await settled()
        assertUntouched()
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        XCTAssertFalse(intake.imagePickerDidChoose(ticket))
        assertUntouched()
        XCTAssertEqual(box.offers, 0)
        XCTAssertEqual(intake.problem, .interrupted, "the user is told to try again, in words without the code")
        let words = PowerBaseSetupQRText.problemMessage(.interrupted)
        XCTAssertFalse(words.contains(F.setupCode) || words.contains(F.eui64) || words.contains("POGO-PB"))

        // A picture chosen anew is entered.
        let again = try XCTUnwrap(tapImageRow())
        XCTAssertNil(intake.problem, "a new scan starts without the old one's message")
        let second = FakeImageLoader()
        XCTAssertTrue(pickerReturns(second, for: again))
        try await eventually { second.pending == 1 }
        second.finish(.symbols([F.text]))
        try await settled()
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.fills, 1)
    }

    func testAPickerThatWasOpenAcrossTheBackgroundDoesNotEnterItsChoice() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        intake.sceneDidEnterBackground()
        XCTAssertNil(intake.openImagePicker, "the picker is taken away")
        XCTAssertNil(intake.scan)
        XCTAssertEqual(intake.problem, .interrupted)
        intake.sceneDidBecomeActive()
        let loader = FakeImageLoader()
        XCTAssertFalse(pickerReturns(loader, for: ticket), "what it returns after the return belongs to no scan")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(loader.starts, 0)
        assertUntouched()
    }

    /// `inactive` -- the app switcher, a system question such as the camera permission, the
    /// picker itself coming up -- is not the background: the screens tell the intake about
    /// `background` only, and a scan goes on through anything else.
    func testOnlyTheBackgroundEndsAPicturesScan() async throws {
        let controller = PowerBaseLocalResetController(provider: FakeResetProvider(board: FakeResetBoard()))
        let ticket = try XCTUnwrap(tapImageRow())
        PowerBaseReenrollScene.apply(.inactive, to: controller, qr: intake)
        PowerBaseReleaseConfirmationScene.apply(.inactive, to: nil, qr: intake)
        XCTAssertEqual(intake.scan, ticket)
        XCTAssertFalse(intake.isSuspended)
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: ticket))
        PowerBaseReenrollScene.apply(.active, to: controller, qr: intake)
        try await eventually { loader.pending == 1 }
        loader.finish(.symbols([F.text]))
        try await settled()
        XCTAssertEqual(box.field.text, F.setupCode)

        box.field.edit("TYPED")
        let second = try XCTUnwrap(tapImageRow())
        PowerBaseReenrollScene.apply(.background, to: controller, qr: intake)
        XCTAssertNil(intake.scan)
        XCTAssertEqual(intake.problem, .interrupted)
        XCTAssertFalse(intake.imagePickerDidChoose(second))
    }

    /// The camera scan goes on after the return, with a camera started afresh. What the camera
    /// of before the background still reports is not taken for the new one.
    func testTheCameraOfBeforeTheBackgroundDoesNotReportIntoTheScanAfterTheReturn() async throws {
        let provider = FakeQRCameraProvider()
        let camera = PowerBaseSetupQRCamera(provider: provider)
        let intake = Intake(camera: camera)
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        intake.targetDidChange(F.target)
        let box = box!
        let ticket = try XCTUnwrap(intake.begin(.camera, for: F.target) { box.apply($0) })
        try await eventually { camera.state == .running }
        let before = try XCTUnwrap(provider.currentHandler)

        intake.sceneDidEnterBackground()
        XCTAssertEqual(intake.scan, ticket, "the scanner is still the user's")
        before([F.text])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(box.field.text, "TYPED", "nothing in the background")

        intake.sceneDidBecomeActive()
        try await eventually { camera.state == .running }
        XCTAssertEqual(provider.starts, 2)
        // A detection of the first start arrives now, late.
        before([F.text])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(box.field.text, "TYPED", "a frame of the camera that was stopped is not a frame of the one that runs")
        XCTAssertEqual(box.offers, 0)
        XCTAssertEqual(intake.scan, ticket)
        // The camera that runs now is heard.
        provider.show(F.text)
        try await eventually { box.field.text == F.setupCode }
        XCTAssertEqual(box.fills, 1)
    }

    // MARK: - 3. What happens while the picker is open

    /// The reviewed defect itself: a picker opened for one hub returns after the app reads
    /// another. Its choice is dropped -- and coming back to the first hub does not revive it.
    func testAPickerThatWasOpenWhileTheHubChangedDoesNotEnterItsChoice() async throws {
        for backToTheFirstHub in [false, true] {
            intake.hubDidChange(EnrollmentFixtures.hubA)
            let ticket = try XCTUnwrap(tapImageRow())
            let serial = ticket.serial
            // The picker is open ...
            intake.hubDidChange(EnrollmentFixtures.hubB)
            XCTAssertNil(intake.openImagePicker, "the picker is taken away")
            XCTAssertNil(intake.scan)
            if backToTheFirstHub { intake.hubDidChange(EnrollmentFixtures.hubA) }
            // ... and returns.
            let loader = FakeImageLoader()
            XCTAssertFalse(pickerReturns(loader, for: ticket))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(loader.starts, 0, "the picture is not even loaded")
            XCTAssertNil(intake.scan, "and no new scan was made for it")
            XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
            assertUntouched("TYPED", "a choice made in a picker that was opened for another hub")
            XCTAssertNil(intake.problem)
            // Only a tap makes the next scan.
            let next = try XCTUnwrap(tapImageRow())
            XCTAssertEqual(next.serial, serial + 1)
            intake.cancel(next)
        }
        XCTAssertEqual(box.offers, 0)
    }

    func testAPickerThatWasOpenWhileAnotherBoardWasSelectedDoesNotEnterItsChoice() async throws {
        for backToTheFirstBoard in [false, true] {
            box.field.select(boardEUI64: F.eui64)
            intake.targetDidChange(F.target)
            let ticket = try XCTUnwrap(tapImageRow())
            box.field.select(boardEUI64: F.otherEUI64)
            intake.targetDidChange(F.otherTarget)
            XCTAssertNil(intake.openImagePicker)
            if backToTheFirstBoard {
                box.field.select(boardEUI64: F.eui64)
                intake.targetDidChange(F.target)
            }
            let loader = FakeImageLoader()
            XCTAssertFalse(pickerReturns(loader, for: ticket))
            XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
            XCTAssertEqual(intake.complete(ticket, with: .symbols([F.otherText])), .ignored)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(loader.starts, 0)
            assertUntouched()
        }
        // The code entry not being shown for a moment (a run began, a result) is the same.
        let ticket = try XCTUnwrap(tapImageRow())
        intake.targetDidChange(nil)
        intake.targetDidChange(F.target)
        XCTAssertFalse(intake.imagePickerDidChoose(ticket))
        assertUntouched()
    }

    func testAPickerThatWasOpenWhileTheScreenWasLeftDoesNotEnterItsChoice() async throws {
        let ticket = try XCTUnwrap(tapImageRow())
        intake.screenDidDisappear()
        XCTAssertNil(intake.openImagePicker)
        let loader = FakeImageLoader()
        XCTAssertFalse(pickerReturns(loader, for: ticket))
        intake.screenDidAppear()
        XCTAssertFalse(pickerReturns(loader, for: ticket), "the screen is back: the scan is not")
        XCTAssertEqual(intake.complete(ticket, with: .symbols([F.text])), .ignored)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(loader.starts, 0)
        assertUntouched()
        XCTAssertNil(intake.problem)
    }

    /// The same changes while the chosen picture is being loaded: what was loaded is dropped.
    func testAPictureBeingReadWhileTheHubBoardOrScreenChangedIsDropped() async throws {
        let changes: [(String, () -> Void)] = [
            ("hub A-B-A", { self.intake.hubDidChange(EnrollmentFixtures.hubB); self.intake.hubDidChange(EnrollmentFixtures.hubA) }),
            ("board A-B-A", { self.intake.targetDidChange(F.otherTarget); self.intake.targetDidChange(F.target) }),
            ("screen left and back", { self.intake.screenDidDisappear(); self.intake.screenDidAppear() }),
            ("closed", { self.intake.cancel() }),
        ]
        for (name, change) in changes {
            let ticket = try XCTUnwrap(tapImageRow(), name)
            let loader = FakeImageLoader()
            XCTAssertTrue(pickerReturns(loader, for: ticket), name)
            try await eventually { loader.pending == 1 }
            change()
            loader.finish(.symbols([F.text]))
            try await settled()
            assertUntouched("TYPED", name)
            XCTAssertNil(intake.problem, name)
        }
        XCTAssertEqual(box.offers, 0)
    }

    // MARK: Cancelling, and choosing again

    func testCancellingTheFilePanelEndsItsScanAndTheSameFileCanBeChosenAgain() async throws {
        // A real file, read by the real reader through the line the file panel's closure runs.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-qr-followup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "setup-qr-fake-ascii-letters", withExtension: "png"))
        let file = directory.appendingPathComponent("fake.png")
        try FileManager.default.copyItem(at: fixture, to: file)

        let first = try XCTUnwrap(tapImageRow(.file))
        // The user gives up: the panel reports the cancellation, and that it closed.
        intake.imagePickerDidCancel(first)
        intake.imagePickerDidClose(first)
        XCTAssertNil(intake.scan)
        XCTAssertNil(intake.problem, "giving up is not a problem")
        assertUntouched()

        // The same file, in a panel opened again.
        let second = try XCTUnwrap(tapImageRow(.file))
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(intake.openImagePicker?.ticket, second)
        intake.imagePickerDidClose(second)
        PowerBaseSetupQRPickedImage.chose(.success(file), for: second, intake: intake)
        XCTAssertEqual(intake.imageStage, .reading)
        try await eventually(timeout: .seconds(10)) { self.intake.unfinishedImageLoads == 0 }
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.fills, 1)

        // And once more, the same file again: nothing remembered a "last selection".
        box.field.edit("TYPED")
        let third = try XCTUnwrap(tapImageRow(.file))
        PowerBaseSetupQRPickedImage.chose(.success(file), for: third, intake: intake)
        try await eventually(timeout: .seconds(10)) { self.intake.unfinishedImageLoads == 0 }
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.fills, 2)

        // A panel that fails to hand a file over ends its scan like a cancellation.
        let failed = try XCTUnwrap(tapImageRow(.file))
        PowerBaseSetupQRPickedImage.chose(.failure(CocoaError(.fileReadNoPermission)), for: failed, intake: intake)
        XCTAssertNil(intake.scan)
    }

    /// The photo picker has no "cancelled": it only closes. The scan then waits, harmlessly,
    /// until the user does anything else -- such as opening the picker again.
    func testClosingThePhotoPickerWithoutAChoiceLeavesTheRowsReadyAndThePickerCanBeOpenedAgain() async throws {
        let first = try XCTUnwrap(tapImageRow(.photos))
        intake.imagePickerDidClose(first)
        XCTAssertNil(intake.openImagePicker)
        XCTAssertNotEqual(intake.imageStage, .reading, "nothing is shown as being read")
        assertUntouched()

        let second = try XCTUnwrap(tapImageRow(.photos))
        XCTAssertEqual(intake.openImagePicker?.ticket, second)
        XCTAssertGreaterThan(second.serial, first.serial)
        let loader = FakeImageLoader()
        XCTAssertTrue(pickerReturns(loader, for: second))
        try await eventually { loader.pending == 1 }
        loader.finish(.symbols([F.text]))
        try await settled()
        XCTAssertEqual(box.field.text, F.setupCode)
        XCTAssertEqual(box.fills, 1)
    }

    /// Callbacks of an earlier picker that arrive late -- its choice, its cancellation, its
    /// closing -- touch neither the scan that has begun since nor the field; the new scan's own
    /// answer is entered.
    func testLateCallbacksOfAnEarlierPickerDoNotTouchTheScanThatBeganSince() async throws {
        for picker in [Intake.ImagePicker.photos, .file] {
            box.field = PowerBaseSetupCodeField(typed: "TYPED")
            box.field.select(boardEUI64: F.eui64)
            let old = try XCTUnwrap(tapImageRow(picker))
            // The user starts over (the row again) before the first picker has said anything.
            let new = try XCTUnwrap(tapImageRow(picker))
            XCTAssertEqual(intake.openImagePicker?.ticket, new)

            // Now the first picker speaks.
            intake.imagePickerDidClose(old)
            XCTAssertEqual(intake.openImagePicker?.ticket, new, "\(picker): the new picker is not closed by the old one closing")
            intake.imagePickerDidCancel(old)
            XCTAssertEqual(intake.scan, new, "\(picker): nor cancelled by the old one's cancellation")
            intake.cancel(old)
            XCTAssertEqual(intake.scan, new)
            let oldLoader = FakeImageLoader()
            XCTAssertFalse(pickerReturns(oldLoader, for: old), "\(picker): the old picker's choice is no one's")
            XCTAssertEqual(intake.complete(old, with: .symbols([F.text])), .ignored)
            XCTAssertEqual(intake.scan, new)
            XCTAssertEqual(intake.imageStage, .choosing(isPickerOpen: true))
            assertUntouched("TYPED", "\(picker)")

            // The new picker's own answer.
            let loader = FakeImageLoader()
            XCTAssertTrue(pickerReturns(loader, for: new))
            try await eventually { loader.pending == 1 }
            // ... and still, while it is read, the old one's stragglers.
            intake.imagePickerDidCancel(old)
            intake.imagePickerDidClose(old)
            intake.cancel(old)
            XCTAssertEqual(intake.imageStage, .reading)
            loader.finish(.symbols([F.text]))
            try await settled()
            XCTAssertEqual(box.field.text, F.setupCode, "\(picker)")
            XCTAssertEqual(oldLoader.starts, 0)
        }
        XCTAssertEqual(box.fills, 2)
    }

    /// A scanner sheet that reports its dismissal late does not close the scan that began since.
    func testALateDismissalOfTheScannerDoesNotCloseAPicturesScan() async throws {
        let provider = FakeQRCameraProvider()
        let intake = Intake(camera: PowerBaseSetupQRCamera(provider: provider))
        intake.hubDidChange(EnrollmentFixtures.hubA)
        intake.screenDidAppear()
        intake.targetDidChange(F.target)
        let field = field!
        let scanner = try XCTUnwrap(PowerBaseSetupQRRows.begin(.camera, intake: intake, target: F.target, field: field))
        let picture = try XCTUnwrap(PowerBaseSetupQRRows.begin(.image(.photos), intake: intake, target: F.target, field: field))
        XCTAssertFalse(provider.isRunning, "the camera of the scan that was replaced is off")
        intake.cancel(scanner)
        XCTAssertEqual(intake.scan, picture)
        XCTAssertEqual(intake.openImagePicker?.ticket, picture)
        XCTAssertTrue(intake.imagePickerDidChoose(picture))
        XCTAssertEqual(intake.complete(picture, with: .symbols([F.text])), .applied)
        XCTAssertEqual(box.field.text, F.setupCode)
    }
}

// MARK: - The real rows and a real picker

/// The rows as the app draws them, in a window: the tap's scan brings a system picker up, and
/// ending that scan takes the picker away. No picture is chosen (a test cannot operate the
/// system's picker), and no camera is used.
@MainActor
final class PowerBaseSetupQRPickerPresentationTests: XCTestCase {
    private typealias F = SetupQRFixtures

    func testThePickerIsShownForItsScanAndTakenAwayWhenThatScanEnds() async throws {
        let intake = PowerBaseSetupQRIntake(camera: nil)
        var form = PowerBaseSetupForm(didStartFinding: true, setupCode: "TYPED")
        form.select(PowerBaseBLEDiscoveredBoard(id: F.boardID, name: nil, advertisedEUI64: F.eui64, rssi: -50))
        let box = FollowUpFormBox(form)
        let screen = NavigationStack {
            List {
                Section {
                    PowerBaseSetupCodeEntry(field: box.binding.code, qrTarget: F.target, qr: intake)
                }
            }
            .onAppear {
                intake.hubDidChange(EnrollmentFixtures.hubA)
                intake.screenDidAppear()
                intake.targetDidChange(F.target)
            }
            .onDisappear { intake.screenDidDisappear() }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await eventually { intake.isScreenPresent }
        XCTAssertNil(window.rootViewController?.presentedViewController, "drawing the rows opens nothing")

        // The row's tap.
        let ticket = try XCTUnwrap(PowerBaseSetupQRRows.begin(.image(PowerBaseSetupQRRows.imagePicker), intake: intake, target: F.target, field: box.binding.code))
        XCTAssertEqual(intake.openImagePicker?.ticket, ticket)
        try await eventually(timeout: .seconds(8)) { window.rootViewController?.presentedViewController != nil }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(intake.isScreenPresent, "the screen under the picker has not gone away")
        XCTAssertEqual(intake.scan, ticket, "and the scan is the one the picker was opened for")

        // The hub changes while the picker is open: the scan is over and its picker goes.
        intake.hubDidChange(EnrollmentFixtures.hubB)
        XCTAssertNil(intake.scan)
        try await eventually(timeout: .seconds(8)) { window.rootViewController?.presentedViewController == nil }
        XCTAssertFalse(intake.imagePickerDidChoose(ticket))
        XCTAssertEqual(box.value.setupCode, "TYPED")

        // Opened again, for the hub the app reads now: another scan, another picker.
        let again = try XCTUnwrap(PowerBaseSetupQRRows.begin(.image(PowerBaseSetupQRRows.imagePicker), intake: intake, target: F.target, field: box.binding.code))
        XCTAssertNotEqual(again, ticket)
        try await eventually(timeout: .seconds(8)) { window.rootViewController?.presentedViewController != nil }
        // The user types meanwhile? Not possible under a picker; ending it by code is: closed.
        intake.cancel(again)
        try await eventually(timeout: .seconds(8)) { window.rootViewController?.presentedViewController == nil }
        XCTAssertEqual(box.value.setupCode, "TYPED")
    }
}

@MainActor
@Observable
private final class FollowUpFormBox {
    var value: PowerBaseSetupForm
    init(_ value: PowerBaseSetupForm) { self.value = value }
    var binding: Binding<PowerBaseSetupForm> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif
