import Foundation
import PowerBaseBLEKit

/// The setup code as a screen holds it while the user enters it: the text of the field and, when
/// it is known, the one board that text belongs to.
///
/// A typed or pasted code belongs to whichever board the user says, as before. A code that came
/// out of a board's QR code -- or from the screen that has just authenticated a board with it --
/// belongs to that board only:
/// - it is accepted only for the board that is selected at that moment;
/// - it does not follow the selection to another board (it is dropped there);
/// - once the user changes it by hand it is a typed code again, and nothing remembers a board.
///
/// In memory only, like the forms it is part of: never stored, copied or logged.
nonisolated struct PowerBaseSetupCodeField: Equatable, Sendable {
    /// What the field shows.
    private(set) var text = ""
    /// The board `text` is known to belong to (EUI-64, lower-case hex); `nil` for a typed code.
    private(set) var codeBoardEUI64: String?
    /// The board selected in the list now, as it advertises itself (EUI-64, lower-case hex).
    private(set) var selectedBoardEUI64: String?

    init() {}

    /// A code the user typed (or a test wrote).
    init(typed text: String) {
        self.text = text
    }

    /// The code another screen hands over, with the board it authenticated there. No board is
    /// selected yet: the code shows up only if the user then picks that same board.
    init(handoff: PowerBaseSetupCodeHandoff) {
        text = handoff.code
        codeBoardEUI64 = handoff.boardEUI64
    }

    /// The user changed the field: typing, pasting, clearing. A changed text is a typed code.
    mutating func edit(_ newText: String) {
        // Bytes, not characters: Swift calls a look-alike string equal.
        guard !newText.utf8.elementsEqual(text.utf8) else { return }
        text = newText
        codeBoardEUI64 = nil
    }

    /// The selection in the board list changed (`nil`: nothing is selected). A code that belongs
    /// to one board is dropped when another board is selected.
    mutating func select(boardEUI64: String?) {
        selectedBoardEUI64 = boardEUI64
        if let owner = codeBoardEUI64, let boardEUI64, owner != boardEUI64 {
            text = ""
            codeBoardEUI64 = nil
        }
    }

    /// Enters the code of a QR code -- only when that QR code names the board that is selected
    /// right now. `false`: nothing was changed.
    mutating func fill(from payload: PowerBaseSetupQRPayload) -> Bool {
        guard let selected = selectedBoardEUI64, payload.eui64.hex == selected else { return false }
        text = payload.setupCode
        codeBoardEUI64 = selected
        return true
    }

    /// The text to authenticate the selected board with: `nil` when the code belongs to a board
    /// other than the selected one.
    var codeForSelectedBoard: String? {
        guard let owner = codeBoardEUI64 else { return text }
        return owner == selectedBoardEUI64 ? text : nil
    }
}

/// A setup code on its way from the screen that authenticated a board with it ("다른 허브에
/// 연결하기") to the registration screen, together with that board. In memory only.
nonisolated struct PowerBaseSetupCodeHandoff: Equatable, Sendable {
    let code: String
    /// The board the code authenticated (EUI-64, lower-case hex).
    let boardEUI64: String

    /// `nil` unless `code` is a setup code and `boardEUI64` an EUI-64 in the form boards
    /// advertise.
    init?(code: String, boardEUI64: String) {
        guard PowerBaseSetupCode.normalized(code) != nil, PowerBaseBLEEUI64(hex: boardEUI64)?.hex == boardEUI64 else { return nil }
        self.code = code
        self.boardEUI64 = boardEUI64
    }
}

// Both hold a setup code: whatever prints or inspects them by accident shows nothing.
extension PowerBaseSetupCodeField: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PowerBaseSetupCodeField(\(text.isEmpty ? "empty" : "redacted"))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension PowerBaseSetupCodeHandoff: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PowerBaseSetupCodeHandoff(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
