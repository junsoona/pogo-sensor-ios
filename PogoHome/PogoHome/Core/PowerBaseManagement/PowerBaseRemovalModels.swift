import Foundation

// The hub's Power Base removal (unenroll) API -- firmware repository,
// docs/power-base-management.md, section 7. A removal is a job the HUB keeps: it survives the app
// being closed, the hub restarting and the Power Base being offline.
//
// Two things are kept apart everywhere in the app:
//   released   the board stored, for good, that its registration is out of use, and told the hub.
//              The hub has removed it from its lists. NOT complete: whether the board erased its
//              stored join information is not confirmed.
//   completed  the hub verified the board's release receipt -- made by the board only after it
//              erased its stored network and checked that. The receipt reaches the hub in one of
//              two ways, and the hub says which one to expect (`PowerBaseEraseConfirmation`): a
//              board with current firmware sends it to the hub itself, and nothing is asked of
//              this app or its user; otherwise it is read from the board over Bluetooth by this
//              app ("삭제 확인") and handed on.

/// Whether the hub can unenroll a Power Base remotely.
nonisolated enum PowerBaseManagementSupport: Hashable, Sendable {
    /// The hub does not say (it predates Power Base management, or does not offer it).
    case unknown
    /// The hub holds a valid management credential for this Base's current enrollment.
    case supported
    /// It does not: this Base was enrolled without one (an earlier enrollment, or older board
    /// firmware). It must be enrolled again through the app before it can be removed from it.
    case unsupported
}

/// How the erase behind a removal is confirmed to the hub, as the hub says (`erase_confirmation`
/// on a removal that is not final, and on a Power Base it can remove).
///
/// Only a hint for what is shown and offered. It never makes a removal complete: that is the
/// hub's `completed`, whichever way the confirmation came in.
nonisolated enum PowerBaseEraseConfirmation: Hashable, Sendable {
    /// The hub does not say: it predates the field, or uses a word this app does not know. Treated
    /// like `manual` -- the confirmation over Bluetooth is offered, as it always was.
    case unspecified
    /// The board sends its confirmation to the hub itself. Nothing to do but wait.
    case automatic
    /// The board does not (older firmware), or it did not arrive in time: it is read from the
    /// board over Bluetooth.
    case manual

    init(wire: String?) {
        switch wire {
        case "automatic": self = .automatic
        case "manual": self = .manual
        default: self = .unspecified
        }
    }
}

/// One removal job as the hub reports it.
nonisolated struct PowerBaseRemoval: Identifiable, Hashable, Sendable {
    nonisolated enum State: String, Hashable, Sendable {
        /// Stored on the hub; the command has not been given to the board. This is where an
        /// offline Base waits. Can be cancelled.
        case pending
        /// The command went out in an answer to the board. Whether it arrived is not known.
        case sent
        /// The board acknowledged the command. Not complete yet.
        case accepted
        /// The board told the hub that its registration is out of use for good; the hub removed
        /// it. Not final: the erase of its stored join information is not confirmed.
        case released
        /// Final: the hub verified the board's release receipt (erased and checked).
        case completed
        /// Final: cancelled before the command was given to the board.
        case cancelled
        /// Final: the same board was enrolled again before a proof arrived.
        case superseded

        var isFinal: Bool {
            switch self {
            case .pending, .sent, .accepted, .released: return false
            case .completed, .cancelled, .superseded: return true
            }
        }
    }

    /// The hub's `removal_id` (32 lower-case hex digits).
    let id: String
    /// The Base's EUI-64, 16 lower-case hex digits.
    let powerBaseIdentifier: String
    let state: State
    /// `sent`/`accepted` without progress for longer than the hub's limit: the outcome cannot be
    /// confirmed right now. Not a state of its own -- a late proof still completes the job.
    let resultUnknown: Bool
    /// The job can still be cancelled (exactly while `pending`).
    let cancellable: Bool
    /// Sensors registered under the Base when the job was created.
    let affectedModuleCount: Int
    let createdAt: Date
    let updatedAt: Date
    /// The hub still has to clear the room assignments of the sensors that left with the Base
    /// (it retries by itself). A different thing from the removal's own state.
    var settingsCleanupPending = false
    /// How the hub expects the erase to be confirmed. Meaningful while the job is not final.
    var eraseConfirmation: PowerBaseEraseConfirmation = .unspecified
    /// The registration this job is about, as the hub names it (its `generation`: 32 lower-case
    /// hex digits, no secret) -- the same kind of value as `PowerBase.record`. A job whose record
    /// is not the one the hub lists for the Base is about an earlier registration. `nil` from a
    /// hub that does not say.
    var record: String? = nil
    /// The hub took the Base out of its list ("허브 목록에서 제거") while this job's command may be
    /// with the board (`sent`/`accepted`). Two things, kept apart: the **list** is settled -- the
    /// Base is not listed any more -- and the **board** is not: whether it erased anything is as
    /// unknown as before, and only its proof makes the job `completed`.
    var powerBaseListRemoved = false
    /// The id of the request that created this job, as the hub says (`request_id`): how a device
    /// recognises the job of its own request when the answer to it was lost. `nil` from a hub that
    /// does not say, and for a job created before the hub wrote it down.
    var requestID: String? = nil

    /// What a screen shows for this job.
    nonisolated enum Presentation: Hashable, Sendable {
        /// Waiting for the Base to come back; can be cancelled.
        case waitingForPowerBase
        /// The command is with (or on its way to) the board; cannot be cancelled.
        case inProgress
        /// No confirmation for a long time; cannot be cancelled, cannot be called done.
        case resultUnknown
        /// The Base was taken out of the hub's list while the command may be with the board: out
        /// of the list for certain, erased or not unknown. Never shown as done, never as a
        /// removal that is still being carried out on a listed Base.
        case removedFromListUnconfirmed
        /// Released, and the board confirms its erase to the hub by itself: still under way, with
        /// nothing for the user to do. Not complete.
        case finishing
        /// Released: the Base is out of the hub's lists, but the erase of its stored join
        /// information is not confirmed. Confirmed by reading the board's receipt over Bluetooth.
        case awaitingEraseConfirmation
        case completed
        case cancelled
        case superseded
    }

    var presentation: Presentation {
        switch state {
        case .pending: return .waitingForPowerBase
        case .sent, .accepted:
            if powerBaseListRemoved { return .removedFromListUnconfirmed }
            return resultUnknown ? .resultUnknown : .inProgress
        case .released: return eraseConfirmation == .automatic ? .finishing : .awaitingEraseConfirmation
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .superseded: return .superseded
        }
    }

    /// Whether "삭제 확인" is offered for this job: reading the board's release receipt over
    /// Bluetooth and handing it to the hub.
    ///
    /// That is where a receipt can exist that the hub has not seen: after `released`, and also
    /// when the board's "released" notice never reached the hub -- the board erases and makes its
    /// receipt all the same, while the hub's job stays `sent`/`accepted` and turns "result
    /// unknown". Offering the screen says nothing about the job: what is shown for it, whether it
    /// can be cancelled and whether it is complete stay exactly what the hub reports.
    ///
    /// Not offered while the hub expects the board to deliver the receipt itself
    /// (`eraseConfirmation == .automatic`): there is nothing to do then. The hub stops expecting
    /// that by itself when the receipt does not arrive, and the screen is offered from then on.
    var offersEraseConfirmation: Bool {
        switch state {
        case .released: return eraseConfirmation != .automatic
        case .sent, .accepted: return resultUnknown
        case .pending, .completed, .cancelled, .superseded: return false
        }
    }

    /// Whether this job says anything about its Base **as the hub lists it now**.
    ///
    /// A job is about one registration of a Base. `completed` ends that registration: the hub
    /// took the Base out of its lists, dropped the registration's key and accepts nothing from the
    /// board until it is registered again (firmware repository, `docs/pogohome-api-v1.md`, "Blocked
    /// Power Bases"). So a Base that the hub lists is a *later* registration than any completed
    /// job of it -- and the hub keeps listing a finished job for ten minutes all the same. Such a
    /// job is history: it is no state of the Base on screen, and it does not stand in the way of
    /// removing the Base again (the hub makes a new job for the new registration).
    ///
    /// Decided from the hub's two lists alone. No time is compared (the times on a job are the
    /// hub's clock), and whether the Base is heard right now plays no part: a new registration
    /// that is offline is still a new registration.
    func concernsPowerBase(listedByHub isListed: Bool) -> Bool {
        !(state == .completed && isListed)
    }

    /// The same question with what the hub says of registrations (`listed`: the Base as the hub
    /// lists it now, `nil` when it does not).
    ///
    /// A job is about one registration. When the hub names it on both sides -- `record` on the
    /// job, `PowerBase.record` on the Base -- a job of **another** registration than the listed
    /// one is history whatever its state: the listed Base is a later registration, and nothing
    /// about that earlier job (waiting, without a result, taken out of the list, completed) is a
    /// state of it or stands in the way of managing it. Where the hub does not say, the rule
    /// above decides.
    func concerns(_ listed: PowerBase?) -> Bool {
        guard let listed else { return true }
        if isAboutAnotherRegistration(than: listed) { return false }
        return concernsPowerBase(listedByHub: true)
    }

    /// The hub names a registration for this job and another one for the Base it lists.
    func isAboutAnotherRegistration(than listed: PowerBase) -> Bool {
        guard let record, let listedRecord = listed.record else { return false }
        return record != listedRecord
    }
}

/// What the hub knew of a removal when "삭제 확인" was opened for it. It only chooses the screen's
/// explanation; the run and what counts as complete are the same.
nonisolated enum PowerBaseReleaseConfirmationOrigin: Hashable, Sendable {
    /// The hub was told "released" by the board.
    case released
    /// The hub gave the command and heard nothing since: the board may have finished, or not.
    case resultUnknown

    init(_ removal: PowerBaseRemoval) {
        self = removal.state == .released ? .released : .resultUnknown
    }
}

nonisolated enum PowerBaseRemovalID {
    /// 32 lower-case hex digits, as the hub issues them.
    static func isValid(_ value: String) -> Bool {
        value.unicodeScalars.count == 32 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// The wire form of a job: in the removal routes' answers (strict) and in the snapshot's
/// `power_base_removals` (lenient: see `PogoSnapshotMapper`).
nonisolated struct PowerBaseRemovalDTO: Decodable, Hashable, Sendable {
    let removalID: String
    let powerBaseUUID: String
    let generation: String?
    let state: String
    let resultUnknown: Bool?
    let cancellable: Bool?
    let createdAtUnixMs: Int64?
    let updatedAtUnixMs: Int64?
    let affectedModuleCount: Int?
    let settingsCleanupPending: Bool?
    /// Added later (additive): `"automatic"` or `"manual"` on a job that is not final. `nil` from
    /// a hub that predates it.
    let eraseConfirmation: String?
    /// Added later (additive): `true` on a `sent`/`accepted` job whose Base the hub took out of
    /// its list. Absent otherwise, and from a hub that predates it.
    let listRemoved: Bool?
    /// Added later (additive): the id of the request that created the job. Absent from a hub
    /// that predates removal requests bound to a registration.
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case removalID = "removal_id"
        case powerBaseUUID = "power_base_uuid"
        case generation
        case state
        case resultUnknown = "result_unknown"
        case cancellable
        case createdAtUnixMs = "created_at_unix_ms"
        case updatedAtUnixMs = "updated_at_unix_ms"
        case affectedModuleCount = "affected_module_count"
        case settingsCleanupPending = "settings_cleanup_pending"
        case eraseConfirmation = "erase_confirmation"
        case listRemoved = "list_removed"
        case requestID = "request_id"
    }

    /// The job, or `nil` when an id is malformed or the state is one this app does not know (a
    /// newer hub): such a job is not shown as something it is not.
    var removal: PowerBaseRemoval? {
        let base = powerBaseUUID.lowercased()
        guard PowerBaseRemovalID.isValid(removalID), ModuleIdentity.isValidRawIdentifier(base), base.count == 16,
              let state = PowerBaseRemoval.State(rawValue: state) else { return nil }
        return PowerBaseRemoval(
            id: removalID,
            powerBaseIdentifier: base,
            state: state,
            resultUnknown: resultUnknown ?? false,
            // Only the hub decides; a job it did not call cancellable is not offered a cancel.
            cancellable: (cancellable ?? false) && state == .pending,
            affectedModuleCount: max(0, affectedModuleCount ?? 0),
            createdAt: Date(timeIntervalSince1970: Double(createdAtUnixMs ?? 0) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(updatedAtUnixMs ?? 0) / 1000),
            settingsCleanupPending: settingsCleanupPending ?? false,
            // Nothing is expected of a job that has ended, whatever a hub might send with it.
            eraseConfirmation: state.isFinal ? .unspecified : PowerBaseEraseConfirmation(wire: eraseConfirmation),
            record: generation.flatMap { PowerBaseRemovalID.isValid($0) ? $0 : nil },
            // Said of a job whose command may be with the board, and of no other.
            powerBaseListRemoved: (listRemoved ?? false) && (state == .sent || state == .accepted),
            requestID: requestID.flatMap { PowerBaseRemovalID.isValid($0) ? $0 : nil }
        )
    }
}

/// Why a removal request didn't give a usable job. Never carries a token.
nonisolated enum PowerBaseRemovalError: Error, Equatable, Sendable {
    /// `401`: the hub doesn't know this device's token.
    case unauthorized
    /// `403` with the hub's code (`tls_required`, …).
    case forbidden(String)
    /// The hub has no removal routes (`404 removal_disabled`, or a hub older than them).
    case notSupported
    /// `404 unknown_power_base`: the hub does not know this Base (any more).
    case unknownPowerBase
    /// `404 removal_not_found`.
    case removalNotFound
    /// `409 power_base_management_unsupported`: this Base has no management credential on the hub.
    /// There is no fallback: the app does not hide it in a list and call that removed.
    case managementUnsupported
    /// `409 enrollment_in_progress`: an enrollment session for this Base is running.
    case enrollmentInProgress
    /// `409 removal_not_cancellable`, with the job as it is now.
    case notCancellable(PowerBaseRemoval?)
    /// `409 removal_capacity_full`: the hub remembers as many removed Power Bases as it can (and
    /// forgets none of them to make room). Nothing was stored; the board gets no command. Not a
    /// "try again later": room is made only when a removed Power Base is registered again.
    case capacityFull
    /// `409 receipt_rejected`: the hub cannot verify this receipt for one of its removals (it is
    /// for another hub, for a registration that was replaced since, or not genuine).
    case receiptRejected
    /// `409 stale_record`: what the hub lists now is not what this request was confirmed for --
    /// the Base was registered again (or a registration was started), or a removal was asked of
    /// that registration and ended, after this device read the list. Nothing was created and the
    /// board gets no command: that registration, or that state of it, is not this request's.
    case staleRecord
    /// `400`/`411`/`413`/`422` with the hub's code.
    case rejected(String)
    /// `503` with the hub's reason (`too_many_removals`, `storage`, `startup`, …).
    case unavailable(String)
    /// The hub presented a different certificate than the one pinned at pairing. Nothing was sent.
    case certificateMismatch
    /// No answer: hub off, network down, timeout. For a `POST` the hub may or may not have the job
    /// now. Sending **the same request** again is safe: it names the registration it was confirmed
    /// for and carries its own id, so the hub answers it with the job it created, or creates that
    /// one job now, or refuses it (`staleRecord`) -- and never removes another registration.
    case unreachable(String)
    /// An answer outside the API contract.
    case badResponse(String)

    var isTransient: Bool {
        switch self {
        case .unreachable, .unavailable, .badResponse: return true
        default: return false
        }
    }

    /// Whether the hub's word is missing (as opposed to a refusal): the outcome is not known.
    var leavesOutcomeUnknown: Bool {
        switch self {
        case .unreachable, .badResponse: return true
        default: return false
        }
    }
}

/// What a removal is asked for: one registration of a Power Base, in the state the user was
/// shown when they confirmed (firmware repository, docs/power-base-management.md, section 16).
///
/// A Base is known by its EUI-64 for as long as the board exists. A registration ends and another
/// begins: the Base is removed, and somebody registers it again. A request that named the Base
/// alone and arrived -- or was sent once more -- after that would remove a registration nobody
/// asked to remove. So a request names what was on screen: the registration (`record`) and how
/// many removals had been asked of it then (`serial`). The hub carries it out only while both are
/// still what it has.
nonisolated struct PowerBaseRemovalBinding: Hashable, Sendable {
    /// `PowerBase.record`: 32 lower-case hex digits.
    let record: String
    /// `PowerBase.removalSerial`.
    let serial: Int

    /// What the hub's `removal_serial` can be: a count that fits 32 bits.
    static func isValidSerial(_ value: Int) -> Bool {
        value >= 0 && value <= Int(UInt32.max)
    }

    var isValid: Bool {
        PowerBaseRemovalID.isValid(record) && Self.isValidSerial(serial)
    }
}

// MARK: - Taking a Power Base out of the hub's list

// "허브 목록에서 제거" (firmware repository, docs/power-base-management.md, section 13) is NOT a
// removal. It is for a Power Base that does not come back: the hub drops its own record of that
// registration, takes the Base and its sensors out of its lists and refuses the Base's data until
// it is registered again. Nothing is said about the board -- what it stored is not erased, and no
// screen of this app calls that "삭제 완료". The hub carries it out at once or refuses; there is
// no job to follow.

/// One Power Base that the hub took out of its list, as the hub reports it.
nonisolated struct PowerBaseForget: Identifiable, Hashable, Sendable {
    /// The hub's `forget_id` (32 lower-case hex digits).
    let id: String
    /// The id the asking device chose for its request: the same request again is the same record.
    let requestID: String
    /// The Base's EUI-64, 16 lower-case hex digits.
    let powerBaseIdentifier: String
    /// The registration that was taken out (`PowerBase.record` at the time).
    let record: String
    /// The hub held a management credential for it.
    let wasManaged: Bool
    let createdAt: Date
    /// Sensors registered under the Base at that moment.
    let affectedModuleCount: Int
    /// A removal of the Base that was still waiting and ended as cancelled with this.
    let cancelledRemovalID: String?
    /// A removal whose command may be with the board: the hub left it exactly as it is.
    let keptRemovalID: String?
    /// The hub still has to clear the room assignments of the sensors that left (it retries).
    var settingsCleanupPending = false
}

/// The wire form of a list removal: in the forget routes' answers and in the snapshot's
/// `power_base_forgets`.
nonisolated struct PowerBaseForgetDTO: Decodable, Hashable, Sendable {
    let forgetID: String
    let requestID: String
    let powerBaseUUID: String
    let record: String
    let state: String
    let managed: Bool?
    let createdAtUnixMs: Int64?
    let affectedModuleCount: Int?
    let cancelledRemovalID: String?
    let keptRemovalID: String?
    let settingsCleanupPending: Bool?

    enum CodingKeys: String, CodingKey {
        case forgetID = "forget_id"
        case requestID = "request_id"
        case powerBaseUUID = "power_base_uuid"
        case record
        case state
        case managed
        case createdAtUnixMs = "created_at_unix_ms"
        case affectedModuleCount = "affected_module_count"
        case cancelledRemovalID = "cancelled_removal_id"
        case keptRemovalID = "kept_removal_id"
        case settingsCleanupPending = "settings_cleanup_pending"
    }

    /// The record, or `nil` when an id is malformed or the state is not the one word this app
    /// knows (`removed_from_hub`): a record from a newer hub is not shown as something it is not.
    var forget: PowerBaseForget? {
        let base = powerBaseUUID.lowercased()
        guard state == "removed_from_hub", PowerBaseRemovalID.isValid(forgetID), PowerBaseRemovalID.isValid(requestID),
              PowerBaseRemovalID.isValid(record), ModuleIdentity.isValidRawIdentifier(base), base.count == 16 else { return nil }
        return PowerBaseForget(
            id: forgetID,
            requestID: requestID,
            powerBaseIdentifier: base,
            record: record,
            wasManaged: managed ?? false,
            createdAt: Date(timeIntervalSince1970: Double(createdAtUnixMs ?? 0) / 1000),
            affectedModuleCount: max(0, affectedModuleCount ?? 0),
            cancelledRemovalID: cancelledRemovalID.flatMap { PowerBaseRemovalID.isValid($0) ? $0 : nil },
            keptRemovalID: keptRemovalID.flatMap { PowerBaseRemovalID.isValid($0) ? $0 : nil },
            settingsCleanupPending: settingsCleanupPending ?? false
        )
    }
}

// A Power Base that is out of the hub's list (firmware repository, docs/power-base-management.md,
// section 15). Not a record of something that happened: the hub's present state. A Base whose
// registration ended -- released by its board, or taken out of the list -- is named in every
// snapshot for as long as it has not been registered again, however long ago that was and
// whether or not the removal job or the list-removal record that ended it is still shown. The
// time a finished job is displayed and the fact that a registration is over are two things.

/// One Power Base the hub says is out of its list now.
nonisolated struct PowerBaseDeparture: Identifiable, Hashable, Sendable {
    enum Reason: String, Sendable {
        /// The board released the registration (an ordinary removal).
        case removed
        /// It was taken out of the hub's list while offline; nothing says the board erased anything.
        case forgotten
    }

    /// The Base's EUI-64, 16 lower-case hex digits.
    let powerBaseIdentifier: String
    /// The registration that ended (`PowerBase.record` while it was listed). `nil`: the hub does
    /// not know it (a block stored by an earlier hub).
    let record: String?
    /// How it ended. `nil`: the hub does not say, or says a word this app does not know.
    let reason: Reason?
    let since: Date?

    var id: String { powerBaseIdentifier }
}

/// The wire form of one entry of the snapshot's `power_base_departures`.
nonisolated struct PowerBaseDepartureDTO: Decodable, Hashable, Sendable {
    let powerBaseUUID: String
    let record: String?
    let reason: String?
    let sinceUnixMs: Int64?

    enum CodingKeys: String, CodingKey {
        case powerBaseUUID = "power_base_uuid"
        case record
        case reason
        case sinceUnixMs = "since_unix_ms"
    }

    /// The departure, or `nil` when the Base's id is malformed: an entry this app cannot read
    /// names no Base. A record that is no record and a reason this app does not know are left
    /// out -- what counts is which Base is out of the list.
    var departure: PowerBaseDeparture? {
        let base = powerBaseUUID.lowercased()
        guard ModuleIdentity.isValidRawIdentifier(base), base.count == 16 else { return nil }
        return PowerBaseDeparture(
            powerBaseIdentifier: base,
            record: record.flatMap { PowerBaseRemovalID.isValid($0) ? $0 : nil },
            reason: reason.flatMap(PowerBaseDeparture.Reason.init(rawValue:)),
            since: sinceUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }
}

/// Why a request to take a Power Base out of the hub's list did not do so. Never carries a token.
nonisolated enum PowerBaseForgetError: Error, Equatable, Sendable {
    /// `401`: the hub doesn't know this device's token.
    case unauthorized
    /// `403` with the hub's code (`tls_required`, …).
    case forbidden(String)
    /// The hub has no such routes (`404 forget_disabled`, or a hub older than them).
    case notSupported
    /// `404 unknown_power_base`: the hub does not list this Base (any more).
    case notListed
    /// `409 power_base_online`: the hub hears the Base right now. Nothing changed.
    case online
    /// `409 stale_record`: the Base was registered again (or a registration was started) after
    /// this device read the list. Nothing changed: that registration is not this request's.
    case staleRecord
    /// `409 enrollment_in_progress`: a registration of this Base is running.
    case enrollmentInProgress
    /// `409 request_id_conflict`: the request id was used for another Base.
    case requestConflict
    /// `409 forget_capacity_full`: the hub remembers as many removed Power Bases as it can.
    case capacityFull
    /// `400`/`411`/`413`/`422` with the hub's code.
    case rejected(String)
    /// `503` with the hub's reason (`storage`, `startup`, `too_many_forgets`, …). Nothing changed.
    case unavailable(String)
    /// The hub presented a different certificate than the one pinned at pairing. Nothing was sent.
    case certificateMismatch
    /// No answer: hub off, network down, timeout. The hub may or may not have carried the request
    /// out; sending the same request again is safe -- the same request id is the same record.
    case unreachable(String)
    /// An answer outside the API contract.
    case badResponse(String)

    /// Whether the hub's word is missing (as opposed to a refusal): the outcome is not known.
    var leavesOutcomeUnknown: Bool {
        switch self {
        case .unreachable, .badResponse: return true
        default: return false
        }
    }
}

nonisolated enum PowerBaseForgetRequestID {
    /// A new request id: 32 lower-case hex digits from the system's random generator.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in
            let value = generator.next() as UInt64
            let hex = String(value, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }
}
