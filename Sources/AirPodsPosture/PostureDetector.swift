import Foundation

public struct PostureDetectorConfiguration: Equatable, Sendable {
    public var verticalAxis: PostureAxis
    public var headDownSign: Double
    public var turnAxis: PostureAxis
    public var turnedLeftSign: Double
    public var tiltAxis: PostureAxis
    public var tiltedLeftSign: Double
    public var verticalThreshold: Double
    public var turnThreshold: Double
    public var tiltThreshold: Double
    public var neutralThreshold: Double
    public var enterHoldDuration: TimeInterval
    public var neutralHoldDuration: TimeInterval

    public init(
        verticalAxis: PostureAxis = .roll,
        headDownSign: Double = -1,
        turnAxis: PostureAxis = .yaw,
        turnedLeftSign: Double = -1,
        tiltAxis: PostureAxis = .pitch,
        tiltedLeftSign: Double = -1,
        verticalThreshold: Double = 15,
        turnThreshold: Double = 18,
        tiltThreshold: Double = 14,
        neutralThreshold: Double = 6,
        enterHoldDuration: TimeInterval = 0.55,
        neutralHoldDuration: TimeInterval = 0.32
    ) {
        self.verticalAxis = verticalAxis
        self.headDownSign = Self.normalizedSign(headDownSign)
        self.turnAxis = turnAxis
        self.turnedLeftSign = Self.normalizedSign(turnedLeftSign)
        self.tiltAxis = tiltAxis
        self.tiltedLeftSign = Self.normalizedSign(tiltedLeftSign)
        self.verticalThreshold = verticalThreshold
        self.turnThreshold = turnThreshold
        self.tiltThreshold = tiltThreshold
        self.neutralThreshold = neutralThreshold
        self.enterHoldDuration = enterHoldDuration
        self.neutralHoldDuration = neutralHoldDuration
    }

    private static func normalizedSign(_ sign: Double) -> Double {
        sign < 0 ? -1 : 1
    }
}

public struct PostureSnapshot: Equatable, Sendable {
    public var kind: PostureKind
    public var confidence: Double
    public var offsetDegrees: Double
    public var heldDuration: TimeInterval
    public var timestamp: TimeInterval
    public var debugSummary: String

    public init(
        kind: PostureKind,
        confidence: Double,
        offsetDegrees: Double,
        heldDuration: TimeInterval,
        timestamp: TimeInterval,
        debugSummary: String
    ) {
        self.kind = kind
        self.confidence = confidence
        self.offsetDegrees = offsetDegrees
        self.heldDuration = heldDuration
        self.timestamp = timestamp
        self.debugSummary = debugSummary
    }
}

public final class PostureDetector {
    public var configuration: PostureDetectorConfiguration

    private var hasObservedSample = false
    private var currentKind: PostureKind = .neutral
    private var currentStartedAt: TimeInterval = 0
    private var candidateKind: PostureKind = .neutral
    private var candidateStartedAt: TimeInterval = 0

    public init(configuration: PostureDetectorConfiguration = PostureDetectorConfiguration()) {
        self.configuration = configuration
    }

    public func reset() {
        hasObservedSample = false
        currentKind = .neutral
        currentStartedAt = 0
        candidateKind = .neutral
        candidateStartedAt = 0
    }

    public func observe(_ sample: PostureSample) -> PostureSnapshot {
        let instant = classify(sample)

        guard hasObservedSample else {
            hasObservedSample = true
            currentKind = .neutral
            currentStartedAt = sample.timestamp
            candidateKind = instant.kind
            candidateStartedAt = sample.timestamp
            return snapshot(kind: currentKind, sample: sample)
        }

        if instant.kind != candidateKind {
            candidateKind = instant.kind
            candidateStartedAt = sample.timestamp
        }

        let requiredHold = instant.kind == .neutral
            ? configuration.neutralHoldDuration
            : configuration.enterHoldDuration
        if currentKind != instant.kind, sample.timestamp - candidateStartedAt >= requiredHold {
            currentKind = instant.kind
            currentStartedAt = candidateStartedAt
        }

        return snapshot(kind: currentKind, sample: sample)
    }

    private func classify(_ sample: PostureSample) -> InstantPosture {
        let vertical = sample.value(on: configuration.verticalAxis) * configuration.headDownSign
        let turn = sample.value(on: configuration.turnAxis) * configuration.turnedLeftSign
        let tilt = sample.value(on: configuration.tiltAxis) * configuration.tiltedLeftSign

        let options = [
            postureOption(
                positiveKind: .headDown,
                negativeKind: .headUp,
                signedValue: vertical,
                threshold: configuration.verticalThreshold
            ),
            postureOption(
                positiveKind: .turnedLeft,
                negativeKind: .turnedRight,
                signedValue: turn,
                threshold: configuration.turnThreshold
            ),
            postureOption(
                positiveKind: .tiltedLeft,
                negativeKind: .tiltedRight,
                signedValue: tilt,
                threshold: configuration.tiltThreshold
            )
        ]

        guard let best = options.max(by: { $0.score < $1.score }),
              best.score >= 1 else {
            return InstantPosture(
                kind: .neutral,
                offsetDegrees: max(abs(vertical), abs(turn), abs(tilt)),
                threshold: configuration.neutralThreshold
            )
        }

        return best
    }

    private func postureOption(
        positiveKind: PostureKind,
        negativeKind: PostureKind,
        signedValue: Double,
        threshold: Double
    ) -> InstantPosture {
        let offset = abs(signedValue)
        return InstantPosture(
            kind: signedValue >= 0 ? positiveKind : negativeKind,
            offsetDegrees: offset,
            threshold: threshold
        )
    }

    private func snapshot(kind: PostureKind, sample: PostureSample) -> PostureSnapshot {
        let measurement = measurement(for: kind, sample: sample)
        let held = max(0, sample.timestamp - currentStartedAt)
        let confidence = confidence(kind: kind, offset: measurement.offset, threshold: measurement.threshold)
        let debugSummary: String

        if kind == .neutral {
            debugSummary = "neutral max offset \(format(measurement.offset)) deg"
        } else {
            debugSummary = "\(kind.label) on \(measurement.axis.label) \(format(measurement.signedValue)) deg"
        }

        return PostureSnapshot(
            kind: kind,
            confidence: confidence,
            offsetDegrees: measurement.offset,
            heldDuration: held,
            timestamp: sample.timestamp,
            debugSummary: debugSummary
        )
    }

    private func measurement(
        for kind: PostureKind,
        sample: PostureSample
    ) -> (axis: PostureAxis, signedValue: Double, offset: Double, threshold: Double) {
        switch kind {
        case .neutral:
            let vertical = sample.value(on: configuration.verticalAxis)
            let turn = sample.value(on: configuration.turnAxis)
            let tilt = sample.value(on: configuration.tiltAxis)
            let offset = max(abs(vertical), abs(turn), abs(tilt))
            return (configuration.verticalAxis, offset, offset, configuration.neutralThreshold)
        case .headDown, .headUp:
            let signed = sample.value(on: configuration.verticalAxis)
            return (configuration.verticalAxis, signed, abs(signed), configuration.verticalThreshold)
        case .turnedLeft, .turnedRight:
            let signed = sample.value(on: configuration.turnAxis)
            return (configuration.turnAxis, signed, abs(signed), configuration.turnThreshold)
        case .tiltedLeft, .tiltedRight:
            let signed = sample.value(on: configuration.tiltAxis)
            return (configuration.tiltAxis, signed, abs(signed), configuration.tiltThreshold)
        }
    }

    private func confidence(kind: PostureKind, offset: Double, threshold: Double) -> Double {
        if kind == .neutral {
            let neutrality = 1 - clamp(offset / max(threshold, 0.1), lower: 0, upper: 1)
            return 0.62 + neutrality * 0.34
        }

        let overThreshold = (offset - threshold) / max(threshold, 0.1)
        return clamp(0.58 + overThreshold * 0.75, lower: 0.58, upper: 0.99)
    }
}

private struct InstantPosture {
    var kind: PostureKind
    var offsetDegrees: Double
    var threshold: Double

    var score: Double {
        offsetDegrees / max(threshold, 0.1)
    }
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}
