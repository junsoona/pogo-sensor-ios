import Foundation

/// Whether a Power Base that is missing from the hub's list was released by that hub -- judged
/// from what this app has itself seen the hub say, in the order it said it, and from nothing else.
///
/// `AppModel` keeps the last sensors on screen while the hub's list is incomplete (a hub that is
/// starting again lists nothing for a moment). A Base the hub has released must not be kept that
/// way: its sensors are gone for good. The hub says so with a removal job that is `released` or
/// `completed` while the Base is not in `power_bases`. But the same picture appears, for a moment,
/// when a Base was removed, enrolled again, and the hub then starts again while the finished job is
/// still in its list. The two are told apart by the job's history, never by a time: the times on a
/// job and on a snapshot are the hub's clock, which can be set back or corrected, and an allowance
/// in seconds cannot tell "just before" from "enrolled again in between".
///
/// What the hub guarantees (firmware repository, `docs/power-base-management.md` §7 and
/// `docs/pogohome-api-v1.md`):
/// - A job is about one enrollment of a Base and only moves forward.
/// - At `released` the hub takes the Base out of `power_bases`. The job stays listed.
/// - After the Base is enrolled again, a `completed` job stays `completed` in the list for a
///   while, and a `released` one stays `released` until the new enrollment is active.
///
/// So a job that has ended is why its Base is not listed, **unless this app has seen that the job
/// was over before the Base's present place in the list** -- then it is *spent*:
/// - it was seen `completed` while the hub listed the Base (the Base was enrolled again after it), or
/// - it had already ended (`released` or `completed`) when the Base appeared in the hub's list as
///   this app saw it -- on the first snapshot from this hub, or after the Base had not been listed.
///
/// A spent job never counts again, however the lists change afterwards. A job seen `released`
/// while the Base was already listed is not spent: that is a release under way (the hub stores the
/// job's state first and changes its list after), however long the hub takes.
///
/// **With a hub that names registrations** (one that reports `power_base_forgets`: it gives every
/// listed Base a `record`, and every job and list removal the `record` it is about) the question
/// "was it over before the Base's present listing?" is not read from the order of the snapshots
/// at all. It is answered by what the hub says in one snapshot:
/// - the Base is listed under **another** registration than the one the job or list removal is
///   about: that operation is an earlier registration's. Spent.
/// - the Base is listed under the **same** registration, or with no registration at all: this is
///   the Base the operation is about, still in the list -- a list that is behind the hub's
///   records (a hub before `0.4.1` could copy its list of Bases before a removal and read its
///   records after it). **Not** spent: when the list catches up and the Base is gone, that
///   operation is why. (`1.3.0 (13)` spent it, and then kept the sensors of a Base that was
///   removed for good.)
///
/// What this cannot tell from a hub that does not name registrations, and then does not assume
/// (the sensors stay; the job itself is still shown, with its confirmation):
/// - A job first seen already ended together with its Base listed. Usually an earlier removal; it
///   could also be the instant between the hub storing the end of a job and changing its list.
/// - A job seen under way and then `completed` with the Base still listed: the Base was removed
///   and enrolled again unseen, or -- for an instant -- the hub got the receipt before the notice.
///
/// **With a hub that names the Bases that are out of its list** (`power_base_departures`, Linux
/// bridge 0.4.2) none of the above is needed for a Base that is gone: the hub says so itself, in
/// every snapshot, until the Base is registered again -- also when the job that ended the
/// registration is no longer in the hub's list (a finished job is shown for ten minutes; a
/// device that was away longer never sees it). That statement is the hub's present state, so it
/// cannot outlive the fact: there is nothing of it to spend. The rules above stay for hubs that
/// do not say it, and for telling an earlier registration's job from the present one's.
///
/// One value belongs to one source: another hub starts from nothing (`AppModel.clearSourceData`).
nonisolated struct PowerBaseReleaseEvidence: Sendable {
    /// The Bases in the snapshot received last.
    private var listed: Set<String> = []
    /// By Base: the jobs known to have been over before the Base's present listing.
    private var spent: [String: Set<String>] = [:]

    /// Takes in the hub's next snapshot -- every one, also one that is then held back -- and
    /// returns the Bases it shows to be released: not listed, with an ended job that is not spent.
    mutating func observe(_ snapshot: HomeSnapshot) -> Set<String> {
        let nowListed = Set(snapshot.powerBases.map(\.hardwareIdentifier))
        // The registration the hub lists for each Base, where it says.
        let listedRecords = Dictionary(
            snapshot.powerBases.compactMap { base in base.record.map { (base.hardwareIdentifier, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // A hub that can take a Base out of its list names registrations everywhere.
        let namesRegistrations = snapshot.reportsPowerBaseForget
        var released: Set<String> = []
        for removal in snapshot.powerBaseRemovals where removal.state == .released || removal.state == .completed {
            let base = removal.powerBaseIdentifier
            if nowListed.contains(base) {
                if namesRegistrations, let record = removal.record {
                    // Spent exactly when the Base is listed under another registration.
                    if let listed = listedRecords[base], listed != record { spent[base, default: []].insert(removal.id) }
                } else if removal.state == .completed || !listed.contains(base) {
                    spent[base, default: []].insert(removal.id)
                }
            } else if spent[base]?.contains(removal.id) != true {
                released.insert(base)
            }
        }
        // A Base the hub took out of its list ("허브 목록에서 제거") is gone in the same way, and
        // its record is kept in the hub's list for a while like a finished job. It names the
        // registration it took out: it is about an earlier registration, and never counts again,
        // exactly when the Base is listed under another one.
        for forget in snapshot.powerBaseForgets {
            let base = forget.powerBaseIdentifier
            if nowListed.contains(base) {
                if let listed = listedRecords[base], listed != forget.record { spent[base, default: []].insert(forget.id) }
            } else if spent[base]?.contains(forget.id) != true {
                released.insert(base)
            }
        }
        // A Base the hub names as out of its list (`power_base_departures`) is not listed because
        // its registration ended and it was not registered again. This is not a record that
        // lingers after the fact: the hub names the Base for exactly as long as that is so, and
        // stops with the next registration. So nothing is remembered and nothing is spent here --
        // every snapshot says it anew, and the one that lists the Base again does not say it.
        // A Base that is listed in this very snapshot is listed, whatever else the snapshot says.
        for departure in snapshot.powerBaseDepartures where !nowListed.contains(departure.powerBaseIdentifier) {
            released.insert(departure.powerBaseIdentifier)
        }
        listed = nowListed
        return released
    }
}
