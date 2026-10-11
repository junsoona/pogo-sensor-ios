import Foundation

/// Which removals ended as `completed` **while this running app was following them** -- the ones
/// worth a "삭제 완료" notice, each exactly once.
///
/// The hub lists a finished job for ten minutes and repeats it in every snapshot, in its list of
/// jobs and in its answers. Reading `completed` is therefore no news by itself: after the app is
/// started again, comes back to the foreground or reads the same list twice, it is the same old
/// fact. What is news is a completion this app can tie to something it saw or did, **by the job's
/// id**:
///
/// - a job it saw under way (waiting, being removed, without a result, to be confirmed) and now
///   sees completed; or
/// - the job the hub named in its answer to this device's own request (the removal request, or the
///   confirmation handed in from "삭제 확인"), whenever that job is seen completed -- in that very
///   answer, before it, or after it.
///
/// Never counted:
/// - a job first seen `completed` that no answer to this device named: an earlier removal, whoever
///   asked for it. **That this device has just asked for the removal of the same Base changes
///   nothing**: the hub keeps a finished job of the Base's earlier registration in its list, and a
///   request whose answer has not arrived says nothing about which job is its own. (`1.2.1 (9)`
///   took the first job seen for such a Base for the request's and announced a removal that had
///   not even been stored.)
/// - a job reported `completed` again -- also when an older word about it ("still under way")
///   turns up in between: a job that was seen to end has ended;
/// - a job that ended any other way (cancelled, overtaken by a new registration);
/// - a job that completed while another job of the same Base is under way: that is the earlier
///   registration's removal turning up late, not the end of what the user is doing now.
///
/// What this leaves out, knowingly: a request whose answer was lost and whose job this app never
/// saw under way. When that job turns up completed it is not announced -- nothing ties it to the
/// request but the Base. The Base still leaves the lists, as the hub says.
///
/// Decided from job ids and states in the order they were seen. No time is compared. One value
/// belongs to one source; another hub starts from nothing.
nonisolated struct PowerBaseRemovalCompletions: Sendable {
    /// One removal that was completed while it was followed.
    nonisolated struct Completion: Identifiable, Hashable, Sendable {
        /// What ended. The two are never told as one another.
        nonisolated enum Kind: Hashable, Sendable {
            /// A removal the hub verified: the board erased what it had stored ("삭제 완료").
            case removalCompleted
            /// The hub took the Base out of its list at this device's request ("허브 목록에서
            /// 제거"): nothing is said about the board.
            case removedFromHubList
        }

        /// The hub's `removal_id` (or, for a list removal, its `forget_id`).
        let id: String
        /// The removed Base's EUI-64, 16 lower-case hex digits.
        let powerBaseIdentifier: String
        var kind: Kind = .removalCompleted
    }

    /// Jobs seen under way and not seen to end, by id, with their Base.
    private var underWay: [String: String] = [:]
    /// Jobs seen in a final state, by id: whether that state was `completed`, and their Base. A
    /// job only moves forward, so a later report that shows one of them under way is an older word
    /// arriving late.
    private var ended: [String: (completed: Bool, powerBase: String)] = [:]
    /// Jobs the hub named in an answer to this device's own request.
    private var answered: Set<String> = []
    /// Jobs whose completion was returned once.
    private var announced: Set<String> = []

    /// Takes in jobs as the hub reported them -- a snapshot's list or the hub's own list -- and
    /// returns the ones that just completed while they were followed, in the order given.
    mutating func observe(_ jobs: [PowerBaseRemoval]) -> [Completion] {
        var finished: [Completion] = []
        for job in jobs {
            if let completion = take(job, wasFollowed: false) { finished.append(completion) }
        }
        return current(finished)
    }

    /// Takes in the hub's answer to this device's own request: the job it names is this device's,
    /// whatever state it is in and whatever was seen of it before.
    mutating func observeAnswer(_ job: PowerBaseRemoval) -> [Completion] {
        answered.insert(job.id)
        if let completion = take(job, wasFollowed: true) { return current([completion]) }
        // The answer is an older word (the job was already seen completed, unannounced because
        // nothing tied it to this device until now).
        if let end = ended[job.id], end.completed, announced.insert(job.id).inserted {
            return current([Completion(id: job.id, powerBaseIdentifier: end.powerBase)])
        }
        return []
    }

    private mutating func take(_ job: PowerBaseRemoval, wasFollowed: Bool) -> Completion? {
        let base = job.powerBaseIdentifier
        guard job.state.isFinal else {
            if ended[job.id] == nil { underWay[job.id] = base }
            return nil
        }
        let sawItUnderWay = underWay.removeValue(forKey: job.id) != nil
        // A job ends once: one that ended another way does not come back as completed news.
        if let earlier = ended[job.id], !earlier.completed { return nil }
        ended[job.id] = (job.state == .completed, base)
        guard job.state == .completed, sawItUnderWay || wasFollowed || answered.contains(job.id) else { return nil }
        return announced.insert(job.id).inserted ? Completion(id: job.id, powerBaseIdentifier: base) : nil
    }

    /// Without the completions of a Base that has another job under way.
    private func current(_ finished: [Completion]) -> [Completion] {
        finished.filter { !underWay.values.contains($0.powerBaseIdentifier) }
    }
}

/// The "삭제 완료" notices the user has still to be shown, and the ones on screen.
///
/// A completion is taken in whenever the hub's word arrives -- also while the app is in the
/// background, another tab is selected or a sheet covers the Devices tab. It is *shown* only while
/// the tab is really on screen, and it counts as shown only once it stayed there for its whole
/// time (or the user put it away). A notice that was cut short -- the app went to the background, a
/// sheet came up -- goes back to the front of the line and is shown again from the start.
///
/// Each completion passes through here once (`PowerBaseRemovalCompletions` hands it out once), so
/// nothing is shown twice to its end.
nonisolated struct PowerBaseRemovalNotices: Equatable, Sendable {
    typealias Completion = PowerBaseRemovalCompletions.Completion

    /// Taken in, not shown to the end yet. Oldest first.
    private(set) var waiting: [Completion] = []
    /// On screen now. Oldest first.
    private(set) var shown: [Completion] = []

    mutating func receive(_ completions: [Completion]) {
        for completion in completions where !waiting.contains(completion) && !shown.contains(completion) {
            waiting.append(completion)
        }
    }

    /// The tab is on screen: everything waiting is shown. Returns what is newly on screen.
    mutating func show() -> [Completion] {
        let appearing = waiting
        shown += appearing
        waiting = []
        return appearing
    }

    /// The tab left the screen before the notices' time was up: they wait again, ahead of the rest.
    mutating func interrupt() {
        waiting = shown + waiting
        shown = []
    }

    /// These notices stayed their whole time, or were put away by the user.
    mutating func finish(_ completions: [Completion]) {
        shown.removeAll { completions.contains($0) }
    }
}
