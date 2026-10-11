import Foundation
import Observation

/// Removing (unenrolling) a Power Base from the hub the app follows.
///
/// The job belongs to the hub, not to this screen: once the hub accepted a request it keeps the
/// job across the app closing, this device going away and the Base being offline, and it alone
/// says when it is complete. So this type only asks, cancels and reports what the hub said:
///
/// - **Only the paired hub picked in "Find hubs".** Requests use this device's own credential for
///   that hub and its pinned certificate; anything else sends nothing.
/// - **Nothing is removed locally.** A Base leaves the app's lists when the hub's snapshot no
///   longer has it. A refused or unsupported request never hides anything.
/// - **Success is the hub's `completed`.** An accepted request, a sent command and silence from
///   the Base are all not that.
/// - **A lost answer is not a "no".** A request without an answer may have been accepted. It is
///   kept exactly as it was sent and can be sent again (`retryRemoval`): the hub answers the same
///   request with the job it created, or creates that one job now, or refuses it.
/// - **A removal is asked of one registration.** The request names the registration the user was
///   shown when they confirmed and that registration's removal serial
///   (`PowerBaseRemovalBinding`), and carries an id of its own. The hub carries it out only for
///   that registration, and at most once -- so a request that arrives late, or is sent again,
///   after the Base was removed and registered again does nothing to the new registration. The
///   Base's EUI-64 alone is never sent as a removal request. What the user confirms anew is a new
///   request (`requestRemoval(of:binding:)`); what is sent again is the old one, unchanged.
/// - **Nothing late applies.** A change of hub drops every job and every answer still on its way.
/// - **A finished removal is history.** The hub keeps listing a completed job for a while, also
///   after the same Base was registered again. Such a job is not the state of a Base the hub
///   lists, and it is news only once, to an app that can tie it to what it saw or asked for by
///   the job's id (`PowerBaseRemovalCompletions`).
/// - **Taking a Base out of the hub's list is another thing.** "허브 목록에서 제거" is no job: the
///   hub does it at once, for an offline Base, or refuses. It is asked with the registration this
///   device saw (`PowerBase.record`) and an id of its own, so that a request can be sent again
///   after a lost answer without doing anything twice -- and can never remove a later
///   registration. It is never shown as a removal, and never as "삭제 완료".
/// - **A request is about one registration, and ends with it.** A request without an answer
///   ("알 수 없음") is kept only while the hub may still carry it out: when the registration it
///   names leaves the list by another way -- another device's request, a removal -- or the hub
///   lists another registration of the Base, it is dropped. It never shows on, or stands in the
///   way of, a registration it was not made for, and an answer that still arrives for it is
///   nobody's (`settleRequests`).
/// - **Taking a completion in is not showing it.** Every completion is recorded when the hub's
///   word arrives, wherever the app is (`completionEvents`, in order, none dropped). What the user
///   is told, and when a screen closes, is decided by who is on screen (`notices`, and the
///   management sheet's own place in the events).
@MainActor
@Observable
final class PowerBaseRemovalController {
    /// What the last action on one Base came to, until the hub's own list says more.
    nonisolated enum Action: Equatable, Sendable {
        /// The `POST` is under way.
        case requesting
        /// The `DELETE` is under way.
        case cancelling
        /// No answer to the removal request came: the hub may or may not have the job. The same
        /// request can be sent again (`retryRemoval`), and the hub's snapshot settles it.
        case resultUnknown
        case failed(Failure)
    }

    nonisolated enum Failure: Equatable, Sendable {
        /// The source is not a paired hub; nothing was sent.
        case notEligible(PowerBaseHubIneligibility)
        /// This device's credential for the hub couldn't be read; nothing was sent.
        case credentialUnavailable
        case request(PowerBaseRemovalError)
    }

    /// What "허브 목록에서 제거" of one Base came to, until the hub's snapshot says more.
    nonisolated enum ForgetAction: Equatable, Sendable {
        /// The `POST` is under way.
        case requesting
        /// No answer came: the hub may or may not have carried it out. The same request can be
        /// sent again (`retryForget`).
        case resultUnknown
        case failed(ForgetFailure)
    }

    nonisolated enum ForgetFailure: Equatable, Sendable {
        /// The source is not a paired hub; nothing was sent.
        case notEligible(PowerBaseHubIneligibility)
        /// This device's credential for the hub couldn't be read; nothing was sent.
        case credentialUnavailable
        case request(PowerBaseForgetError)
    }

    /// The list removal under way, without an answer, or refused, by Base.
    private(set) var forgetActions: [String: ForgetAction] = [:]
    /// The request this device made for a Base and has no final word on: sent again exactly as
    /// it is (the hub answers the same request with the same record).
    private var forgetRequests: [String: ForgetRequest] = [:]
    private struct ForgetRequest {
        let requestID: String
        let record: String
    }

    /// The removal request this device made for a Base and has no final word on: sent again
    /// exactly as it is. Never replaced by "whatever is listed now" -- a new confirmation makes
    /// a new one.
    private var removalRequests: [String: RemovalRequest] = [:]
    private struct RemovalRequest {
        let requestID: String
        let binding: PowerBaseRemovalBinding
    }

    /// The jobs the hub listed last, by Base (the open job if there is one, else the latest).
    private(set) var removals: [String: PowerBaseRemoval] = [:]
    /// The action under way, or its failure, by Base.
    private(set) var actions: [String: Action] = [:]
    /// The hub's list could not be read just now (shown as a hint; the jobs go on at the hub).
    private(set) var refreshProblem: PowerBaseRemovalError?
    private(set) var target: PowerBaseHubTarget = .none
    /// One removal that was completed while this app was following it, numbered in the order the
    /// hub's word arrived. The numbers go on across sources and are never used twice.
    nonisolated struct CompletionEvent: Identifiable, Hashable, Sendable {
        let serial: Int
        let completion: PowerBaseRemovalCompletions.Completion
        var id: Int { serial }
    }

    /// Every followed removal of the current source that the hub completed, oldest first. Nothing
    /// is taken out when it was shown: a screen that has to react (a management sheet closing)
    /// keeps its own place by `serial`. Never holds a job that was only read as completed.
    private(set) var completionEvents: [CompletionEvent] = []
    /// The serial of the latest event, whichever source it was from.
    private(set) var completionSerial = 0
    /// The "삭제 완료" notices: the ones the user has still to be shown, and the ones on screen.
    private(set) var notices = PowerBaseRemovalNotices()

    private let transport: PowerBaseRemovalTransport
    private let credentials: HubCredentialStoring
    private var generation = 0
    /// What this app has seen of the current source's jobs, in order (`sourceDidReport`).
    private var completions = PowerBaseRemovalCompletions()
    /// The source whose snapshot jobs were reported last (`sourceDidReport`); `nil` before the first report.
    private(set) var reportedSource: SensorSourceIdentity?
    /// Ids of answered jobs that a snapshot has carried since.
    private var carried: Set<String> = []

    init(
        transport: PowerBaseRemovalTransport = URLSessionPowerBaseRemovalTransport(),
        credentials: HubCredentialStoring = KeychainHubCredentialStore()
    ) {
        self.transport = transport
        self.credentials = credentials
    }

    var ineligibility: PowerBaseHubIneligibility? { target.ineligibility }

    /// The job to show for a Base, from the hub's snapshot and from what the hub answered to this
    /// device (a request, a cancel, a confirmation, the list read while the sheet is shown).
    func removal(for powerBaseIdentifier: String, in snapshot: HomeSnapshot) -> PowerBaseRemoval? {
        Self.removal(for: powerBaseIdentifier, in: snapshot, answered: removals[powerBaseIdentifier])
    }

    /// The rules, in order:
    ///
    /// 1. **One job, its latest word.** When the snapshot and the answer are about the same job,
    ///    the one that is further along (`isFurtherAlong`): an answer is shown before the next
    ///    snapshot arrives, and an older answer never undoes a later snapshot.
    /// 2. **Two jobs: the one under way.** The hub makes a job for a Base only when none of its
    ///    jobs is under way, so a job under way is the newer one -- whether the snapshot has it or
    ///    the answer. Between two finished jobs the snapshot's stands; an answer about another job
    ///    never replaces the snapshot's job under way.
    /// 3. **A finished removal is history once the Base is listed again.** A completed job is the
    ///    job of a Base only while the hub does not list that Base
    ///    (`PowerBaseRemoval.concernsPowerBase`). Listed again, the Base was registered again and
    ///    has no job -- until the hub makes a new one. The one exception is a snapshot that is
    ///    itself behind: it still has that very job under way, so its list of Bases is from before
    ///    the job completed, too.
    ///
    /// No time is compared. The times on a job are the hub's clock, which can be set back.
    nonisolated static func removal(for powerBaseIdentifier: String, in snapshot: HomeSnapshot, answered: PowerBaseRemoval?) -> PowerBaseRemoval? {
        let shown = snapshot.removal(forPowerBase: powerBaseIdentifier)
        var latest = shown
        if var answered {
            let sameJob = snapshot.powerBaseRemovals.first { $0.id == answered.id }
            if let sameJob, !isFurtherAlong(answered, than: sameJob) { answered = sameJob }
            if let shown, shown.id != answered.id {
                latest = shown.state.isFinal && !answered.state.isFinal ? answered : shown
            } else {
                latest = answered
            }
        }
        guard let latest else { return nil }
        let listed = snapshot.powerBases.first { $0.hardwareIdentifier == powerBaseIdentifier }
        // A job of another registration than the listed one is history, whatever its state and
        // however old the snapshot is (`PowerBaseRemoval.concerns`): it is never the listed
        // Base's job.
        if let listed, latest.isAboutAnotherRegistration(than: listed) { return nil }
        let snapshotIsBehind = snapshot.powerBaseRemovals.contains { $0.id == latest.id && !$0.state.isFinal }
        return latest.concernsPowerBase(listedByHub: listed != nil && !snapshotIsBehind) ? latest : nil
    }

    /// Whether `removal` is a later word of the hub about the same job than `other`. A job only
    /// moves forward -- pending, sent, accepted, released, then completed; cancelled or superseded
    /// end it -- and "no result" is said of a job that stays where it is. So is "confirm it by
    /// hand" of a released job the hub first expected to be confirmed by the board itself.
    nonisolated static func isFurtherAlong(_ removal: PowerBaseRemoval, than other: PowerBaseRemoval) -> Bool {
        func step(_ state: PowerBaseRemoval.State) -> Int {
            switch state {
            case .pending: return 0
            case .sent: return 1
            case .accepted: return 2
            case .released: return 3
            case .completed, .cancelled, .superseded: return 4
            }
        }
        if step(removal.state) != step(other.state) { return step(removal.state) > step(other.state) }
        // The Base was taken out of the list after the command went out: a later word, too.
        if removal.powerBaseListRemoved != other.powerBaseListRemoved { return removal.powerBaseListRemoved }
        if removal.resultUnknown != other.resultUnknown { return removal.resultUnknown }
        return removal.state == .released && removal.eraseConfirmation == .manual && other.eraseConfirmation == .automatic
    }

    func action(for powerBaseIdentifier: String) -> Action? { actions[powerBaseIdentifier] }

    func forgetAction(for powerBaseIdentifier: String) -> ForgetAction? { forgetActions[powerBaseIdentifier] }

    // MARK: - Source

    /// The app now reads `newTarget`. Another hub (or none) drops everything that belonged to the
    /// previous one; answers still on their way are ignored.
    func targetDidChange(_ newTarget: PowerBaseHubTarget) {
        let previous = target
        target = newTarget
        guard newTarget.hubID != previous.hubID || newTarget.ineligibility != previous.ineligibility else { return }
        generation += 1
        removals = [:]
        actions = [:]
        removalRequests = [:]
        forgetActions = [:]
        forgetRequests = [:]
        refreshProblem = nil
        carried = []
    }

    /// The jobs in the app's latest snapshot, read from `source`. Called for the first snapshot
    /// and for every change, whether or not a management screen is shown: this is how a removal
    /// that the hub carries out by itself is seen to end. Another source starts from nothing.
    ///
    /// `forgets`: the Bases the hub says it took out of its list. One that answers a request of
    /// this device whose answer was lost settles that request.
    ///
    /// `powerBases`: the Bases the hub lists in the same snapshot (`nil`: the caller does not
    /// say). With them, what is left of a request for a registration that is gone or replaced is
    /// dropped (`settleRequests`).
    ///
    /// `departures`: the Bases the hub names as out of its list in the same snapshot. A removal
    /// request without an answer ends when its Base is one of them: whichever registration ended
    /// last, the one the request named is over.
    func sourceDidReport(
        _ jobs: [PowerBaseRemoval], forgets: [PowerBaseForget] = [], powerBases: [PowerBase]? = nil,
        departures: [PowerBaseDeparture] = [], from source: SensorSourceIdentity
    ) {
        if source != reportedSource {
            // Another hub: what the previous one completed is told on no screen of this one.
            reportedSource = source
            completions = PowerBaseRemovalCompletions()
            completionEvents = []
            notices = PowerBaseRemovalNotices()
            carried = []
        }
        for forget in forgets {
            // Only this device's own request, known by its id: a list removal another device
            // asked for takes the Base off this screen too, and is news to nobody here.
            guard let request = forgetRequests[forget.powerBaseIdentifier], request.requestID == forget.requestID else { continue }
            forgetWasCarriedOut(forget)
        }
        settleRequests(jobs: jobs, forgets: forgets, powerBases: powerBases, departures: departures)
        // What was answered to this device never stays behind the snapshots: an answer the
        // snapshot has caught up with is replaced by the snapshot's word, and one whose job the
        // hub listed and no longer lists is dropped -- that job ended and left the hub's history.
        for (base, answered) in removals {
            if let listed = jobs.first(where: { $0.id == answered.id }) {
                carried.insert(answered.id)
                if !Self.isFurtherAlong(answered, than: listed) { removals[base] = listed }
            } else if carried.contains(answered.id) {
                removals[base] = nil
            }
        }
        follow(jobs)
    }

    /// The hub confirmed a removal to this device ("삭제 확인"): its answer is shown at once, and
    /// the snapshot follows. The job it names is the one this device confirmed.
    func removalWasConfirmed(_ removal: PowerBaseRemoval) {
        adopt(removal, generation: generation, isAnswerToThisDevice: true)
    }

    // MARK: - Notices

    /// The Devices tab is really on screen (foreground, selected, nothing over it): the notices
    /// that were waiting are shown now. Returns the ones that are newly on screen, to be announced.
    @discardableResult
    func showWaitingNotices() -> [PowerBaseRemovalCompletions.Completion] {
        notices.show()
    }

    /// The tab left the screen while notices were shown: they are shown again when it is back.
    func noticesWereInterrupted() {
        notices.interrupt()
    }

    /// These notices stayed on screen for their whole time, or the user put them away.
    func noticesWereShown(_ shown: [PowerBaseRemovalCompletions.Completion]) {
        notices.finish(shown)
    }

    // MARK: - Actions

    /// Asks the hub to unenroll one registration of `powerBaseIdentifier`: the one the user was
    /// shown and has just confirmed (`binding`, taken when the confirmation opened -- not whatever
    /// the list offers by now). Every call is a new confirmation and so a new request with an id
    /// of its own. Ignored while an action for that Base is under way.
    func requestRemoval(of powerBaseIdentifier: String, binding: PowerBaseRemovalBinding) {
        guard !isBusy(powerBaseIdentifier) else { return }
        guard let context = context(for: powerBaseIdentifier) else { return }
        let request = RemovalRequest(requestID: PowerBaseForgetRequestID.make(), binding: binding)
        removalRequests[powerBaseIdentifier] = request
        send(request, for: powerBaseIdentifier, context: context)
    }

    /// Sends the removal request that got no answer again, unchanged: the same registration, the
    /// same serial, the same id. This is what "다시 요청해도 안전합니다" promises.
    func retryRemoval(of powerBaseIdentifier: String) {
        guard actions[powerBaseIdentifier] == .resultUnknown, let request = removalRequests[powerBaseIdentifier],
              let context = context(for: powerBaseIdentifier) else { return }
        send(request, for: powerBaseIdentifier, context: context)
    }

    private func send(_ request: RemovalRequest, for powerBaseIdentifier: String, context: Context) {
        actions[powerBaseIdentifier] = .requesting
        Task { [weak self, transport] in
            let result: Result<PowerBaseRemoval, Error>
            do {
                result = .success(try await transport.request(
                    baseURL: context.baseURL, credential: context.credential, powerBaseIdentifier: powerBaseIdentifier,
                    binding: request.binding, requestID: request.requestID
                ))
            } catch {
                result = .failure(error)
            }
            self?.finishRequest(result, for: powerBaseIdentifier, requestID: request.requestID, generation: context.generation)
        }
    }

    /// Asks the hub to cancel a job that is still waiting. The hub refuses once the command may
    /// have reached the board; that refusal is shown, never overridden.
    func cancelRemoval(_ removal: PowerBaseRemoval) {
        let base = removal.powerBaseIdentifier
        guard !isBusy(base), let context = context(for: base) else { return }
        actions[base] = .cancelling
        Task { [weak self, transport] in
            let result: Result<PowerBaseRemoval, Error>
            do {
                result = .success(try await transport.cancel(baseURL: context.baseURL, credential: context.credential, removalID: removal.id))
            } catch let PowerBaseRemovalError.notCancellable(current?) {
                // The hub's word for what the job is now -- shown, with the refusal.
                self?.adopt(current, generation: context.generation)
                result = .failure(PowerBaseRemovalError.notCancellable(current))
            } catch {
                result = .failure(error)
            }
            self?.finish(result, for: base, generation: context.generation)
        }
    }

    /// Asks the hub to take `powerBaseIdentifier` out of its list ("허브 목록에서 제거"): for a Base
    /// the hub does not hear. `record` is the registration the user was shown and confirmed
    /// (`PowerBase.record`); the hub refuses when it lists another one by now, or hears the Base.
    /// Ignored while a request for that Base is under way. The caller has confirmed with the user.
    func forgetPowerBase(_ powerBaseIdentifier: String, record: String) {
        guard forgetActions[powerBaseIdentifier] != .requesting, !isBusy(powerBaseIdentifier) else { return }
        if let reason = target.ineligibility {
            forgetActions[powerBaseIdentifier] = .failed(.notEligible(reason))
            return
        }
        guard let hubID = target.hubID, let baseURL = target.baseURL else { return }
        guard let stored = try? credentials.credential(forHubID: hubID), stored.hubID.lowercased() == hubID.lowercased() else {
            forgetActions[powerBaseIdentifier] = .failed(.credentialUnavailable)
            return
        }
        // A request without a final word is sent again as it is; a new confirmation of another
        // registration is a new request.
        let request: ForgetRequest
        if let earlier = forgetRequests[powerBaseIdentifier], earlier.record == record {
            request = earlier
        } else {
            request = ForgetRequest(requestID: PowerBaseForgetRequestID.make(), record: record)
            forgetRequests[powerBaseIdentifier] = request
        }
        forgetActions[powerBaseIdentifier] = .requesting
        let current = generation
        Task { [weak self, transport] in
            let result: Result<PowerBaseForget, Error>
            do {
                result = .success(try await transport.forget(
                    baseURL: baseURL, credential: stored, powerBaseIdentifier: powerBaseIdentifier,
                    record: request.record, requestID: request.requestID
                ))
            } catch {
                result = .failure(error)
            }
            self?.finishForget(result, for: powerBaseIdentifier, requestID: request.requestID, generation: current)
        }
    }

    /// Sends the request that got no answer again, unchanged.
    func retryForget(of powerBaseIdentifier: String) {
        guard forgetActions[powerBaseIdentifier] == .resultUnknown, let request = forgetRequests[powerBaseIdentifier] else { return }
        forgetPowerBase(powerBaseIdentifier, record: request.record)
    }

    /// The failure (or the missing answer) shown for a Base was read.
    func dismissForgetFailure(for powerBaseIdentifier: String) {
        switch forgetActions[powerBaseIdentifier] {
        case .failed:
            forgetActions[powerBaseIdentifier] = nil
            forgetRequests[powerBaseIdentifier] = nil
        case .requesting, .resultUnknown, nil:
            break
        }
    }

    /// Reads the hub's list of jobs. Called when a management screen appears and while it is
    /// shown; the snapshot the app follows carries the same jobs, this also catches a job whose
    /// outcome can no longer be confirmed (`result_unknown`), which changes with time alone.
    func refresh() async {
        guard target.ineligibility == nil, let hubID = target.hubID, let baseURL = target.baseURL,
              let credential = try? credentials.credential(forHubID: hubID), credential.hubID.lowercased() == hubID.lowercased() else { return }
        let current = generation
        do {
            let listed = try await transport.list(baseURL: baseURL, credential: credential)
            guard current == generation else { return }
            refreshProblem = nil
            removals = Self.byPowerBase(listed)
            follow(listed)
        } catch {
            guard current == generation else { return }
            let error = error as? PowerBaseRemovalError ?? .unreachable("HTTP")
            // A hub without the routes simply has no jobs to show.
            refreshProblem = error == .notSupported ? nil : error
        }
    }

    /// The failure shown for a Base was read; the row goes back to its normal state. What was
    /// asked is over with it: the next removal is a new confirmation.
    func dismissFailure(for powerBaseIdentifier: String) {
        if case .failed = actions[powerBaseIdentifier] {
            actions[powerBaseIdentifier] = nil
            removalRequests[powerBaseIdentifier] = nil
        }
    }

    // MARK: - Internals

    private struct Context {
        let generation: Int
        let baseURL: URL
        let credential: HubCredential
    }

    /// What is left of this device's own requests is kept only for the registration it was made
    /// for. Decided from what the hub says in one snapshot, never from a time:
    ///
    /// - A request without a final word ("요청 중", "알 수 없음") names a registration
    ///   (`ForgetRequest.record`). It ends, without a notice, when the hub shows that this
    ///   registration left the list by **another** way -- a list removal of the same registration
    ///   that is not this request's, or a removal of it that the board released -- or that the
    ///   Base is listed under **another** registration. Its own answer, should it still arrive,
    ///   is then nobody's (`finishForget`).
    /// - A refusal is a final word and is shown until it is read -- also on the registration that
    ///   replaced the one it was about (that is what "그사이 다시 등록되어" tells). It ends unread
    ///   only when the hub does not list the Base at all: nothing is shown for such a Base, and
    ///   should the Base be listed again later, that is another matter. So does the failure of a
    ///   removal request.
    ///
    /// A Base that is merely missing from the list with nothing said about it (a hub that is
    /// starting again) ends nothing that is still open: the request stays, unseen, until the hub
    /// says more.
    ///
    /// A **removal** request without an answer is settled the same way, by what the hub shows of
    /// the registration it names:
    ///
    /// - the hub lists a job with this request's id: that is the answer, arrived by another way.
    ///   It is taken as the answer (`adopt`), and whatever still comes for the request is nobody's;
    /// - the hub lists a job of that registration that another request created, or shows that the
    ///   registration left the list (released, completed, taken out of the list -- or, when none
    ///   of those records is shown any more, the Base named as out of the list): what was asked
    ///   is under way or done. The request ends, without a notice of its own;
    /// - the hub lists the Base under **another** registration: the request was about one that is
    ///   gone. It ends -- and is never sent again, so nothing of it can reach the new registration
    ///   from this app. (Should a copy of it still arrive at the hub, the hub refuses it.)
    ///
    /// A request that is still on its way (`requesting`) is ended by its own job, or by the Base
    /// being listed under another registration; otherwise its answer is waited for.
    private func settleRequests(jobs: [PowerBaseRemoval], forgets: [PowerBaseForget], powerBases: [PowerBase]?, departures: [PowerBaseDeparture]) {
        // The Bases the hub lists in this snapshot, with the registration it names for each;
        // empty when the caller does not say which are listed (then nothing is read from a Base
        // being listed, or not).
        var listed: [String: String?] = [:]
        for base in powerBases ?? [] { listed[base.hardwareIdentifier] = .some(base.record) }

        for (base, request) in removalRequests {
            if let own = jobs.first(where: { $0.powerBaseIdentifier == base && $0.requestID == request.requestID }) {
                removalRequests[base] = nil
                if actions[base] == .requesting || actions[base] == .resultUnknown { actions[base] = nil }
                adopt(own, generation: generation, isAnswerToThisDevice: true)
                continue
            }
            let record = request.binding.record
            var replaced = false
            if case let .some(.some(now)) = listed[base] { replaced = now != record }
            if replaced {
                // The registration this request names is gone and another is listed: whatever
                // the hub still answers to it -- its old job, or a refusal -- is about nothing on
                // this screen, also when the request is still on its way.
                removalRequests[base] = nil
                if actions[base] == .requesting || actions[base] == .resultUnknown { actions[base] = nil }
                continue
            }
            guard actions[base] == .resultUnknown else { continue }
            let underWayOrDone = jobs.contains { $0.powerBaseIdentifier == base && $0.record == record }
                || forgets.contains { $0.powerBaseIdentifier == base && $0.record == record }
                // Out of the hub's list and not listed again: whichever registration ended last,
                // the one this request named has ended (the job that ended it may be shown no
                // more: a finished job is listed for ten minutes).
                || (listed[base] == nil && departures.contains { $0.powerBaseIdentifier == base })
            if underWayOrDone {
                removalRequests[base] = nil
                actions[base] = nil
            }
        }
        guard powerBases != nil else { return }

        for (base, request) in forgetRequests {
            let removedByAnotherRequest = forgets.contains {
                $0.powerBaseIdentifier == base && $0.record == request.record && $0.requestID != request.requestID
            }
            let released = jobs.contains {
                $0.powerBaseIdentifier == base && $0.record == request.record && ($0.state == .released || $0.state == .completed)
            }
            var replaced = false
            if case let .some(.some(record)) = listed[base] { replaced = record != request.record }
            if removedByAnotherRequest || released || replaced {
                forgetRequests[base] = nil
                forgetActions[base] = nil
            }
        }
        for (base, action) in forgetActions {
            if case .failed = action, listed[base] == nil { forgetActions[base] = nil }
        }
        for (base, action) in actions {
            if case .failed = action, listed[base] == nil { actions[base] = nil }
        }
    }

    private func isBusy(_ powerBaseIdentifier: String) -> Bool {
        switch actions[powerBaseIdentifier] {
        case .requesting, .cancelling: return true
        case .resultUnknown, .failed, nil: return false
        }
    }

    /// The hub, address and credential for a request, or `nil` after recording why there is none.
    private func context(for powerBaseIdentifier: String) -> Context? {
        if let reason = target.ineligibility {
            actions[powerBaseIdentifier] = .failed(.notEligible(reason))
            return nil
        }
        guard let hubID = target.hubID, let baseURL = target.baseURL else { return nil }
        do {
            guard let stored = try credentials.credential(forHubID: hubID), stored.hubID.lowercased() == hubID.lowercased() else {
                actions[powerBaseIdentifier] = .failed(.credentialUnavailable)
                return nil
            }
            return Context(generation: generation, baseURL: baseURL, credential: stored)
        } catch {
            actions[powerBaseIdentifier] = .failed(.credentialUnavailable)
            return nil
        }
    }

    /// `isAnswerToThisDevice`: the hub's answer to this device's own removal request or
    /// confirmation -- the job it names is the one this device asked about.
    private func adopt(_ removal: PowerBaseRemoval, generation current: Int, isAnswerToThisDevice: Bool = false) {
        guard current == generation else { return }
        // An answer about an earlier job of the Base (it arrives late) never replaces a later one.
        let isEarlierJob = removals[removal.powerBaseIdentifier].map { $0.id != removal.id && removal.state.isFinal && !$0.state.isFinal } ?? false
        if !isEarlierJob { removals[removal.powerBaseIdentifier] = removal }
        record(isAnswerToThisDevice ? completions.observeAnswer(removal) : completions.observe([removal]))
    }

    /// Every word of the hub about its jobs passes through here, in the order it arrived.
    private func follow(_ jobs: [PowerBaseRemoval]) {
        record(completions.observe(jobs))
    }

    /// Every completion becomes an event and a notice to show: none is dropped when several
    /// arrive in one report.
    private func record(_ finished: [PowerBaseRemovalCompletions.Completion]) {
        for completion in finished {
            completionSerial += 1
            completionEvents.append(CompletionEvent(serial: completionSerial, completion: completion))
        }
        notices.receive(finished)
    }

    private func finish(_ result: Result<PowerBaseRemoval, Error>, for powerBaseIdentifier: String, generation current: Int) {
        guard current == generation else { return }
        switch result {
        case let .success(removal):
            actions[powerBaseIdentifier] = nil
            adopt(removal, generation: current)
        case let .failure(error):
            actions[powerBaseIdentifier] = .failed(.request(error as? PowerBaseRemovalError ?? .unreachable("HTTP")))
        }
    }

    /// The answer to a removal request -- or its absence.
    ///
    /// Only for the request that is still this device's open one for the Base: another hub since,
    /// a request that the snapshot settled meanwhile (its registration is gone, or its job was
    /// seen), or one the user put away -- an answer that still arrives for such a request is
    /// nobody's, and changes nothing that is on screen for the Base as it is listed now.
    private func finishRequest(_ result: Result<PowerBaseRemoval, Error>, for powerBaseIdentifier: String, requestID: String, generation current: Int) {
        guard current == generation, removalRequests[powerBaseIdentifier]?.requestID == requestID else { return }
        switch result {
        case let .success(removal):
            actions[powerBaseIdentifier] = nil
            removalRequests[powerBaseIdentifier] = nil
            adopt(removal, generation: current, isAnswerToThisDevice: true)
        case let .failure(error):
            let error = error as? PowerBaseRemovalError ?? .unreachable("HTTP")
            if error.leavesOutcomeUnknown {
                // Not a "no": the request stays as it is, to be sent again or settled by the snapshot.
                actions[powerBaseIdentifier] = .resultUnknown
            } else {
                actions[powerBaseIdentifier] = .failed(.request(error))
                removalRequests[powerBaseIdentifier] = nil
            }
        }
    }

    private func finishForget(_ result: Result<PowerBaseForget, Error>, for powerBaseIdentifier: String, requestID: String, generation current: Int) {
        // Another hub since, or another request for this Base: this answer is nobody's.
        guard current == generation, forgetRequests[powerBaseIdentifier]?.requestID == requestID else { return }
        switch result {
        case let .success(forget):
            forgetWasCarriedOut(forget)
        case let .failure(error):
            let error = error as? PowerBaseForgetError ?? .unreachable("HTTP")
            if error.leavesOutcomeUnknown {
                // Not a "no": the request stays, to be sent again or settled by the snapshot.
                forgetActions[powerBaseIdentifier] = .resultUnknown
            } else {
                forgetActions[powerBaseIdentifier] = .failed(.request(error))
                forgetRequests[powerBaseIdentifier] = nil
            }
        }
    }

    /// The hub's record of this device's own request: told as what it is. Once: the request it
    /// answers is dropped here, and nothing but that open request leads here.
    private func forgetWasCarriedOut(_ forget: PowerBaseForget) {
        let base = forget.powerBaseIdentifier
        forgetActions[base] = nil
        forgetRequests[base] = nil
        // The answers kept for this Base are about a registration that is out of the list.
        if let answered = removals[base], answered.state.isFinal || answered.id == forget.cancelledRemovalID { removals[base] = nil }
        record([PowerBaseRemovalCompletions.Completion(id: forget.id, powerBaseIdentifier: base, kind: .removedFromHubList)])
    }

    /// One job per Base: the one that is not final if there is one, otherwise the most recently
    /// updated.
    nonisolated static func byPowerBase(_ removals: [PowerBaseRemoval]) -> [String: PowerBaseRemoval] {
        var out: [String: PowerBaseRemoval] = [:]
        for removal in removals {
            guard let existing = out[removal.powerBaseIdentifier] else {
                out[removal.powerBaseIdentifier] = removal
                continue
            }
            let better: Bool
            if existing.state.isFinal != removal.state.isFinal {
                better = !removal.state.isFinal
            } else {
                better = removal.updatedAt > existing.updatedAt
            }
            if better { out[removal.powerBaseIdentifier] = removal }
        }
        return out
    }
}
