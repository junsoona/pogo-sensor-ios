import Foundation

/// A readable summary of a shared-settings document, for the screens where the user confirms
/// uploading this device's settings or using the hub's.
nonisolated struct SharedSettingsSummary: Hashable, Sendable {
    struct ModuleLine: Hashable, Sendable, Identifiable {
        /// The real module UUID.
        let id: String
        let name: String
        let roomName: String
    }

    let document: HubSettingsDocument
    let homeName: String
    let isDefaultHomeName: Bool
    /// In display order, without "미지정 공간".
    let rooms: [Room]
    let modules: [ModuleLine]
    /// This device's module settings that are not shared because the module isn't on this hub
    /// right now (another hub's module, a simulated one, or one that is not connected).
    let leftOutModuleCount: Int

    /// What uploading this device's own settings would share: its home name and rooms, and the
    /// names/rooms of the modules the current hub reports.
    static func upload(local: HomeConfigurationSnapshot, snapshot: HomeSnapshot, language: AppLanguage) -> SharedSettingsSummary {
        let raw = HubSettingsMapping.rawIdentifiers(document: nil, snapshot: snapshot)
        let document = HubSettingsMapping.document(from: local, rawIdentifiers: raw)
        let leftOut = local.modules.values.filter { module in
            raw[module.moduleID] == nil && (module.customName != nil || module.roomID != ModuleCatalog.unspecifiedRoomID)
        }.count
        return make(document: document, snapshot: snapshot, language: language, leftOutModuleCount: leftOut)
    }

    /// The hub's settings as they would appear on this device.
    static func hub(_ document: HubSettingsDocument, snapshot: HomeSnapshot, language: AppLanguage) -> SharedSettingsSummary {
        make(document: document, snapshot: snapshot, language: language, leftOutModuleCount: 0)
    }

    private static func make(document: HubSettingsDocument, snapshot: HomeSnapshot, language: AppLanguage, leftOutModuleCount: Int) -> SharedSettingsSummary {
        let configuration = HubSettingsMapping.configuration(from: document, language: language)
        let rooms = configuration.rooms.filter { $0.id != ModuleCatalog.unspecifiedRoomID }.sorted { $0.sortOrder < $1.sortOrder }
        let roomNames = Dictionary(uniqueKeysWithValues: configuration.rooms.map { ($0.id, $0.name) })
        let modules = document.modules.map { module in
            let id = ModuleIdentity.stableUUID(forRawIdentifier: module.uuid)
            let hardwareName = snapshot.modules.first { $0.id == id }?.hardwareName
            let unspecified = language.string(ModuleCatalog.unspecifiedRoomName)
            return ModuleLine(
                id: module.uuid,
                name: module.name ?? hardwareName ?? module.uuid,
                roomName: module.roomID.flatMap { roomNames[$0] } ?? unspecified
            )
        }
        return SharedSettingsSummary(
            document: document,
            homeName: document.homeName ?? HomeConfigurationDefaults.homeName(in: language),
            isDefaultHomeName: document.homeName == nil,
            rooms: rooms,
            modules: modules,
            leftOutModuleCount: leftOutModuleCount
        )
    }
}

extension AppModel {
    /// What "이 기기 설정 올리기" would share with the hub the app follows now. Always this device's
    /// own settings — never another hub's shared copy.
    func sharedSettingsUploadSummary() -> SharedSettingsSummary {
        SharedSettingsSummary.upload(local: deviceConfiguration, snapshot: sensorSnapshot, language: language)
    }

    func sharedSettingsSummary(of document: HubSettingsDocument) -> SharedSettingsSummary {
        SharedSettingsSummary.hub(document, snapshot: sensorSnapshot, language: language)
    }
}
