import Foundation
import os

/// The last settings this device confirmed with one hub — what the app shows while that hub is
/// off, and the revision the next change is based on. One file per `hub_id`, so one hub's rooms and
/// names are never shown for another hub (or for simulated data).
///
/// Only a device that turned sharing on (downloaded or uploaded) has an entry for a hub: the entry
/// is what "this device uses this hub's settings" means. The device's own on-device settings
/// (`SwiftDataHomeConfigurationStore`) are never touched by sharing and come back when it is turned
/// off.
nonisolated struct SharedSettingsCacheEntry: Codable, Hashable, Sendable {
    let hubID: String
    let revision: String
    let updatedAtUnixMs: Int64
    let settings: HubSettingsDocument
    let confirmedAt: Date
}

nonisolated protocol SharedSettingsCaching: Sendable {
    func entry(forHubID hubID: String) -> SharedSettingsCacheEntry?
    func save(_ entry: SharedSettingsCacheEntry) throws
    func removeEntry(forHubID hubID: String) throws
}

/// `Application Support/SharedHomeSettings/<hub_id>.json`, written atomically. Not in the App Group:
/// the widgets and the Watch get names through the glance, never from here.
nonisolated final class FileSharedSettingsCache: SharedSettingsCaching {
    private let directory: URL
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome", category: "SharedSettings")

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "SharedHomeSettings", directoryHint: .isDirectory)
    }

    private func fileURL(hubID: String) -> URL? {
        let id = hubID.lowercased()
        guard HubBonjour.isValidHubID(id) else { return nil }
        return directory.appending(path: "\(id).json", directoryHint: .notDirectory)
    }

    func entry(forHubID hubID: String) -> SharedSettingsCacheEntry? {
        guard let url = fileURL(hubID: hubID), let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(SharedSettingsCacheEntry.self, from: data),
              entry.hubID.lowercased() == hubID.lowercased() else {
            Self.logger.error("ignoring an unreadable shared settings cache for \(hubID, privacy: .public)")
            return nil
        }
        return entry
    }

    func save(_ entry: SharedSettingsCacheEntry) throws {
        guard let url = fileURL(hubID: entry.hubID) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeEntry(forHubID hubID: String) throws {
        guard let url = fileURL(hubID: hubID) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

/// For tests and previews.
nonisolated final class InMemorySharedSettingsCache: SharedSettingsCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SharedSettingsCacheEntry]
    var failsToSave = false

    init(_ entries: [SharedSettingsCacheEntry] = []) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.hubID.lowercased(), $0) })
    }

    func entry(forHubID hubID: String) -> SharedSettingsCacheEntry? {
        lock.withLock { entries[hubID.lowercased()] }
    }

    func save(_ entry: SharedSettingsCacheEntry) throws {
        try lock.withLock {
            if failsToSave { throw CocoaError(.fileWriteOutOfSpace) }
            entries[entry.hubID.lowercased()] = entry
        }
    }

    func removeEntry(forHubID hubID: String) throws {
        lock.withLock { _ = entries.removeValue(forKey: hubID.lowercased()) }
    }
}
