import Foundation

enum WatchSettingsKeys {
    /// `[String]` of `HomeGlanceValueID.stringValue`, in the order the Watch lists them.
    static let selectedValueIDs = "pogohome.watch.selectedValueIDs"
}

/// The iPhone's settings as the Watch receives them. Built fresh for every hand-over from what the
/// app itself uses — the same resolved bridge address, the same names — so the Watch can never be
/// configured differently from the iPhone.
enum PhoneWatchSettings {
    static func make(defaults: UserDefaults, snapshot: HomeSnapshot, now: Date) -> WatchSettings {
        let mode = DataSourceMode(rawValue: defaults.string(forKey: PogoSettingsKeys.dataSourceMode) ?? "") ?? .live
        let urlString = defaults.string(forKey: PogoSettingsKeys.liveBaseURL) ?? PogoAPIEndpoint.defaultBaseURLString
        // The address and hub the iPhone itself connects to (a hub picked in "Find hubs" wins over
        // the typed address, exactly as for the app's own connection).
        let target = DataSourceFactory.target(in: defaults)
        return WatchSettings(
            updatedAt: now,
            dataSourceMode: mode == .mock ? .mock : .live,
            hubBaseURL: (target.address ?? DataSourceFactory.resolvedLiveBaseURL(from: urlString)).absoluteString,
            hubID: target.selectedHub?.hubID,
            selectedValueIDs: selection(in: defaults),
            moduleLabels: moduleLabels(of: snapshot)
        )
    }

    static func selection(in defaults: UserDefaults) -> [String] {
        WatchSettings.normalizedSelection(defaults.stringArray(forKey: WatchSettingsKeys.selectedValueIDs) ?? [])
    }

    static func setSelection(_ ids: [String], in defaults: UserDefaults) {
        defaults.set(WatchSettings.normalizedSelection(ids), forKey: WatchSettingsKeys.selectedValueIDs)
    }

    /// Adds `id` at the end, or removes it. Returns `false` (and changes nothing) when adding
    /// would exceed `WatchSettings.maximumSelectedValues`.
    @discardableResult
    static func toggle(_ id: String, in defaults: UserDefaults) -> Bool {
        var ids = selection(in: defaults)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            guard ids.count < WatchSettings.maximumSelectedValues else { return false }
            ids.append(id)
        }
        setSelection(ids, in: defaults)
        return true
    }

    /// The user's names for every module, rooms in the user's order and modules by name within a
    /// room — the order the glance lists values in.
    static func moduleLabels(of snapshot: HomeSnapshot) -> [WatchModuleLabel] {
        let roomOrder = Dictionary(snapshot.rooms.map { ($0.id, $0.sortOrder) }, uniquingKeysWith: { first, _ in first })
        return snapshot.modules
            .sorted { a, b in
                let orderA = roomOrder[a.roomID] ?? .max
                let orderB = roomOrder[b.roomID] ?? .max
                if orderA != orderB { return orderA < orderB }
                switch a.name.localizedStandardCompare(b.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.id.uuidString < b.id.uuidString
                }
            }
            .map { WatchModuleLabel(moduleID: $0.id, name: $0.name, roomName: snapshot.room(for: $0)?.name) }
    }
}

/// Answers the Watch's "what is the state now?" — possibly with the app launched in the
/// background just for this. Never claims more than the iPhone knows:
///
/// - Simulated data is answered as such.
/// - With the app in the foreground and its POGO connection confirmed, that state is the answer.
/// - Otherwise the iPhone fetches the bridge's snapshot once. That works only where the iPhone
///   itself reaches the bridge (the home network); anywhere else the answer is "unreachable" with
///   the last stored glance, which the Watch keeps showing as not confirmed.
@MainActor
struct WatchRelayResponder {
    var settings: @MainActor () -> WatchSettings
    /// The app's current glance, only while it is in the foreground with a confirmed connection.
    var liveGlance: @MainActor () -> HomeGlanceSnapshot?
    /// The last glance the app built or stored, confirmed or not.
    var lastGlance: @MainActor () -> HomeGlanceSnapshot?
    /// Applies the user's names and rooms, as `AppModel.snapshot` shows them.
    var applyConfiguration: @MainActor (HomeSnapshot) -> HomeSnapshot
    var homeName: @MainActor () -> String
    var fetchSnapshot: @MainActor (URL) async throws -> HomeSnapshot
    var now: @MainActor () -> Date

    func reply() async -> WatchRelayReply {
        let settings = settings()
        if settings.dataSourceMode == .mock {
            return answer(.simulated, glance: liveGlance() ?? lastGlance(), settings: settings)
        }
        if let live = liveGlance() {
            return answer(.confirmed, glance: live, settings: settings)
        }
        guard let url = settings.directHubURL else {
            return answer(.hubUnreachable, glance: lastGlance(), settings: settings)
        }
        do {
            let fetched = try await fetchSnapshot(url)
            let fetchedAt = now()
            let glance = PogoGlanceRefresher.refreshed(
                previous: lastGlance(),
                fetched: applyConfiguration(fetched),
                from: settings.pogoSource ?? .hub(url),
                fetchedAt: fetchedAt,
                homeName: homeName()
            )
            return answer(glance.pogo.verifiedAt == fetchedAt ? .confirmed : .hubRecovering, glance: glance, settings: settings)
        } catch {
            return answer(.hubUnreachable, glance: lastGlance(), settings: settings)
        }
    }

    private func answer(_ outcome: WatchRelayReply.Outcome, glance: HomeGlanceSnapshot?, settings: WatchSettings) -> WatchRelayReply {
        WatchRelayReply(outcome: outcome, payload: WatchSyncPayload(sentAt: now(), glance: glance, settings: settings))
    }
}
