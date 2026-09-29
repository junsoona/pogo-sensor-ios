import SwiftUI

/// The Rooms tab's Apple Home part, below the POGO rooms: every Apple Home room that has a
/// visible accessory, per home, exactly as HomeKit names and assigns them. Nothing here is
/// stored in PogoHome; a room moved or renamed in the Home app shows up here as HomeKit
/// reports it.
struct AppleHomeRoomsSection: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let state = appleHome.snapshot.accessState
        let layout = appleHome.layout(pogo: appModel.snapshot)
        let roomCount = layout.homes.reduce(0) { $0 + $1.rooms.count }
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(
                title: "Apple 홈",
                subtitle: state == .ready
                    ? String(localized: "rooms.count", defaultValue: "\(roomCount)개", comment: "Number of rooms (plural)")
                    : AppleHomeText.accessStateSummary(state)
            )
            if state != .ready {
                AppleHomeAccessNotice(state: state)
            } else if layout.homes.isEmpty {
                Text("Apple 홈의 방에 표시할 기기가 없습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(layout.homes) { home in
                    VStack(alignment: .leading, spacing: 10) {
                        AppleHomeHomeHeader(group: home)
                        // Top-aligned and row-filling, like the POGO room cards above.
                        LazyVGrid(columns: PogoTheme.cardColumns(for: dynamicTypeSize, alignment: .top), spacing: PogoTheme.gridSpacing) {
                            ForEach(home.rooms) { room in
                                NavigationLink(value: AppleHomeRoute.room(room.id)) {
                                    AppleHomeRoomCard(room: room)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A home's name over its rooms/devices, with how many devices are listed.
struct AppleHomeHomeHeader: View {
    let group: AppleHomeHomeGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "house.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: group.home.name)
                .font(.headline)
            Spacer(minLength: 8)
            Text(String(localized: "devices.count", defaultValue: "\(group.accessoryCount)개", comment: "Number of devices (plural)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A room's name over its devices (Devices tab, Dashboard).
struct AppleHomeRoomGroupHeader: View {
    let room: AppleHomeRoomGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: AppleHomeRoomText.name(of: room))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(String(localized: "devices.count", defaultValue: "\(room.accessories.count)개", comment: "Number of devices (plural)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

enum AppleHomeRoomText {
    static func name(of room: AppleHomeRoomGroup) -> String {
        guard let name = room.name else {
            return String(localized: "방 미지정", comment: "Device card: module has no room")
        }
        return name.isEmpty ? String(localized: "이름 없는 방", comment: "Apple Home room whose name is empty") : name
    }

    static func summary(of room: AppleHomeRoomGroup) -> String {
        let count = String(localized: "devices.count", defaultValue: "\(room.accessories.count)개", comment: "Number of devices (plural)")
        let notResponding = room.notRespondingCount
        guard notResponding > 0 else { return count }
        return String(
            localized: "\(count) · 응답 없음 \(notResponding)",
            comment: "Apple Home room card: number of devices · number not responding"
        )
    }
}

private struct AppleHomeRoomCard: View {
    let room: AppleHomeRoomGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconCircle(
                systemName: room.isUnassigned ? "questionmark.square.dashed" : "square.grid.2x2.fill",
                diameter: 38,
                background: room.isUnassigned ? Color(.systemGray) : .orange
            )
            DeviceSourceBadge(text: String(localized: "Apple 홈", comment: "Source badge of an Apple Home room"))
            Text(verbatim: AppleHomeRoomText.name(of: room))
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Text(AppleHomeRoomText.summary(of: room))
                .font(.caption)
                .foregroundStyle(room.notRespondingCount > 0 ? Color.red : Color.secondary)
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 142, maxHeight: .infinity, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AppleHomeRoomText.name(of: room)))
        .accessibilityValue(Text(verbatim: "\(String(localized: "Apple 홈", comment: "Source badge of an Apple Home room")), \(AppleHomeRoomText.summary(of: room))"))
        .accessibilityAddTraits(.isButton)
    }
}

/// One Apple Home room's devices, identified by home and room id — so it follows a rename, and
/// shows "not found" once HomeKit no longer lists a visible device in it.
struct AppleHomeRoomDetailView: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let key: AppleHomeRoomKey

    var body: some View {
        let state = appleHome.snapshot.accessState
        let layout = appleHome.layout(pogo: appModel.snapshot)
        let room = layout.room(key)
        let hidden = layout.hiddenDuplicates(in: key)
        Group {
            if state != .ready {
                CenteredEmptyState {
                    AppleHomeAccessNotice(state: state)
                }
            } else if let room {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let home = appleHome.snapshot.home(with: key.homeID) {
                            Label {
                                Text(verbatim: home.name)
                            } icon: {
                                Image(systemName: "house.fill").foregroundStyle(.orange)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: PogoTheme.cardColumns(for: dynamicTypeSize), spacing: PogoTheme.gridSpacing) {
                            ForEach(room.accessories) { accessory in
                                AppleHomeAccessoryTile(accessory: accessory, showsRoom: false)
                            }
                        }
                        AppleHomeHiddenDuplicatesList(accessories: hidden)
                    }
                    .padding()
                }
                .screenBackground()
            } else {
                CenteredEmptyState {
                    ContentUnavailableView(
                        "방을 찾을 수 없습니다",
                        systemImage: "questionmark.circle",
                        description: Text("Apple 홈에서 이 방이 삭제되었거나, 이 방에 표시할 기기가 더 이상 없습니다.")
                    )
                }
            }
        }
        .detailTitle(room.map(AppleHomeRoomText.name(of:)) ?? String(localized: "room.detail.fallbackTitle", defaultValue: "방", comment: "Title of a room screen whose room no longer exists (singular)"))
    }
}

/// Apple Home accessories hidden as duplicates of POGO sensors — collapsed, still reachable.
struct AppleHomeHiddenDuplicatesList: View {
    let accessories: [AppleHomeAccessory]

    var body: some View {
        if !accessories.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(accessories) { accessory in
                        NavigationLink(value: AppleHomeRoute.accessory(accessory.id)) {
                            Label(accessory.name, systemImage: "link")
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("조각보 센서와 같은 Apple 홈 기기 \(accessories.count)개", comment: "Collapsed list of Apple Home accessories hidden as duplicates of POGO sensors (plural)")
                    .font(.subheadline)
            }
        }
    }
}
