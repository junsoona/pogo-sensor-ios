import Foundation

nonisolated struct Room: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let symbolName: String
    let sortOrder: Int

    init(id: UUID, name: String, symbolName: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.sortOrder = sortOrder
    }
}
