import Foundation

/// Abstracts `Task.sleep` so `LiveSensorDataSource`'s reconnect backoff can be unit tested
/// without a test actually waiting in real time.
nonisolated protocol AsyncSleeping: Sendable {
    func sleep(seconds: Double) async throws
}

nonisolated struct RealAsyncSleeper: AsyncSleeping {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Bounded exponential backoff: 1s, 2s, 4s, 8s, 16s, capped at 30s. Pure function, so its
/// shape — and that it truly is bounded and increasing, never a busy loop of 0s delays —
/// is directly unit testable.
nonisolated enum ReconnectBackoff {
    static func delaySeconds(forAttempt attempt: Int, base: Double = 1, cap: Double = 30) -> Double {
        guard attempt > 0 else { return 0 }
        let exponent = min(attempt - 1, 8) // keeps pow() well away from overflow
        return min(base * pow(2, Double(exponent)), cap)
    }
}
