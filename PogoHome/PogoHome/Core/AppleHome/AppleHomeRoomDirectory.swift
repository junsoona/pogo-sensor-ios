import Foundation

/// Where an Apple Home accessory sits, by HomeKit identity only: the home's and the room's
/// `uniqueIdentifier`. `roomID == nil` is that home's "no room" group (HomeKit's default room).
///
/// Names are never part of the key, so two homes that each have a "거실", or an Apple Home room
/// named like a POGO room, stay separate groups — and a room renamed in Apple Home keeps its
/// group.
nonisolated struct AppleHomeRoomKey: Hashable, Sendable {
    let homeID: UUID
    let roomID: UUID?
}

/// One Apple Home room (or a home's "no room" group) and the accessories in it.
nonisolated struct AppleHomeRoomGroup: Identifiable, Hashable, Sendable {
    let id: AppleHomeRoomKey
    /// HomeKit's current room name; `nil` for the "no room" group (the UI names it).
    let name: String?
    let accessories: [AppleHomeAccessory]

    var isUnassigned: Bool { id.roomID == nil }
    var notRespondingCount: Int { accessories.filter { !$0.isOperable }.count }
}

nonisolated struct AppleHomeHomeGroup: Identifiable, Hashable, Sendable {
    let home: AppleHomeInfo
    /// Named rooms by name (then id), the "no room" group last; empty groups are left out.
    let rooms: [AppleHomeRoomGroup]

    var id: UUID { home.id }
    var accessoryCount: Int { rooms.reduce(0) { $0 + $1.accessories.count } }
}

/// The Apple Home part of the Rooms, Devices and Dashboard screens: the accessories the
/// duplicate policy (`DeviceDirectory`) leaves visible, grouped by home and room, plus the
/// ones hidden as duplicates of POGO sensors.
///
/// Apple Home rooms are only ever read from HomeKit here; they are never copied into the POGO
/// room store, and POGO rooms never appear here.
nonisolated struct AppleHomeLayout: Hashable, Sendable {
    let homes: [AppleHomeHomeGroup]
    /// Accessories the user marked as the same device as a POGO sensor (still reachable).
    let hiddenDuplicates: [AppleHomeAccessory]

    static let empty = AppleHomeLayout(homes: [], hiddenDuplicates: [])

    var visibleAccessories: [AppleHomeAccessory] {
        homes.flatMap { $0.rooms.flatMap(\.accessories) }
    }

    func room(_ key: AppleHomeRoomKey) -> AppleHomeRoomGroup? {
        homes.first { $0.id == key.homeID }?.rooms.first { $0.id == key }
    }

    func hiddenDuplicates(in key: AppleHomeRoomKey) -> [AppleHomeAccessory] {
        hiddenDuplicates.filter { AppleHomeRoomDirectory.key(of: $0) == key }
    }
}

nonisolated enum AppleHomeRoomDirectory {
    static func key(of accessory: AppleHomeAccessory) -> AppleHomeRoomKey {
        AppleHomeRoomKey(homeID: accessory.homeID, roomID: accessory.roomID)
    }

    static func layout(snapshot: AppleHomeSnapshot, listing: DeviceDirectory.Listing) -> AppleHomeLayout {
        let visibleIDs = Set(listing.visible.filter { $0.source == .appleHome }.map(\.id.rawValue))
        let hiddenIDs = Set(listing.hiddenDuplicates.filter { $0.source == .appleHome }.map(\.id.rawValue))
        let visible = snapshot.accessories.filter { visibleIDs.contains($0.id) }
        let hidden = snapshot.accessories.filter { hiddenIDs.contains($0.id) }.sorted(by: byName)
        return AppleHomeLayout(homes: groups(visible, homes: snapshot.homes), hiddenDuplicates: hidden)
    }

    /// Groups by home (in HomeKit's order) and room. Accessories whose home isn't in `homes`
    /// are left out rather than attached to a guessed home.
    static func groups(_ accessories: [AppleHomeAccessory], homes: [AppleHomeInfo]) -> [AppleHomeHomeGroup] {
        homes.compactMap { home in
            let inHome = accessories.filter { $0.homeID == home.id }
            guard !inHome.isEmpty else { return nil }
            let byRoom = Dictionary(grouping: inHome) { $0.roomID }
            let rooms = byRoom.map { roomID, members -> AppleHomeRoomGroup in
                AppleHomeRoomGroup(
                    id: AppleHomeRoomKey(homeID: home.id, roomID: roomID),
                    // Every accessory in a room reports the same, current HomeKit name.
                    name: roomID == nil ? nil : members.lazy.compactMap(\.roomName).first ?? "",
                    accessories: members.sorted(by: byName)
                )
            }
            return AppleHomeHomeGroup(home: home, rooms: rooms.sorted(by: roomOrder))
        }
    }

    private static func roomOrder(_ a: AppleHomeRoomGroup, _ b: AppleHomeRoomGroup) -> Bool {
        switch (a.id.roomID, b.id.roomID) {
        case (nil, _): return false
        case (_, nil): return true
        case let (aID?, bID?):
            switch (a.name ?? "").localizedStandardCompare(b.name ?? "") {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return aID.uuidString < bID.uuidString
            }
        }
    }

    private static func byName(_ a: AppleHomeAccessory, _ b: AppleHomeAccessory) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id.uuidString < b.id.uuidString
        }
    }
}
