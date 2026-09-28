import Foundation

/// What PogoHome knows about an accessory's *values* — kept apart from whether HomeKit lists the
/// accessory as responding (`isOperable`, the Dashboard's "responding" count). A responding
/// accessory can still have a value read that timed out, and the reverse.
nonisolated enum AppleHomeValueStatus: Hashable, Sendable {
    /// Nothing PogoHome shows on it can be read: no value is expected, and none is missing.
    case nothingToRead
    /// The automatic read is queued or running and hasn't failed yet.
    case checking
    /// An automatic read failed with a transient error; `attempt` of `maxAttempts` is queued or
    /// running. Not yet a failure to report, not a value either.
    case retrying(attempt: Int, maxAttempts: Int)
    /// The last read failed and no automatic retry is left (message from the provider).
    case failed(String)
    /// The newest value PogoHome read or was notified of in this session.
    case checked(Date)
    /// No value read yet and no automatic read pending (e.g. the accessory doesn't respond).
    case notChecked

    static func resolve(_ accessory: AppleHomeAccessory) -> AppleHomeValueStatus {
        guard accessory.hasReadableValues else { return .nothingToRead }
        if let autoRead = accessory.autoRead {
            return autoRead.isRetry ? .retrying(attempt: autoRead.attempt, maxAttempts: autoRead.maxAttempts) : .checking
        }
        if let error = accessory.lastReadError { return .failed(error) }
        if let checkedAt = accessory.lastCheckedAt { return .checked(checkedAt) }
        return .notChecked
    }

    /// An automatic read is queued or running.
    var isPending: Bool {
        switch self {
        case .checking, .retrying: return true
        case .nothingToRead, .failed, .checked, .notChecked: return false
        }
    }
}

/// Why a listed accessory is counted on the Dashboard's Apple Home card — at most one reason
/// per accessory, so the card's numbers and the list behind it (`AppleHomeIssueList`) always
/// add up to the same accessories.
nonisolated enum AppleHomeIssueReason: Hashable, Sendable {
    /// HomeKit lists it as not responding, or has blocked it (`isOperable == false`). Its values
    /// aren't read while this lasts, so no read failure is counted for it.
    case notResponding(isBlocked: Bool)
    /// It responds, but the last value read failed and no automatic retry is left.
    case readFailed(String)
    /// It responds; a read failed with a transient error and is being retried automatically.
    case retrying(attempt: Int, maxAttempts: Int)
    /// It responds; the first automatic read is queued or running.
    case checking

    /// The card's lines and the list's sections, in the order both show them.
    enum Category: Int, CaseIterable, Hashable, Sendable {
        case notResponding
        case readFailed
        case retrying
        case checking
    }

    var category: Category {
        switch self {
        case .notResponding: return .notResponding
        case .readFailed: return .readFailed
        case .retrying: return .retrying
        case .checking: return .checking
        }
    }

    /// `nil` for an accessory that responds and has nothing pending or failed.
    static func resolve(_ accessory: AppleHomeAccessory) -> AppleHomeIssueReason? {
        guard accessory.isOperable else { return .notResponding(isBlocked: accessory.isBlocked) }
        switch AppleHomeValueStatus.resolve(accessory) {
        case let .failed(message): return .readFailed(message)
        case let .retrying(attempt, maxAttempts): return .retrying(attempt: attempt, maxAttempts: maxAttempts)
        case .checking: return .checking
        case .nothingToRead, .checked, .notChecked: return nil
        }
    }
}

nonisolated struct AppleHomeIssue: Identifiable, Hashable, Sendable {
    let accessory: AppleHomeAccessory
    let reason: AppleHomeIssueReason

    var id: UUID { accessory.id }
}

/// Every listed accessory with an `AppleHomeIssueReason`, in the order given (the layout's
/// home → room → name order). The Dashboard card counts exactly these.
nonisolated struct AppleHomeIssueList: Hashable, Sendable {
    let issues: [AppleHomeIssue]

    static func evaluate(_ accessories: [AppleHomeAccessory]) -> AppleHomeIssueList {
        AppleHomeIssueList(issues: accessories.compactMap { accessory in
            AppleHomeIssueReason.resolve(accessory).map { AppleHomeIssue(accessory: accessory, reason: $0) }
        })
    }

    var isEmpty: Bool { issues.isEmpty }

    func issues(in category: AppleHomeIssueReason.Category) -> [AppleHomeIssue] {
        issues.filter { $0.reason.category == category }
    }

    func count(_ category: AppleHomeIssueReason.Category) -> Int {
        issues(in: category).count
    }
}

/// Value reads across the listed accessories, for the Dashboard's Apple Home card. Counts only
/// accessories HomeKit lists as responding: one that doesn't respond is already counted there.
nonisolated struct AppleHomeValueCheckSummary: Hashable, Sendable {
    /// First automatic read queued or running.
    let checking: Int
    /// Automatic read being retried after a transient failure.
    let retrying: Int
    /// Last read failed, no retry left.
    let failed: Int

    init(checking: Int, retrying: Int = 0, failed: Int) {
        self.checking = checking
        self.retrying = retrying
        self.failed = failed
    }

    static func evaluate(_ accessories: [AppleHomeAccessory]) -> AppleHomeValueCheckSummary {
        evaluate(AppleHomeIssueList.evaluate(accessories))
    }

    static func evaluate(_ issues: AppleHomeIssueList) -> AppleHomeValueCheckSummary {
        AppleHomeValueCheckSummary(
            checking: issues.count(.checking),
            retrying: issues.count(.retrying),
            failed: issues.count(.readFailed)
        )
    }
}
