import Foundation

/// Builds the POGO part of a glance from one snapshot fetched just now, outside the app's live
/// connection: the iPhone answering the Watch while PogoHome isn't in the foreground, or the Watch
/// reading the bridge itself. Same rules as `HomeGlanceBuilder`: a complete snapshot is a
/// confirmation at `fetchedAt`; an incomplete one (the bridge's registry rebuilding) keeps the
/// previous values, unverified. The Apple Home part is carried over untouched.
nonisolated enum PogoGlanceRefresher {
    static func refreshed(
        previous: HomeGlanceSnapshot?,
        fetched snapshot: HomeSnapshot,
        from source: SensorSourceIdentity,
        fetchedAt: Date,
        homeName: String
    ) -> HomeGlanceSnapshot {
        let health = HomeHealthEvaluator.evaluate(
            snapshot: snapshot,
            connectionStatus: .connected,
            lastSyncAt: fetchedAt,
            now: fetchedAt
        )
        let (section, sensors) = HomeGlanceBuilder.pogoPart(
            HomeGlanceBuilder.PogoInput(
                snapshot: snapshot,
                health: health,
                connectionStatus: .connected,
                lastSyncAt: fetchedAt,
                isSimulated: false,
                sessionStartedAt: fetchedAt,
                source: source
            ),
            previous: previous
        )
        return HomeGlanceSnapshot(
            writtenAt: fetchedAt,
            homeName: homeName,
            pogo: section,
            appleHome: previous?.appleHome ?? .off,
            sensors: sensors + (previous?.appleHomeSensors ?? [])
        )
    }

    /// Names modules — and places them in rooms — as the iPhone last described them. Modules the
    /// iPhone didn't describe keep the bridge catalog's name and room.
    static func applyingLabels(_ labels: [WatchModuleLabel], to snapshot: HomeSnapshot) -> HomeSnapshot {
        guard !labels.isEmpty else { return snapshot }
        let byModule = Dictionary(labels.map { ($0.moduleID, $0) }, uniquingKeysWith: { first, _ in first })

        // Rooms in the order the iPhone lists its modules (the order its rooms are sorted in).
        var rooms: [Room] = []
        var roomIDsByName: [String: UUID] = [:]
        for label in labels {
            guard let name = label.roomName, roomIDsByName[name] == nil else { continue }
            let id = ModuleIdentity.stableUUID(forRawIdentifier: Data(name.utf8).map { String(format: "%02x", $0) }.joined(), namespace: "pogohome.watch.room.v1")
            roomIDsByName[name] = id
            rooms.append(Room(id: id, name: name, symbolName: "square.split.2x2", sortOrder: rooms.count))
        }

        let modules = snapshot.modules.map { module -> SensorModule in
            guard let label = byModule[module.id] else { return module }
            return SensorModule(
                id: module.id,
                name: label.name,
                hardwareName: module.hardwareName,
                hardwareIdentifier: module.hardwareIdentifier,
                roomID: label.roomName.flatMap { roomIDsByName[$0] } ?? module.roomID,
                readings: module.readings,
                isOnline: module.isOnline,
                lastSeen: module.lastSeen,
                roleDescription: module.roleDescription,
                powerBaseIdentifier: module.powerBaseIdentifier,
                parentIdentifier: module.parentIdentifier
            )
        }
        let usedRoomIDs = Set(modules.map(\.roomID))
        let catalogRooms = snapshot.rooms.filter { usedRoomIDs.contains($0.id) && !rooms.contains($0) }
        return HomeSnapshot(
            timestamp: snapshot.timestamp,
            rooms: rooms + catalogRooms,
            modules: modules,
            powerBases: snapshot.powerBases,
            reportsPowerBases: snapshot.reportsPowerBases
        )
    }
}

/// How the Watch combines glances that reach it by different ways — the iPhone's hand-overs and
/// its own direct reads — into the one it shows.
///
/// - POGO: the more recent *confirmation* (`pogo.verifiedAt`) wins; for the same confirmation, the
///   later-written glance wins, so "no longer confirmed" isn't undone by an older copy. A switch
///   between simulated and live data, or to another hub, goes by what was written last.
/// - Apple Home: while either side can't read Apple Home, the later-written glance decides —
///   values of a revoked or turned-off Apple Home never come back from an older copy. Otherwise the
///   more recent confirmation wins.
nonisolated enum WatchGlanceMerger {
    static func merge(current: HomeGlanceSnapshot?, incoming: HomeGlanceSnapshot) -> HomeGlanceSnapshot {
        guard let current else { return incoming }
        let incomingIsLater = incoming.writtenAt >= current.writtenAt

        let takesIncomingPogo: Bool
        if incoming.pogo.isSimulated != current.pogo.isSimulated || incoming.pogo.sourceID != current.pogo.sourceID {
            takesIncomingPogo = incomingIsLater
        } else {
            takesIncomingPogo = isMoreRecent(incoming.pogo.verifiedAt, than: current.pogo.verifiedAt) ?? incomingIsLater
        }

        let takesIncomingAppleHome: Bool
        if incoming.appleHome.access != .ready || current.appleHome.access != .ready {
            takesIncomingAppleHome = incomingIsLater
        } else {
            takesIncomingAppleHome = isMoreRecent(incoming.appleHome.verifiedAt, than: current.appleHome.verifiedAt) ?? incomingIsLater
        }

        let pogoSource = takesIncomingPogo ? incoming : current
        let appleHomeSource = takesIncomingAppleHome ? incoming : current
        return HomeGlanceSnapshot(
            writtenAt: max(incoming.writtenAt, current.writtenAt),
            homeName: incomingIsLater ? incoming.homeName : current.homeName,
            pogo: pogoSource.pogo,
            appleHome: appleHomeSource.appleHome,
            sensors: pogoSource.pogoSensors + appleHomeSource.appleHomeSensors
        )
    }

    /// No way to the bridge worked: the values stay, but the POGO state is no longer confirmed.
    static func markingUnreachable(_ glance: HomeGlanceSnapshot?, at date: Date) -> HomeGlanceSnapshot? {
        guard var glance else { return nil }
        if glance.pogo.state != .waitingForData {
            glance.pogo.state = .unverified
        }
        glance.writtenAt = max(glance.writtenAt, date)
        return glance
    }

    /// `nil` when both are the same moment (or both missing).
    private static func isMoreRecent(_ a: Date?, than b: Date?) -> Bool? {
        switch (a, b) {
        case (nil, nil): return nil
        case (_?, nil): return true
        case (nil, _?): return false
        case let (a?, b?): return a == b ? nil : a > b
        }
    }
}
