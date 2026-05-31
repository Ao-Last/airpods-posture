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
    private let pipeline = AirPodsPosturePipeline()
    private let sounds = SoundFeedback()
    private var latestFrame: HeadMotionFrame?
    private var processedFrameTimestamp: TimeInterval = -.infinity
    private var processingTimer: DispatchSourceTimer?
    private var recordingSession: GestureRecordingSession?
    private var eventToken = UUID()
    private var lastUIPublishTimestamp = 0.0
    private var sampleRateWindowStart = 0.0
    private var sampleRateCount = 0
    private var uiUpdatePending = false
    private var lastSignalQualityLabel = ""
    private var lastSignalQualityPublishTimestamp = 0.0
    private var lastSoundedPosture: PostureKind = .neutral
    private var lastPostureSoundTimestamp: TimeInterval = -.infinity
    private let recordingDuration: TimeInterval = 1.35
    private let postureSoundCooldown: TimeInterval = 0.12
    private let postureSoundNeutralThreshold = 5.5
    private let postureSoundMotionSpeedThreshold = 60.0

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
            self.pipeline.resetGestureRecognizer()
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
        let frame = HeadMotionFrame(
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

    private func handle(_ frame: HeadMotionFrame) {
        let output = pipeline.observe(frame, recognizeGestures: recordingSession == nil)

        switch output {
        case .calibrating(let progress, let timestamp):
            publishCalibrationProgress(progress, timestamp: timestamp)

        case .calibrated:
            DispatchQueue.main.async {
                self.isCalibrated = true
                self.calibrationProgress = 1
                self.updateStatus("Ready. Try nod, shake, tilt left, or tilt right.", color: .green)
                self.sounds.play(.calibrated)
            }

        case .accepted(let sample, let posture, let event, let quality):
            publishSignalQuality(quality, timestamp: sample.timestamp)
            processAcceptedSample(sample, posture: posture, event: event)
        case .reset(let sample, let quality):
            publishSignalQuality(quality, timestamp: sample.timestamp)
            cancelRecordingForSignalIfNeeded(quality.debugSummary)
            publishSample(sample, event: nil)
        case .dropped(_, let quality):
            publishSignalQuality(quality, timestamp: frame.timestamp)
            cancelRecordingForSignalIfNeeded(quality.debugSummary)
        }
    }

    private func processAcceptedSample(
        _ sample: PostureSample,
        posture: PostureSnapshot,
        event: GestureEvent?
    ) {
        if consumeRecordingSample(sample) {
            publishSample(sample, event: nil, posture: posture)
            return
        }

        if event == nil {
            playPostureSoundIfNeeded(sample: sample)
        }

        publishSample(sample, event: event, posture: posture)
    }

    private func resetPipeline() {
        pipeline.reset()
        lastUIPublishTimestamp = 0
        sampleRateWindowStart = 0
        sampleRateCount = 0
        processedFrameTimestamp = -.infinity
        recordingSession = nil
        uiUpdatePending = false
        lastSignalQualityLabel = ""
        lastSignalQualityPublishTimestamp = 0
        lastSoundedPosture = .neutral
        lastPostureSoundTimestamp = -.infinity
    }

    private func playPostureSoundIfNeeded(sample: PostureSample) {
        guard let candidate = postureSoundCandidate(for: sample) else {
            if isNeutralEnoughForPostureSoundReset(sample) {
                lastSoundedPosture = .neutral
            }
            return
        }

        guard candidate.kind != lastSoundedPosture,
              sample.timestamp - lastPostureSoundTimestamp >= postureSoundCooldown else {
            return
        }

        lastSoundedPosture = candidate.kind
        lastPostureSoundTimestamp = sample.timestamp
        sounds.play(
            .posture(
                PostureSoundCue(
                    kind: candidate.kind,
                    offsetDegrees: candidate.offsetDegrees,
                    angularSpeed: sample.angularSpeed,
                    accelerationMagnitude: sample.accelerationMagnitude
                )
            )
        )
    }

    private func postureSoundCandidate(for sample: PostureSample) -> PostureSoundCandidate? {
        let options = [
            postureSoundOption(
                positiveKind: .headDown,
                negativeKind: .headUp,
                signedValue: -sample.roll,
                threshold: 14,
                axis: .roll,
                sample: sample,
                allowsVelocityOnset: false
            ),
            postureSoundOption(
                positiveKind: .turnedLeft,
                negativeKind: .turnedRight,
                signedValue: sample.yaw,
                threshold: 9,
                axis: .yaw,
                sample: sample,
                allowsVelocityOnset: true
            ),
            postureSoundOption(
                positiveKind: .tiltedLeft,
                negativeKind: .tiltedRight,
                signedValue: -sample.pitch,
                threshold: 8,
                axis: .pitch,
                sample: sample,
                allowsVelocityOnset: true
            )
        ]

        return options.compactMap { $0 }.max { $0.score < $1.score }
    }

    private func postureSoundOption(
        positiveKind: PostureKind,
        negativeKind: PostureKind,
        signedValue: Double,
        threshold: Double,
        axis: PostureAxis,
        sample: PostureSample,
        allowsVelocityOnset: Bool
    ) -> PostureSoundCandidate? {
        let offset = abs(signedValue)
        let speed = abs(sample.angularVelocity(on: axis))
        let hasEnoughOffset = offset >= threshold
        let hasFastOnset = allowsVelocityOnset
            && offset >= postureSoundNeutralThreshold
            && speed >= postureSoundMotionSpeedThreshold

        guard hasEnoughOffset || hasFastOnset else {
            return nil
        }

        let speedScore = min(speed / postureSoundMotionSpeedThreshold, 2) * 0.15
        return PostureSoundCandidate(
            kind: signedValue >= 0 ? positiveKind : negativeKind,
            offsetDegrees: max(offset, threshold),
            score: offset / threshold + speedScore
        )
    }

    private func isNeutralEnoughForPostureSoundReset(_ sample: PostureSample) -> Bool {
        let maxOffset = max(abs(sample.yaw), abs(sample.pitch), abs(sample.roll))
        return maxOffset <= postureSoundNeutralThreshold
            && sample.angularSpeed < postureSoundMotionSpeedThreshold
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

        guard let learningResult = pipeline.learnGesture(kind: session.kind, samples: session.samples) else {
            DispatchQueue.main.async {
                self.recordingGesture = nil
                self.recordingProgress = 0
                self.updateStatus("Recording could not be learned. Try again.", color: .orange)
                self.sounds.play(.error)
            }
            return
        }

        DispatchQueue.main.async {
            self.recordingGesture = nil
            self.recordingProgress = 0
            self.calibrationProfileSummary = self.profileSummary(for: learningResult.configuration)
            self.lastDebugSummary = learningResult.summary
            self.updateStatus("Learned \(session.kind.label).", color: .green)
            self.sounds.play(.calibrated)
        }
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

private struct GestureRecordingSession {
    var kind: GestureKind
    var startedAt: TimeInterval?
    var samples: [PostureSample] = []
}

private struct PostureSoundCandidate {
    var kind: PostureKind
    var offsetDegrees: Double
    var score: Double
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
