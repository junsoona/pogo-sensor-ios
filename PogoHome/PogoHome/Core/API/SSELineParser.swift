import Foundation

/// One dispatched Server-Sent Event: an optional `event:` name and the (possibly
/// multi-line) `data:` payload.
struct SSEParsedEvent: Hashable, Sendable {
    let event: String?
    let data: String
}

/// Incremental, line-based SSE parser per the WHATWG spec's "event stream interpretation":
/// fields accumulate until a blank line dispatches the event, `:`-prefixed lines are
/// comments (the API's heartbeats) and are silently ignored, and unknown fields are
/// ignored rather than treated as errors. Pure and synchronous so it's testable without
/// any networking — feed it lines, get back parsed events.
nonisolated struct SSELineParser {
    private var eventName: String?
    private var dataLines: [String] = []

    init() {}

    /// Feed one line (no trailing newline). Returns a parsed event only when a blank line
    /// dispatches one; otherwise returns `nil` and the parser keeps accumulating.
    mutating func consume(line: String) -> SSEParsedEvent? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return SSEParsedEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        }

        if line.hasPrefix(":") {
            // Comment line — this is how the API's heartbeats show up. Not an event.
            return nil
        }

        let field: Substring
        var value: Substring
        if let colonIndex = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colonIndex]
            value = line[line.index(after: colonIndex)...]
            if value.first == " " {
                value.removeFirst()
            }
        } else {
            field = line[...]
            value = ""
        }

        switch field {
        case "event":
            eventName = String(value)
        case "data":
            dataLines.append(String(value))
        default:
            break // id/retry/unknown fields aren't needed by this app.
        }
        return nil
    }
}
