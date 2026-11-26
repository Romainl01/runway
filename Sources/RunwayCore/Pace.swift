import Foundation

public enum PaceProjection: Equatable, Sendable {
    /// 100 % is reached before the reset.
    case hitsLimit(at: Date, beforeReset: TimeInterval)
    /// Projected percent at reset time (< 100).
    case reachesAtReset(percent: Double)
}

public enum Pace {
    public static let sessionWindow: TimeInterval = 5 * 3600
    public static let minimumElapsed: TimeInterval = 15 * 60
    public static let minimumPercent: Double = 5

    /// Linear projection of the session usage.
    /// Window start = resetsAt − 5 h; rate = percent / elapsed minutes.
    /// Returns nil when less than 15 min elapsed, less than 5 % used, or already at 100 %.
    public static func project(percent: Double, resetsAt: Date, now: Date,
                               window: TimeInterval = sessionWindow) -> PaceProjection? {
        let start = resetsAt.addingTimeInterval(-window)
        let elapsedMinutes = now.timeIntervalSince(start) / 60
        let remainingMinutes = resetsAt.timeIntervalSince(now) / 60
        guard elapsedMinutes * 60 >= minimumElapsed,
              percent >= minimumPercent,
              percent < 100,
              remainingMinutes > 0
        else { return nil }

        let ratePerMinute = percent / elapsedMinutes
        let projected = percent + ratePerMinute * remainingMinutes
        if projected >= 100 {
            let minutesToWall = (100 - percent) / ratePerMinute
            let hitAt = now.addingTimeInterval(minutesToWall * 60)
            return .hitsLimit(at: hitAt, beforeReset: resetsAt.timeIntervalSince(hitAt))
        }
        return .reachesAtReset(percent: projected)
    }
}
