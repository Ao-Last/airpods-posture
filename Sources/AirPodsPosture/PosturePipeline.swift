import Foundation

public struct HeadMotionFrame: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var quaternion: HeadsetQuaternion
    public var rotationRateDegreesPerSecond: MotionVector
    public var userAcceleration: MotionVector

    public init(
        timestamp: TimeInterval,
        quaternion: HeadsetQuaternion,
        rotationRateDegreesPerSecond: MotionVector = .zero,
        userAcceleration: MotionVector = .zero
    ) {
        self.timestamp = timestamp
        self.quaternion = quaternion
        self.rotationRateDegreesPerSecond = rotationRateDegreesPerSecond
        self.userAcceleration = userAcceleration
    }
}

public enum MotionSignalState: String, Sendable {
    case stable
    case recovering
    case gap
    case spike
}

public struct MotionSignalQuality: Equatable, Sendable {
    public var state: MotionSignalState
    public var label: String
    public var debugSummary: String
    public var statusText: String
    public var shouldSurface: Bool

    public init(
        state: MotionSignalState,
        label: String,
        debugSummary: String,
        statusText: String,
        shouldSurface: Bool
    ) {
        self.state = state
        self.label = label
        self.debugSummary = debugSummary
        self.statusText = statusText
        self.shouldSurface = shouldSurface
    }

    public static let stable = MotionSignalQuality(
        state: .stable,
        label: "signal: stable",
        debugSummary: "signal stable",
        statusText: "Ready.",
        shouldSurface: false
    )

    public static let recovering = MotionSignalQuality(
        state: .recovering,
        label: "signal: recovering",
        debugSummary: "recovering after signal gap",
        statusText: "Recovering after signal gap.",
        shouldSurface: false
    )

    public static func gap(_ duration: TimeInterval) -> MotionSignalQuality {
        MotionSignalQuality(
            state: .gap,
            label: "signal: gap \(format(duration * 1_000)) ms",
            debugSummary: "signal gap \(format(duration * 1_000)) ms; recognition windows reset",
            statusText: "Signal gap detected. Recognition windows reset.",
            shouldSurface: true
        )
    }

    public static func spike(_ degrees: Double) -> MotionSignalQuality {
        MotionSignalQuality(
            state: .spike,
            label: "signal: spike dropped",
            debugSummary: "dropped motion spike \(format(degrees)) deg",
            statusText: "Motion spike dropped.",
            shouldSurface: true
        )
    }
}

public enum MotionSignalObservation: Equatable, Sendable {
    case accepted(PostureSample, MotionSignalQuality)
    case reset(PostureSample, MotionSignalQuality)
    case dropped(PostureSample, MotionSignalQuality)

    public var quality: MotionSignalQuality {
        switch self {
        case .accepted(_, let quality),
             .reset(_, let quality),
             .dropped(_, let quality):
            quality
        }
    }

    public var sample: PostureSample {
        switch self {
        case .accepted(let sample, _),
             .reset(let sample, _),
             .dropped(let sample, _):
            sample
        }
    }
}

public struct MotionSignalGuardConfiguration: Equatable, Sendable {
    public var gapThreshold: TimeInterval
    public var recoveryDuration: TimeInterval
    public var minimumJumpLimit: Double
    public var maximumJumpLimit: Double
    public var jumpVelocityLimit: Double
    public var filterTimeConstant: TimeInterval

    public init(
        gapThreshold: TimeInterval = 0.18,
        recoveryDuration: TimeInterval = 0.35,
        minimumJumpLimit: Double = 38,
        maximumJumpLimit: Double = 95,
        jumpVelocityLimit: Double = 720,
        filterTimeConstant: TimeInterval = 0.035
    ) {
        self.gapThreshold = gapThreshold
        self.recoveryDuration = recoveryDuration
        self.minimumJumpLimit = minimumJumpLimit
        self.maximumJumpLimit = maximumJumpLimit
        self.jumpVelocityLimit = jumpVelocityLimit
        self.filterTimeConstant = filterTimeConstant
    }
}

public struct MotionSignalGuard: Sendable {
    public var configuration: MotionSignalGuardConfiguration

    private var previousRawSample: PostureSample?
    private var previousFilteredSample: PostureSample?
    private var recoveringUntil: TimeInterval = -.infinity

    public init(configuration: MotionSignalGuardConfiguration = MotionSignalGuardConfiguration()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        previousRawSample = nil
        previousFilteredSample = nil
        recoveringUntil = -.infinity
    }

    public mutating func observe(_ sample: PostureSample) -> MotionSignalObservation {
        guard let previousRawSample else {
            self.previousRawSample = sample
            previousFilteredSample = sample
            return .accepted(sample, .stable)
        }

        let deltaTime = sample.timestamp - previousRawSample.timestamp
        guard deltaTime > 0 else {
            return .dropped(sample, .spike(0))
        }

        if deltaTime >= configuration.gapThreshold {
            self.previousRawSample = sample
            previousFilteredSample = sample
            recoveringUntil = sample.timestamp + configuration.recoveryDuration
            return .reset(sample, .gap(deltaTime))
        }

        let jumpDegrees = maximumAxisDelta(from: previousRawSample, to: sample)
        let jumpLimit = min(
            configuration.maximumJumpLimit,
            max(configuration.minimumJumpLimit, configuration.jumpVelocityLimit * deltaTime)
        )
        if jumpDegrees > jumpLimit {
            recoveringUntil = sample.timestamp + configuration.recoveryDuration
            return .dropped(sample, .spike(jumpDegrees))
        }

        self.previousRawSample = sample

        let filteredSample: PostureSample
        if let previousFilteredSample {
            let alpha = clamp(
                deltaTime / (deltaTime + configuration.filterTimeConstant),
                lower: 0.25,
                upper: 0.72
            )
            filteredSample = lowPass(previous: previousFilteredSample, next: sample, alpha: alpha)
        } else {
            filteredSample = sample
        }
        previousFilteredSample = filteredSample

        let quality: MotionSignalQuality = sample.timestamp < recoveringUntil ? .recovering : .stable
        return .accepted(filteredSample, quality)
    }

    private func maximumAxisDelta(from previous: PostureSample, to next: PostureSample) -> Double {
        max(
            abs(next.yaw - previous.yaw),
            abs(next.pitch - previous.pitch),
            abs(next.roll - previous.roll)
        )
    }

    private func lowPass(previous: PostureSample, next: PostureSample, alpha: Double) -> PostureSample {
        PostureSample(
            timestamp: next.timestamp,
            yaw: previous.yaw + (next.yaw - previous.yaw) * alpha,
            pitch: previous.pitch + (next.pitch - previous.pitch) * alpha,
            roll: previous.roll + (next.roll - previous.roll) * alpha,
            rotationRateDegreesPerSecond: previous.rotationRateDegreesPerSecond.interpolated(
                toward: next.rotationRateDegreesPerSecond,
                alpha: alpha
            ),
            userAcceleration: previous.userAcceleration.interpolated(
                toward: next.userAcceleration,
                alpha: alpha
            )
        )
    }
}

public struct AirPodsPosturePipelineConfiguration: Equatable, Sendable {
    public var requiredCalibrationSamples: Int
    public var signalGuard: MotionSignalGuardConfiguration
    public var postureDetector: PostureDetectorConfiguration
    public var postureEpisodeDetector: PostureEpisodeDetectorConfiguration
    public var gestureRecognizer: RecognizerConfiguration

    public init(
        requiredCalibrationSamples: Int = 32,
        signalGuard: MotionSignalGuardConfiguration = MotionSignalGuardConfiguration(),
        postureDetector: PostureDetectorConfiguration = PostureDetectorConfiguration(),
        postureEpisodeDetector: PostureEpisodeDetectorConfiguration = PostureEpisodeDetectorConfiguration(),
        gestureRecognizer: RecognizerConfiguration = RecognizerConfiguration()
    ) {
        self.requiredCalibrationSamples = max(1, requiredCalibrationSamples)
        self.signalGuard = signalGuard
        self.postureDetector = postureDetector
        self.postureEpisodeDetector = postureEpisodeDetector
        self.gestureRecognizer = gestureRecognizer
    }
}

public enum AirPodsPosturePipelineOutput: Equatable, Sendable {
    case calibrating(progress: Double, timestamp: TimeInterval)
    case calibrated(timestamp: TimeInterval)
    case accepted(
        sample: PostureSample,
        posture: PostureSnapshot,
        gesture: GestureEvent?,
        episodeEvents: [PostureEpisodeEvent],
        signalQuality: MotionSignalQuality
    )
    case reset(sample: PostureSample, signalQuality: MotionSignalQuality)
    case dropped(sample: PostureSample, signalQuality: MotionSignalQuality)
}

public struct GestureLearningResult: Equatable, Sendable {
    public var configuration: RecognizerConfiguration
    public var summary: String

    public init(configuration: RecognizerConfiguration, summary: String) {
        self.configuration = configuration
        self.summary = summary
    }
}

public final class AirPodsPosturePipeline: @unchecked Sendable {
    private let calibration = MotionCalibration()
    private var calibrationFrames: [HeadsetQuaternion] = []
    private var signalGuard: MotionSignalGuard
    private let postureDetector: PostureDetector
    private let postureEpisodeDetector: PostureEpisodeDetector
    private let gestureRecognizer: PostureGestureRecognizer

    public var configuration: AirPodsPosturePipelineConfiguration

    public init(configuration: AirPodsPosturePipelineConfiguration = AirPodsPosturePipelineConfiguration()) {
        self.configuration = configuration
        signalGuard = MotionSignalGuard(configuration: configuration.signalGuard)
        postureDetector = PostureDetector(configuration: configuration.postureDetector)
        postureEpisodeDetector = PostureEpisodeDetector(configuration: configuration.postureEpisodeDetector)
        gestureRecognizer = PostureGestureRecognizer(configuration: configuration.gestureRecognizer)
    }

    public var isCalibrated: Bool {
        calibration.isCalibrated
    }

    public var recognizerConfiguration: RecognizerConfiguration {
        get { gestureRecognizer.configuration }
        set {
            configuration.gestureRecognizer = newValue
            gestureRecognizer.configuration = newValue
        }
    }

    public func reset() {
        calibration.reset()
        calibrationFrames.removeAll(keepingCapacity: true)
        signalGuard = MotionSignalGuard(configuration: configuration.signalGuard)
        postureDetector.configuration = configuration.postureDetector
        postureDetector.reset()
        postureEpisodeDetector.configuration = configuration.postureEpisodeDetector
        postureEpisodeDetector.reset()
        gestureRecognizer.configuration = configuration.gestureRecognizer
        gestureRecognizer.reset()
    }

    public func resetRecognitionWindows() {
        signalGuard.reset()
        postureDetector.reset()
        postureEpisodeDetector.reset()
        gestureRecognizer.reset()
    }

    public func resetGestureRecognizer() {
        gestureRecognizer.reset()
    }

    public func observe(
        _ frame: HeadMotionFrame,
        recognizeGestures: Bool = true
    ) -> AirPodsPosturePipelineOutput {
        guard calibration.isCalibrated else {
            calibrationFrames.append(frame.quaternion)
            let progress = min(
                Double(calibrationFrames.count) / Double(configuration.requiredCalibrationSamples),
                1
            )

            guard calibrationFrames.count >= configuration.requiredCalibrationSamples,
                  let baseline = HeadsetQuaternion.average(calibrationFrames) else {
                return .calibrating(progress: progress, timestamp: frame.timestamp)
            }

            calibration.calibrate(with: baseline)
            calibrationFrames.removeAll(keepingCapacity: true)
            return .calibrated(timestamp: frame.timestamp)
        }

        guard let rawSample = calibration.sample(
            from: frame.quaternion,
            timestamp: frame.timestamp,
            rotationRateDegreesPerSecond: frame.rotationRateDegreesPerSecond,
            userAcceleration: frame.userAcceleration
        ) else {
            return .dropped(
                sample: PostureSample(timestamp: frame.timestamp, yaw: 0, pitch: 0, roll: 0),
                signalQuality: .spike(0)
            )
        }

        let signalObservation = signalGuard.observe(rawSample)

        switch signalObservation {
        case .accepted(let sample, let quality):
            let posture = postureDetector.observe(sample)
            let episodeEvents = postureEpisodeDetector.observe(posture)
            let gesture = recognizeGestures ? gestureRecognizer.observe(sample) : nil
            return .accepted(
                sample: sample,
                posture: posture,
                gesture: gesture,
                episodeEvents: episodeEvents,
                signalQuality: quality
            )
        case .reset(let sample, let quality):
            postureDetector.reset()
            postureEpisodeDetector.reset()
            gestureRecognizer.reset()
            return .reset(sample: sample, signalQuality: quality)
        case .dropped(let sample, let quality):
            postureDetector.reset()
            postureEpisodeDetector.reset()
            gestureRecognizer.reset()
            return .dropped(sample: sample, signalQuality: quality)
        }
    }

    public func learnGesture(kind: GestureKind, samples: [PostureSample]) -> GestureLearningResult? {
        guard samples.count >= 8 else {
            return nil
        }

        let metrics = AxisMetrics(samples: samples)
        var updatedConfiguration = gestureRecognizer.configuration
        let summary: String

        switch kind {
        case .nod:
            let axis = metrics.dominantRangeAxis
            let range = metrics.range(on: axis)
            updatedConfiguration.nodAxis = axis
            updatedConfiguration.nodMinimumRange = tunedDynamicThreshold(from: range)
            summary = "nod -> \(axis.label) range \(format(range)) deg"
        case .shake:
            let axis = metrics.dominantRangeAxis
            let range = metrics.range(on: axis)
            updatedConfiguration.shakeAxis = axis
            updatedConfiguration.shakeMinimumRange = tunedDynamicThreshold(from: range)
            summary = "shake -> \(axis.label) range \(format(range)) deg"
        case .tiltLeft, .tiltRight:
            let axis = metrics.dominantOffsetAxis
            let mean = metrics.meanTailOffset(on: axis)
            let sign = mean < 0 ? -1.0 : 1.0
            let offset = abs(mean)
            updatedConfiguration.tiltAxis = axis
            updatedConfiguration.tiltLeftSign = kind == .tiltLeft ? sign : -sign
            updatedConfiguration.tiltMinimumOffset = max(7, min(24, offset * 0.55))
            updatedConfiguration.tiltNeutralOffset = max(4, updatedConfiguration.tiltMinimumOffset * 0.42)
            summary = "\(kind.label) -> \(axis.label) offset \(format(mean)) deg"
        }

        recognizerConfiguration = updatedConfiguration
        if kind == .nod || kind == .shake {
            gestureRecognizer.learnTemplate(for: kind, samples: samples)
        }
        gestureRecognizer.reset()

        return GestureLearningResult(configuration: updatedConfiguration, summary: summary)
    }

    private func tunedDynamicThreshold(from range: Double) -> Double {
        max(6, min(24, range * 0.45))
    }
}

private struct AxisMetrics {
    var samples: [PostureSample]

    var dominantRangeAxis: PostureAxis {
        PostureAxis.allCases.max { range(on: $0) < range(on: $1) } ?? .yaw
    }

    var dominantOffsetAxis: PostureAxis {
        PostureAxis.allCases.max { abs(meanTailOffset(on: $0)) < abs(meanTailOffset(on: $1)) } ?? .yaw
    }

    func range(on axis: PostureAxis) -> Double {
        let values = samples.map { $0.value(on: axis) }
        guard let min = values.min(), let max = values.max() else {
            return 0
        }

        return max - min
    }

    func meanTailOffset(on axis: PostureAxis) -> Double {
        let tailCount = max(1, samples.count / 2)
        let tail = samples.suffix(tailCount)
        let total = tail.reduce(0) { $0 + $1.value(on: axis) }
        return total / Double(tail.count)
    }
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}
