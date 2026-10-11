import SwiftUI

/// The Power Base whose management sheet is shown.
struct PowerBaseManagementTarget: Identifiable, Hashable {
    /// The Base's EUI-64, 16 lower-case hex digits.
    let identifier: String
    var id: String { identifier }
}

/// "Power Base 관리": what the hub says about one Power Base, and removing (unenrolling) it.
///
/// The sheet only asks the hub and shows what the hub answers (see `PowerBaseRemovalController`):
/// it removes nothing from the app's lists itself, and it calls a removal done only when the
/// hub's job is `completed`.
///
/// The second action, "허브 목록에서 제거", is for an offline Base that does not come back: the
/// hub takes it out of its list at once (or refuses), and nothing is said about the board.
///
/// When the removal of this Base is completed while the app was following it -- or the hub took
/// the Base out of its list at this device's request -- the sheet closes --
/// with the "삭제 확인" screen, if that is where the user was. The tab shows the notice
/// (`PowerBaseRemovalCompletionNotice`).
///
/// The sheet reacts to completions that were recorded **after it was opened**
/// (`controller.completionEvents`, by serial), and only for its own Base: a job that was already
/// completed when it was first read is no event at all, a completion of another Base is not this
/// sheet's, and a completion from before the sheet was opened (the Base was registered again
/// since) is behind it. It closes while the app is in the foreground: a completion that arrives
/// in the background is kept, and the sheet closes when the user is back to see it.
struct PowerBaseManagementSheet: View {
    let target: PowerBaseManagementTarget
    let controller: PowerBaseRemovalController

    /// Replaced in tests: the controller of the "삭제 확인" screen.
    var makeConfirmation: (String) -> PowerBaseReleaseConfirmationController = {
        PowerBaseReleaseConfirmationController(powerBaseIdentifier: $0, provider: PowerBaseEnrollmentBLECentral())
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The serial of the latest completion event when this sheet was opened.
    @State private var openedAtSerial: Int?
    /// The removal whose erase is being confirmed (the pushed screen): released, or without a
    /// result for a long time.
    @State private var confirming: PowerBaseRemoval?

    private var state: PowerBaseManagementPresentation.State {
        PowerBaseManagementPresentation.state(
            identifier: target.identifier, snapshot: appModel.snapshot, target: controller.target,
            removal: controller.removal(for: target.identifier, in: appModel.snapshot),
            action: controller.action(for: target.identifier),
            isCurrentStateVerified: appModel.isPowerBaseStateVerified,
            forgetAction: controller.forgetAction(for: target.identifier)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                PowerBaseManagementContent(
                    state: state,
                    hasRefreshProblem: controller.refreshProblem != nil,
                    onDelete: { controller.requestRemoval(of: target.identifier, binding: $0) },
                    onRetryRemoval: { controller.retryRemoval(of: target.identifier) },
                    onCancelRemoval: { controller.cancelRemoval($0) },
                    onDismissFailure: { controller.dismissFailure(for: target.identifier) },
                    onConfirmErase: { confirming = $0 },
                    onForget: { controller.forgetPowerBase(target.identifier, record: $0) },
                    onRetryForget: { controller.retryForget(of: target.identifier) },
                    onDismissForgetFailure: { controller.dismissForgetFailure(for: target.identifier) }
                )
            }
            .sheetListSpacing()
            .navigationTitle(Text(verbatim: PowerBaseManagementText.sheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .sheetCloseAction { dismiss() }
            .navigationDestination(item: $confirming) { removal in
                PowerBaseReleaseConfirmationView(
                    powerBaseIdentifier: removal.powerBaseIdentifier,
                    origin: PowerBaseReleaseConfirmationOrigin(removal),
                    makeController: { makeConfirmation(removal.powerBaseIdentifier) },
                    // The hub's answer is shown at once; its snapshot follows.
                    onConfirmed: { controller.removalWasConfirmed($0) }
                )
            }
        }
        // On the sheet itself, not on a row: whichever screen of it is shown. One closure for the
        // sheet's place in the events and for the decision, so their order is not left to chance.
        .onChange(of: CloseCheck(isActive: scenePhase == .active, latestSerial: controller.completionSerial), initial: true) { _, check in
            let opened = openedAtSerial ?? check.latestSerial
            openedAtSerial = opened
            if check.isActive, Self.closes(on: controller.completionEvents, after: opened, target: target) { dismiss() }
        }
        // While the sheet is shown the hub's own list is read too: a job without confirmation
        // becomes "결과 확인 불가" with time alone, without any change in the snapshot.
        .task {
            while !Task.isCancelled {
                await controller.refresh()
                guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            }
        }
    }
}

extension PowerBaseManagementSheet {
    /// What the sheet looks at to decide whether to close: read together, compared together.
    fileprivate struct CloseCheck: Equatable {
        let isActive: Bool
        let latestSerial: Int
    }

    /// Whether the completions recorded since the sheet was opened (`serial`) end it: only a
    /// removal of the Base it is about.
    static func closes(on events: [PowerBaseRemovalController.CompletionEvent], after serial: Int, target: PowerBaseManagementTarget) -> Bool {
        events.contains { $0.serial > serial && $0.completion.powerBaseIdentifier == target.identifier }
    }
}

/// The sheet's sections. Separate from the owner above so every state can be rendered in a test.
struct PowerBaseManagementContent: View {
    let state: PowerBaseManagementPresentation.State
    var hasRefreshProblem = false
    /// Asks the hub to remove the Base; the argument is what the user was shown when the
    /// confirmation opened -- the registration and its removal serial.
    var onDelete: (PowerBaseRemovalBinding) -> Void = { _ in }
    /// Sends the removal request that got no answer again, unchanged.
    var onRetryRemoval: () -> Void = {}
    var onCancelRemoval: (PowerBaseRemoval) -> Void = { _ in }
    var onDismissFailure: () -> Void = {}
    /// Opens the screen that confirms a Base's erase over Bluetooth (see
    /// `PowerBaseRemoval.offersEraseConfirmation`).
    var onConfirmErase: (PowerBaseRemoval) -> Void = { _ in }
    /// Shows the delete confirmation as soon as the content appears. For tests and renders: the
    /// dialog is otherwise only reachable by a tap.
    var startsConfirming = false
    /// Asks the hub to take the Base out of its list; the argument is the registration the user
    /// was shown (`PowerBase.record`).
    var onForget: (String) -> Void = { _ in }
    var onRetryForget: () -> Void = {}
    var onDismissForgetFailure: () -> Void = {}
    /// Shows the "허브 목록에서 제거" confirmation as soon as the content appears (tests, renders).
    var startsConfirmingForget = false

    @State private var isConfirming = false
    /// What the open "Power Base 삭제" dialog was opened for.
    @State private var removalConfirmation = PowerBaseRemovalConfirmation()
    @State private var isConfirmingForget = false
    /// The registration the open "허브 목록에서 제거" dialog was opened for.
    @State private var forgetConfirmation = PowerBaseForgetConfirmation()

    private typealias T = PowerBaseManagementText

    var body: some View {
        statusSection
            .onAppear {
                if startsConfirming {
                    removalConfirmation.open(for: state.removalBinding)
                    isConfirming = true
                }
                if startsConfirmingForget, let offer = state.forgetOffer {
                    forgetConfirmation.open(for: offer)
                    isConfirmingForget = true
                }
            }
        if let removal = state.removal {
            removalSection(removal)
        }
        deleteSection
        forgetSection
    }

    private var statusSection: some View {
        Section {
            SheetIconRow(systemImage: "powerplug.fill", iconStyle: .tint) {
                Text(verbatim: state.label)
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.connection(of: state.base, isCurrentStateVerified: state.isCurrentStateVerified))
                    .font(.subheadline)
                    .foregroundStyle(state.isCurrentStateVerified && state.base?.isOnline == false ? Color.red : Color.secondary)
                    .sheetParagraph()
                Text(verbatim: T.sensors(state.sensorCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text(verbatim: T.statusHeader)
        }
        .sheetRowInsets()
    }

    private func removalSection(_ removal: PowerBaseRemoval) -> some View {
        let presentation = removal.presentation
        return Section {
            SheetIconRow(systemImage: Self.symbol(presentation), iconStyle: Self.style(presentation)) {
                Text(verbatim: T.removalTitle(presentation))
                    .font(.headline)
                    .sheetParagraph()
                Text(verbatim: T.removalMessage(presentation))
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
            if hasRefreshProblem {
                SheetIconRow(systemImage: "wifi.exclamationmark", iconStyle: .orange) {
                    Text(verbatim: T.refreshProblem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
            if removal.settingsCleanupPending {
                // A different thing from the removal's own state: shown next to it, not as it.
                SheetIconRow(systemImage: "clock.arrow.circlepath", iconStyle: .secondary) {
                    Text(verbatim: T.cleanupPending)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(PowerBaseManagementPresentation.removalActions(for: removal, isActing: state.action != nil), id: \.self) { action in
                switch action {
                case .confirmErase:
                    if presentation == .resultUnknown || presentation == .removedFromListUnconfirmed {
                        // The state above stays "결과 확인 불가": the button is a way to find out,
                        // not a result.
                        SheetIconRow(systemImage: "info.circle", iconStyle: .secondary) {
                            Text(verbatim: T.confirmEraseWhenUnknown)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Button {
                        onConfirmErase(removal)
                    } label: {
                        SheetIconRow(systemImage: "checkmark.shield") { Text(verbatim: T.confirmErase) }
                    }
                case .cancel:
                    Button {
                        onCancelRemoval(removal)
                    } label: {
                        SheetIconRow(systemImage: "arrow.uturn.backward") { Text(verbatim: T.cancelRemoval) }
                    }
                }
            }
        } header: {
            Text(verbatim: T.removalHeader)
        }
        .sheetRowInsets()
    }

    @ViewBuilder
    private var deleteSection: some View {
        let unavailable = T.unavailableMessage(state.availability)
        if state.action != nil || state.availability == .available || unavailable != nil {
            Section {
                switch state.action {
                case .requesting:
                    progressRow(T.requesting)
                case .cancelling:
                    progressRow(T.cancelling)
                case .resultUnknown:
                    SheetIconRow(systemImage: "questionmark.circle.fill", iconStyle: .orange) {
                        Text(verbatim: T.removalResultUnknown).sheetParagraph()
                    }
                    .accessibilityElement(children: .combine)
                    // The same request, as it was confirmed: not a new one for what is listed now.
                    Button(action: onRetryRemoval) {
                        SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: T.removalRetry) }
                    }
                case let .failed(failure):
                    SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                        Text(verbatim: T.failureMessage(failure)).sheetParagraph()
                    }
                    .accessibilityElement(children: .combine)
                    Button(action: onDismissFailure) {
                        SheetIconRow(systemImage: "checkmark") { Text(verbatim: T.dismissFailure) }
                    }
                case nil:
                    if state.availability == .available {
                        Button(role: .destructive) {
                            // What is confirmed is what is shown now: the dialog keeps it.
                            removalConfirmation.open(for: state.removalBinding)
                            isConfirming = true
                        } label: {
                            SheetIconRow(systemImage: "trash") { Text(verbatim: T.delete) }
                        }
                        .confirmationDialog(
                            Text(verbatim: T.confirmTitle(label: state.label)),
                            isPresented: $isConfirming,
                            titleVisibility: .visible
                        ) {
                            Button(role: .destructive) {
                                // The registration the dialog was opened for -- not whatever
                                // the list offers by now.
                                if let binding = removalConfirmation.confirmed() { onDelete(binding) }
                                removalConfirmation.close()
                            } label: {
                                Text(verbatim: T.deleteConfirm)
                            }
                            Button(role: .cancel) { removalConfirmation.close() } label: { Text(verbatim: T.keep) }
                        } message: {
                            Text(verbatim: T.confirmMessage(
                                sensorCount: state.affectedSensorCount, isOnline: state.base?.isOnline ?? false,
                                eraseConfirmation: state.base?.eraseConfirmation ?? .unspecified
                            ))
                        }
                    } else if let unavailable {
                        SheetIconRow(systemImage: "info.circle", iconStyle: .secondary) {
                            Text(verbatim: unavailable)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                Text(verbatim: T.deleteHeader)
            } footer: {
                Text(verbatim: T.deleteFooter).sheetFooter()
            }
            .sheetRowInsets()
        }
    }

    /// "허브 목록에서 제거": shown while it can be asked for, is under way, got no answer or was
    /// refused. A separate section from the removal -- it is a different thing.
    @ViewBuilder
    private var forgetSection: some View {
        if state.forgetAction != nil || state.forgetOffer != nil {
            Section {
                switch state.forgetAction {
                case .requesting:
                    progressRow(T.forgetRequesting)
                case .resultUnknown:
                    SheetIconRow(systemImage: "questionmark.circle.fill", iconStyle: .orange) {
                        Text(verbatim: T.forgetResultUnknown).sheetParagraph()
                    }
                    .accessibilityElement(children: .combine)
                    Button(action: onRetryForget) {
                        SheetIconRow(systemImage: "arrow.clockwise") { Text(verbatim: T.forgetRetry) }
                    }
                case let .failed(failure):
                    SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                        Text(verbatim: T.forgetFailureMessage(failure)).sheetParagraph()
                    }
                    .accessibilityElement(children: .combine)
                    Button(action: onDismissForgetFailure) {
                        SheetIconRow(systemImage: "checkmark") { Text(verbatim: T.dismissFailure) }
                    }
                case nil:
                    if let offer = state.forgetOffer {
                        SheetIconRow(systemImage: "info.circle", iconStyle: .secondary) {
                            Text(verbatim: T.forgetExplanation)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                        .accessibilityElement(children: .combine)
                        Button(role: .destructive) {
                            // What is confirmed is what is shown now: the dialog keeps it.
                            forgetConfirmation.open(for: offer)
                            isConfirmingForget = true
                        } label: {
                            SheetIconRow(systemImage: "minus.circle") { Text(verbatim: T.forgetHeader) }
                        }
                        .confirmationDialog(
                            Text(verbatim: T.forgetConfirmTitle(label: state.label)),
                            isPresented: $isConfirmingForget,
                            titleVisibility: .visible
                        ) {
                            Button(role: .destructive) {
                                // The registration the dialog was opened for -- not whatever
                                // the list offers by now.
                                if let record = forgetConfirmation.confirmedRecord() { onForget(record) }
                                forgetConfirmation.close()
                            } label: {
                                Text(verbatim: T.forgetConfirm)
                            }
                            Button(role: .cancel) { forgetConfirmation.close() } label: { Text(verbatim: T.keep) }
                        } message: {
                            Text(verbatim: T.forgetConfirmMessage(offer.removalEffect))
                        }
                    }
                }
            } header: {
                Text(verbatim: T.forgetHeader)
            } footer: {
                Text(verbatim: T.forgetFooter).sheetFooter()
            }
            .sheetRowInsets()
        }
    }

    private func progressRow(_ text: String) -> some View {
        SheetIconRow {
            SheetRowProgress()
        } content: {
            Text(verbatim: text).sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ presentation: PowerBaseRemoval.Presentation) -> String {
        switch presentation {
        case .waitingForPowerBase: return "clock.fill"
        case .inProgress, .finishing: return "arrow.triangle.2.circlepath"
        case .resultUnknown: return "questionmark.circle.fill"
        case .removedFromListUnconfirmed: return "questionmark.circle"
        case .awaitingEraseConfirmation: return "checkmark.shield"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "arrow.uturn.backward.circle.fill"
        case .superseded: return "arrow.triangle.branch"
        }
    }

    static func style(_ presentation: PowerBaseRemoval.Presentation) -> AnyShapeStyle {
        switch presentation {
        case .waitingForPowerBase, .resultUnknown, .awaitingEraseConfirmation: return AnyShapeStyle(Color.orange)
        case .inProgress, .finishing: return AnyShapeStyle(.tint)
        case .completed: return AnyShapeStyle(Color.green)
        // Not something to act on: the list is settled, and nothing is being carried out.
        case .cancelled, .superseded, .removedFromListUnconfirmed: return AnyShapeStyle(Color.secondary)
        }
    }
}

/// The button next to a Power Base's title that opens its management sheet.
struct PowerBaseManageButton: View {
    let identifier: String
    @Environment(DeviceActions.self) private var actions: DeviceActions?

    var body: some View {
        Button {
            actions?.managingPowerBase = PowerBaseManagementTarget(identifier: identifier)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: "\(PowerBaseManagementPresentation.label(forIdentifier: identifier)), \(PowerBaseManagementText.sheetTitle)"))
    }
}

/// The removal state of a Base as one short line in a list ("삭제 대기", …); nothing without a job.
struct PowerBaseRemovalBadge: View {
    let removal: PowerBaseRemoval?

    var body: some View {
        if let presentation = PowerBaseManagementPresentation.badge(for: removal) {
            Label {
                Text(verbatim: PowerBaseManagementText.removalTitle(presentation))
            } icon: {
                Image(systemName: PowerBaseManagementContent.symbol(presentation))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PowerBaseManagementContent.style(presentation))
        }
    }
}
