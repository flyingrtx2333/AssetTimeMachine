import Foundation

nonisolated enum FedPolicyDirection001Logic {
    enum State: String { case easing, tightening }
    struct Event { let dateKey: String; let state: State }

    static func state(executionDateKey: String, events: [Event]) -> State? {
        var latest: State? = nil
        for event in events {
            guard event.dateKey < executionDateKey else { break }
            latest = event.state
        }
        return latest
    }
}
