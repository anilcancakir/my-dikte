/// How long the remote link waits before it starts the ssh child again, as a pure value so the
/// back-off is tested without a process or a clock.
///
/// The delay doubles per consecutive failure up to a minute, because a Mac that is asleep or off the
/// network stays that way for a while and a retry per second would only spend battery and log lines.
/// A session that lived `healthySession` resets it: that connection worked, so its loss is a fresh
/// event and the first retry should be quick.
struct ReconnectSchedule: Equatable, Sendable {
    static let delays: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(30),
        .seconds(60),
    ]

    static let healthySession: Duration = .seconds(30)

    private var failures: Int = 0

    /// The wait before the next attempt, given how long the session that just ended had lived.
    mutating func nextDelay(afterSessionLasting lifetime: Duration) -> Duration {
        if lifetime >= Self.healthySession {
            failures = 0
        }

        let delay: Duration = Self.delays[failures]
        failures = min(failures + 1, Self.delays.count - 1)
        return delay
    }
}
