import SwiftUI

/// User-facing wording for Apple Home state, shared by the device list, detail and Settings.
enum AppleHomeText {
    static func accessStateSummary(_ state: AppleHomeAccessState) -> String {
        switch state {
        case .off: return String(localized: "꺼짐", comment: "Apple Home in PogoHome: turned off")
        case .unsupported: return String(localized: "지원되지 않음", comment: "Apple Home in PogoHome: not available on this device")
        case .loading: return String(localized: "확인 중", comment: "Apple Home in PogoHome: loading")
        case .denied: return String(localized: "접근 거부됨", comment: "Apple Home in PogoHome: permission denied")
        case .restricted: return String(localized: "접근 제한됨", comment: "Apple Home in PogoHome: restricted by the system")
        case .noHome: return String(localized: "집 없음", comment: "Apple Home in PogoHome: no home exists")
        case .ready: return String(localized: "연결됨", comment: "Power Base state: the bridge hears it")
        }
    }

    static func connection(of accessory: AppleHomeAccessory) -> String {
        if accessory.isBlocked {
            return String(localized: "Apple 홈에서 차단됨", comment: "Apple Home accessory state: blocked by HomeKit")
        }
        return accessory.isReachable
            ? String(localized: "응답함", comment: "Apple Home accessory state: reachable")
            : String(localized: "응답 없음", comment: "Apple Home accessory state: not reachable")
    }

    static func lastChecked(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "아직 값을 읽지 않음", comment: "Apple Home accessory: no value read yet")
        }
        return String(
            localized: "마지막 확인 \(date.formatted(.relative(presentation: .numeric)))",
            comment: "Apple Home accessory: when a value was last read (relative time)"
        )
    }

    /// The tile's "last checked" line, worded by `AppleHomeValueStatus`: an accessory with
    /// nothing to read isn't described as "not read yet", and while an automatic read is pending
    /// only an earlier check (if any) is mentioned.
    static func valueCheckLine(of accessory: AppleHomeAccessory) -> String? {
        switch AppleHomeValueStatus.resolve(accessory) {
        case .nothingToRead:
            return String(localized: "읽을 수 있는 값 없음", comment: "Apple Home accessory: it has no value PogoHome can read (not a failure)")
        case .checking, .retrying:
            return accessory.lastCheckedAt.map { lastChecked($0) }
        case .failed, .checked, .notChecked:
            return lastChecked(accessory.lastCheckedAt)
        }
    }

    /// An automatic read is being retried after a transient failure.
    static func retrying(attempt: Int, maxAttempts: Int) -> String {
        String(
            localized: "값 읽기 지연 · 자동으로 다시 읽는 중 (\(attempt)/\(maxAttempts))",
            comment: "Apple Home: a value read was slow or timed out and is retried automatically; attempt number / maximum attempts"
        )
    }

    static func source(of accessory: AppleHomeAccessory) -> String {
        accessory.isMatter
            ? String(localized: "Apple 홈 · Matter", comment: "Device source: Apple Home, Matter accessory")
            : String(localized: "Apple 홈 · HomeKit", comment: "Device source: Apple Home, HomeKit accessory")
    }

    static func symbolName(for accessory: AppleHomeAccessory) -> String {
        let kinds = accessory.services.map(\.kind)
        let preferred: [(AppleHomeServiceKind, String)] = [
            (.lightbulb, "lightbulb.fill"), (.outlet, "poweroutlet.type.b.fill"), (.switch, "switch.2"),
            (.fan, "fan.fill"), (.airPurifier, "air.purifier.fill"), (.lockMechanism, "lock.fill"),
            (.windowCovering, "blinds.horizontal.closed"), (.temperatureSensor, "thermometer.medium"),
            (.humiditySensor, "humidity.fill"), (.airQualitySensor, "aqi.medium"), (.lightSensor, "sun.max.fill"),
            (.contactSensor, "door.left.hand.closed"), (.motionSensor, "figure.walk.motion"),
            (.occupancySensor, "person.fill"), (.leakSensor, "drop.fill"), (.smokeSensor, "smoke.fill"),
        ]
        return preferred.first { kinds.contains($0.0) }?.1 ?? "homekit"
    }
}

/// A small capsule naming where a device's data comes from.
struct DeviceSourceBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "homekit")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}

/// Explains why Apple Home devices aren't listed and offers the one action that can help.
/// Shown for every state except `.ready`.
struct AppleHomeAccessNotice: View {
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(\.openURL) private var openURL
    let state: AppleHomeAccessState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(tint)
            }
            if state == .loading {
                ProgressView()
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actionButton
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .off:
            Button("Apple 홈 연결") { appleHome.enable() }
                .buttonStyle(.borderedProminent)
        case .denied:
            Button {
                if let url = PlatformSupport.appleHomePermissionSettingsURL { openURL(url) }
            } label: {
                Text(PlatformSupport.isMacCatalyst
                    ? String(localized: "시스템 설정 열기", comment: "Mac: opens System Settings at the Apple Home permission")
                    : String(localized: "설정 열기"))
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private var title: String {
        switch state {
        case .off: return String(localized: "Apple 홈 기기 보기", comment: "Apple Home notice title: not turned on yet")
        case .unsupported: return String(localized: "Apple 홈을 사용할 수 없음", comment: "Apple Home notice title")
        case .loading: return String(localized: "Apple 홈 정보를 불러오는 중", comment: "Apple Home notice title")
        case .denied: return String(localized: "Apple 홈 접근이 허용되지 않음", comment: "Apple Home notice title")
        case .restricted: return String(localized: "Apple 홈 접근이 제한됨", comment: "Apple Home notice title")
        case .noHome: return String(localized: "Apple 홈에 집이 없음", comment: "Apple Home notice title")
        case .ready: return ""
        }
    }

    private var message: String {
        switch state {
        case .off:
            return PlatformSupport.isMacCatalyst
                ? String(localized: "Apple 홈에 추가한 Matter·HomeKit 기기를 조각보 홈에서 확인합니다. 연결하면 macOS가 Apple 홈 접근 권한을 묻습니다. 조각보 센서는 이 설정과 관계없이 그대로 표시됩니다.", comment: "Apple Home notice on the Mac: not turned on yet")
                : String(localized: "Apple 홈에 추가한 Matter·HomeKit 기기를 조각보 홈에서 확인합니다. 연결하면 iOS가 Apple 홈 접근 권한을 묻습니다. 조각보 센서는 이 설정과 관계없이 그대로 표시됩니다.", comment: "Apple Home notice: not turned on yet")
        case .unsupported:
            return String(localized: "이 기기에서는 HomeKit을 사용할 수 없습니다.", comment: "Apple Home notice")
        case .loading:
            return String(localized: "권한 요청에 답하면 Apple 홈의 기기 목록을 가져옵니다.", comment: "Apple Home notice: waiting for permission / first home list")
        case .denied:
            return PlatformSupport.isMacCatalyst
                ? String(localized: "시스템 설정 > 개인정보 보호 및 보안 > 홈에서 조각보 홈을 허용하면 Apple 홈 기기가 표시됩니다. 조각보 센서는 계속 정상적으로 표시됩니다.", comment: "Apple Home notice on the Mac: permission denied")
                : String(localized: "설정 > 개인정보 보호 및 보안 > 홈 데이터에서 조각보 홈을 허용하면 Apple 홈 기기가 표시됩니다. 조각보 센서는 계속 정상적으로 표시됩니다.", comment: "Apple Home notice: permission denied")
        case .restricted:
            return String(localized: "스크린 타임이나 기기 관리 설정 때문에 Apple 홈 데이터에 접근할 수 없습니다.", comment: "Apple Home notice: restricted")
        case .noHome:
            return String(localized: "Apple 홈 앱에서 집을 만들거나, 기기 추가 화면의 ‘Matter 기기 추가’로 기기를 등록하세요.", comment: "Apple Home notice: no home")
        case .ready:
            return ""
        }
    }

    private var symbolName: String {
        switch state {
        case .off, .noHome, .loading: return "homekit"
        case .denied, .restricted: return "hand.raised.fill"
        case .unsupported: return "xmark.circle"
        case .ready: return "checkmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .denied, .restricted: return .orange
        case .unsupported: return .secondary
        default: return .orange
        }
    }
}
