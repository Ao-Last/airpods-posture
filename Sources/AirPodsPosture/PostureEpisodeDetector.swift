import Foundation

public enum PostureEpisodePhase: String, Equatable, Sendable {
    case entered
    case sustained
    case recovered
    case exited
}

public struct PostureEpisodeEvent: Equatable, Sendable {
    public var posture: PostureKind
    public var phase: PostureEpisodePhase
    public var timestamp: TimeInterval
    public var startedAt: TimeInterval
    public var endedAt: TimeInterval?
    public var duration: TimeInterval
    public var averageConfidence: Double
    public var peakOffsetDegrees: Double
    public var debugSummary: String

    public init(
        posture: PostureKind,
        phase: PostureEpisodePhase,
        timestamp: TimeInterval,
        startedAt: TimeInterval,
        endedAt: TimeInterval?,
        duration: TimeInterval,
        averageConfidence: Double,
        peakOffsetDegrees: Double,
        debugSummary: String
    ) {
        self.posture = posture
        self.phase = phase
        self.timestamp = timestamp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.averageConfidence = averageConfidence
        self.peakOffsetDegrees = peakOffsetDegrees
        self.debugSummary = debugSummary
    }
}

public struct PostureEpisodeDetectorConfiguration: Equatable, Sendable {
    public var minimumSustainedDuration: TimeInterval
    public var recoveryDuration: TimeInterval
    public var minimumConfidence: Double

    public init(
        minimumSustainedDuration: TimeInterval = 15,
        recoveryDuration: TimeInterval = 1.2,
        minimumConfidence: Double = 0.68
    ) {
        self.minimumSustainedDuration = max(0, minimumSustainedDuration)
        self.recoveryDuration = max(0, recoveryDuration)
        self.minimumConfidence = clamp(minimumConfidence, lower: 0, upper: 1)
    }
}

public final class PostureEpisodeDetector {
    public var configuration: PostureEpisodeDetectorConfiguration

    private var activeEpisode: ActivePostureEpisode?

    public init(configuration: PostureEpisodeDetectorConfiguration = PostureEpisodeDetectorConfiguration()) {
        self.configuration = configuration
    }

    public func reset() {
        activeEpisode = nil
    }

    public func observe(_ snapshot: PostureSnapshot) -> [PostureEpisodeEvent] {
        if snapshot.kind == .neutral {
            return observeNeutral(snapshot)
        }

        guard snapshot.confidence >= configuration.minimumConfidence else {
            return observeNeutral(snapshot)
        }

        guard var activeEpisode else {
            let episode = ActivePostureEpisode(snapshot: snapshot)
            activeEpisode = episode
            return [episode.event(phase: .entered, timestamp: snapshot.timestamp)]
        }

        if activeEpisode.posture != snapshot.kind {
            let exited = activeEpisode.event(
                phase: .exited,
                timestamp: snapshot.timestamp,
                endedAt: snapshot.timestamp
            )
            let nextEpisode = ActivePostureEpisode(snapshot: snapshot)
            self.activeEpisode = nextEpisode
            return [
                exited,
                nextEpisode.event(phase: .entered, timestamp: snapshot.timestamp)
            ]
        }

        activeEpisode.recoveryStartedAt = nil
        activeEpisode.observe(snapshot)

        var events: [PostureEpisodeEvent] = []
        if !activeEpisode.hasEmittedSustained,
           activeEpisode.duration(at: snapshot.timestamp) >= configuration.minimumSustainedDuration {
            activeEpisode.hasEmittedSustained = true
            events.append(activeEpisode.event(phase: .sustained, timestamp: snapshot.timestamp))
        }

        self.activeEpisode = activeEpisode
        return events
    }

    private func observeNeutral(_ snapshot: PostureSnapshot) -> [PostureEpisodeEvent] {
        guard var activeEpisode else {
            return []
        }

        if activeEpisode.recoveryStartedAt == nil {
            activeEpisode.recoveryStartedAt = snapshot.timestamp
        }

        guard let recoveryStartedAt = activeEpisode.recoveryStartedAt,
              snapshot.timestamp - recoveryStartedAt >= configuration.recoveryDuration else {
            self.activeEpisode = activeEpisode
            return []
        }

        let recovered = activeEpisode.event(
            phase: .recovered,
            timestamp: snapshot.timestamp,
            endedAt: recoveryStartedAt
        )
        self.activeEpisode = nil
        return [recovered]
    }
}

private struct ActivePostureEpisode {
    var posture: PostureKind
    var startedAt: TimeInterval
    var lastTimestamp: TimeInterval
    var peakOffsetDegrees: Double
    var confidenceTotal: Double
    var sampleCount: Int
    var hasEmittedSustained = false
    var recoveryStartedAt: TimeInterval?

    init(snapshot: PostureSnapshot) {
        posture = snapshot.kind
        startedAt = snapshot.timestamp
        lastTimestamp = snapshot.timestamp
        peakOffsetDegrees = snapshot.offsetDegrees
        confidenceTotal = snapshot.confidence
        sampleCount = 1
    }

    mutating func observe(_ snapshot: PostureSnapshot) {
        lastTimestamp = snapshot.timestamp
        peakOffsetDegrees = max(peakOffsetDegrees, snapshot.offsetDegrees)
        confidenceTotal += snapshot.confidence
        sampleCount += 1
    }

    func duration(at timestamp: TimeInterval) -> TimeInterval {
        max(0, timestamp - startedAt)
    }

    var averageConfidence: Double {
        confidenceTotal / Double(max(1, sampleCount))
    }

    func event(
        phase: PostureEpisodePhase,
        timestamp: TimeInterval,
        endedAt: TimeInterval? = nil
    ) -> PostureEpisodeEvent {
        let duration = max(0, (endedAt ?? timestamp) - startedAt)
        let debugSummary = "\(posture.label) \(phase.rawValue) after \(format(duration))s"
        return PostureEpisodeEvent(
            posture: posture,
            phase: phase,
            timestamp: timestamp,
            startedAt: startedAt,
            endedAt: endedAt,
            duration: duration,
            averageConfidence: averageConfidence,
            peakOffsetDegrees: peakOffsetDegrees,
            debugSummary: debugSummary
        )
    }
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}
