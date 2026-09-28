import Foundation
import os

/// Where the app leaves the latest `HomeGlanceSnapshot` for its widgets: one JSON file in the
/// App Group container both the app and the widget extension are entitled to
/// (`com.apple.security.application-groups`). The file outlives the app process, so a widget
/// can still read the last confirmed state while PogoHome isn't running.
///
/// The file is written atomically, so a reader sees either the previous or the new snapshot,
/// never a partial one. On iOS it stays readable after the first unlock following a restart
/// (`completeUntilFirstUserAuthentication`), which Lock Screen widgets need.
nonisolated struct HomeGlanceStore: Sendable {
    static let appGroupIdentifier = "group.com.junsoona.PogoHome"
    static let fileName = "home-glance.json"

    enum LoadResult: Equatable, Sendable {
        /// Nothing written yet (the app hasn't run since the widgets were installed).
        case missing
        /// A file exists but can't be used — damaged, or written by another schema version.
        case unreadable
        case snapshot(HomeGlanceSnapshot)

        var snapshot: HomeGlanceSnapshot? {
            if case let .snapshot(snapshot) = self { return snapshot }
            return nil
        }
    }

    let fileURL: URL

    private static let logger = Logger(subsystem: "com.junsoona.PogoHome", category: "HomeGlanceStore")

    init(directory: URL) {
        self.fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// The store in the shared App Group container, or `nil` if this build isn't entitled to
    /// the group (the widgets then show their "open the app" state).
    static func shared(fileManager: FileManager = .default) -> HomeGlanceStore? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            logger.error("App Group container unavailable: \(appGroupIdentifier, privacy: .public)")
            return nil
        }
        return HomeGlanceStore(directory: container.appending(path: "Library/Application Support/Glance", directoryHint: .isDirectory))
    }

    func load() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            Self.logger.error("glance read failed: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
        guard
            let snapshot = try? Self.decoder.decode(HomeGlanceSnapshot.self, from: data),
            snapshot.schemaVersion == HomeGlanceSnapshot.currentSchemaVersion
        else {
            return .unreadable
        }
        return .snapshot(snapshot)
    }

    func save(_ snapshot: HomeGlanceSnapshot) throws {
        let data = try Self.encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
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
