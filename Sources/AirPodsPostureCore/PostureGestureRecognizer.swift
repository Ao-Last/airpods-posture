import Foundation

public struct RecognizerConfiguration: Equatable, Sendable {
    public var dynamicWindow: TimeInterval
    public var cooldown: TimeInterval
    public var nodAxis: PostureAxis
    public var shakeAxis: PostureAxis
    public var tiltAxis: PostureAxis
    public var tiltLeftSign: Double
    public var nodMinimumRange: Double
    public var shakeMinimumRange: Double
    public var dynamicNoiseFloor: Double
    public var minimumDynamicConfidence: Double
    public var tiltMinimumOffset: Double
    public var tiltHoldDuration: TimeInterval
    public var tiltNeutralOffset: Double
    public var tiltMaximumCrossAxis: Double
    public var segmentStartAngularSpeed: Double
    public var segmentEndAngularSpeed: Double
    public var segmentEndReturnOffset: Double
    public var segmentQuietDuration: TimeInterval
    public var segmentMinimumDuration: TimeInterval
    public var segmentMaximumDuration: TimeInterval
    public var segmentMinimumSamples: Int

    public init(
        dynamicWindow: TimeInterval = 0.9,
        cooldown: TimeInterval = 0.65,
        nodAxis: PostureAxis = .roll,
        shakeAxis: PostureAxis = .yaw,
        tiltAxis: PostureAxis = .pitch,
        tiltLeftSign: Double = -1,
        nodMinimumRange: Double = 11,
        shakeMinimumRange: Double = 13,
        dynamicNoiseFloor: Double = 1.2,
        minimumDynamicConfidence: Double = 0.58,
        tiltMinimumOffset: Double = 16,
        tiltHoldDuration: TimeInterval = 0.24,
        tiltNeutralOffset: Double = 7,
        tiltMaximumCrossAxis: Double = 14,
        segmentStartAngularSpeed: Double = 42,
        segmentEndAngularSpeed: Double = 18,
        segmentEndReturnOffset: Double = 6,
        segmentQuietDuration: TimeInterval = 0.10,
        segmentMinimumDuration: TimeInterval = 0.16,
        segmentMaximumDuration: TimeInterval = 1.05,
        segmentMinimumSamples: Int = 5
    ) {
        self.dynamicWindow = dynamicWindow
        self.cooldown = cooldown
        self.nodAxis = nodAxis
        self.shakeAxis = shakeAxis
        self.tiltAxis = tiltAxis
        self.tiltLeftSign = tiltLeftSign == 0 ? -1 : (tiltLeftSign < 0 ? -1 : 1)
        self.nodMinimumRange = nodMinimumRange
        self.shakeMinimumRange = shakeMinimumRange
        self.dynamicNoiseFloor = dynamicNoiseFloor
        self.minimumDynamicConfidence = minimumDynamicConfidence
        self.tiltMinimumOffset = tiltMinimumOffset
        self.tiltHoldDuration = tiltHoldDuration
        self.tiltNeutralOffset = tiltNeutralOffset
        self.tiltMaximumCrossAxis = tiltMaximumCrossAxis
        self.segmentStartAngularSpeed = segmentStartAngularSpeed
        self.segmentEndAngularSpeed = segmentEndAngularSpeed
        self.segmentEndReturnOffset = segmentEndReturnOffset
        self.segmentQuietDuration = segmentQuietDuration
        self.segmentMinimumDuration = segmentMinimumDuration
        self.segmentMaximumDuration = segmentMaximumDuration
        self.segmentMinimumSamples = max(3, segmentMinimumSamples)
    }
}

public final class PostureGestureRecognizer {
    private var samples: [PostureSample] = []
    private var segmenter = GestureSegmenter()
    private var learnedTemplates: [GestureKind: DynamicGestureTemplate] = [:]
    private var lastEventTimestamp: TimeInterval = -.infinity
    private var tiltCandidate: TiltCandidate?
    private var activeTilt: GestureKind?

    public var configuration: RecognizerConfiguration

    public init(configuration: RecognizerConfiguration = RecognizerConfiguration()) {
        self.configuration = configuration
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
        segmenter.reset()
        lastEventTimestamp = -.infinity
        tiltCandidate = nil
        activeTilt = nil
    }

    public func learnTemplate(for kind: GestureKind, samples: [PostureSample]) {
        guard kind == .nod || kind == .shake,
              samples.count >= configuration.segmentMinimumSamples else {
            return
        }

        let stats = WindowStats(samples: samples)
        let axis = stats.dominantRangeAxis
        guard let values = normalizedSeries(samples.map { $0.value(on: axis) }) else {
            return
        }

        learnedTemplates[kind] = DynamicGestureTemplate(kind: kind, axis: axis, values: resampled(values, count: 16))
    }

    public func observe(_ sample: PostureSample) -> GestureEvent? {
        samples.append(sample)
        pruneSamples(now: sample.timestamp)

        if sample.timestamp - lastEventTimestamp < configuration.cooldown {
            updateTiltReset(using: sample)
            _ = segmenter.observe(sample, configuration: configuration)
            return nil
        }

        if let tilt = detectTilt(using: sample) {
            return emit(tilt)
        }

        if let segment = segmenter.observe(sample, configuration: configuration),
           let dynamic = classifyDynamicSamples(segment.samples, timestamp: sample.timestamp, source: "segment") {
            return emit(dynamic)
        }

        guard !segmenter.isActive else {
            return nil
        }

        if let dynamic = detectDynamicGesture(now: sample.timestamp) {
            return emit(dynamic)
        }

        return nil
    }

    private func emit(_ event: GestureEvent) -> GestureEvent {
        lastEventTimestamp = event.timestamp
        samples.removeAll(keepingCapacity: true)
        segmenter.reset()

        if event.kind == .tiltLeft || event.kind == .tiltRight {
            activeTilt = event.kind
        }

        return event
    }

    private func pruneSamples(now: TimeInterval) {
        let oldest = now - max(configuration.dynamicWindow, configuration.tiltHoldDuration) - 0.1
        samples.removeAll { $0.timestamp < oldest }
    }

    private func updateTiltReset(using sample: PostureSample) {
        if abs(sample.value(on: configuration.tiltAxis)) < configuration.tiltNeutralOffset {
            activeTilt = nil
            tiltCandidate = nil
        }
    }

    private func detectTilt(using sample: PostureSample) -> GestureEvent? {
        updateTiltReset(using: sample)

        let tiltValue = sample.value(on: configuration.tiltAxis)
        guard abs(tiltValue) >= configuration.tiltMinimumOffset else {
            return nil
        }

        let crossAxisMaximum = PostureAxis.allCases
            .filter { $0 != configuration.tiltAxis }
            .map { abs(sample.value(on: $0)) }
            .max() ?? 0
        guard crossAxisMaximum <= configuration.tiltMaximumCrossAxis else {
            tiltCandidate = nil
            return nil
        }

        let kind: GestureKind = tiltValue * configuration.tiltLeftSign > 0 ? .tiltLeft : .tiltRight
        guard activeTilt != kind else {
            return nil
        }

        if tiltCandidate?.kind != kind {
            tiltCandidate = TiltCandidate(
                kind: kind,
                startedAt: sample.timestamp,
                peakOffset: abs(tiltValue)
            )
            return nil
        }

        guard var tiltCandidate else {
            return nil
        }

        tiltCandidate.peakOffset = max(tiltCandidate.peakOffset, abs(tiltValue))
        self.tiltCandidate = tiltCandidate

        let heldFor = sample.timestamp - tiltCandidate.startedAt
        guard heldFor >= configuration.tiltHoldDuration else {
            return nil
        }

        let amplitude = tiltCandidate.peakOffset
        let confidence = clamp((amplitude - configuration.tiltMinimumOffset) / 12 + 0.62, lower: 0, upper: 0.98)
        return GestureEvent(
            kind: kind,
            confidence: confidence,
            amplitudeDegrees: amplitude,
            duration: heldFor,
            timestamp: sample.timestamp,
            debugSummary: "\(configuration.tiltAxis.label) \(format(amplitude)) deg held \(format(heldFor))s"
        )
    }

    private func detectDynamicGesture(now: TimeInterval) -> GestureEvent? {
        let recent = samples.filter { now - $0.timestamp <= configuration.dynamicWindow }
        guard recent.count >= configuration.segmentMinimumSamples else {
            return nil
        }

        return classifyDynamicSamples(recent, timestamp: now, source: "window")
    }

    private func classifyDynamicSamples(
        _ samples: [PostureSample],
        timestamp: TimeInterval,
        source: String
    ) -> GestureEvent? {
        guard samples.count >= configuration.segmentMinimumSamples,
              let first = samples.first,
              let last = samples.last else {
            return nil
        }

        let stats = WindowStats(samples: samples)
        let nod = dynamicCandidate(
            kind: .nod,
            axis: configuration.nodAxis,
            samples: samples,
            stats: stats,
            minimumRange: configuration.nodMinimumRange
        )
        let shake = dynamicCandidate(
            kind: .shake,
            axis: configuration.shakeAxis,
            samples: samples,
            stats: stats,
            minimumRange: configuration.shakeMinimumRange
        )

        let duration = last.timestamp - first.timestamp
        let best: DynamicCandidate
        let runnerUp: DynamicCandidate
        if nod.score >= shake.score {
            best = nod
            runnerUp = shake
        } else {
            best = shake
            runnerUp = nod
        }

        guard best.score >= configuration.minimumDynamicConfidence,
              best.score > runnerUp.score + 0.04 else {
            return nil
        }

        return GestureEvent(
            kind: best.kind,
            confidence: best.score,
            amplitudeDegrees: best.range,
            duration: duration,
            timestamp: timestamp,
            debugSummary: "\(source) \(best.axis.label) range \(format(best.range)) deg, dtw \(format(best.templateScore)), speed \(format(best.peakAngularSpeed)) deg/s"
        )
    }

    private func dynamicCandidate(
        kind: GestureKind,
        axis: PostureAxis,
        samples: [PostureSample],
        stats: WindowStats,
        minimumRange: Double
    ) -> DynamicCandidate {
        let values = samples.map { $0.value(on: axis) }
        let range = stats.range(on: axis)
        let reversals = reversalCount(values)
        guard range >= minimumRange, reversals >= 1 else {
            return DynamicCandidate(
                kind: kind,
                axis: axis,
                range: range,
                score: 0,
                templateScore: 0,
                reversals: reversals,
                peakAngularSpeed: peakAngularSpeed(samples: samples, axis: axis)
            )
        }

        let secondaryMax = max(stats.secondaryRangeA(for: axis), stats.secondaryRangeB(for: axis))
        let amplitudeScore = clamp((range - minimumRange) / (minimumRange * 1.15), lower: 0, upper: 1)
        let dominanceScore = clamp((range - secondaryMax) / max(range, 0.1), lower: 0, upper: 1)
        let reversalScore = clamp(Double(reversals) / 2, lower: 0, upper: 1)
        let endOffset = abs(samples.last?.value(on: axis) ?? 0)
        let returnScore = endOffset < 7 ? 1 : (endOffset < 11 ? 0.55 : 0.2)
        let peakSpeed = peakAngularSpeed(samples: samples, axis: axis)
        let velocityScore = clamp((peakSpeed - 35) / 145, lower: 0, upper: 1)
        let accelerationScore = clamp((samples.map(\.accelerationMagnitude).max() ?? 0) / 0.18, lower: 0, upper: 1)
        let templateScore = templateMatchScore(kind: kind, axis: axis, values: values)

        let score = 0.20 * templateScore
            + 0.25 * amplitudeScore
            + 0.22 * dominanceScore
            + 0.12 * reversalScore
            + 0.11 * returnScore
            + 0.08 * velocityScore
            + 0.02 * accelerationScore

        return DynamicCandidate(
            kind: kind,
            axis: axis,
            range: range,
            score: clamp(score, lower: 0, upper: 0.99),
            templateScore: templateScore,
            reversals: reversals,
            peakAngularSpeed: peakSpeed
        )
    }

    private func templateMatchScore(kind: GestureKind, axis: PostureAxis, values: [Double]) -> Double {
        guard let normalized = normalizedSeries(values) else {
            return 0
        }

        let learned = learnedTemplates[kind]
        let template: [Double]
        if let learned, learned.axis == axis {
            template = learned.values
        } else {
            template = Self.defaultTemplate
        }

        let prepared = resampled(normalized, count: 16)
        let forward = dynamicTimeWarpingDistance(prepared, template)
        let inverse = dynamicTimeWarpingDistance(prepared, template.map { -$0 })
        let distance = min(forward, inverse)

        return clamp(1 - distance / 0.55, lower: 0, upper: 1)
    }

    private func reversalCount(_ values: [Double]) -> Int {
        guard values.count >= 3 else {
            return 0
        }

        var previousSign = 0
        var reversals = 0

        for index in 1..<values.count {
            let delta = values[index] - values[index - 1]
            guard abs(delta) >= configuration.dynamicNoiseFloor else {
                continue
            }

            let sign = delta > 0 ? 1 : -1
            if previousSign != 0, sign != previousSign {
                reversals += 1
            }
            previousSign = sign
        }

        return reversals
    }

    private func peakAngularSpeed(samples: [PostureSample], axis: PostureAxis) -> Double {
        var peak = samples.map { abs($0.angularVelocity(on: axis)) }.max() ?? 0

        for index in 1..<samples.count {
            let current = samples[index]
            let previous = samples[index - 1]
            let deltaTime = current.timestamp - previous.timestamp
            guard deltaTime > 0 else {
                continue
            }

            let derivedSpeed = abs(current.value(on: axis) - previous.value(on: axis)) / deltaTime
            peak = max(peak, derivedSpeed)
        }

        return peak
    }

    private static let defaultTemplate: [Double] = [
        0.0, -0.55, -1.0, -0.62, -0.12, 0.54, 1.0, 0.42, 0.0
    ]
}

private struct GestureSegmenter {
    private var previousSample: PostureSample?
    private var activeSamples: [PostureSample] = []
    private var quietStartedAt: TimeInterval?

    var isActive: Bool {
        !activeSamples.isEmpty
    }

    mutating func reset() {
        previousSample = nil
        activeSamples.removeAll(keepingCapacity: true)
        quietStartedAt = nil
    }

    mutating func observe(_ sample: PostureSample, configuration: RecognizerConfiguration) -> GestureSegment? {
        let speed = effectiveAngularSpeed(current: sample, previous: previousSample)
        defer { previousSample = sample }

        guard !activeSamples.isEmpty else {
            if speed >= configuration.segmentStartAngularSpeed {
                if let previousSample {
                    activeSamples = [previousSample, sample]
                } else {
                    activeSamples = [sample]
                }
            }
            return nil
        }

        activeSamples.append(sample)

        guard let first = activeSamples.first else {
            return nil
        }

        let duration = sample.timestamp - first.timestamp
        if speed <= configuration.segmentEndAngularSpeed {
            if quietStartedAt == nil {
                quietStartedAt = sample.timestamp
            }
        } else {
            quietStartedAt = nil
        }

        let quietEnough = quietStartedAt.map { sample.timestamp - $0 >= configuration.segmentQuietDuration } ?? false
        let returnedToNeutral = hasReturnedToNeutral(configuration: configuration)
        let canComplete = activeSamples.count >= configuration.segmentMinimumSamples
            && duration >= configuration.segmentMinimumDuration

        if canComplete && (quietEnough || returnedToNeutral || duration >= configuration.segmentMaximumDuration) {
            let segment = GestureSegment(samples: activeSamples)
            activeSamples.removeAll(keepingCapacity: true)
            quietStartedAt = nil
            return segment
        }

        if duration >= configuration.segmentMaximumDuration {
            activeSamples.removeAll(keepingCapacity: true)
            quietStartedAt = nil
        }

        return nil
    }

    private func effectiveAngularSpeed(current: PostureSample, previous: PostureSample?) -> Double {
        let measured = current.angularSpeed
        guard measured < 1, let previous else {
            return measured
        }

        let deltaTime = current.timestamp - previous.timestamp
        guard deltaTime > 0 else {
            return 0
        }

        return PostureAxis.allCases
            .map { abs(current.value(on: $0) - previous.value(on: $0)) / deltaTime }
            .max() ?? 0
    }

    private func hasReturnedToNeutral(configuration: RecognizerConfiguration) -> Bool {
        guard activeSamples.count >= configuration.segmentMinimumSamples,
              let last = activeSamples.last else {
            return false
        }

        let dynamicAxes = Set([configuration.nodAxis, configuration.shakeAxis])
        let maxOffset = dynamicAxes
            .map { abs(last.value(on: $0)) }
            .max() ?? 0
        guard maxOffset <= configuration.segmentEndReturnOffset else {
            return false
        }

        return dynamicAxes.contains { axis in
            let values = activeSamples.map { $0.value(on: axis) }
            let excursionThreshold = axis == configuration.nodAxis
                ? configuration.nodMinimumRange * 0.25
                : configuration.shakeMinimumRange * 0.25
            return localReversalCount(values, noiseFloor: configuration.dynamicNoiseFloor) >= 1
                && hasBiphasicExcursion(values, threshold: excursionThreshold)
        }
    }
}

private struct GestureSegment {
    var samples: [PostureSample]
}

private struct DynamicGestureTemplate {
    var kind: GestureKind
    var axis: PostureAxis
    var values: [Double]
}

private struct DynamicCandidate {
    var kind: GestureKind
    var axis: PostureAxis
    var range: Double
    var score: Double
    var templateScore: Double
    var reversals: Int
    var peakAngularSpeed: Double
}

private struct TiltCandidate {
    var kind: GestureKind
    var startedAt: TimeInterval
    var peakOffset: Double
}

private struct WindowStats {
    var yawRange: Double
    var pitchRange: Double
    var rollRange: Double

    init(samples: [PostureSample]) {
        yawRange = Self.range(samples.map(\.yaw))
        pitchRange = Self.range(samples.map(\.pitch))
        rollRange = Self.range(samples.map(\.roll))
    }

    var dominantRangeAxis: PostureAxis {
        PostureAxis.allCases.max { range(on: $0) < range(on: $1) } ?? .yaw
    }

    func range(on axis: PostureAxis) -> Double {
        switch axis {
        case .yaw:
            yawRange
        case .pitch:
            pitchRange
        case .roll:
            rollRange
        }
    }

    func secondaryRangeA(for axis: PostureAxis) -> Double {
        PostureAxis.allCases.filter { $0 != axis }.first.map { range(on: $0) } ?? 0
    }

    func secondaryRangeB(for axis: PostureAxis) -> Double {
        let otherAxes = PostureAxis.allCases.filter { $0 != axis }
        guard otherAxes.count > 1 else {
            return 0
        }

        return range(on: otherAxes[1])
    }

    private static func range(_ values: [Double]) -> Double {
        guard let min = values.min(), let max = values.max() else {
            return 0
        }

        return max - min
    }
}

private func normalizedSeries(_ values: [Double]) -> [Double]? {
    guard let min = values.min(),
          let max = values.max(),
          max - min > 0.01 else {
        return nil
    }

    let mid = (min + max) / 2
    let halfRange = (max - min) / 2
    return values.map { clamp(($0 - mid) / halfRange, lower: -1, upper: 1) }
}

private func resampled(_ values: [Double], count: Int) -> [Double] {
    guard count > 1,
          values.count > 1 else {
        return values
    }

    let step = Double(values.count - 1) / Double(count - 1)
    return (0..<count).map { outputIndex in
        let source = Double(outputIndex) * step
        let lower = Int(floor(source))
        let upper = min(values.count - 1, lower + 1)
        let ratio = source - Double(lower)
        return values[lower] + (values[upper] - values[lower]) * ratio
    }
}

private func dynamicTimeWarpingDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else {
        return .infinity
    }

    var previous = Array(repeating: Double.infinity, count: rhs.count + 1)
    previous[0] = 0

    for leftIndex in 1...lhs.count {
        var current = Array(repeating: Double.infinity, count: rhs.count + 1)
        for rightIndex in 1...rhs.count {
            let cost = abs(lhs[leftIndex - 1] - rhs[rightIndex - 1])
            current[rightIndex] = cost + min(previous[rightIndex], current[rightIndex - 1], previous[rightIndex - 1])
        }
        previous = current
    }

    return previous[rhs.count] / Double(lhs.count + rhs.count)
}

private func localReversalCount(_ values: [Double], noiseFloor: Double) -> Int {
    guard values.count >= 3 else {
        return 0
    }

    var previousSign = 0
    var reversals = 0

    for index in 1..<values.count {
        let delta = values[index] - values[index - 1]
        guard abs(delta) >= noiseFloor else {
            continue
        }

        let sign = delta > 0 ? 1 : -1
        if previousSign != 0, sign != previousSign {
            reversals += 1
        }
        previousSign = sign
    }

    return reversals
}

private func hasBiphasicExcursion(_ values: [Double], threshold: Double) -> Bool {
    guard let min = values.min(), let max = values.max() else {
        return false
    }

    return min <= -threshold && max >= threshold
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}
