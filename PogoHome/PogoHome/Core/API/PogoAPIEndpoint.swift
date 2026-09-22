import Foundation

/// The Linux PogoHome API's base URL plus the fixed paths this app talks to.
nonisolated struct PogoAPIEndpoint: Hashable, Sendable {
    let baseURL: URL

    var snapshotURL: URL { baseURL.appendingPathComponent("api/v1/snapshot") }
    var eventsURL: URL { baseURL.appendingPathComponent("api/v1/events") }
    var healthURL: URL { baseURL.appendingPathComponent("api/v1/health") }
}

extension PogoAPIEndpoint {
    static let defaultBaseURLString = "http://192.168.50.129:8787"
}
