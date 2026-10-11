import Foundation
import Observation
import PowerBaseBLEKit

/// What one look -- one camera frame, or one image -- found.
nonisolated enum PowerBaseSetupQRReading: Equatable, Sendable {
    /// The text of every QR symbol in view; `nil` for a symbol that holds no text.
    case symbols([String?])
    case unreadableImage
    case imageTooLarge
}

// May hold what a QR code says: nothing that prints it shows more than a count.
extension PowerBaseSetupQRReading: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        switch self {
        case let .symbols(symbols): return "PowerBaseSetupQRReading(\(symbols.count) symbol(s))"
        case .unreadableImage: return "PowerBaseSetupQRReading(unreadable image)"
        case .imageTooLarge: return "PowerBaseSetupQRReading(image too large)"
        }
    }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// Reading a Power Base setup QR code into the setup code field of a screen (firmware repository,
/// docs/power-base.md "QR 설정 코드"). One per screen, created and told about the screen's life by
/// the view that owns the screen, next to its controller.
///
/// It only ever enters a setup code into the field. It has no Bluetooth, no hub and no
/// controller: reading a code starts nothing, and the screen's own buttons stay the only way to
/// register, reset or confirm anything.
///
/// A scan is one piece of work from the user's tap to the code in the field -- for a picture:
/// opening the picker, the choice, loading, reading and entering are one scan with one ticket,
/// issued when the picker is opened. Whatever comes back for a ticket that is no longer the
/// current one changes nothing and says nothing.
///
/// A code is entered only when all of this still holds at the moment it arrives:
/// - the scan it belongs to is still the current one: not closed, replaced or already used, the
///   user has not changed the field by hand since it began, and (for a picture) the app has not
///   been in the background since;
/// - the screen is on screen, and the app is not in the background;
/// - the same hub is read as when the scan began;
/// - the board that was selected when the scan began is still the selected one;
/// - exactly one QR code is in view, it is a Power Base setup QR code, and it names that board
///   (on "삭제 확인": also the board the removal is about).
///
/// Otherwise the field and the selection stay as they are, and the user is told why in words
/// that never contain what the QR code said.
@MainActor
@Observable
final class PowerBaseSetupQRIntake {
    /// The board a code is read for.
    nonisolated struct Target: Equatable, Sendable {
        /// The selected row of the board list.
        let boardID: UUID
        /// What that board advertises as its EUI-64 (lower-case hex). It picks the QR code; it
        /// authenticates nothing.
        let boardEUI64: String
        /// "삭제 확인": the Power Base the removal is about. The QR code must name it as well.
        var requiredEUI64: String?

        /// A board without a well-formed identity cannot be read a code for.
        var isUsable: Bool {
            PowerBaseBLEEUI64(hex: boardEUI64)?.hex == boardEUI64 && (requiredEUI64 == nil || requiredEUI64 == boardEUI64)
        }
    }

    /// Where the user chooses a picture.
    nonisolated enum ImagePicker: Equatable, Sendable {
        /// The system's photo picker (iPhone, iPad).
        case photos
        /// A file panel (Mac).
        case file
    }

    nonisolated enum Source: Equatable, Sendable {
        /// Looks again and again until a code is entered or the scanner is closed.
        case camera
        /// One picture chosen in a picker, looked at once.
        case image(ImagePicker)

        var isImage: Bool {
            if case .image = self { true } else { false }
        }
    }

    /// One scan, from the tap that began it. Results are only taken for the current one.
    nonisolated struct Ticket: Equatable, Sendable {
        /// Never used twice by one intake: an older scan cannot be mistaken for a newer one.
        let serial: Int
        let source: Source
        let target: Target
    }

    /// How far a picture's scan has come.
    nonisolated enum ImageStage: Equatable, Sendable {
        /// The picker was opened for this scan; nothing has been chosen yet. `isPickerOpen`
        /// turns false when the picker says it closed -- its choice, if there is one, may still
        /// be on its way.
        case choosing(isPickerOpen: Bool)
        /// A picture was chosen: it is being loaded and read.
        case reading
    }

    /// Why nothing was entered. No case carries anything that was read.
    nonisolated enum Problem: Error, Equatable, Sendable, CaseIterable {
        case notPowerBaseCode
        case unsupportedVersion
        case damagedCode
        /// A valid code of another board than the selected one.
        case differentBoard
        /// More than one different QR code in view: none is chosen.
        case severalCodes
        case noCodeInImage
        case unreadableImage
        case imageTooLarge
        /// The app went to the background while an image was read.
        case interrupted
    }

    nonisolated enum Completion: Equatable, Sendable {
        case applied
        case refused(Problem)
        /// Late, repeated, or nothing to see: nothing changed and nothing is said.
        case ignored
    }

    /// The scan under way.
    private(set) var scan: Ticket?
    /// Where the current scan is, when it is a picture's; `nil` otherwise.
    private(set) var imageStage: ImageStage?
    /// Why the last look of this screen entered nothing.
    private(set) var problem: Problem?
    /// The last scan entered a code, and the field and the selection are as it left them.
    private(set) var didFill = false
    private(set) var isSuspended = false
    private(set) var isScreenPresent = false
    /// The board the code entry is shown for now; `nil` while it is not shown.
    private(set) var currentTarget: Target?

    /// `nil` where the app offers no camera scan (Mac Catalyst).
    let camera: PowerBaseSetupQRCamera?

    /// Pictures that are still being loaded or read, whichever scan they were chosen for. For tests.
    @ObservationIgnored private(set) var unfinishedImageLoads = 0
    @ObservationIgnored private var apply: ((PowerBaseSetupQRPayload) -> Bool)?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var hubID: String?

    init(camera: PowerBaseSetupQRCamera? = PowerBaseSetupQRCamera.system()) {
        self.camera = camera
    }

    // MARK: - A scan

    /// The user asked to read a code for `target`: tapped the camera row, or tapped the row that
    /// opens a picker. The scan exists from this tap -- for a picture, from before the picker is
    /// on screen, so everything that happens while the user chooses happens to this scan.
    /// `apply` enters a code into the screen's field and says whether the field took it. `nil`:
    /// there is nothing to read a code for, and nothing was started -- no camera, no picker.
    @discardableResult
    func begin(_ source: Source, for target: Target?, apply: @escaping (PowerBaseSetupQRPayload) -> Bool) -> Ticket? {
        endScan()
        setProblem(nil)
        didFill = false
        guard isScreenPresent, !isSuspended, let target, target.isUsable, target == currentTarget else { return nil }
        if source == .camera, camera == nil { return nil }
        serial += 1
        let ticket = Ticket(serial: serial, source: source, target: target)
        scan = ticket
        self.apply = apply
        switch source {
        case .camera:
            camera?.open { [weak self] symbols in
                self?.complete(ticket, with: .symbols(symbols))
            }
        case .image:
            imageStage = .choosing(isPickerOpen: true)
        }
        return ticket
    }

    // MARK: - A picture's picker

    /// The picker to show now and the scan it was opened for; `nil` when none is to be shown.
    /// The view shows a picker for exactly this and takes it away when this turns `nil`.
    var openImagePicker: (picker: ImagePicker, ticket: Ticket)? {
        guard let scan, case let .image(picker) = scan.source, imageStage == .choosing(isPickerOpen: true) else { return nil }
        return (picker, scan)
    }

    /// The scan whose picker's callbacks are still listened to: while it is choosing, also
    /// after its picker closed (the choice may arrive after the picker says it closed).
    var choosingImageTicket: Ticket? {
        guard let scan, case .choosing = imageStage else { return nil }
        return scan
    }

    /// The picker opened for `ticket` says it is no longer on screen. That alone ends nothing:
    /// a picker closes when the user chose as well as when the user gave up, and the choice may
    /// arrive after this. A picker of an older scan closing is none of the current scan's business.
    func imagePickerDidClose(_ ticket: Ticket) {
        guard scan == ticket, case .choosing = imageStage else { return }
        imageStage = .choosing(isPickerOpen: false)
    }

    /// The user gave up in the picker opened for `ticket`. Only that scan is ended: a late
    /// cancellation of an older picker does not touch the scan that has begun since.
    func imagePickerDidCancel(_ ticket: Ticket) {
        guard scan == ticket, case .choosing = imageStage else { return }
        endScan()
        setProblem(nil)
    }

    /// The picker opened for `ticket` returned a choice. `false`: that scan is over -- the
    /// screen was left, the hub or the board changed, the user typed, started another scan or
    /// the app was in the background while the picker was open -- and the choice is dropped:
    /// it is not looked at, and no new scan is made for it.
    @discardableResult
    func imagePickerDidChoose(_ ticket: Ticket) -> Bool {
        guard scan == ticket, case .choosing = imageStage, isScreenPresent, !isSuspended, ticket.target == currentTarget else { return false }
        imageStage = .reading
        return true
    }

    /// The picker opened for `ticket` returned a choice, and `load` reads it (off the main
    /// actor; the picture stays in memory). Nothing is loaded for a scan that is over, and what
    /// was loaded for a scan that ended meanwhile is dropped.
    @discardableResult
    func imagePickerDidChoose(_ ticket: Ticket, load: @escaping @Sendable () async -> PowerBaseSetupQRReading) -> Bool {
        guard imagePickerDidChoose(ticket) else { return false }
        unfinishedImageLoads += 1
        Task { [weak self] in
            let reading = await load()
            self?.complete(ticket, with: reading)
            self?.unfinishedImageLoads -= 1
        }
        return true
    }

    /// What a look of scan `ticket` found. It may arrive at any time, any number of times.
    @discardableResult
    func complete(_ ticket: Ticket, with reading: PowerBaseSetupQRReading) -> Completion {
        guard let scan, scan == ticket, isScreenPresent else { return .ignored }
        // A picture is looked at only after it was chosen for this scan.
        if ticket.source.isImage, imageStage != .reading { return .ignored }
        guard !isSuspended else {
            // Nothing is entered behind the user's back. The camera looks again when the app is
            // back. (A picture's scan ended when the app went to the background.)
            return .ignored
        }
        guard ticket.target == currentTarget else {
            endScan()
            return .ignored
        }
        switch Self.evaluate(reading, for: ticket.target) {
        case nil:
            guard ticket.source.isImage else { return .ignored }
            endScan()
            setProblem(.noCodeInImage)
            return .refused(.noCodeInImage)
        case let .failure(problem):
            if ticket.source.isImage { endScan() }
            setProblem(problem)
            return .refused(problem)
        case let .success(payload):
            let apply = self.apply
            // Over before the field is touched: a repeated result finds no scan.
            endScan()
            // The field has the last word: it takes the code only for the board selected now.
            guard apply?(payload) == true else { return .ignored }
            setProblem(nil)
            didFill = true
            return .applied
        }
    }

    /// The user closed the scanner or gave up. Does not wait for anything.
    func cancel() {
        endScan()
        setProblem(nil)
    }

    /// The scanner (or picker) shown for `ticket` was closed. Only that scan is ended: a sheet
    /// that reports its dismissal late does not close the scan that has begun since.
    func cancel(_ ticket: Ticket) {
        guard scan == ticket else { return }
        cancel()
    }

    /// What one look says about `target`: the code to enter, why not, or `nil` when no QR code
    /// was in view. One string is read as a whole or not at all: nothing is taken from one code
    /// and combined with another.
    nonisolated static func evaluate(_ reading: PowerBaseSetupQRReading, for target: Target) -> Result<PowerBaseSetupQRPayload, Problem>? {
        let symbols: [String?]
        switch reading {
        case .unreadableImage: return .failure(.unreadableImage)
        case .imageTooLarge: return .failure(.imageTooLarge)
        case let .symbols(found): symbols = found
        }
        // The same code seen twice is one code. Compared as bytes: strings that only look alike
        // are different codes.
        var distinct: [(bytes: [UInt8]?, text: String?)] = []
        for symbol in symbols {
            let bytes = symbol.map { Array($0.utf8) }
            if !distinct.contains(where: { $0.bytes == bytes }) { distinct.append((bytes, symbol)) }
        }
        guard let only = distinct.first else { return nil }
        guard distinct.count == 1 else { return .failure(.severalCodes) }
        guard let text = only.text else { return .failure(.notPowerBaseCode) }
        let payload: PowerBaseSetupQRPayload
        do {
            payload = try PowerBaseSetupQRPayload(parsing: text)
        } catch PowerBaseSetupQRError.notPowerBaseCode {
            return .failure(.notPowerBaseCode)
        } catch PowerBaseSetupQRError.unsupportedVersion {
            return .failure(.unsupportedVersion)
        } catch {
            return .failure(.damagedCode)
        }
        guard target.isUsable, payload.eui64.hex == target.boardEUI64 else { return .failure(.differentBoard) }
        return .success(payload)
    }

    // MARK: - The screen, the app, the hub, the selection

    func screenDidAppear() {
        isScreenPresent = true
    }

    /// The screen went away: a scan under way is over, and a late result changes nothing.
    func screenDidDisappear() {
        isScreenPresent = false
        endScan()
        setProblem(nil)
        didFill = false
    }

    /// Nothing is entered in the background and the camera is off. A camera scan carries on
    /// when the app is back -- if it is still the current scan then, and with a camera started
    /// afresh: what the camera of before reports later is dropped by `PowerBaseSetupQRCamera`.
    ///
    /// A picture's scan is over, whether its picker is still open or the picture is being read:
    /// what was chosen or read across the background is not entered after the return either.
    /// Only a picture chosen anew can be. (`inactive` -- the app switcher, a system question --
    /// is not this: the screens call this for `background` only.)
    func sceneDidEnterBackground() {
        isSuspended = true
        camera?.sceneDidEnterBackground()
        if scan?.source.isImage == true {
            endScan()
            setProblem(.interrupted)
        }
    }

    func sceneDidBecomeActive() {
        isSuspended = false
        camera?.sceneDidBecomeActive()
    }

    /// The hub the app reads. A scan begun for one hub's screen is over when it changes.
    func hubDidChange(_ newHubID: String?) {
        guard newHubID != hubID else { return }
        hubID = newHubID
        endScan()
        setProblem(nil)
        didFill = false
    }

    /// The board the code entry is shown for changed (`nil`: it is not shown any more -- another
    /// selection, a run under way, a result). What was read or said for the previous one is over.
    func targetDidChange(_ target: Target?) {
        guard target != currentTarget else { return }
        currentTarget = target
        endScan()
        setProblem(nil)
        didFill = false
    }

    /// The user changed the field by hand -- typed, deleted or pasted. What the user wrote
    /// stands: a scan that was under way is over (its result, good or bad, arrives to nothing),
    /// and what was said about the last scan is out of date.
    func fieldWasEdited() {
        endScan()
        setProblem(nil)
        didFill = false
    }

    /// The text field wrote `newText`. A text field also writes back what it already shows
    /// (focus, layout, a Return that adds nothing): that is not the user editing, and it ends
    /// nothing -- not a scan under way, and not the notice that a code was just entered.
    func userTyped(_ newText: String, into field: inout PowerBaseSetupCodeField) {
        // Bytes, as the field itself compares.
        guard !newText.utf8.elementsEqual(field.text.utf8) else { return }
        fieldWasEdited()
        field.edit(newText)
    }

    /// The user tapped the paste button. Always the user's own act, also when the pasted text
    /// is what the field already shows.
    func userPasted(_ text: String, into field: inout PowerBaseSetupCodeField) {
        fieldWasEdited()
        field.edit(text)
    }

    // MARK: - Private

    private func endScan() {
        if scan?.source == .camera { camera?.close() }
        scan = nil
        imageStage = nil
        apply = nil
    }

    /// A camera reports thirty times a second: only a change is a change.
    private func setProblem(_ newValue: Problem?) {
        if problem != newValue { problem = newValue }
    }
}
