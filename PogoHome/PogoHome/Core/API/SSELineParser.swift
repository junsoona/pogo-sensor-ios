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
///
/// What it keeps is bounded. The data of an event is released when the event is dispatched (or
/// when a blank line ends an event without data). An event whose data grows beyond
/// `maxEventDataBytes` -- many `data:` lines and no blank line -- is given up: what was kept of
/// it is released at once, the rest of it is not kept, and the blank line that finally ends it
/// dispatches nothing (`droppedEventCount`). A parser belongs to one connection; an event that
/// was not finished when the connection ended is never dispatched.
nonisolated struct SSELineParser {
    let maxEventDataBytes: Int
    /// Events that were given up because their data was larger than `maxEventDataBytes`.
    private(set) var droppedEventCount = 0

    private var eventName: String?
    private var dataLines: [String] = []
    private var dataByteCount = 0
    /// The event under way was given up: its lines are ignored until the blank line that ends it.
    private var isDroppingEvent = false

    init(maxEventDataBytes: Int = SSEStreamLimits.maxEventDataBytes) {
        self.maxEventDataBytes = max(1, maxEventDataBytes)
    }

    /// Bytes of data kept for an event that has not ended yet.
    var bufferedDataByteCount: Int { dataByteCount }

    /// Feed one line (no trailing newline). Returns a parsed event only when a blank line
    /// dispatches one; otherwise returns `nil` and the parser keeps accumulating.
    mutating func consume(line: String) -> SSEParsedEvent? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines = []
                dataByteCount = 0
                isDroppingEvent = false
            }
            // An event that was given up has no data left by now: nothing is dispatched for it.
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
            guard !isDroppingEvent else { break }
            // One byte per line for the "\n" the lines are joined with.
            let added = value.utf8.count + 1
            if dataByteCount + added > maxEventDataBytes {
                isDroppingEvent = true
                droppedEventCount += 1
                dataLines = []
                dataByteCount = 0
                break
            }
            dataLines.append(String(value))
            dataByteCount += added
        default:
            break // id/retry/unknown fields aren't needed by this app.
        }
        return nil
    }
}
