import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center toggle for one Apple Home light, outlet or switch.
///
/// This extension only draws it, from the catalog the app stored (`AppleHomePowerStore`); it
/// never calls HomeKit. The tap runs `SetAppleHomePowerIntent` in the app process, which reads
/// the device, writes, and reads it back before the control shows the new state.
///
/// iOS 27 and later only: earlier systems can't pin the intent to the app process
/// (`allowedExecutionTargets`), and in this extension HomeKit refuses every request.
@available(iOS 27.0, *)
struct AppleHomePowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: AppleHomePowerControlKind.power,
            provider: AppleHomePowerValueProvider()
        ) { value in
            ControlWidgetToggle(
                isOn: value.display.isOn,
                action: SetAppleHomePowerIntent(target: value.entity, isShownStateKnown: value.display.isStateKnown)
            ) {
                Label(value.display.title, systemImage: value.display.symbolName)
                    .controlWidgetActionHint(Text(value.display.actionHint))
                    .modifier(ControlStatusModifier(status: value.display.status))
            } valueLabel: { isOn in
                // The system flips the toggle as soon as it's tapped; until the app has read the
                // device back and the control reloads, say that it's in progress.
                Text(isOn == value.display.isOn ? value.display.valueText : value.display.pendingText(requestedOn: isOn))
            }
        }
        .displayName(LocalizedStringResource("Apple 홈 기기 전원", comment: "Control gallery: Apple Home power control name"))
        .description(LocalizedStringResource("선택한 조명, 콘센트 또는 스위치를 켜고 끕니다. 기기가 새 상태를 보고해야 완료로 표시됩니다.", comment: "Control gallery: Apple Home power control description"))
        .promptsForUserConfiguration()
    }
}

/// Shows the last action's note (e.g. a failure) in Control Center right after it.
private struct ControlStatusModifier: ViewModifier {
    let status: String?

    func body(content: Content) -> some View {
        if let status {
            content.controlWidgetStatus(Text(status))
        } else {
            content
        }
    }
}

@available(iOS 27.0, *)
struct AppleHomePowerControlValue {
    let display: AppleHomePowerControlDisplay
    let entity: AppleHomePowerTargetEntity?
}

@available(iOS 27.0, *)
struct AppleHomePowerValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectAppleHomePowerTargetIntent) -> AppleHomePowerControlValue {
        let title = configuration.target?.name ?? String(localized: "거실 조명", comment: "Control gallery preview: sample light name")
        return AppleHomePowerControlValue(
            display: AppleHomePowerControlDisplay(title: title, state: .on, kind: .light, status: nil),
            entity: configuration.target
        )
    }

    func currentValue(configuration: SelectAppleHomePowerTargetIntent) async throws -> AppleHomePowerControlValue {
        let display = AppleHomePowerControlDisplay.make(
            targetID: configuration.target?.targetID,
            configuredName: configuration.target?.name,
            load: AppleHomePowerStore.shared()?.load() ?? .missing,
            now: Date()
        )
        return AppleHomePowerControlValue(display: display, entity: configuration.target)
    }
}
