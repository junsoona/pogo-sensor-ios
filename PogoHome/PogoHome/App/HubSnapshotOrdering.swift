import Foundation

/// Hands out ordinals to this app's snapshot requests: a request that was started later has a
/// larger one. Only for telling which of two requests was started first -- never a time, never
/// compared with anything the hub says.
enum SnapshotRequestClock {
    private static var last: UInt64 = 0

    /// A new ordinal, for a request that starts now.
    static func next() -> UInt64 {
        last += 1
        return last
    }

    /// The largest ordinal handed out so far: every request that starts from now on has a larger one.
    static var now: UInt64 { last }
}

/// Keeps an older snapshot from being applied after a newer one.
///
/// The app gets the hub's state in two ways at once -- answers to `GET /api/v1/snapshot` (when it
/// connects, and every few seconds) and events on `GET /api/v1/events` -- over separate
/// connections, so what arrives later is not always what the hub said later. An answer that was
/// on its way while the hub removed a Base and somebody registered it again, applied after the
/// event that showed the new registration, took the screen back: the new registration's Base was
/// judged removed until the next snapshot (firmware repository, docs/power-base-management.md,
/// section 16).
///
/// **Within one run of the hub** the order is the hub's own word (`HubSnapshotOrder`): it numbers
/// its snapshots as it makes them, one at a time, `GET` answers and events alike. A snapshot
/// whose number is not larger than the largest one applied is older (or the same) and is not
/// applied. No clock is compared -- not the hub's, which can be set back, and not this device's.
///
/// **Across a restart of the hub** the numbers start again under another stream id, and they say
/// nothing about each other. What is known then is causal: a request this app **started after**
/// it first saw the present stream can only have been answered by that run of the hub or a later
/// one -- the earlier runs had ended before. So a snapshot of another stream is taken as the new
/// present stream when its request was started after the present one was first seen, and is not
/// applied when its request was started before (it may be an earlier run's answer that arrives
/// late). That can drop a snapshot that was in fact newer; it can never lock the app out: the
/// next request is a later one. (A snapshot that came from no request of this app -- a test's,
/// simulated data -- has no ordinal and is taken as it comes.)
///
/// **A hub that does not say where its snapshots stand** (Linux bridge 0.4.2 and earlier) is
/// followed as before: every snapshot is applied in the order it arrives. There is nothing to
/// decide from, and nothing is guessed from a time.
///
/// One value belongs to one source: another hub starts from nothing (`AppModel.clearSourceData`).
nonisolated struct HubSnapshotOrdering: Sendable {
    /// The stream of the run of the hub this app is following; `nil` before any snapshot said one.
    private(set) var stream: String?
    /// The largest sequence applied of that stream.
    private(set) var highestSequence: Int64 = 0
    /// `SnapshotRequestClock.now` when `stream` was first seen.
    private var streamSeenAt: UInt64 = 0

    /// Whether a snapshot that arrived this way is to be applied; taking it in when it is.
    /// `now`: `SnapshotRequestClock.now` at this moment.
    mutating func admits(_ delivery: SnapshotDelivery, now: UInt64) -> Bool {
        guard let order = delivery.hubOrder else { return true }
        if order.stream == stream {
            guard order.sequence > highestSequence else { return false }
            highestSequence = order.sequence
            return true
        }
        // Another run of the hub than the one followed so far.
        if stream != nil, let asked = delivery.requestOrdinal, asked <= streamSeenAt {
            // Asked for before the present run was first seen: possibly an earlier run's answer.
            return false
        }
        stream = order.stream
        highestSequence = order.sequence
        streamSeenAt = now
        return true
    }
}
