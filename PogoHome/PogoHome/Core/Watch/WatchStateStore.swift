import Foundation
import os

/// Where the Watch keeps its state between launches — one JSON file in its App Group container,
/// read by its widgets too. Written atomically; readable after the first unlock since restart,
/// so complications can draw while the Watch is off the wrist.
nonisolated protocol WatchStateStoring: Sendable {
    func load() -> WatchStoredState
    func save(_ state: WatchStoredState) throws
}

nonisolated struct WatchStateStore: WatchStateStoring {
    static let fileName = "watch-state.json"

    let fileURL: URL

    private static let logger = Logger(subsystem: "com.junsoona.PogoHome", category: "WatchStateStore")

    init(directory: URL) {
        self.fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// The store in the App Group container shared by the Watch app and its widgets, or `nil` if
    /// this build isn't entitled to the group.
    static func shared(fileManager: FileManager = .default) -> WatchStateStore? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: HomeGlanceStore.appGroupIdentifier) else {
            logger.error("App Group container unavailable: \(HomeGlanceStore.appGroupIdentifier, privacy: .public)")
            return nil
        }
        return WatchStateStore(directory: container.appending(path: "Library/Application Support/Watch", directoryHint: .isDirectory))
    }

    /// A missing, damaged or other-version file reads as empty: the Watch then says it has no data
    /// rather than guessing.
    func load() -> WatchStoredState {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        guard
            let state = try? Self.decoder.decode(WatchStoredState.self, from: data),
            state.schemaVersion == WatchStoredState.currentSchemaVersion
        else {
            Self.logger.error("watch state unreadable; starting empty")
            return .empty
        }
        return state
    }

    func save(_ state: WatchStoredState) throws {
        let data = try Self.encoder.encode(state)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
