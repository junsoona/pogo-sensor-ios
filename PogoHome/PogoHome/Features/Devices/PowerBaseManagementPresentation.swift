import Foundation

/// What the "Power Base 관리" sheet and the device list show about one Power Base and its removal
/// (unenroll) job, as plain values and strings -- separate from the views so every state can be
/// checked in a test and rendered in every language.
///
/// The rules it encodes:
/// - **Removed means the hub verified it.** Only the hub's `completed` is "삭제 완료". A request
///   the hub accepted, a command that was sent and a Base that fell silent are not -- and neither
///   is `released`: the Base is out of use and out of the hub's lists then, but whether it erased
///   its stored join information is not confirmed. Until the hub says `completed` a job is
///   "삭제 대기" or "삭제 중" -- or, when someone has to act, its own state with the way to
///   confirm it.
/// - **One request, then nothing to do.** A Base whose board confirms its erase to the hub itself
///   (the hub says so: `PowerBaseEraseConfirmation.automatic`) goes from the request to
///   "삭제 완료" without another step. The confirmation over Bluetooth is offered only when the hub
///   stops expecting that, or never did.
/// - **The settings clean-up is a third thing.** Whether the hub has cleared the rooms of the
///   sensors that left with the Base is shown separately from the removal's state.
/// - **Nothing is hidden locally.** A Base that cannot be removed (older hub, or enrolled without a
///   management credential) is said to be unsupported, with what to do. There is no fallback that
///   takes it out of the list and calls that removed.
/// - **A job the user started stays visible** until the hub ends it: waiting for an offline Base,
///   in progress, or without confirmation.
/// - **A finished removal leaves the lists.** Once the hub says `completed` there is nothing left
///   to do or to look at: the Base is gone from the device list and so is its request. The user is
///   told once, by a short notice (`PowerBaseRemovalCompletions`), and the screen that was following
///   the removal closes. The hub's record of the finished job is not shown as a list of its own.
/// - **Taking a Base out of the hub's list is offered for a Base that does not come back, and is
///   called what it is.** "허브 목록에서 제거" is offered only for a Base the hub lists as offline,
///   by a hub that says it can do it, with the registration the hub lists (`PowerBase.record`).
///   It is a second, separate action next to the removal: its texts say that the Power Base's own
///   stored connection is not erased, and its outcome is never "삭제 완료".
/// - **Out of the list and erased are two answers.** When a Base was taken out of the hub's list
///   while a removal's command may be with the board, the hub keeps that removal as it is. The
///   app shows it as what it is: the Base **is** out of the list, and whether the board erased
///   anything is **not confirmed** (`PowerBaseRemoval.Presentation.removedFromListUnconfirmed`).
///   It is never "삭제 완료", it is not a removal still being carried out, and -- being about a
///   registration that left the list -- it never stands in the way of the same Base when that is
///   registered again.
/// - **A request belongs to the registration it was confirmed for.** The confirmation of "허브
///   목록에서 제거" keeps the registration the user was shown when it opened
///   (`PowerBaseForgetConfirmation`); a list that changes behind the open dialog does not change
///   what is asked.
/// - **A finished removal says nothing of a Base that is listed again.** The hub keeps that record
///   for a while, also after the same Base was registered again; the new registration is managed
///   and removed like any other (`PowerBaseRemovalController.removal(for:in:answered:)`).
/// - **A removal is confirmed for one registration, and asked of that one.** The confirmation of
///   "Power Base 삭제" keeps what the user was shown when it opened -- the registration and its
///   removal serial (`PowerBaseRemovalConfirmation`) -- and that is what the request names. A
///   removal is offered only when the hub gives both (`PowerBase.removalBinding`): with a hub
///   that would take the Base's id alone, nothing is asked, and the app says the hub has to be
///   updated. A request without an answer is shown as that, with a button that sends **the same
///   request** again -- which is why saying "asking again is safe" is true.
nonisolated enum PowerBaseManagementPresentation {
    /// Whether a removal can be requested for a Base right now, and if not, why.
    enum Availability: Equatable, Sendable {
        case available
        /// A job is shown for the Base -- under way, or completed with the Base gone from the hub's
        /// lists: nothing to request.
        case removalExists
        /// The app is not reading a paired hub picked in "Find hubs".
        case hubNotEligible(PowerBaseHubIneligibility)
        /// The hub does not offer Power Base management at all.
        case hubUnsupported
        /// The hub holds no management credential for this Base's current enrollment.
        case powerBaseUnsupported
        /// The hub no longer lists this Base.
        case gone
    }

    /// "허브 목록에서 제거" as it can be asked for a Base right now.
    struct ForgetOffer: Equatable, Sendable {
        /// What it means for a removal of the Base that is under way.
        enum RemovalEffect: Equatable, Sendable {
            case none
            /// A removal that is still waiting ends as cancelled with it.
            case cancelsPendingRemoval
            /// A removal whose command may be with the Power Base stays as it is.
            case keepsSentRemoval
        }

        /// The registration the hub lists for the Base: what the request names.
        var record: String
        var removalEffect: RemovalEffect
    }

    /// Everything the sheet shows, taken at one moment.
    struct State: Equatable, Sendable {
        /// The Base's EUI-64, 16 lower-case hex digits.
        var identifier: String
        /// The Base as the hub's snapshot has it; `nil` once the hub no longer lists it.
        var base: PowerBase?
        /// Sensors the hub lists under the Base right now.
        var sensorCount: Int
        var removal: PowerBaseRemoval?
        var action: PowerBaseRemovalController.Action?
        var availability: Availability
        /// The hub's current word about its Power Bases is known (`AppModel.isPowerBaseStateVerified`:
        /// connected and up to date). Says nothing about sensors: a Base without any is known too.
        var isCurrentStateVerified: Bool
        /// "허브 목록에서 제거" can be asked for now; `nil` when it is not offered.
        var forgetOffer: ForgetOffer? = nil
        /// The list removal under way, without an answer, or refused.
        var forgetAction: PowerBaseRemovalController.ForgetAction? = nil

        /// What a removal confirmed now would be asked for: the listed registration and its
        /// removal serial. `nil` when the hub does not give both.
        var removalBinding: PowerBaseRemovalBinding? { base?.removalBinding }

        var label: String { PowerBaseManagementPresentation.label(forIdentifier: identifier) }

        /// How many sensors a removal affects: what the hub counted when it created the job, or
        /// what it lists now.
        var affectedSensorCount: Int {
            if let removal, !removal.state.isFinal { return max(removal.affectedModuleCount, sensorCount) }
            return sensorCount
        }
    }

    static func label(forIdentifier identifier: String) -> String {
        "Power Base ··\(identifier.suffix(4))"
    }

    static func state(
        identifier: String, snapshot: HomeSnapshot, target: PowerBaseHubTarget,
        removal: PowerBaseRemoval?, action: PowerBaseRemovalController.Action?, isCurrentStateVerified: Bool,
        forgetAction: PowerBaseRemovalController.ForgetAction? = nil
    ) -> State {
        let base = snapshot.powerBases.first { $0.hardwareIdentifier == identifier }
        let sensors = snapshot.modules.filter { $0.powerBaseIdentifier == identifier }.count
        return State(
            identifier: identifier, base: base, sensorCount: sensors, removal: removal, action: action,
            availability: availability(base: base, snapshot: snapshot, target: target, removal: removal),
            isCurrentStateVerified: isCurrentStateVerified,
            forgetOffer: forgetOffer(base: base, snapshot: snapshot, target: target, removal: removal, isCurrentStateVerified: isCurrentStateVerified),
            // Nothing of it is shown for a Base the hub no longer lists.
            forgetAction: base == nil ? nil : forgetAction
        )
    }

    /// Whether "허브 목록에서 제거" is offered. The hub decides again when it is asked; this only
    /// keeps the app from offering what the hub would refuse, or what it never said it can do:
    ///
    /// - the app reads a paired hub, and that hub says it can (`reportsPowerBaseForget`) -- an
    ///   older hub is never assumed to;
    /// - the hub's current word is known, it lists the Base with a `record`, and it does not hear
    ///   the Base or any sensor under it;
    /// - no removal is in the way: none, one that is still waiting (it is cancelled with this), or
    ///   one whose command went out and has had no result for a long time (it stays). While a
    ///   removal is being carried out the offer waits.
    static func forgetOffer(
        base: PowerBase?, snapshot: HomeSnapshot, target: PowerBaseHubTarget, removal: PowerBaseRemoval?, isCurrentStateVerified: Bool
    ) -> ForgetOffer? {
        guard target.ineligibility == nil, snapshot.reportsPowerBaseForget, isCurrentStateVerified,
              let base, let record = base.record, !base.isOnline,
              !snapshot.modules(on: base).contains(where: \.isOnline) else { return nil }
        guard let removal else { return ForgetOffer(record: record, removalEffect: .none) }
        switch removal.presentation {
        case .cancelled, .superseded: return ForgetOffer(record: record, removalEffect: .none)
        case .waitingForPowerBase: return ForgetOffer(record: record, removalEffect: .cancelsPendingRemoval)
        case .resultUnknown: return ForgetOffer(record: record, removalEffect: .keepsSentRemoval)
        // `removedFromListUnconfirmed`: the Base is out of the list already.
        case .inProgress, .finishing, .awaitingEraseConfirmation, .completed, .removedFromListUnconfirmed: return nil
        }
    }

    static func availability(base: PowerBase?, snapshot: HomeSnapshot, target: PowerBaseHubTarget, removal: PowerBaseRemoval?) -> Availability {
        if let removal {
            switch removal.presentation {
            case .waitingForPowerBase, .inProgress, .resultUnknown, .finishing, .awaitingEraseConfirmation, .completed,
                 .removedFromListUnconfirmed: return .removalExists
            // A cancelled job, or one overtaken by a new enrollment, leaves the Base as it is: it
            // can be asked again.
            case .cancelled, .superseded: break
            }
        }
        if let reason = target.ineligibility { return .hubNotEligible(reason) }
        guard snapshot.reportsPowerBaseManagement else { return .hubUnsupported }
        guard let base else { return .gone }
        switch base.management {
        // The hub can remove this Base. A removal is asked of one registration, though: without
        // the hub's word for which registration this is and how many removals were asked of it,
        // the only request left would name the Base alone -- and that one is not sent. Such a
        // hub (Linux bridge 0.4.2 and earlier) has to be updated.
        case .supported: return base.removalBinding != nil ? .available : .hubUnsupported
        case .unsupported, .unknown: return .powerBaseUnsupported
        }
    }

    /// The short status a list shows next to a Base with a job; `nil` when there is nothing to say
    /// (no job, or one that ended without changing the Base).
    static func badge(for removal: PowerBaseRemoval?) -> PowerBaseRemoval.Presentation? {
        guard let presentation = removal?.presentation else { return nil }
        switch presentation {
        case .waitingForPowerBase, .inProgress, .resultUnknown, .finishing, .awaitingEraseConfirmation, .completed,
             .removedFromListUnconfirmed: return presentation
        case .cancelled, .superseded: return nil
        }
    }

    /// What the user can do about a job, in the order the sheet lists it.
    nonisolated enum RemovalAction: Hashable, Sendable {
        /// Open "삭제 확인": read the board's receipt over Bluetooth and hand it to the hub.
        case confirmErase
        /// Ask the hub to cancel the job.
        case cancel
    }

    /// The buttons the sheet shows under a job. `isActing`: a request of this sheet is under way
    /// or has just failed. None of them changes what the job is shown as: a job is cancellable
    /// exactly while the hub says so, and it is complete only when the hub says `completed`.
    static func removalActions(for removal: PowerBaseRemoval, isActing: Bool) -> [RemovalAction] {
        var actions: [RemovalAction] = []
        if removal.offersEraseConfirmation { actions.append(.confirmErase) }
        // Only the hub decides whether a job can still be cancelled.
        if removal.cancellable, !isActing { actions.append(.cancel) }
        return actions
    }

    /// "Power Base 삭제 요청": the jobs of Bases the hub no longer lists that are still under way --
    /// waiting, being removed, without a result, or in need of a confirmation. A job the user
    /// started never just vanishes from here; it leaves when the hub ends it. A completed one is
    /// not listed: the removal is over, and the user was told when it ended.
    static func openRemovalsWithoutPowerBase(in snapshot: HomeSnapshot) -> [PowerBaseRemoval] {
        snapshot.removalsWithoutPowerBase.filter { removal in
            switch removal.presentation {
            case .waitingForPowerBase, .inProgress, .resultUnknown, .finishing, .awaitingEraseConfirmation,
                 .removedFromListUnconfirmed: return true
            case .completed, .cancelled, .superseded: return false
            }
        }
    }
}

/// The registration a "허브 목록에서 제거" confirmation was opened for.
///
/// The dialog stays open while the hub's list can change behind it: another device takes the Base
/// out of the list, the Base is registered again, and the sheet's state then offers the same
/// button for the **new** registration. What the user confirms is what they were shown when the
/// dialog opened, so that is what is asked of the hub -- and the hub refuses a registration that
/// is not listed any more (`stale_record`), instead of removing one nobody confirmed.
nonisolated struct PowerBaseForgetConfirmation: Equatable, Sendable {
    /// The registration shown when the dialog opened; `nil` while no dialog is open.
    private(set) var record: String?

    var isOpen: Bool { record != nil }

    /// The dialog opens for `offer`.
    mutating func open(for offer: PowerBaseManagementPresentation.ForgetOffer) {
        record = offer.record
    }

    /// The dialog closed (confirmed, cancelled or dismissed).
    mutating func close() {
        record = nil
    }

    /// What the confirm button asks for: the registration the dialog was opened for, whatever is
    /// offered now. `nil` when no dialog is open: then nothing is asked.
    func confirmedRecord() -> String? {
        record
    }
}

/// The registration a "Power Base 삭제" confirmation was opened for.
///
/// The dialog stays open while the hub's list can change behind it: another device removes the
/// Base, somebody registers it again, and the sheet then offers the same button for the **new**
/// registration. What the user confirms is what they were shown when the dialog opened, so that
/// is what is asked of the hub -- and the hub refuses a request for a registration it no longer
/// lists (`stale_record`) instead of removing one nobody confirmed.
nonisolated struct PowerBaseRemovalConfirmation: Equatable, Sendable {
    /// What was listed when the dialog opened; `nil` while no dialog is open.
    private(set) var binding: PowerBaseRemovalBinding?

    var isOpen: Bool { binding != nil }

    /// The dialog opens for the Base as it is listed now (`nil`: the hub gives nothing to name).
    mutating func open(for binding: PowerBaseRemovalBinding?) {
        self.binding = binding
    }

    /// The dialog closed (confirmed, cancelled or dismissed).
    mutating func close() {
        binding = nil
    }

    /// What the confirm button asks for: the registration the dialog was opened for, whatever is
    /// listed now. `nil` when no dialog is open: then nothing is asked.
    func confirmed() -> PowerBaseRemovalBinding? {
        binding
    }
}

/// The wording of Power Base management, in the app's language.
nonisolated enum PowerBaseManagementText {
    typealias Availability = PowerBaseManagementPresentation.Availability

    static var sheetTitle: String { String(localized: "Power Base 관리", comment: "Power Base management: sheet title and the button that opens it") }
    static var statusHeader: String { String(localized: "상태", comment: "Power Base management: section header") }
    static var removalHeader: String { String(localized: "삭제 상태", comment: "Power Base management: section header of the removal job") }
    static var deleteHeader: String { String(localized: "삭제", comment: "Power Base management: section header of the delete action") }
    static var delete: String { String(localized: "Power Base 삭제", comment: "Power Base management: the destructive button") }
    static var deleteConfirm: String { String(localized: "삭제", comment: "Power Base management: confirms the removal") }
    static var keep: String { String(localized: "취소", comment: "Power Base management: dismisses the confirmation") }
    static var cancelRemoval: String { String(localized: "삭제 요청 취소", comment: "Power Base management: cancels a removal that is still waiting") }
    static var requesting: String { String(localized: "허브에 삭제를 요청하는 중입니다.", comment: "Power Base management: the request is under way") }
    /// No answer to the removal request. The button under it sends the same request again, which
    /// is what makes its second sentence true.
    static var removalResultUnknown: String { String(localized: "허브의 응답을 받지 못해 요청이 전달됐는지 알 수 없습니다. 다시 요청해도 안전합니다.", comment: "Power Base management failure: no answer; the request may have arrived") }
    static var removalRetry: String { String(localized: "다시 요청", comment: "Power Base management: sends the removal request that got no answer again, unchanged") }
    static var cancelling: String { String(localized: "허브에 취소를 요청하는 중입니다.", comment: "Power Base management: the cancel is under way") }
    static var dismissFailure: String { String(localized: "확인", comment: "Power Base management: dismisses a failure message") }
    static var listHeader: String { String(localized: "Power Base 삭제 요청", comment: "Device list: section of removal jobs whose Power Base is no longer listed") }
    static var refreshProblem: String { String(localized: "허브에서 삭제 상태를 읽지 못해 최신이 아닐 수 있습니다. 삭제 요청은 허브에 남아 있습니다.", comment: "Power Base management: the hub's list of jobs could not be read") }
    static var deleteFooter: String { String(localized: "삭제하면 연결된 센서도 기기 목록과 Apple 홈에서 사라지고 방 지정이 해제됩니다. 센서 모듈에 저장된 정보는 지워지지 않습니다. 다시 사용하려면 'Power Base 추가'에서 새로 등록하세요.", comment: "Power Base management: under the delete button -- what a removal does to the sensors and their rooms, and that the Base has to be registered again") }
    static var confirmErase: String { String(localized: "삭제 확인", comment: "Power Base management: opens the screen that confirms a released Power Base's erase over Bluetooth; also that screen's title and its main button") }
    static var confirmEraseWhenUnknown: String { String(localized: "Power Base가 이미 삭제를 마쳤다면 가까이에서 아래 '삭제 확인'으로 완료할 수 있습니다.", comment: "Power Base management: shown with a removal whose result is unknown, above the button that opens the Bluetooth confirmation; offering it does not mean the removal is done") }
    static var cleanupPending: String { String(localized: "허브가 이 Power Base에 있던 센서의 방 지정을 아직 정리하지 못했습니다. 허브가 자동으로 다시 시도합니다.", comment: "Power Base management: the hub still has to clear the room assignments of the removed sensors") }
    /// The dialog's sentence for a Base whose removal someone has to confirm near it afterwards.
    static var confirmLater: String { String(localized: "삭제 뒤 Power Base 가까이에서 '삭제 확인'을 한 번 해야 완료됩니다.", comment: "Power Base management: confirmation dialog, a Base whose removal has to be confirmed once near it afterwards") }
    /// The dialog's sentence for a Base that needs nothing more: only what it means for later.
    static var confirmRegisterAgain: String { String(localized: "다시 사용하려면 새로 등록해야 합니다.", comment: "Power Base management: confirmation dialog, a removed Base has to be registered again to be used") }
    /// The dialog's sentence for a Base the hub does not hear right now.
    static var confirmOffline: String { String(localized: "지금은 연결이 끊겨 있어 '삭제 대기'로 남고, Power Base가 다시 연결되면 삭제됩니다.", comment: "Power Base management: confirmation dialog, offline Base -- the request waits; names the state shown meanwhile") }

    // MARK: 허브 목록에서 제거

    static var forgetHeader: String { String(localized: "허브 목록에서 제거", comment: "Power Base management: section header and button -- takes an offline Power Base out of this hub's list; this is not the removal") }
    static var forgetExplanation: String { String(localized: "연결이 끊긴 Power Base를 이 허브의 목록에서만 지금 지웁니다. Power Base에 저장된 연결 정보는 지워지지 않습니다.", comment: "Power Base management: above the 'remove from hub list' button -- what it does and what it does not do") }
    static var forgetFooter: String { String(localized: "'Power Base 삭제'는 Power Base가 다시 연결되면 저장된 연결 정보까지 지웁니다. '허브 목록에서 제거'는 되돌릴 수 없으며, 다시 사용하려면 'Power Base 추가'에서 새로 등록해야 합니다.", comment: "Power Base management: under the 'remove from hub list' button -- the difference from the removal, that it cannot be undone, and how to use the Base again") }
    static var forgetConfirm: String { String(localized: "목록에서 제거", comment: "Power Base management: confirms taking the Power Base out of the hub's list") }
    static var forgetRequesting: String { String(localized: "허브에 목록에서 제거를 요청하는 중입니다.", comment: "Power Base management: the 'remove from hub list' request is under way") }
    static var forgetResultUnknown: String { String(localized: "허브의 응답을 받지 못해 목록에서 제거됐는지 알 수 없습니다. 다시 확인해도 안전합니다.", comment: "Power Base management: no answer to the 'remove from hub list' request; asking again is safe") }
    static var forgetRetry: String { String(localized: "다시 확인", comment: "Power Base management: sends the 'remove from hub list' request that got no answer again") }

    static func forgetConfirmTitle(label: String) -> String {
        String(localized: "\(label) 허브 목록에서 제거", comment: "Power Base management: title of the confirmation for taking a Power Base out of the hub's list; the argument is the Power Base's label")
    }

    /// The confirmation's message: what is taken out, and that the Power Base itself is not
    /// erased -- one short paragraph. A removal under way adds its one sentence.
    static func forgetConfirmMessage(_ effect: PowerBaseManagementPresentation.ForgetOffer.RemovalEffect) -> String {
        var sentences = [
            String(localized: "이 허브의 목록에서 Power Base와 센서를 제거합니다. Power Base에 저장된 연결 정보는 지워지지 않습니다.", comment: "Power Base management: confirmation for taking a Power Base out of the hub's list -- what it does and that the Power Base's own stored connection is not erased"),
        ]
        switch effect {
        case .none: break
        case .cancelsPendingRemoval:
            sentences.append(String(localized: "대기 중인 삭제 요청은 취소됩니다.", comment: "Power Base management: confirmation for taking a Power Base out of the hub's list, when a removal is still waiting"))
        case .keepsSentRemoval:
            sentences.append(String(localized: "이미 보낸 삭제 요청은 그대로 남습니다.", comment: "Power Base management: confirmation for taking a Power Base out of the hub's list, when a removal's command may already be with the Power Base"))
        }
        return sentences.joined(separator: " ")
    }

    /// The short notice shown once when the hub took a Power Base out of its list at this device's
    /// request; also what VoiceOver announces. Never worded as a completed removal.
    static func forgetNotice(label: String) -> String {
        String(localized: "\(label) 허브 목록에서 제거됨", comment: "Power Base management: short notice when the hub took the Power Base out of its list; the argument is the Power Base's label")
    }

    static func forgetFailureMessage(_ failure: PowerBaseRemovalController.ForgetFailure) -> String {
        switch failure {
        case let .notEligible(reason):
            return unavailableMessage(.hubNotEligible(reason)) ?? ""
        case .credentialUnavailable:
            return failureMessage(.credentialUnavailable)
        case let .request(error):
            switch error {
            case .unauthorized, .forbidden, .certificateMismatch:
                return String(localized: "허브가 이 기기의 연결 정보를 확인하지 못했습니다. 설정에서 허브에 다시 연결한 뒤 시도하세요. 아무것도 바뀌지 않았습니다.", comment: "Power Base management failure of 'remove from hub list': not authorized")
            case .notSupported:
                return String(localized: "연결된 허브가 '허브 목록에서 제거'를 지원하지 않습니다. 허브를 업데이트해야 합니다.", comment: "Power Base management failure of 'remove from hub list': the hub is too old")
            case .notListed:
                return String(localized: "이 Power Base는 이제 허브의 목록에 없습니다.", comment: "Power Base management failure of 'remove from hub list': the hub does not list the Base (any more)")
            case .online:
                return String(localized: "Power Base가 다시 연결되어 목록에서 제거하지 않았습니다. 지우려면 'Power Base 삭제'를 사용하세요.", comment: "Power Base management failure of 'remove from hub list': the hub hears the Base again")
            case .staleRecord:
                return String(localized: "그사이 이 Power Base가 다시 등록되어 목록에서 제거하지 않았습니다. 목록을 새로 확인하세요.", comment: "Power Base management failure of 'remove from hub list': the Base was registered again meanwhile")
            case .enrollmentInProgress:
                return String(localized: "이 Power Base의 등록이 진행 중이라 지금은 목록에서 제거할 수 없습니다. 등록이 끝난 뒤 다시 시도하세요.", comment: "Power Base management failure of 'remove from hub list': an enrollment is running")
            case .capacityFull:
                return String(localized: "허브의 삭제 기록이 가득 차 목록에서 제거할 수 없습니다. 이전에 삭제한 Power Base를 다시 등록하면 자리가 생깁니다. 아무것도 바뀌지 않았습니다.", comment: "Power Base management failure of 'remove from hub list': the hub's list of removed Power Bases is full")
            case .unavailable, .rejected, .requestConflict, .unreachable, .badResponse:
                return String(localized: "허브가 지금은 요청을 받을 수 없습니다. 잠시 뒤 다시 시도하세요. 아무것도 바뀌지 않았습니다.", comment: "Power Base management failure of 'remove from hub list': hub busy, not ready, or the request was not accepted")
            }
        }
    }

    /// The short notice shown once when a removal the app was following is completed; also what
    /// VoiceOver announces.
    static func completionNotice(label: String) -> String {
        String(localized: "\(label) 삭제 완료", comment: "Power Base removal: short notice when the removal is completed; the argument is the Power Base's label")
    }

    static func sensors(_ count: Int) -> String {
        String(localized: "연결된 센서 \(count)개", comment: "Power Base management: number of sensors under the Power Base (plural)")
    }

    static func connection(of base: PowerBase?, isCurrentStateVerified: Bool) -> String {
        guard let base else {
            return String(localized: "허브의 목록에 없음", comment: "Power Base management: the hub no longer lists this Power Base")
        }
        guard isCurrentStateVerified else {
            return String(localized: "상태 확인 중", comment: "Power Base management: the hub's current state is not known")
        }
        return base.isOnline
            ? String(localized: "연결됨", comment: "Power Base state: the bridge hears it")
            : String(localized: "연결 끊김", comment: "Power Base state: the bridge no longer hears it")
    }

    static func confirmTitle(label: String) -> String {
        String(localized: "\(label) 삭제", comment: "Power Base management: confirmation title; the argument is the Power Base's label")
    }

    /// The confirmation dialog's message: two or three short sentences in one paragraph (the
    /// dialog is narrow). What a removal does in general is under the button (`deleteFooter`).
    ///
    /// First what disappears. Then what is different about this Base: it is offline (the request
    /// waits) and/or someone has to confirm the removal near it afterwards -- `eraseConfirmation`
    /// is what the hub says of the Base, and only `automatic` means nothing more is needed.
    static func confirmMessage(sensorCount: Int, isOnline: Bool, eraseConfirmation: PowerBaseEraseConfirmation = .unspecified) -> String {
        var sentences = [
            sensorCount == 0
                ? String(localized: "이 Power Base가 기기 목록에서 사라집니다.", comment: "Power Base management: confirmation, no sensors attached")
                : String(localized: "이 Power Base와 연결된 센서 \(sensorCount)개가 기기 목록과 Apple 홈에서 사라집니다.", comment: "Power Base management: confirmation with the number of affected sensors (plural)"),
        ]
        if !isOnline { sentences.append(confirmOffline) }
        if eraseConfirmation != .automatic {
            sentences.append(confirmLater)
        } else if isOnline {
            sentences.append(confirmRegisterAgain)
        }
        return sentences.joined(separator: " ")
    }

    static func removalTitle(_ presentation: PowerBaseRemoval.Presentation) -> String {
        switch presentation {
        case .waitingForPowerBase: return String(localized: "삭제 대기", comment: "Power Base removal state: stored on the hub, waiting for the Power Base")
        // One title for the whole time between the command and the hub's confirmation.
        case .inProgress, .finishing: return String(localized: "삭제 중", comment: "Power Base removal state: the removal is under way and not confirmed yet (the command is with the board, or the board is erasing and reporting by itself)")
        case .resultUnknown: return String(localized: "결과 확인 불가", comment: "Power Base removal state: no confirmation for a long time")
        case .removedFromListUnconfirmed: return String(localized: "삭제 미확인", comment: "Power Base removal state: the Base was taken out of the hub's list after the delete command went out; whether the Power Base erased anything is not confirmed")
        case .awaitingEraseConfirmation: return String(localized: "삭제 확인 필요", comment: "Power Base removal state: the Base is out of the hub's lists; someone has to confirm near it that the removal finished")
        case .completed: return String(localized: "삭제 완료", comment: "Power Base removal state: the hub verified the board's release")
        case .cancelled: return String(localized: "삭제 요청 취소됨", comment: "Power Base removal state: cancelled before it was carried out")
        case .superseded: return String(localized: "삭제 전에 다시 등록됨", comment: "Power Base removal state: the board was enrolled again first")
        }
    }

    static func removalMessage(_ presentation: PowerBaseRemoval.Presentation) -> String {
        switch presentation {
        case .waitingForPowerBase:
            return String(localized: "Power Base가 다시 연결되면 삭제됩니다. 앱을 닫아도 요청은 허브에 남으며, 그 전에는 취소할 수 있습니다.", comment: "Power Base removal: waiting for an offline Base")
        case .inProgress:
            return String(localized: "Power Base를 삭제하고 있습니다. 이 단계에서는 취소할 수 없습니다.", comment: "Power Base removal: in progress")
        case .resultUnknown:
            return String(localized: "삭제 결과를 오랫동안 확인하지 못했습니다. 아직 삭제된 것이 아니며 취소할 수도 없습니다. Power Base가 다시 연결되면 허브가 결과를 확인합니다.", comment: "Power Base removal: the outcome cannot be confirmed")
        case .removedFromListUnconfirmed:
            return String(localized: "허브 목록에서는 제거됐습니다. 그 전에 보낸 삭제 명령이 Power Base에서 실행됐는지는 확인되지 않았습니다. Power Base가 응답하면 허브가 결과를 확인하고, 다시 등록하면 이 기록은 사라집니다.", comment: "Power Base removal: the Base is out of the hub's list for certain; whether the delete command sent before that was carried out on the Power Base is not confirmed; what ends this record")
        case .finishing:
            return String(localized: "삭제를 마무리하고 있습니다. 따로 할 일은 없으며, 끝나면 목록에서 사라집니다.", comment: "Power Base removal: out of the hub's lists and finishing by itself; nothing to do, not complete yet")
        case .awaitingEraseConfirmation:
            return String(localized: "Power Base와 센서는 목록에서 빠졌지만, 삭제가 끝났는지는 아직 확인되지 않았습니다. Power Base 가까이에서 아래 '삭제 확인'을 하면 완료됩니다.", comment: "Power Base removal: out of the hub's lists, not confirmed; how to complete it")
        case .completed:
            return String(localized: "삭제했습니다. 다시 사용하려면 'Power Base 추가'에서 새로 등록하세요.", comment: "Power Base removal: completed")
        case .cancelled:
            return String(localized: "삭제 요청을 취소했습니다. Power Base는 그대로 등록되어 있습니다.", comment: "Power Base removal: cancelled")
        case .superseded:
            return String(localized: "삭제가 확인되기 전에 이 Power Base가 다시 등록되어, 이전 삭제 요청은 더 이상 적용되지 않습니다.", comment: "Power Base removal: superseded by a new enrollment before the erase was confirmed")
        }
    }

    /// Why no removal can be requested, with what to do; `nil` when one can (or a job exists).
    static func unavailableMessage(_ availability: Availability) -> String? {
        switch availability {
        case .available, .removalExists:
            return nil
        case let .hubNotEligible(reason):
            switch reason {
            case .simulatedData:
                return String(localized: "지금은 시뮬레이션 데이터를 보고 있어 Power Base를 삭제할 수 없습니다.", comment: "Power Base management: simulated data")
            case .typedAddress, .noAddress:
                return String(localized: "Power Base를 삭제하려면 설정의 '허브 찾기'에서 허브를 선택해야 합니다.", comment: "Power Base management: no hub picked in Find hubs")
            case .notPaired:
                return String(localized: "이 기기가 허브에 연결(페어링)되어 있지 않아 Power Base를 삭제할 수 없습니다. 설정의 '허브 설정 공유'에서 허브에 연결하세요.", comment: "Power Base management: this device is not paired with the hub")
            }
        case .hubUnsupported:
            return String(localized: "지원하지 않음: 연결된 허브가 Power Base 삭제를 지원하지 않습니다. 허브를 업데이트해야 합니다.", comment: "Power Base management: the hub is too old")
        case .powerBaseUnsupported:
            return String(localized: "지원하지 않음: 이 Power Base는 앱에서 삭제할 수 없는 방식으로 등록되었습니다. Power Base 펌웨어를 업데이트하고 'Power Base 추가'로 다시 등록하면 삭제할 수 있습니다.", comment: "Power Base management: this Base was enrolled without a management credential")
        case .gone:
            return String(localized: "이 Power Base는 더 이상 허브의 목록에 없습니다.", comment: "Power Base management: the Base is gone")
        }
    }

    static func failureMessage(_ failure: PowerBaseRemovalController.Failure) -> String {
        switch failure {
        case let .notEligible(reason):
            return unavailableMessage(.hubNotEligible(reason)) ?? ""
        case .credentialUnavailable:
            return String(localized: "이 기기의 허브 연결 정보를 읽지 못했습니다. 허브에는 아무것도 요청하지 않았습니다.", comment: "Power Base management failure: no credential")
        case let .request(error):
            return requestFailureMessage(error)
        }
    }

    static func requestFailureMessage(_ error: PowerBaseRemovalError) -> String {
        switch error {
        case .unauthorized, .forbidden, .certificateMismatch:
            return String(localized: "허브가 이 기기의 연결 정보를 확인하지 못했습니다. 설정에서 허브에 다시 연결한 뒤 시도하세요. 아무것도 삭제되지 않았습니다.", comment: "Power Base management failure: not authorized")
        case .notSupported:
            return unavailableMessage(.hubUnsupported) ?? ""
        case .managementUnsupported:
            return unavailableMessage(.powerBaseUnsupported) ?? ""
        case .unknownPowerBase, .removalNotFound:
            return String(localized: "허브가 이 Power Base 또는 삭제 요청을 더 이상 알지 못합니다. 목록을 새로 확인하세요.", comment: "Power Base management failure: unknown Base or job")
        case .enrollmentInProgress:
            return String(localized: "이 Power Base의 등록이 진행 중이라 지금은 삭제할 수 없습니다. 등록이 끝난 뒤 다시 시도하세요.", comment: "Power Base management failure: an enrollment is running")
        case .notCancellable:
            return String(localized: "삭제 명령이 이미 Power Base로 전달됐을 수 있어 취소할 수 없습니다.", comment: "Power Base management failure: the job can no longer be cancelled")
        case .capacityFull:
            return String(localized: "허브의 삭제 기록이 가득 차 더 삭제할 수 없습니다. 이전에 삭제한 Power Base를 다시 등록하면 자리가 생깁니다. 아무것도 삭제되지 않았습니다.", comment: "Power Base management failure: the hub's list of removed Power Bases is full")
        case .receiptRejected:
            return String(localized: "허브가 이 Power Base의 삭제 확인을 받아들이지 않았습니다. 다른 허브에 등록됐던 Power Base이거나, 그사이 다시 등록된 Power Base일 수 있습니다.", comment: "Power Base management failure: the hub could not verify the release receipt")
        case .staleRecord:
            return String(localized: "그사이 이 Power Base의 등록이나 삭제 요청 상태가 바뀌어 삭제를 요청하지 않았습니다. 목록을 새로 확인한 뒤 다시 시도하세요.", comment: "Power Base management failure: the Base was registered again, or a removal was asked of it and ended, after this device read the list; nothing was requested")
        case .unavailable:
            return String(localized: "허브가 지금은 삭제 요청을 받을 수 없습니다. 잠시 뒤 다시 시도하세요. 아무것도 삭제되지 않았습니다.", comment: "Power Base management failure: hub busy or not ready")
        case .unreachable, .badResponse:
            return String(localized: "허브의 응답을 받지 못해 요청이 전달됐는지 알 수 없습니다. 다시 요청해도 안전합니다.", comment: "Power Base management failure: no answer; the request may have arrived")
        case .rejected:
            return String(localized: "허브가 요청을 받아들이지 않았습니다. 아무것도 삭제되지 않았습니다.", comment: "Power Base management failure: rejected")
        }
    }
}
