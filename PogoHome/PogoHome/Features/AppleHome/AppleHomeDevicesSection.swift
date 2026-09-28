import SwiftUI

/// The Devices tab's Apple Home part, below the POGO sensors. Shows only what HomeKit reports:
/// the access state, and for `.ready` the accessories the duplicate policy leaves visible,
/// grouped by home and then by room (by HomeKit id, never by name).
struct AppleHomeDevicesSection: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var snapshot: AppleHomeSnapshot { appleHome.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let layout = appleHome.layout(pogo: appModel.snapshot)

            HomeSectionHeader(
                title: "Apple 홈",
                subtitle: snapshot.accessState == .ready
                    ? String(localized: "devices.count", defaultValue: "\(layout.visibleAccessories.count)개", comment: "Number of devices (plural)")
                    : AppleHomeText.accessStateSummary(snapshot.accessState)
            )

            if snapshot.accessState != .ready {
                AppleHomeAccessNotice(state: snapshot.accessState)
            } else if layout.homes.isEmpty && layout.hiddenDuplicates.isEmpty {
                Text("Apple 홈에 등록된 기기가 없습니다. 오른쪽 위 + 버튼에서 Matter 기기를 추가할 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(layout.homes) { home in
                    VStack(alignment: .leading, spacing: 10) {
                        AppleHomeHomeHeader(group: home)
                        ForEach(home.rooms) { room in
                            AppleHomeRoomGroupHeader(room: room)
                            LazyVGrid(columns: PogoTheme.cardColumns(for: dynamicTypeSize), spacing: PogoTheme.gridSpacing) {
                                ForEach(room.accessories) { accessory in
                                    AppleHomeAccessoryTile(accessory: accessory, showsRoom: false)
                                }
                            }
                        }
                    }
                }
                AppleHomeHiddenDuplicatesList(accessories: layout.hiddenDuplicates)
            }
        }
    }
}
