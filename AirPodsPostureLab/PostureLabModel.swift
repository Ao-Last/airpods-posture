import CoreMotion
import SwiftUI

final class PostureLabModel: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate, @unchecked Sendable {
    @Published var status = "Starting"
    @Published var authorizationLabel = "authorization: unknown"
    @Published var calibrationProgress = 0.0
    @Published var isCalibrated = false
    @Published var isRunning = false
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0
    @Published var lastGesture: GestureKind?
    @Published var lastConfidence = 0.0
    @Published var lastDebugSummary = "no gesture yet"
    @Published var sampleRateLabel = "0 Hz"
    @Published var signalQualityLabel = "signal: waiting"
    @Published var currentPosture: PostureKind = .neutral
    @Published var postureConfidence = 0.0
    @Published var postureOffset = 0.0
    @Published var postureHeldDurationLabel = "0.0s"
    @Published var postureDebugSummary = "neutral"
    @Published var recordingGesture: GestureKind?
    @Published var recordingProgress = 0.0
    @Published var calibrationProfileSummary = "nod roll | shake yaw | tilt pitch"
    @Published var statusColor: Color = .secondary

    private let manager = CMHeadphoneMotionManager()
    private let motionDeliveryQueue = OperationQueue()
    private let processingQueue = DispatchQueue(label: "dev.airpods-posture.lab.app.processing", qos: .userInteractive)
    private let latestFrameLock = NSLock()
    private let calibration = MotionCalibration()
    private let recognizer = PostureGestureRecognizer()
    private let postureDetector = PostureDetector()
    private let sounds = SoundFeedback()
    private var motionSignalGuard = MotionSignalGuard()
    private var latestFrame: MotionFrame?
    private var processedFrameTimestamp: TimeInterval = -.infinity
    private var processingTimer: DispatchSourceTimer?
    private var recordingSession: GestureRecordingSession?
    private var calibrationFrames: [HeadsetQuaternion] = []
    private var eventToken = UUID()
    private var lastUIPublishTimestamp = 0.0
    private var sampleRateWindowStart = 0.0
    private var sampleRateCount = 0
    private var uiUpdatePending = false
    private var lastSignalQualityLabel = ""
    private var lastSignalQualityPublishTimestamp = 0.0
    private let recordingDuration: TimeInterval = 1.35

    override init() {
        motionDeliveryQueue.name = "dev.airpods-posture.lab.app.motion-delivery"
        motionDeliveryQueue.maxConcurrentOperationCount = 1
        motionDeliveryQueue.qualityOfService = .userInteractive
        super.init()
        manager.delegate = self
    }

    func start() {
        guard !isRunning else {
            return
        }

        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        authorizationLabel = "authorization: \(authorization.label)"

        guard authorization != .denied, authorization != .restricted else {
            updateStatus("Motion permission is \(authorization.label). Enable it in System Settings.", color: .red)
            sounds.play(.error)
            return
        }

        isRunning = true
        updateStatus("Hold your head naturally while calibration starts.", color: .secondary)
        sounds.play(.armed)
        startProcessingLoop()
        manager.startConnectionStatusUpdates()
        manager.startDeviceMotionUpdates(to: motionDeliveryQueue) { [weak self] motion, error in
            guard let self else {
                return
            }

            if let error {
                DispatchQueue.main.async {
                    self.updateStatus("Motion error: \(error.localizedDescription)", color: .red)
                    self.sounds.play(.error)
                }
                return
            }

            guard let motion else {
                return
            }

            self.storeLatestFrame(from: motion)
        }
    }

    func stop() {
        guard isRunning else {
            return
        }

        isRunning = false
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        stopProcessingLoop()
        updateStatus("Stopped", color: .secondary)
    }

    func resetCalibration() {
        isCalibrated = false
        calibrationProgress = 0
        lastGesture = nil
        sampleRateLabel = "0 Hz"
        signalQualityLabel = "signal: calibrating"
        currentPosture = .neutral
        postureConfidence = 0
        postureOffset = 0
        postureHeldDurationLabel = "0.0s"
        postureDebugSummary = "neutral"
        recordingGesture = nil
        recordingProgress = 0
        updateStatus("Recalibrating. Hold your head naturally.", color: .secondary)
        sounds.play(.armed)

        clearLatestFrame()
        processingQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.resetPipeline()
        }
    }

    func startRecording(_ gesture: GestureKind) {
        guard isCalibrated else {
            updateStatus("Calibrate neutral posture first.", color: .orange)
            sounds.play(.error)
            return
        }

        recordingGesture = gesture
        recordingProgress = 0
        updateStatus("Recording \(gesture.label). Move naturally once.", color: .secondary)
        sounds.play(.armed)

        processingQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.recordingSession = GestureRecordingSession(kind: gesture)
            self.recognizer.reset()
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.updateStatus("AirPods motion connected. Calibrating neutral posture.", color: .green)
            self.sounds.play(.connected)
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async {
            self.isCalibrated = false
            self.calibrationProgress = 0
            self.sampleRateLabel = "0 Hz"
            self.signalQualityLabel = "signal: disconnected"
            self.currentPosture = .neutral
            self.postureConfidence = 0
            self.postureOffset = 0
            self.postureHeldDurationLabel = "0.0s"
            self.postureDebugSummary = "neutral"
            self.recordingGesture = nil
            self.recordingProgress = 0
            self.updateStatus("AirPods motion disconnected.", color: .orange)
            self.sounds.play(.disconnected)
        }

        clearLatestFrame()
        processingQueue.async { [weak self] in
            self?.resetPipeline()
        }
    }

    private func storeLatestFrame(from motion: CMDeviceMotion) {
        let frame = MotionFrame(
            timestamp: motion.timestamp,
            quaternion: HeadsetQuaternion(
                w: motion.attitude.quaternion.w,
                x: motion.attitude.quaternion.x,
                y: motion.attitude.quaternion.y,
                z: motion.attitude.quaternion.z
            ),
            rotationRateDegreesPerSecond: MotionVector(
                x: motion.rotationRate.x * 180 / .pi,
                y: motion.rotationRate.y * 180 / .pi,
                z: motion.rotationRate.z * 180 / .pi
            ),
            userAcceleration: MotionVector(
                x: motion.userAcceleration.x,
                y: motion.userAcceleration.y,
                z: motion.userAcceleration.z
            )
        )

        latestFrameLock.withLock {
            if let latestFrame, latestFrame.timestamp > frame.timestamp {
                return
            }

            latestFrame = frame
        }
    }

    private func clearLatestFrame() {
        latestFrameLock.withLock {
            latestFrame = nil
        }
    }

    private func startProcessingLoop() {
        stopProcessingLoop()
        resetPipeline()

        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.processLatestFrame()
        }
        processingTimer = timer
        timer.resume()
    }

    private func stopProcessingLoop() {
        processingTimer?.cancel()
        processingTimer = nil
        clearLatestFrame()
    }

    private func processLatestFrame() {
        guard let frame = latestFrameLock.withLock({ latestFrame }),
              frame.timestamp > processedFrameTimestamp else {
            return
        }

        processedFrameTimestamp = frame.timestamp
        handle(frame)
    }

    private func handle(_ frame: MotionFrame) {
        let quaternion = frame.quaternion

        if !calibration.isCalibrated {
            calibrationFrames.append(quaternion)
            let progress = min(Double(calibrationFrames.count) / 32, 1)
            publishCalibrationProgress(progress, timestamp: frame.timestamp)

            guard calibrationFrames.count >= 32,
                  let baseline = HeadsetQuaternion.average(calibrationFrames) else {
                return
            }

            calibration.calibrate(with: baseline)
            calibrationFrames.removeAll(keepingCapacity: true)
            DispatchQueue.main.async {
                self.isCalibrated = true
                self.calibrationProgress = 1
                self.updateStatus("Ready. Try nod, shake, tilt left, or tilt right.", color: .green)
                self.sounds.play(.calibrated)
            }
            return
        }

        guard let rawSample = calibration.sample(
            from: quaternion,
            timestamp: frame.timestamp,
            rotationRateDegreesPerSecond: frame.rotationRateDegreesPerSecond,
            userAcceleration: frame.userAcceleration
        ) else {
            return
        }

        let signalObservation = motionSignalGuard.observe(rawSample)
        publishSignalQuality(signalObservation.quality, timestamp: rawSample.timestamp)

        switch signalObservation {
        case .accepted(let sample, _):
            processAcceptedSample(sample)
        case .reset(let sample, let quality):
            recognizer.reset()
            postureDetector.reset()
            cancelRecordingForSignalIfNeeded(quality.debugSummary)
            publishSample(sample, event: nil)
        case .dropped(_, let quality):
            recognizer.reset()
            postureDetector.reset()
            cancelRecordingForSignalIfNeeded(quality.debugSummary)
        }
    }

    private func processAcceptedSample(_ sample: PostureSample) {
        let posture = postureDetector.observe(sample)

        if consumeRecordingSample(sample) {
            publishSample(sample, event: nil, posture: posture)
            return
        }

        let event = recognizer.observe(sample)
        publishSample(sample, event: event, posture: posture)
    }

    private func resetPipeline() {
        calibration.reset()
        recognizer.reset()
        postureDetector.reset()
        motionSignalGuard.reset()
        calibrationFrames.removeAll(keepingCapacity: true)
        lastUIPublishTimestamp = 0
        sampleRateWindowStart = 0
        sampleRateCount = 0
        processedFrameTimestamp = -.infinity
        recordingSession = nil
        uiUpdatePending = false
        lastSignalQualityLabel = ""
        lastSignalQualityPublishTimestamp = 0
    }

    private func publishCalibrationProgress(_ progress: Double, timestamp: TimeInterval) {
        guard shouldPublishUI(timestamp: timestamp) else {
            return
        }

        DispatchQueue.main.async {
            self.calibrationProgress = progress
            self.updateStatus("Calibrating neutral posture.", color: .secondary)
        }
    }

    private func publishSample(
        _ sample: PostureSample,
        event: GestureEvent?,
        posture: PostureSnapshot? = nil
    ) {
        let sampleRateLabel = updateSampleRate(timestamp: sample.timestamp)
        let shouldPublishPose = event != nil || shouldPublishUI(timestamp: sample.timestamp)

        guard shouldPublishPose || sampleRateLabel != nil else {
            return
        }

        guard event != nil || !uiUpdatePending else {
            return
        }

        uiUpdatePending = true
        DispatchQueue.main.async {
            if shouldPublishPose {
                self.yaw = sample.yaw
                self.pitch = sample.pitch
                self.roll = sample.roll
            }

            if let sampleRateLabel {
                self.sampleRateLabel = sampleRateLabel
            }

            if let posture, shouldPublishPose {
                self.currentPosture = posture.kind
                self.postureConfidence = posture.confidence
                self.postureOffset = posture.offsetDegrees
                self.postureHeldDurationLabel = String(format: "%.1fs", posture.heldDuration)
                self.postureDebugSummary = posture.debugSummary
            }

            if let event {
                self.lastGesture = event.kind
                self.lastConfidence = event.confidence
                self.lastDebugSummary = event.debugSummary
                self.updateStatus("\(event.kind.label.capitalized) recognized", color: .green)
                self.sounds.play(.gesture(event.kind))
                self.clearGestureAfterDelay()
            }

            self.processingQueue.async {
                self.uiUpdatePending = false
            }
        }
    }

    private func shouldPublishUI(timestamp: TimeInterval) -> Bool {
        guard timestamp - lastUIPublishTimestamp >= 1.0 / 15.0 else {
            return false
        }

        lastUIPublishTimestamp = timestamp
        return true
    }

    private func updateSampleRate(timestamp: TimeInterval) -> String? {
        if sampleRateWindowStart == 0 {
            sampleRateWindowStart = timestamp
        }

        sampleRateCount += 1
        let elapsed = timestamp - sampleRateWindowStart
        guard elapsed >= 1 else {
            return nil
        }

        let rate = Double(sampleRateCount) / elapsed
        sampleRateWindowStart = timestamp
        sampleRateCount = 0
        return String(format: "%.0f Hz", rate)
    }

    private func publishSignalQuality(_ quality: MotionSignalQuality, timestamp: TimeInterval) {
        guard quality.label != lastSignalQualityLabel
            || timestamp - lastSignalQualityPublishTimestamp >= 1 else {
            return
        }

        lastSignalQualityLabel = quality.label
        lastSignalQualityPublishTimestamp = timestamp

        DispatchQueue.main.async {
            self.signalQualityLabel = quality.label

            guard quality.shouldSurface else {
                return
            }

            self.lastDebugSummary = quality.debugSummary
            if self.isRunning, self.isCalibrated {
                self.updateStatus(quality.statusText, color: .orange)
            }
        }
    }

    private func cancelRecordingForSignalIfNeeded(_ reason: String) {
        guard recordingSession != nil else {
            return
        }

        recordingSession = nil
        DispatchQueue.main.async {
            self.recordingGesture = nil
            self.recordingProgress = 0
            self.lastDebugSummary = reason
            self.updateStatus("Recording interrupted by signal quality.", color: .orange)
            self.sounds.play(.error)
        }
    }

    private func consumeRecordingSample(_ sample: PostureSample) -> Bool {
        guard var session = recordingSession else {
            return false
        }

        if session.startedAt == nil {
            session.startedAt = sample.timestamp
        }

        session.samples.append(sample)
        recordingSession = session

        let elapsed = sample.timestamp - (session.startedAt ?? sample.timestamp)
        let progress = min(max(elapsed / recordingDuration, 0), 1)
        publishRecordingProgress(progress, kind: session.kind, timestamp: sample.timestamp)

        if progress >= 1 {
            recordingSession = nil
            applyRecording(session)
        }

        return true
    }

    private func publishRecordingProgress(_ progress: Double, kind: GestureKind, timestamp: TimeInterval) {
        guard shouldPublishUI(timestamp: timestamp) else {
            return
        }

        DispatchQueue.main.async {
            self.recordingGesture = kind
            self.recordingProgress = progress
        }
    }

    private func applyRecording(_ session: GestureRecordingSession) {
        guard session.samples.count >= 8 else {
            DispatchQueue.main.async {
                self.recordingGesture = nil
                self.recordingProgress = 0
                self.updateStatus("Recording was too short. Try again.", color: .orange)
                self.sounds.play(.error)
            }
            return
        }

        let metrics = AxisMetrics(samples: session.samples)
        var configuration = recognizer.configuration
        var learnedText = ""

        switch session.kind {
        case .nod:
            let axis = metrics.dominantRangeAxis
            let range = metrics.range(on: axis)
            configuration.nodAxis = axis
            configuration.nodMinimumRange = tunedDynamicThreshold(from: range)
            learnedText = "nod -> \(axis.label) range \(format(range)) deg"
        case .shake:
            let axis = metrics.dominantRangeAxis
            let range = metrics.range(on: axis)
            configuration.shakeAxis = axis
            configuration.shakeMinimumRange = tunedDynamicThreshold(from: range)
            learnedText = "shake -> \(axis.label) range \(format(range)) deg"
        case .tiltLeft, .tiltRight:
            let axis = metrics.dominantOffsetAxis
            let mean = metrics.meanTailOffset(on: axis)
            let sign = mean < 0 ? -1.0 : 1.0
            let offset = abs(mean)

            configuration.tiltAxis = axis
            configuration.tiltLeftSign = session.kind == .tiltLeft ? sign : -sign
            configuration.tiltMinimumOffset = max(7, min(24, offset * 0.55))
            configuration.tiltNeutralOffset = max(4, configuration.tiltMinimumOffset * 0.42)
            learnedText = "\(session.kind.label) -> \(axis.label) offset \(format(mean)) deg"
        }

        recognizer.configuration = configuration
        if session.kind == .nod || session.kind == .shake {
            recognizer.learnTemplate(for: session.kind, samples: session.samples)
        }
        recognizer.reset()

        DispatchQueue.main.async {
            self.recordingGesture = nil
            self.recordingProgress = 0
            self.calibrationProfileSummary = self.profileSummary(for: configuration)
            self.lastDebugSummary = learnedText
            self.updateStatus("Learned \(session.kind.label).", color: .green)
            self.sounds.play(.calibrated)
        }
    }

    private func tunedDynamicThreshold(from range: Double) -> Double {
        max(6, min(24, range * 0.45))
    }

    private func profileSummary(for configuration: RecognizerConfiguration) -> String {
        "nod \(configuration.nodAxis.label) | shake \(configuration.shakeAxis.label) | tilt \(configuration.tiltAxis.label)"
    }

    private func clearGestureAfterDelay() {
        let token = UUID()
        eventToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard self.eventToken == token else {
                return
            }

            self.lastGesture = nil
            if self.isRunning, self.isCalibrated {
                self.updateStatus("Ready. Try nod, shake, tilt left, or tilt right.", color: .green)
            }
        }
    }

    private func updateStatus(_ status: String, color: Color) {
        self.status = status
        statusColor = color
        authorizationLabel = "authorization: \(CMHeadphoneMotionManager.authorizationStatus().label)"
    }
}

private struct MotionFrame: Sendable {
    var timestamp: TimeInterval
    var quaternion: HeadsetQuaternion
    var rotationRateDegreesPerSecond: MotionVector
    var userAcceleration: MotionVector
}

private struct GestureRecordingSession {
    var kind: GestureKind
    var startedAt: TimeInterval?
    var samples: [PostureSample] = []
}

private enum MotionSignalObservation {
    case accepted(PostureSample, MotionSignalQuality)
    case reset(PostureSample, MotionSignalQuality)
    case dropped(PostureSample, MotionSignalQuality)

    var quality: MotionSignalQuality {
        switch self {
        case .accepted(_, let quality),
             .reset(_, let quality),
             .dropped(_, let quality):
            quality
        }
    }
}

private struct MotionSignalQuality {
    var label: String
    var debugSummary: String
    var statusText: String
    var shouldSurface: Bool

    static let stable = MotionSignalQuality(
        label: "signal: stable",
        debugSummary: "signal stable",
        statusText: "Ready. Try nod, shake, tilt left, or tilt right.",
        shouldSurface: false
    )

    static let recovering = MotionSignalQuality(
        label: "signal: recovering",
        debugSummary: "recovering after signal gap",
        statusText: "Recovering after signal gap.",
        shouldSurface: false
    )

    static func gap(_ duration: TimeInterval) -> MotionSignalQuality {
        MotionSignalQuality(
            label: "signal: gap \(format(duration * 1_000)) ms",
            debugSummary: "signal gap \(format(duration * 1_000)) ms; gesture window reset",
            statusText: "Signal gap detected. Gesture window reset.",
            shouldSurface: true
        )
    }

    static func spike(_ degrees: Double) -> MotionSignalQuality {
        MotionSignalQuality(
            label: "signal: spike dropped",
            debugSummary: "dropped motion spike \(format(degrees)) deg",
            statusText: "Motion spike dropped.",
            shouldSurface: true
        )
    }
}

private struct MotionSignalGuard {
    private var previousRawSample: PostureSample?
    private var previousFilteredSample: PostureSample?
    private var recoveringUntil: TimeInterval = -.infinity

    private let gapThreshold: TimeInterval = 0.18
    private let recoveryDuration: TimeInterval = 0.35
    private let minimumJumpLimit = 38.0
    private let maximumJumpLimit = 95.0
    private let jumpVelocityLimit = 720.0
    private let filterTimeConstant: TimeInterval = 0.035

    mutating func reset() {
        previousRawSample = nil
        previousFilteredSample = nil
        recoveringUntil = -.infinity
    }

    mutating func observe(_ sample: PostureSample) -> MotionSignalObservation {
        guard let previousRawSample else {
            self.previousRawSample = sample
            previousFilteredSample = sample
            return .accepted(sample, .stable)
        }

        let deltaTime = sample.timestamp - previousRawSample.timestamp
        guard deltaTime > 0 else {
            return .dropped(sample, .spike(0))
        }

        if deltaTime >= gapThreshold {
            self.previousRawSample = sample
            previousFilteredSample = sample
            recoveringUntil = sample.timestamp + recoveryDuration
            return .reset(sample, .gap(deltaTime))
        }

        let jumpDegrees = maximumAxisDelta(from: previousRawSample, to: sample)
        let jumpLimit = min(
            maximumJumpLimit,
            max(minimumJumpLimit, jumpVelocityLimit * deltaTime)
        )
        if jumpDegrees > jumpLimit {
            recoveringUntil = sample.timestamp + recoveryDuration
            return .dropped(sample, .spike(jumpDegrees))
        }

        self.previousRawSample = sample

        let filteredSample: PostureSample
        if let previousFilteredSample {
            let alpha = clamp(deltaTime / (deltaTime + filterTimeConstant), lower: 0.25, upper: 0.72)
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

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private extension CMAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined:
            "not determined"
        case .restricted:
            "restricted"
        case .denied:
            "denied"
        case .authorized:
            "authorized"
        @unknown default:
            "unknown"
        }
    }
}
