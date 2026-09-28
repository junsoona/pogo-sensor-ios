import Foundation

/// Builds the source-neutral `DeviceSummary` list from both sources and applies the duplicate
/// policy.
///
/// ## Duplicate policy (POGO Linux API vs. Apple Home)
///
/// A POGO sensor module can appear twice: once from the Linux PogoHome API, and once in Apple
/// Home, if the user also added the Linux Matter bridge there (each module is a bridged Matter
/// endpoint). The two paths share no identifier PogoHome can read: the bridge publishes the
/// module UUID only as the Matter `UniqueID` attribute, which HomeKit does not expose, and the
/// PogoHome API does not report Matter endpoint IDs. So:
///
/// 1. The POGO Linux API entry is the canonical one for a POGO module. Its UUID, name, room and
///    automatic recovery are PogoHome's own and are never changed by anything in Apple Home.
/// 2. Nothing is merged automatically — not by name, room, model or sensor types. Guessing
///    could hide a real, different device.
/// 3. The user can mark an Apple Home accessory as the same device as a POGO module. While that
///    module exists in the POGO snapshot, the Apple Home entry is listed under
///    `hiddenDuplicates` instead of `visible` (still reachable, never deleted from Apple Home).
/// 4. If the linked module is not in the POGO snapshot, the link has no effect and the Apple
///    Home entry is visible again — a device is never hidden from both lists.
/// 5. The two entries keep separate identities (`DeviceIdentifier` includes the source), so a
///    command for one can never be sent to the other.
nonisolated enum DeviceDirectory {
    struct Listing: Hashable, Sendable {
        let visible: [DeviceSummary]
        let hiddenDuplicates: [DeviceSummary]
    }

    static func listing(
        pogo: HomeSnapshot,
        isPogoStateVerified: Bool,
        appleHome: AppleHomeSnapshot,
        links: [UUID: UUID]
    ) -> Listing {
        let pogoSummaries = pogo.modules.map { module in
            pogoSummary(module, room: pogo.room(for: module), isStateVerified: isPogoStateVerified)
        }
        let pogoIDs = Set(pogo.modules.map(\.id))
        var visible = pogoSummaries
        var hidden: [DeviceSummary] = []
        for accessory in appleHome.accessories {
            let linkedModule = links[accessory.id].flatMap { pogoIDs.contains($0) ? $0 : nil }
            let summary = appleHomeSummary(accessory, linkedPogoModuleID: linkedModule)
            if summary.duplicateOf == nil {
                visible.append(summary)
            } else {
                hidden.append(summary)
            }
        }
        return Listing(visible: visible, hiddenDuplicates: hidden)
    }

    /// A POGO module as-is: id, name and room exactly as `AppModel` presents them.
    static func pogoSummary(_ module: SensorModule, room: Room?, isStateVerified: Bool) -> DeviceSummary {
        DeviceSummary(
            id: .pogoModule(module.id),
            name: module.name,
            roomName: room?.name,
            connection: isStateVerified ? (module.isOnline ? .connected : .disconnected) : .unverified,
            lastCheckedAt: module.lastSeen,
            values: module.sortedReadings.map { reading in
                DeviceReadableValue(
                    id: reading.kind.rawValue,
                    label: reading.kind.displayName,
                    displayValue: reading.formattedValue,
                    symbolName: reading.kind.symbolName,
                    needsAttention: reading.status.needsAttention
                )
            },
            // The PogoHome API is read-only.
            controls: [],
            isMatter: false,
            duplicateOf: nil
        )
    }

    static func appleHomeSummary(_ accessory: AppleHomeAccessory, linkedPogoModuleID: UUID?) -> DeviceSummary {
        DeviceSummary(
            id: .appleHomeAccessory(accessory.id),
            name: accessory.name,
            roomName: accessory.roomName,
            connection: accessory.isOperable ? .connected : .disconnected,
            lastCheckedAt: accessory.lastCheckedAt,
            values: AppleHomeCapabilities.values(of: accessory),
            controls: AppleHomeCapabilities.controls(of: accessory),
            isMatter: accessory.isMatter,
            duplicateOf: linkedPogoModuleID.map(DeviceIdentifier.pogoModule)
        )
    }
}
