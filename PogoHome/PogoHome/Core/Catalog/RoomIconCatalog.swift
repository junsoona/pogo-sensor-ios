import Foundation

/// The fixed catalog of selectable room icons, grouped for `RoomIconPicker`. Every name here
/// is a real SF Symbol as of iOS 17; `SymbolAvailability.resolvedName(for:)` still guards
/// every render site in case a picker built on a newer OS ever adds a symbol older devices
/// don't have.
nonisolated enum RoomIconCatalog {
    /// One selectable icon and the room name suggested (as a gray placeholder) when the
    /// room-name field is left empty with this icon selected. Keeping the name next to the
    /// symbol makes "every selectable icon has a suggestion" true by construction. The
    /// suggestion is a localized resource, resolved per language — see `RoomNameSource`.
    struct Icon: Sendable {
        let symbolName: String
        let suggestedRoomName: LocalizedStringResource
    }

    struct Category: Identifiable, Sendable {
        let id: String
        let title: LocalizedStringResource
        let icons: [Icon]

        var symbolNames: [String] { icons.map(\.symbolName) }

        func title(in language: AppLanguage) -> String {
            language.string(title)
        }
    }

    /// Used for a persisted icon that isn't (or is no longer) in the catalog.
    static let fallbackSuggestedRoomName: LocalizedStringResource = "새로운 방"

    static let categories: [Category] = [
        Category(id: "living", title: "거실·휴식", icons: [
            Icon(symbolName: "sofa.fill", suggestedRoomName: "거실"),
            Icon(symbolName: "tv.fill", suggestedRoomName: "미디어룸"),
            Icon(symbolName: "lamp.floor.fill", suggestedRoomName: "라운지"),
            Icon(symbolName: "popcorn.fill", suggestedRoomName: "홈시어터"),
        ]),
        Category(id: "bedroom", title: "침실·유아실", icons: [
            Icon(symbolName: "bed.double.fill", suggestedRoomName: "침실"),
            Icon(symbolName: "moon.zzz.fill", suggestedRoomName: "안방"),
            Icon(symbolName: "teddybear.fill", suggestedRoomName: "아이방"),
            Icon(symbolName: "stroller.fill", suggestedRoomName: "유아실"),
        ]),
        Category(id: "office", title: "작업실·서재", icons: [
            Icon(symbolName: "desktopcomputer", suggestedRoomName: "작업실"),
            Icon(symbolName: "books.vertical.fill", suggestedRoomName: "서재"),
            Icon(symbolName: "pencil.and.ruler.fill", suggestedRoomName: "공부방"),
            Icon(symbolName: "printer.fill", suggestedRoomName: "사무실"),
        ]),
        Category(id: "kitchen", title: "주방·식당", icons: [
            Icon(symbolName: "fork.knife", suggestedRoomName: "주방"),
            Icon(symbolName: "cup.and.saucer.fill", suggestedRoomName: "식당"),
            Icon(symbolName: "refrigerator.fill", suggestedRoomName: "팬트리"),
            Icon(symbolName: "flame.fill", suggestedRoomName: "보일러실"),
        ]),
        Category(id: "bathroom", title: "욕실·세탁실", icons: [
            Icon(symbolName: "shower.fill", suggestedRoomName: "욕실"),
            Icon(symbolName: "bathtub.fill", suggestedRoomName: "안방 욕실"),
            Icon(symbolName: "washer.fill", suggestedRoomName: "세탁실"),
            Icon(symbolName: "toilet.fill", suggestedRoomName: "화장실"),
        ]),
        Category(id: "entry", title: "현관·복도·계단", icons: [
            Icon(symbolName: "door.left.hand.open", suggestedRoomName: "현관"),
            Icon(symbolName: "stairs", suggestedRoomName: "계단"),
            Icon(symbolName: "shoeprints.fill", suggestedRoomName: "신발장"),
            Icon(symbolName: "figure.walk", suggestedRoomName: "복도"),
        ]),
        Category(id: "garage", title: "차고·창고·공구실", icons: [
            Icon(symbolName: "door.garage.closed", suggestedRoomName: "차고"),
            Icon(symbolName: "wrench.and.screwdriver.fill", suggestedRoomName: "공구실"),
            Icon(symbolName: "hammer.fill", suggestedRoomName: "작업장"),
            Icon(symbolName: "shippingbox.fill", suggestedRoomName: "창고"),
        ]),
        Category(id: "outdoor", title: "정원·발코니·야외", icons: [
            Icon(symbolName: "tree.fill", suggestedRoomName: "정원"),
            Icon(symbolName: "leaf.fill", suggestedRoomName: "베란다"),
            Icon(symbolName: "sun.max.fill", suggestedRoomName: "발코니"),
            Icon(symbolName: "cloud.sun.fill", suggestedRoomName: "테라스"),
        ]),
        Category(id: "fitness", title: "운동·취미", icons: [
            Icon(symbolName: "dumbbell.fill", suggestedRoomName: "홈짐"),
            Icon(symbolName: "figure.run", suggestedRoomName: "운동실"),
            Icon(symbolName: "gamecontroller.fill", suggestedRoomName: "게임룸"),
            Icon(symbolName: "paintpalette.fill", suggestedRoomName: "취미실"),
        ]),
        Category(id: "other", title: "기타", icons: [
            Icon(symbolName: "house.fill", suggestedRoomName: "다용도실"),
            Icon(symbolName: "star.fill", suggestedRoomName: "나만의 공간"),
            Icon(symbolName: "questionmark.circle.fill", suggestedRoomName: "기타 공간"),
            Icon(symbolName: "square.dashed", suggestedRoomName: "새 공간"),
        ]),
    ]

    /// All catalog symbol names, flattened — used to validate coverage in tests.
    static var allSymbolNames: [String] {
        categories.flatMap(\.symbolNames)
    }

    /// The base (not yet de-duplicated) room name suggested for `symbolName`, in `language`.
    /// See `RoomNameSuggestion` for turning it into a name that is actually free to save.
    static func suggestedRoomName(for symbolName: String, in language: AppLanguage = .current) -> String {
        language.string(suggestedRoomNameResource(for: symbolName))
    }

    static func suggestedRoomNameResource(for symbolName: String) -> LocalizedStringResource {
        for category in categories {
            if let icon = category.icons.first(where: { $0.symbolName == symbolName }) {
                return icon.suggestedRoomName
            }
        }
        return fallbackSuggestedRoomName
    }
}
